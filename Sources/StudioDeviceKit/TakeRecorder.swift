#if os(iOS) && (DEBUG || STUDIO_DEVICE_CAPTURE)
import Foundation
import StudioDeviceWire
import UIKit

/// Runs one take: starts the screen capture and the touch tap together, stops
/// them together, and assembles the result.
///
/// The ordering here is the whole reason on-device capture beats the simulator
/// path. The tap timestamps touches on the host clock, the capture reports the
/// first frame's presentation time on (we believe) that same clock, and
/// rebasing one against the other lands the log on the video frame-exactly —
/// no clap marker, no correlation pass, no "potential drift" warning.
@MainActor
final class TakeRecorder {
    private let store: TakeStore
    private var capture: ScreenCapture?
    private var takeID: String?
    /// Auto-stop, so a take nobody stopped can't fill the device.
    private var deadline: Task<Void, Never>?

    private(set) var isRecording = false

    init(store: TakeStore) {
        self.store = store
    }

    func start(options: StudioDeviceRequest.RecordOptions) async throws -> String {
        guard !isRecording else {
            throw StudioDeviceResponse.Failure(.alreadyRecording,
                                               "This device is already recording.")
        }
        let id = try store.createTake()
        let capture = ScreenCapture(outputURL: store.videoURL(for: id),
                                    includeAppAudio: options.includeAppAudio)
        do {
            try await capture.start()
        } catch {
            capture.abandon()
            store.delete(id)
            throw Self.failure(from: error)
        }
        // The tap starts AFTER capture is running: a touch logged before the
        // first frame exists has no video to sit against and would rebase to a
        // negative time.
        let bounds = DeviceInfo.activeScreen?.coordinateSpace.bounds ?? .zero
        TouchTap.shared.startRecording(referenceBounds: bounds)

        self.capture = capture
        self.takeID = id
        isRecording = true

        // Keep the screen awake: a take is minutes of the user driving the app
        // with no Mac in the loop, and an idle-locked screen ends the recording.
        UIApplication.shared.isIdleTimerDisabled = true

        let limit = options.maximumDuration
        deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(limit))
            guard !Task.isCancelled else { return }
            _ = try? await self?.stop()
        }
        return id
    }

    func stop() async throws -> StudioDeviceResponse.TakeSummary {
        guard isRecording, let capture, let id = takeID else {
            throw StudioDeviceResponse.Failure(.notRecording, "No recording is running.")
        }
        isRecording = false
        deadline?.cancel()
        deadline = nil
        UIApplication.shared.isIdleTimerDisabled = false

        let anchor: TouchTake.VideoAnchor
        do {
            anchor = try await capture.stop()
        } catch {
            _ = TouchTap.shared.finishRecording(videoStart: 0)
            store.delete(id)
            self.capture = nil
            self.takeID = nil
            throw Self.failure(from: error)
        }

        let strokes = TouchTap.shared.finishRecording(videoStart: anchor.firstFramePTS)
        var screen = DeviceInfo.screen
        // Pixel size comes from the frames themselves, not from points × scale
        // — ReplayKit does not promise they match.
        if capture.pixelSize.width > 0 {
            screen.pixelWidth = Int(capture.pixelSize.width)
            screen.pixelHeight = Int(capture.pixelSize.height)
        }
        let take = TouchTake(
            strokes: strokes,
            duration: capture.duration,
            screen: screen,
            device: DeviceInfo.identity,
            video: anchor)
        try store.write(take, for: id)

        self.capture = nil
        self.takeID = nil

        return StudioDeviceResponse.TakeSummary(
            id: id,
            duration: take.duration,
            videoBytes: store.videoBytes(for: id),
            strokeCount: take.strokes.count,
            maximumConcurrentStrokes: take.maximumConcurrentStrokes,
            hasAudio: capture.wroteAudio)
    }

    /// Map capture errors onto wire failures, keeping the distinction between
    /// "the user said no" and "the system couldn't" — they need different
    /// advice, and collapsing them sends the developer to the wrong place.
    private static func failure(from error: Error) -> StudioDeviceResponse.Failure {
        if let failure = error as? StudioDeviceResponse.Failure { return failure }
        switch error as? ScreenCapture.CaptureError {
        case .denied:
            return .init(.captureDenied,
                         "Screen recording was declined on the device.")
        case .unavailable(let why):
            return .init(.captureUnavailable, why)
        case .noFrames:
            return .init(.captureUnavailable,
                         "The recording produced no frames — the app may have been "
                         + "backgrounded before it started.")
        case .writerFailed(let why):
            return .init(.internalError, "Could not write the recording: \(why)")
        case nil:
            return .init(.internalError, error.localizedDescription)
        }
    }
}
#endif
