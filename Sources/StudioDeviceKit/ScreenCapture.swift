#if os(iOS) && (DEBUG || STUDIO_DEVICE_CAPTURE)
import AVFoundation
import QuartzCore
import ReplayKit
import StudioDeviceWire

/// Records the host app's screen to a `.mov` via ReplayKit's in-process capture.
///
/// `startCapture` (rather than `startRecording`) is what makes this usable at
/// all: it hands over `CMSampleBuffer`s directly, so the file is ours to write
/// and ship, with no Broadcast Upload Extension, no app group, and no second
/// target for the host developer to add. The trade is that it captures THIS APP
/// only — leave the app and frames stop (DEVICEKIT.md §4.1).
///
/// ReplayKit calls the handler on its own queue, so all writer state lives
/// behind `queue` and nothing here touches the main actor.
final class ScreenCapture: @unchecked Sendable {
    enum CaptureError: LocalizedError {
        case unavailable(String)
        case denied
        case noFrames
        case writerFailed(String)

        var errorDescription: String? {
            switch self {
            case .unavailable(let why): why
            case .denied: "Screen recording permission was declined."
            case .noFrames: "The recording produced no frames."
            case .writerFailed(let why): why
            }
        }
    }

    private let queue = DispatchQueue(label: "com.fumberger.studiodevicekit.capture")
    /// AVFoundation's writer types predate Sendable and never gained it. The
    /// serial `queue` is the real guarantee here — every touch of this state
    /// goes through it, including the escaping `finishWriting` callback.
    nonisolated(unsafe) private var writer: AVAssetWriter?
    nonisolated(unsafe) private var videoInput: AVAssetWriterInput?
    nonisolated(unsafe) private var audioInput: AVAssetWriterInput?
    private var started = false
    /// Whether the app's own audio is being written alongside the picture.
    private let includeAppAudio: Bool
    /// Set once any audio has actually been written — reported back so a silent
    /// take is distinguishable from a broken one.
    private(set) var wroteAudio = false

    /// The two clock anchors, captured from the first frame that lands
    /// (DEVICEKIT.md §4.3). Recording both means a wrong assumption about which
    /// clock ReplayKit uses is a correction on already-shot takes, not a
    /// re-shoot.
    private var firstFramePTS: TimeInterval?
    private var firstFrameArrival: TimeInterval?
    private var lastPTS: CMTime = .zero

    let outputURL: URL

    init(outputURL: URL, includeAppAudio: Bool) {
        self.outputURL = outputURL
        self.includeAppAudio = includeAppAudio
    }

    /// Anchor and duration, readable once the take has stopped.
    private(set) var anchor = TouchTake.VideoAnchor()
    private(set) var pixelSize = CGSize.zero
    private(set) var duration: TimeInterval = 0

