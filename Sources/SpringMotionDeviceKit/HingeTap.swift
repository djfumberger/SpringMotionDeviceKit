#if os(iOS) && (DEBUG || STUDIO_DEVICE_CAPTURE)
import QuartzCore
import SpringMotionDeviceWire
import UIKit

/// Logs a foldable's hinge over a take — how far open it is, moment to moment —
/// so Studio can fold its 3D model in step with the recording.
///
/// The same shape as `TouchTap`: readings are stamped on the host clock as they
/// arrive and rebased against the first video frame when the take ends, so they
/// land on the same timeline as the touches. Readings come at the system's
/// chosen rate (`UIHinge` promises no frequency), so each is kept as it came;
/// Studio does the smoothing.
///
/// `UIHingeInteraction` is iOS 27.1. Compiled out entirely under an older SDK —
/// a host app on an older Xcode still builds — and inert on an older OS or a
/// phone without a hinge, where the interaction simply never reports.
@MainActor
final class HingeTap {
    static let shared = HingeTap()

    private struct Reading {
        let host: TimeInterval
        let angle: Float
        let status: TouchTake.HingeStatus
    }

    private var readings: [Reading] = []
    private var detach: (() -> Void)?

    func startRecording() {
        readings = []
        detach?()
        detach = nil
        // UIKit 9127.0.85 is the iOS 27.1 SDK — the first with UIHingeInteraction
        // (27.0's is 9127.0.84). A compiler check can't tell them apart: both
        // ship Swift 6.4.
        #if canImport(UIKit, _underlyingVersion: 9127.0.85)
        if #available(iOS 27.1, *), let window = Self.keyWindow {
            let interaction = UIHingeInteraction { [weak self] _, update in
                // nil: the interaction left a hierarchy that reports a hinge.
                guard let self, let hinge = update.hinge else { return }
                readings.append(Reading(host: CACurrentMediaTime(),
                                        angle: Float(hinge.angle),
                                        status: Self.status(hinge.status)))
            }
            window.addInteraction(interaction)
            detach = { [weak window, weak interaction] in
                if let interaction { window?.removeInteraction(interaction) }
            }
        }
        #endif
    }

    /// The take's hinge log, rebased so `videoStart` is t = 0, or nil when the
    /// device reported nothing (no hinge, an older OS). The reading in force
    /// when the video began is kept AT 0 — the interaction reports its initial
    /// state as it attaches, which may be before the first frame, and dropping
    /// it would leave the opening pose unknown until the hinge next moved.
    func finishRecording(videoStart: TimeInterval) -> [TouchTake.HingeSample]? {
        detach?()
        detach = nil
        defer { readings = [] }
        var samples: [TouchTake.HingeSample] = []
        if let opening = readings.last(where: { $0.host <= videoStart }) {
            samples.append(.init(t: 0, angle: opening.angle, status: opening.status))
        }
        for reading in readings where reading.host > videoStart {
            samples.append(.init(t: reading.host - videoStart, angle: reading.angle, status: reading.status))
        }
        return samples.isEmpty ? nil : samples
    }

    private static var keyWindow: UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        return scene?.keyWindow ?? scene?.windows.first
    }

    #if canImport(UIKit, _underlyingVersion: 9127.0.85)
    @available(iOS 27.1, *)
    private static func status(_ status: UIHinge.Status) -> TouchTake.HingeStatus {
        switch status {
        case .closed: .closed
        case .partiallyOpen: .partiallyOpen
        case .fullyOpen: .fullyOpen
        default: .unknown
        }
    }
    #endif
}
#endif
