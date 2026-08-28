#if os(iOS)
import Foundation
import SwiftUI
#if DEBUG || STUDIO_DEVICE_CAPTURE
import SpringMotionDeviceWire
#endif

/// Thrown by the release-build stubs. The SDK's public surface stays present in
/// every configuration so host code compiles unchanged — but the machinery
/// behind it does not.
public struct SpringMotionUnavailable: LocalizedError {
    public init() {}
    public var errorDescription: String? {
        "SpringMotionDeviceKit is not compiled into this build."
    }
}

/// The SDK's entire public surface.
///
/// ```swift
/// // UIKit
/// func application(_: UIApplication, didFinishLaunchingWithOptions _: …) -> Bool {
///     SpringMotion.enable()
///     return true
/// }
///
/// // SwiftUI
/// WindowGroup { ContentView().springMotionCapture() }
/// ```
///
/// This API is present in every configuration so host code compiles unchanged.
/// The IMPLEMENTATION behind it is compiled only when `DEBUG` or
/// `STUDIO_DEVICE_CAPTURE` is defined — every other source file in the SDK is
/// wrapped in that condition, so a release build genuinely contains no screen
/// recorder, no local-network listener and no `sendEvent` swizzle rather than
/// merely declining to use them.
///
/// (Gating only a runtime flag is not enough, and looks identical in source: the
/// swizzle still ships as an ObjC category on `UIWindow`, and the Bonjour
/// service type still sits in the binary's strings. Verified by inspecting a
/// release build — see DEVICEKIT.md §3.1.)
@MainActor
public enum SpringMotion {
    /// True when the SDK is compiled in. Read it to gate your own debug UI.
    public static var isEnabled: Bool { isCompiledIn }

    #if DEBUG || STUDIO_DEVICE_CAPTURE
    private static let isCompiledIn = true
    #else
    private static let isCompiledIn = false
    #endif

    #if DEBUG || STUDIO_DEVICE_CAPTURE
    private static var store = TakeStore()
    private static var recorder: TakeRecorder?
    private static var server: ControlServer?
    private static var pairing: PairingStore?
    private static var didEnable = false
    private static var rotationObserver: (any NSObjectProtocol)?

    /// Start listening. Installs the touch tap and begins advertising over
    /// Bonjour so Studio can find this app. Safe to call more than once.
    public static func enable() {
        guard isCompiledIn, !didEnable else { return }
        didEnable = true
        TouchTap.install()
        let recorder = TakeRecorder(store: store)
        let pairing = PairingStore()
        let server = ControlServer(recorder: recorder, store: store, pairing: pairing)
        Self.recorder = recorder
        Self.pairing = pairing
        Self.server = server
        server.start()

        // The TXT record carries the screen size Studio picks a device frame
        // from, so a rotation has to republish or a landscape take lands in a
        // portrait bezel.
        rotationObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { Self.server?.refreshAdvertisement() }
            }

        for warning in DeviceInfo.configurationWarnings {
            print("[SpringMotionDeviceKit] \(warning)")
        }
    }

    /// Stop advertising and drop every connection. Takes already on disk stay
    /// there — `enable()` again and they are still collectable.
    public static func disable() {
        server?.stop()
        server = nil
        if let rotationObserver {
            NotificationCenter.default.removeObserver(rotationObserver)
        }
        rotationObserver = nil
        didEnable = false
    }

    /// Whether a take is currently running.
    public static var isRecording: Bool { recorder?.isRecording ?? false }

    /// Whether the Bonjour advertisement is live. False here with
    /// `isEnabled == true` almost always means a missing Info.plist key — the
    /// specific reason is printed at launch and reported to Studio.
    public static var isAdvertising: Bool { server?.isRunning ?? false }

    /// Forget every paired Mac.
    public static func unpairAll() { pairing?.revokeAll() }

    // MARK: Local control
    //
    // The same calls the Mac drives remotely, exposed directly so the SDK can
    // be exercised from a debug button before any of the networking exists —
    // and so a developer can shoot a take with no Mac in the room and collect
    // it later.

    @discardableResult
    public static func startRecording() async throws -> String {
        guard isCompiledIn else { return "" }
        enable()
        guard let recorder else { throw SpringMotionResponse.Failure(
            .internalError, "SpringMotion is not enabled.") }
        return try await recorder.start(options: .init())
    }

    @discardableResult
    public static func stopRecording() async throws -> TakeHandle {
        guard isCompiledIn, let recorder else {
            throw SpringMotionResponse.Failure(.notRecording, "No recording is running.")
        }
        let summary = try await recorder.stop()
        return TakeHandle(id: summary.id,
                          duration: summary.duration,
                          strokeCount: summary.strokeCount,
                          maximumConcurrentStrokes: summary.maximumConcurrentStrokes,
                          videoURL: store.videoURL(for: summary.id),
                          touchesURL: store.touchesURL(for: summary.id))
    }

    /// Takes still on the device that Studio has not collected.
    public static var pendingTakes: [TakeHandle] {
        store.pendingIDs.compactMap { id in
            guard let take = try? store.loadTake(id) else { return nil }
            return TakeHandle(id: id,
                              duration: take.duration,
                              strokeCount: take.strokes.count,
                              maximumConcurrentStrokes: take.maximumConcurrentStrokes,
                              videoURL: store.videoURL(for: id),
                              touchesURL: store.touchesURL(for: id))
        }
    }

    public static func deleteTake(_ id: String) { store.delete(id) }
    public static func clearTakes() { store.deleteAll() }

    #else

    // MARK: Release stubs
    //
    // Same signatures, no implementation and no reference to any of the SDK's
    // machinery — so none of it is compiled, and a host app that forgets to
    // wrap its own call sites still builds and still ships clean.

    public static func enable() {}
    public static func disable() {}
    public static var isRecording: Bool { false }
    public static var isAdvertising: Bool { false }
    public static func unpairAll() {}

    @discardableResult
    public static func startRecording() async throws -> String {
        throw SpringMotionUnavailable()
    }

    @discardableResult
    public static func stopRecording() async throws -> TakeHandle {
        throw SpringMotionUnavailable()
    }

    public static var pendingTakes: [TakeHandle] { [] }
    public static func deleteTake(_ id: String) {}
    public static func clearTakes() {}

    #endif

    /// A finished take on disk. Hand the two URLs to a share sheet to get a
    /// recording off the device without Studio at all — which is how the
    /// capture core gets tested before the transport exists.
    public struct TakeHandle: Sendable, Identifiable {
        public let id: String
        public let duration: TimeInterval
        public let strokeCount: Int
        public let maximumConcurrentStrokes: Int
        public let videoURL: URL
        public let touchesURL: URL
    }
}

public extension View {
    /// SwiftUI install point. Equivalent to calling `SpringMotion.enable()`.
    /// A no-op in release builds — `enable()` is the stub there.
    func springMotionCapture() -> some View {
        task { SpringMotion.enable() }
    }
}
#endif
