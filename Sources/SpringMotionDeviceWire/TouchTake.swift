import Foundation
import simd

/// One recorded take: the raw multi-touch interaction log that travels beside
/// the screen recording.
///
/// Kept RAW — every stroke as it happened, not pre-assigned to touch indicators
/// — for the same reason `MouseRecording` keeps raw samples instead of finished
/// states: the split into lanes is a heuristic, and a heuristic that improves
/// must be re-runnable over takes already shot. Studio does the splitting
/// (`TouchTakeImporter`); the device just tells the truth.
///
/// All times are seconds from the first video frame, so a take drops straight
/// onto a timeline with no offset arithmetic. All coordinates are normalized to
/// the screen (0…1, origin top-left) so the log survives any render size.
public struct TouchTake: Codable, Equatable, Sendable {
    /// The wire-format version. Bumped when a change would make an older
    /// Studio misread a newer take; `hello` compares it before recording so the
    /// failure lands before the shoot, not after.
    public static let formatVersion = 1

    public var version: Int = TouchTake.formatVersion
    public var strokes: [Stroke] = []
    /// Total recording length — the last stroke may end well before the video.
    public var duration: TimeInterval = 0
    public var screen: Screen = Screen()
    public var device: DeviceIdentity = DeviceIdentity()
    public var video: VideoAnchor = VideoAnchor()
    /// How far open a foldable was, over the take — nil on a device without a
    /// hinge (or an SDK/OS too old to read one). Optional and additive, so an
    /// older Studio decodes a newer take by ignoring it: no format bump.
    public var hinge: [HingeSample]?

    public init(version: Int = TouchTake.formatVersion,
                strokes: [Stroke] = [],
                duration: TimeInterval = 0,
                screen: Screen = Screen(),
                device: DeviceIdentity = DeviceIdentity(),
                video: VideoAnchor = VideoAnchor(),
                hinge: [HingeSample]? = nil) {
        self.version = version
        self.strokes = strokes
        self.duration = duration
        self.screen = screen
        self.device = device
        self.video = video
        self.hinge = hinge
    }

    /// One reading of a foldable's hinge (`UIHinge`, iOS 27.1), `t` seconds
    /// after the first video frame — the same clock as the touches.
    ///
    /// Kept as the system reported it. Readings arrive at whatever rate the
    /// system chooses, and the angle's zero/flat convention is the system's
    /// too, so Studio calibrates from `status` (closed / fully open) rather
    /// than the device assuming what an angle means.
    public struct HingeSample: Codable, Equatable, Sendable {
        public var t: TimeInterval
        /// `UIHinge.angle`, radians.
        public var angle: Float
        public var status: HingeStatus

        public init(t: TimeInterval, angle: Float, status: HingeStatus) {
            self.t = t; self.angle = angle; self.status = status
        }
    }

    /// `UIHinge.Status`.
    public enum HingeStatus: String, Codable, Equatable, Sendable {
        case unknown, closed, partiallyOpen, fullyOpen
    }

    /// One position of one finger, `t` seconds after the first video frame.
    public struct Sample: Codable, Equatable, Sendable {
        public var t: TimeInterval
        /// Normalized to the screen, 0…1, origin top-left. May fall outside
        /// 0…1 for a touch that slides off an edge — kept raw.
        public var x: Float
        public var y: Float
        /// 0…1, `UITouch.force / maximumPossibleForce`. 0 on hardware without
        /// force sensing, which is most of it — treat 0 as "unknown", not "light".
        public var force: Float
        /// `UITouch.majorRadius` in points: how fat the contact patch is. A
        /// thumb reads much wider than a fingertip, and that is worth showing.
        public var radius: Float

        public init(t: TimeInterval, x: Float, y: Float,
                    force: Float = 0, radius: Float = 0) {
            self.t = t; self.x = x; self.y = y
            self.force = force; self.radius = radius
        }
    }

    /// What made the contact. A pencil stroke should not be drawn as a
    /// fingertip, so the distinction survives to the editor.
    public enum StrokeKind: String, Codable, Equatable, Sendable {
        case direct     // a finger on the glass
        case pencil     // Apple Pencil
        case indirect   // trackpad / pointer-driven
        case unknown
    }

    /// One finger, from touch-down to lift, with every position in between.
    ///
    /// A stroke is the unit of lane assignment: two strokes overlapping in time
    /// are two simultaneous fingers and must land in different lanes.
    public struct Stroke: Codable, Equatable, Sendable {
        /// Monotonic per take. `UITouch` identity is pointer identity and does
        /// not serialize, so the tap assigns these as strokes begin.
        public var id: Int
        public var kind: StrokeKind
        /// Never empty: a stroke is created from its `began` sample.
        public var samples: [Sample]
        /// The system took the touch away mid-stroke (a system edge gesture, an
        /// incoming call). The finger did NOT deliberately lift — a tap
        /// indicator should fade rather than release.
        public var cancelled: Bool

        public init(id: Int, kind: StrokeKind = .direct,
                    samples: [Sample] = [], cancelled: Bool = false) {
            self.id = id
            self.kind = kind
            self.samples = samples
            self.cancelled = cancelled
        }

