#if os(iOS) && (DEBUG || STUDIO_DEVICE_CAPTURE)
import QuartzCore
import StudioDeviceWire
import UIKit

/// Watches every touch the host app receives and reassembles them into strokes.
///
/// The tap is a swizzle of `UIWindow.sendEvent(_:)`, installed on the CLASS
/// rather than on an instance. That distinction matters: the system keyboard
/// lives in `UIRemoteKeyboardWindow`, a `UIWindow` subclass the app never
/// creates itself, so an instance-level hook on the app's own window would miss
/// every keyboard tap — a large fraction of what a product demo shows.
///
/// A gesture recognizer was the alternative. It loses: recognizers can be
/// starved by other recognizers, and touches heading for a system edge gesture
/// never reach one at all. `sendEvent` sees everything the app sees.
@MainActor
final class TouchTap {
    static let shared = TouchTap()

    /// Strokes finished so far this take, in the order they ended.
    private var completed: [TouchTake.Stroke] = []
    /// Strokes still in progress, keyed by touch identity. `UITouch` objects
    /// are recycled by UIKit but stay identical for one touch's whole life,
    /// which is exactly the guarantee needed to accumulate a stroke.
    private var active: [ObjectIdentifier: TouchTake.Stroke] = [:]
    private var nextStrokeID = 0
    private(set) var isRecording = false

    /// Points the log normalizes against — the screen's CURRENT orientation, so
    /// x/y line up with the ReplayKit frames, which are also interface-oriented.
    private var referenceBounds: CGRect = .zero

    private init() {}

    /// Install the hook. Idempotent, and never uninstalled: swapping an
    /// implementation back out races against any call already in flight, and a
    /// hook that early-returns when idle costs a boolean check per event.
    static func install() {
        _ = swizzleOnce
    }

