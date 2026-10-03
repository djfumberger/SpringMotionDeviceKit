import Foundation

/// Names and constants both ends agree on.
public enum SpringMotionProtocol {
    /// SDK / protocol version. Advertised in the TXT record and checked by
    /// `hello`, so a mismatch is reported before a shoot rather than after.
    public static let version = "1"

    /// The Bonjour service type. Host apps must list this in their Info.plist
    /// under `NSBonjourServices` or iOS silently refuses to advertise.
    public static let serviceType = "_springmotion._tcp"

    /// TXT record keys — kept to one or two characters because a TXT record is
    /// a small budget and this is machine-read, not human-read.
    public enum TXT {
        public static let deviceName = "n"      // "Dave's iPhone"
        public static let machine = "m"         // "iPhone17,1"
        public static let widthPoints = "w"
        public static let heightPoints = "h"
        public static let scale = "s"
        public static let bundleID = "b"
        public static let version = "v"
    }

    /// How long a pairing code stays valid once shown.
    public static let pairingCodeLifetime: TimeInterval = 120
}

/// Which half of a take is being fetched.
public enum TakePart: String, Codable, Sendable {
    case video
    case touches
}

/// Mac → device.
public enum SpringMotionRequest: Codable, Sendable {
    /// Identify, and check whether this peer is already trusted. Always the
    /// first message on a connection.
    case hello(token: String?, client: String)
    /// Redeem the six-digit code the device is displaying.
    case pair(code: String)
    case startRecording(RecordOptions)
    case stopRecording
    case fetchTake(id: String, part: TakePart)
    case deleteTake(id: String)

    public struct RecordOptions: Codable, Sendable {
        /// Capture the app's audio alongside the video.
        ///
        /// ON by default: a demo of anything that makes sound is worth little
        /// silent, and an unwanted track is one mute away in Studio, whereas a
        /// missing one is a re-shoot.
        public var includeAppAudio: Bool = true
        /// Hard stop, so a forgotten recording can't fill the device. The Mac
        /// stopping normally is the expected path.
        public var maximumDuration: TimeInterval = 15 * 60

        public init(includeAppAudio: Bool = true,
                    maximumDuration: TimeInterval = 15 * 60) {
            self.includeAppAudio = includeAppAudio
            self.maximumDuration = maximumDuration
        }
    }
}

/// Device → Mac.
///
/// `blob` is the one case with a tail: the announcement is a framed JSON
/// message, and exactly `bytes` raw bytes follow it on the connection before
/// normal framing resumes. Nothing else may be interleaved in between.
public enum SpringMotionResponse: Codable, Sendable {
    case hello(HelloInfo)
    /// This peer is not trusted yet; the device is now showing `codeLength`
    /// digits on its screen for the user to read across.
    case pairingRequired(codeLength: Int)
    case paired(token: String)
    case recordingStarted(takeID: String)
    case recordingStopped(TakeSummary)
    case take(TouchTake)
    case blob(BlobHeader)
    case ok
    case failure(Failure)

    public struct HelloInfo: Codable, Sendable {
        public var device: TouchTake.DeviceIdentity
        public var screen: TouchTake.Screen
        public var protocolVersion: String
        public var isRecording: Bool
        /// Takes still on the device — a crashed Studio can come back and
        /// collect what it never fetched.
        public var pendingTakeIDs: [String]
        /// Set when the host app is missing a required Info.plist key. The
        /// developer sees a specific instruction instead of a silent no-show.
        public var configurationWarnings: [String]
        /// Set when the app is running in the iOS Simulator: which simulator.
        /// ReplayKit delivers no frames there, so the device records only its
        /// logs (`TakeSummary.hasVideo` false) and Studio films that simulator
        /// itself, lining the two up on the clock they share — the Mac's.
        public var simulatorUDID: String?

        public init(device: TouchTake.DeviceIdentity, screen: TouchTake.Screen,
                    protocolVersion: String = SpringMotionProtocol.version,
                    isRecording: Bool = false,
                    pendingTakeIDs: [String] = [],
                    configurationWarnings: [String] = [],
                    simulatorUDID: String? = nil) {
            self.device = device
            self.screen = screen
            self.protocolVersion = protocolVersion
            self.isRecording = isRecording
            self.pendingTakeIDs = pendingTakeIDs
            self.configurationWarnings = configurationWarnings
            self.simulatorUDID = simulatorUDID
        }
    }

    public struct TakeSummary: Codable, Sendable {
        public var id: String
        public var duration: TimeInterval
        public var videoBytes: Int
        public var strokeCount: Int
        /// Peak simultaneous fingers — Studio turns this into that many touch
        /// indicator layers, so it is worth showing in the UI before the pull.
        public var maximumConcurrentStrokes: Int
        /// Whether any audio actually reached the file. Distinguishes "the app
        /// was silent" from "audio capture failed", which look identical once
        /// the take is on the Mac and only one of them is worth re-shooting.
        public var hasAudio: Bool
        /// False for a logs-only take (the Simulator): there is no `.video` part
        /// to fetch. Absent (an older SDK) means a video was recorded.
        public var hasVideo: Bool?

        public init(id: String, duration: TimeInterval, videoBytes: Int,
                    strokeCount: Int, maximumConcurrentStrokes: Int,
                    hasAudio: Bool = false, hasVideo: Bool? = nil) {
            self.id = id
            self.duration = duration
            self.videoBytes = videoBytes
            self.strokeCount = strokeCount
            self.maximumConcurrentStrokes = maximumConcurrentStrokes
            self.hasAudio = hasAudio
            self.hasVideo = hasVideo
        }
    }

    public struct BlobHeader: Codable, Sendable {
        public var part: TakePart
        public var bytes: Int
        public var contentType: String

        public init(part: TakePart, bytes: Int, contentType: String) {
            self.part = part
            self.bytes = bytes
            self.contentType = contentType
        }
    }

    /// A failure the user can act on. `code` is for Studio to branch on;
    /// `message` is what gets shown.
    public struct Failure: Codable, Sendable, Error {
        public enum Code: String, Codable, Sendable {
            case notPaired
            case badPairingCode
            case alreadyRecording
            case notRecording
            case captureUnavailable      // ReplayKit refused
            case captureDenied           // user declined the consent alert
            case unknownTake
            case versionMismatch
            case internalError
        }

        public var code: Code
        public var message: String

        public init(_ code: Code, _ message: String) {
            self.code = code
            self.message = message
        }
    }
}

public extension SpringMotionRequest {
    func encoded() throws -> Data { try JSONEncoder().encode(self) }
    static func decode(_ data: Data) throws -> Self {
        try JSONDecoder().decode(Self.self, from: data)
    }
}

public extension SpringMotionResponse {
    func encoded() throws -> Data { try JSONEncoder().encode(self) }
    static func decode(_ data: Data) throws -> Self {
        try JSONDecoder().decode(Self.self, from: data)
    }
}