        public var began: TimeInterval { samples.first?.t ?? 0 }
        public var ended: TimeInterval { samples.last?.t ?? began }

        /// Whether this stroke is a TAP rather than a drag: brief, and it never
        /// travelled far from where it landed. `screenSize` puts the threshold
        /// in points instead of resolution-relative normalized units — the same
        /// convention as `MouseRecording.isTap`.
        public func isTap(screenSize: SIMD2<Float>,
                          maxDuration: TimeInterval = 0.35,
                          maxTravel: Float = 14) -> Bool {
            guard ended - began <= maxDuration, let first = samples.first else { return false }
            let origin = SIMD2(first.x, first.y)
            return samples.allSatisfy { sample in
                let travel = (SIMD2(sample.x, sample.y) - origin) * screenSize
                return simd_length(travel) <= maxTravel
            }
        }
    }

    /// The screen the take was shot on, in points — what normalized coordinates
    /// multiply back up into.
    public struct Screen: Codable, Equatable, Sendable {
        public var width: Float = 0
        public var height: Float = 0
        public var scale: Float = 1
        /// Pixel size of the written video. Usually `size * scale`, but
        /// ReplayKit is free to hand back something else, and the mapping from
        /// log to frame must not assume.
        public var pixelWidth: Int = 0
        public var pixelHeight: Int = 0
        /// `portrait`, `landscapeLeft`, … — the orientation held for the take.
        /// A take that rotates mid-shoot is out of scope for now (§8 phase 4).
        public var orientation: String = "portrait"

        public init(width: Float = 0, height: Float = 0, scale: Float = 1,
                    pixelWidth: Int = 0, pixelHeight: Int = 0,
                    orientation: String = "portrait") {
            self.width = width; self.height = height; self.scale = scale
            self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
            self.orientation = orientation
        }
    }

    /// Who shot it. `machine` is what picks the catalog frame — Studio maps
    /// `iPhone17,1` to "iPhone 16 Pro" on its side, so the table can improve
    /// without every host app re-shipping the SDK.
    public struct DeviceIdentity: Codable, Equatable, Sendable {
        public var name: String = ""            // "Dave's iPhone"
        public var machine: String = ""         // "iPhone17,1"
        public var systemVersion: String = ""   // "26.2"
        public var appBundleID: String = ""
        public var appVersion: String = ""
        public var sdkVersion: String = SpringMotionProtocol.version

        public init(name: String = "", machine: String = "",
                    systemVersion: String = "", appBundleID: String = "",
                    appVersion: String = "",
                    sdkVersion: String = SpringMotionProtocol.version) {
            self.name = name; self.machine = machine
            self.systemVersion = systemVersion
            self.appBundleID = appBundleID; self.appVersion = appVersion
            self.sdkVersion = sdkVersion
        }
    }

    /// The two clock anchors, both recorded on purpose (DEVICEKIT.md §4.3).
    ///
    /// Touch timestamps are rebased against `firstFramePTS` on the assumption
    /// that ReplayKit's presentation timestamps share the host clock with
    /// `CACurrentMediaTime()`. If that assumption ever fails, `firstFrameArrival`
    /// is the fallback anchor and the correction is arithmetic on already-shot
    /// takes rather than a re-shoot.
    public struct VideoAnchor: Codable, Equatable, Sendable {
        /// Presentation timestamp of the first written frame, seconds.
        public var firstFramePTS: TimeInterval = 0
        /// `CACurrentMediaTime()` at the moment that frame reached us.
        public var firstFrameArrival: TimeInterval = 0
        /// Which of the two the times in this take were rebased against, so a
        /// reader never has to guess.
        public var rebasedAgainst: String = "pts"

        public init(firstFramePTS: TimeInterval = 0,
                    firstFrameArrival: TimeInterval = 0,
                    rebasedAgainst: String = "pts") {
            self.firstFramePTS = firstFramePTS
            self.firstFrameArrival = firstFrameArrival
            self.rebasedAgainst = rebasedAgainst
        }
    }
}

public extension TouchTake {
    /// The screen size in points as a vector — what normalized coordinates
    /// scale through.
    var screenSize: SIMD2<Float> { SIMD2(screen.width, screen.height) }

    /// The most fingers down at any one instant. This is the lane count Studio
    /// will need, and it is worth knowing BEFORE splitting: a take that peaks at
    /// five is either a five-finger gesture or a palm, and the difference
    /// matters to whoever is about to get five touch indicators.
    var maximumConcurrentStrokes: Int {
        // Sweep the begin/end edges in time order; +1 on a begin, -1 on an end.
        var edges: [(t: TimeInterval, delta: Int)] = []
        for stroke in strokes {
            edges.append((stroke.began, 1))
            edges.append((stroke.ended, -1))
        }
        // Ends before begins at equal times: a finger lifting exactly as
        // another lands is ONE finger down, not two.
        edges.sort { $0.t == $1.t ? $0.delta < $1.delta : $0.t < $1.t }
        var current = 0, peak = 0
        for edge in edges {
            current += edge.delta
            peak = max(peak, current)
        }
        return peak
    }
}