    private static let swizzleOnce: Void = {
        guard let original = class_getInstanceMethod(UIWindow.self,
                                                     #selector(UIWindow.sendEvent(_:))),
              let replacement = class_getInstanceMethod(UIWindow.self,
                                                        #selector(UIWindow.studioDeviceKit_sendEvent(_:)))
        else {
            assertionFailure("StudioDeviceKit: could not hook UIWindow.sendEvent")
            return
        }
        method_exchangeImplementations(original, replacement)
    }()

    func startRecording(referenceBounds: CGRect) {
        completed.removeAll()
        active.removeAll()
        nextStrokeID = 0
        self.referenceBounds = referenceBounds
        isRecording = true
    }

    /// Close the take. Fingers still down when the Mac hits stop are closed
    /// where they are and marked `cancelled` — they did not deliberately lift,
    /// and a touch indicator that "releases" on a finger still pressed is a lie.
    ///
    /// `videoStart` is the host-clock anchor every timestamp is rebased against,
    /// which is what makes the log frame-exact against the recording.
    func finishRecording(videoStart: TimeInterval) -> [TouchTake.Stroke] {
        isRecording = false
        for var stroke in active.values {
            stroke.cancelled = true
            completed.append(stroke)
        }
        active.removeAll()

        let rebased = completed
            .map { stroke -> TouchTake.Stroke in
                var copy = stroke
                copy.samples = stroke.samples.map { sample in
                    var s = sample
                    s.t = sample.t - videoStart
                    return s
                }
                return copy
            }
            // Anything that ended before the first frame landed has no video to
            // sit against — drop it rather than emit negative times.
            .filter { $0.ended >= 0 }
            .sorted { $0.began < $1.began }
        completed.removeAll()
        return rebased
    }

    // MARK: The hook

    /// Called for every event the host app delivers, recording or not — so the
    /// idle path must stay trivial.
    fileprivate func observe(_ event: UIEvent, in window: UIWindow) {
        guard isRecording, event.type == .touches, let touches = event.allTouches else { return }
        for touch in touches where touch.window === window {
            switch touch.phase {
            case .began:
                begin(touch, in: window)
            case .moved, .stationary:
                extend(touch, event: event, in: window)
            case .ended:
                end(touch, event: event, in: window, cancelled: false)
            case .cancelled:
                end(touch, event: event, in: window, cancelled: true)
            default:
                // `.regionEntered`/`.regionMoved`/`.regionExited` are hover
                // events from a pencil or pointer — no contact, nothing to draw.
                continue
            }
        }
    }

    private func begin(_ touch: UITouch, in window: UIWindow) {
        let key = ObjectIdentifier(touch)
        // A recycled UITouch beginning again while we still hold an open stroke
        // means we missed its end. Close the old one rather than lose it.
        if let stale = active.removeValue(forKey: key) {
            var closed = stale
            closed.cancelled = true
            completed.append(closed)
        }
        var stroke = TouchTake.Stroke(id: nextStrokeID, kind: kind(of: touch))
        nextStrokeID += 1
        stroke.samples = [sample(from: touch, in: window)]
        active[key] = stroke
    }

    private func extend(_ touch: UITouch, event: UIEvent, in window: UIWindow) {
        let key = ObjectIdentifier(touch)
        guard var stroke = active[key] else { return }   // began before we started
        stroke.samples.append(contentsOf: samples(for: touch, event: event, in: window))
        active[key] = stroke
    }

    private func end(_ touch: UITouch, event: UIEvent, in window: UIWindow,
                     cancelled: Bool) {
        let key = ObjectIdentifier(touch)
        guard var stroke = active.removeValue(forKey: key) else { return }
        stroke.samples.append(contentsOf: samples(for: touch, event: event, in: window))
        stroke.cancelled = cancelled
        completed.append(stroke)
    }

    /// Every position UIKit has for this touch since the last delivery.
    ///
    /// A 120Hz display coalesces several touch positions into one event
    /// delivery; `coalescedTouches` is the only way to see them all. Without it
    /// a fast drag is sampled at frame rate and the replayed finger visibly
    /// corners where the real one curved.
    private func samples(for touch: UITouch, event: UIEvent,
                         in window: UIWindow) -> [TouchTake.Sample] {
        guard let coalesced = event.coalescedTouches(for: touch), !coalesced.isEmpty else {
            return [sample(from: touch, in: window)]
        }
        return coalesced.map { sample(from: $0, in: window) }
    }

    private func sample(from touch: UITouch, in window: UIWindow) -> TouchTake.Sample {
        // `touch.timestamp` is seconds since boot — the same timebase as
        // `CACurrentMediaTime()`, and more accurate than reading the clock here,
        // because it is when the touch actually happened rather than when the
        // main thread got around to delivering it.
        let t = touch.timestamp > 0 ? touch.timestamp : CACurrentMediaTime()
        let point = window.convert(touch.location(in: nil),
                                   to: window.screen.coordinateSpace)
        let bounds = referenceBounds.isEmpty ? window.screen.coordinateSpace.bounds
                                             : referenceBounds
        let force = touch.maximumPossibleForce > 0
            ? Float(touch.force / touch.maximumPossibleForce) : 0
        return TouchTake.Sample(
            t: t,
            x: bounds.width > 0 ? Float(point.x / bounds.width) : 0.5,
            y: bounds.height > 0 ? Float(point.y / bounds.height) : 0.5,
            force: force,
            radius: Float(touch.majorRadius))
    }

    private func kind(of touch: UITouch) -> TouchTake.StrokeKind {
        switch touch.type {
        case .direct: .direct
        case .pencil: .pencil
        case .indirect, .indirectPointer: .indirect
        @unknown default: .unknown
        }
    }
}

extension UIWindow {
    /// The swizzled half. After `method_exchangeImplementations`, this selector
    /// holds the ORIGINAL implementation — so calling it here forwards the
    /// event on, it does not recurse.
    @objc fileprivate dynamic func studioDeviceKit_sendEvent(_ event: UIEvent) {
        // Observe first: a touch that triggers a system gesture may never come
        // back through here, and losing the last sample of a swipe-to-dismiss is
        // exactly the sample that explains what happened.
        MainActor.assumeIsolated {
            TouchTap.shared.observe(event, in: self)
        }
        studioDeviceKit_sendEvent(event)
    }
}
#endif