    func start() async throws {
        let recorder = RPScreenRecorder.shared()
        guard recorder.isAvailable else {
            throw CaptureError.unavailable(
                "Screen recording is unavailable — AirPlay, an active call, or "
                + "another recording can all block it.")
        }
        // The system disables its own microphone/camera prompts for us; we only
        // ever want what the app itself draws.
        recorder.isMicrophoneEnabled = false
        recorder.isCameraEnabled = false

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            recorder.startCapture { [weak self] buffer, type, error in
                guard let self, error == nil else { return }
                // SYNCHRONOUSLY, not `queue.async`: ReplayKit is free to recycle
                // the sample buffer the moment this handler returns, so writing
                // it later would encode whatever frame landed next. `sync` also
                // applies the back-pressure that keeps us honest — if the writer
                // is slow, capture slows rather than silently corrupting.
                switch type {
                case .video:
                    self.queue.sync { self.append(buffer) }
                case .audioApp where self.includeAppAudio:
                    self.queue.sync { self.appendAudio(buffer) }
                default:
                    // `.audioMic` never arrives — the mic is disabled above.
                    break
                }
            } completionHandler: { error in
                if let error {
                    // A declined consent alert surfaces as a ReplayKit
                    // permission error; say which it was, because "recording
                    // failed" sends the developer looking in the wrong place.
                    let code = (error as NSError).code
                    if code == RPRecordingErrorCode.userDeclined.rawValue {
                        continuation.resume(throwing: CaptureError.denied)
                    } else {
                        continuation.resume(throwing: error)
                    }
                } else {
                    continuation.resume()
                }
            }
        }
    }

    /// Stop capture and finish the file. Returns the anchor + geometry the take
    /// metadata needs.
    @discardableResult
    func stop() async throws -> TouchTake.VideoAnchor {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            RPScreenRecorder.shared().stopCapture { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }

        // Drain: buffers already handed to us may still be queued behind the
        // stop, and finishing the writer under them truncates the tail.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard let writer = self.writer, let input = self.videoInput,
                      self.started
                else {
                    continuation.resume(throwing: CaptureError.noFrames)
                    return
                }
                input.markAsFinished()
                // Every input must be finished or `finishWriting` never calls
                // back and the take is lost.
                self.audioInput?.markAsFinished()
                self.duration = CMTimeGetSeconds(self.lastPTS)
                    - (self.firstFramePTS ?? 0)
                // Read the outcome back off `self` rather than capturing the
                // writer in this escaping callback — same object, but the
                // property carries the `nonisolated(unsafe)` that says why it
                // is safe to cross queues.
                writer.finishWriting {
                    if self.writer?.status == .failed {
                        continuation.resume(throwing: CaptureError.writerFailed(
                            self.writer?.error?.localizedDescription ?? "unknown"))
                    } else {
                        continuation.resume()
                    }
                }
            }
        }

        anchor = TouchTake.VideoAnchor(
            firstFramePTS: firstFramePTS ?? 0,
            firstFrameArrival: firstFrameArrival ?? 0,
            rebasedAgainst: "pts")
        return anchor
    }

    /// Tear down without producing a file — startup-failure cleanup.
    func abandon() {
        RPScreenRecorder.shared().stopCapture { _ in }
        queue.async {
            self.writer?.cancelWriting()
            self.writer = nil
            self.videoInput = nil
            try? FileManager.default.removeItem(at: self.outputURL)
        }
    }

    // MARK: Writing

    private func append(_ buffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(buffer) else { return }
        let pts = buffer.presentationTimeStamp

        if writer == nil {
            // Size comes from the first frame rather than from UIScreen:
            // ReplayKit is free to hand back something other than
            // points × scale, and the log→frame mapping must not assume.
            guard let pixels = CMSampleBufferGetImageBuffer(buffer) else { return }
            let width = CVPixelBufferGetWidth(pixels)
            let height = CVPixelBufferGetHeight(pixels)
            pixelSize = CGSize(width: width, height: height)
            guard makeWriter(width: width, height: height) else { return }
        }
        guard let writer, let input = videoInput else { return }

        if !started {
            writer.startWriting()
            writer.startSession(atSourceTime: pts)
            started = true
            firstFramePTS = CMTimeGetSeconds(pts)
            firstFrameArrival = CACurrentMediaTime()
        }
        // Dropping frames the writer isn't ready for is correct: capture is
        // real-time and there is no back-pressure to apply to a screen.
        guard input.isReadyForMoreMediaData, writer.status == .writing else { return }
        if input.append(buffer) { lastPTS = pts }
    }

    /// The app's own audio, written alongside the picture.
    ///
    /// Two rules of AVAssetWriter shape this. Every input must be added BEFORE
    /// `startWriting`, and nothing may be appended before `startSession` or with
    /// a timestamp earlier than it. Since the session is anchored on the first
    /// VIDEO frame (the video also being what supplies the writer's dimensions),
    /// any audio that arrives ahead of that frame is dropped — it has no picture
    /// to sit against, and appending it would fault the writer.
    private func appendAudio(_ buffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(buffer), started,
              let writer, let input = audioInput,
              writer.status == .writing, input.isReadyForMoreMediaData
        else { return }
        guard let first = firstFramePTS,
              CMTimeGetSeconds(buffer.presentationTimeStamp) >= first else { return }
        if input.append(buffer) { wroteAudio = true }
    }

    private func makeWriter(width: Int, height: Int) -> Bool {
        try? FileManager.default.removeItem(at: outputURL)
        guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mov) else {
            return false
        }
        // HEVC: a screen recording is mostly flat colour and hard edges, where
        // HEVC's gain over H.264 is large, and the take has to cross a Wi-Fi
        // link before anyone can use it.
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(6_000_000, width * height * 4),
                AVVideoExpectedSourceFrameRateKey: 60,
            ],
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { return false }
        writer.add(input)

        // Added here, with the video input, because AVAssetWriter refuses new
        // inputs once writing starts — and writing starts on this same first
        // frame. The settings are therefore FIXED rather than derived from the
        // first audio buffer's format, which has not arrived yet: the encoder
        // resamples if the source differs. Deterministic startup is worth more
        // than avoiding a resample, since a writer that waits for audio never
        // starts at all when the app happens to be silent.
        if includeAppAudio {
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 44_100,
                AVEncoderBitRateKey: 192_000,   // music, not just UI blips
            ])
            audio.expectsMediaDataInRealTime = true
            if writer.canAdd(audio) {
                writer.add(audio)
                self.audioInput = audio
            }
        }

        self.writer = writer
        self.videoInput = input
        return true
    }
}
#endif
