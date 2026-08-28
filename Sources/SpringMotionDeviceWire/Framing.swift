import Foundation

/// Length-prefixed message framing, shared by both ends of the connection.
///
/// The wire is `[4-byte big-endian length][payload]`, repeated. Payloads are
/// JSON except for blob bodies, which follow their announcing message as raw
/// bytes (see `SpringMotionResponse.blob`).
///
/// This exists instead of HTTP because both ends are ours and both speak
/// Network.framework: a framed read is a dozen lines each side, whereas HTTP
/// means writing a request parser for iOS and a response parser for macOS, with
/// chunked-encoding and header-folding corner cases nobody wants to own. The
/// cost is that `curl` can't poke at it — accepted (DEVICEKIT.md §5.2).
public enum SpringMotionFraming {
    /// The header size in bytes.
    public static let headerSize = 4

    /// Refuse absurd lengths outright. A corrupt or hostile first four bytes
    /// otherwise become a 4GB allocation, and this listens on the LAN.
    public static let maximumMessageSize = 64 * 1024 * 1024

    public enum FramingError: Error, Equatable {
        case messageTooLarge(Int)
    }

    /// Prefix `payload` with its big-endian length, ready to send.
    public static func frame(_ payload: Data) throws -> Data {
        guard payload.count <= maximumMessageSize else {
            throw FramingError.messageTooLarge(payload.count)
        }
        var out = Data(capacity: headerSize + payload.count)
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }
}

/// Accumulates bytes off a connection and hands back whole messages.
///
/// Network.framework delivers whatever arrived, which is not the same shape as
/// what was sent: one `receive` can carry half a message or three of them. This
/// buffers until a full message is present and never assumes otherwise.
///
/// It also serves the blob case: after a blob is announced, the caller switches
/// the decoder into `expectRaw(bytes:)`, and subsequent input is handed back
/// verbatim rather than being read as framed messages.
public struct FrameDecoder: Sendable {
    private var buffer = Data()
    /// Bytes of raw blob body still owed, when in the middle of one.
    private var rawRemaining = 0
    /// The blob's last byte has been handed over and `.rawFinished` is due.
    private var rawJustFinished = false

    public init() {}

    /// What came off the wire.
    public enum Output: Equatable, Sendable {
        /// A complete framed message payload (JSON).
        case message(Data)
        /// Part of an announced blob body. Emitted as it arrives so a large
        /// video can stream to disk instead of being assembled in memory.
        case raw(Data)
        /// The announced blob is complete.
        case rawFinished
    }

    /// Switch into raw mode for exactly `bytes` bytes.
    ///
    /// MUST be called SYNCHRONOUSLY from the loop that pulled the announcing
    /// message — before the next `next()`. Deferring it across an `await` or a
    /// continuation resume does not work and fails in a confusing way: the
    /// draining loop keeps running while the resumed task waits its turn, so
    /// the blob's first bytes get read as a length header, the stream
    /// desynchronises, and the transfer hangs rather than erroring.
    ///
    /// (This is not hypothetical — it is exactly how the first version of
    /// `RemoteDeviceRecorder.fetchVideo` was written, and it hung on every
    /// take. The fix was registering the destination before sending the request
    /// so the switch could happen here, inline.)
    public mutating func expectRaw(bytes: Int) {
        rawRemaining = max(0, bytes)
    }

    public var isReadingRaw: Bool { rawRemaining > 0 }

    /// Buffer newly-received bytes without interpreting them.
    public mutating func append(_ incoming: Data) {
        buffer.append(incoming)
    }

    /// Pull the next complete unit, or nil when more bytes are needed.
    ///
    /// Pulling ONE at a time is the point. A blob's announcement and its first
    /// bytes routinely arrive in the same read, and the caller only learns to
    /// expect raw bytes by reading that announcement — so it must be able to
    /// call `expectRaw` before the next unit is interpreted. An API that
    /// decoded a whole read at once would parse the blob's body as frames and
    /// desynchronise the stream.
    ///
    /// Throws only on a length header above `maximumMessageSize` — a
    /// desynchronised or hostile stream, where continuing would mean buffering
    /// unboundedly.
    public mutating func next() throws -> Output? {
        if rawRemaining > 0 {
            guard !buffer.isEmpty else { return nil }
            let take = min(rawRemaining, buffer.count)
            let chunk = buffer.prefix(take)
            buffer.removeFirst(take)
            rawRemaining -= take
            // The finish marker is emitted on the FOLLOWING pull, so a chunk is
            // never silently merged with the end of the blob.
            if rawRemaining == 0 { rawJustFinished = true }
            return .raw(chunk)
        }
        if rawJustFinished {
            rawJustFinished = false
            return .rawFinished
        }

        guard buffer.count >= SpringMotionFraming.headerSize else { return nil }
        // `buffer` has had bytes removed from the front, so its indices are NOT
        // zero-based — read through a re-based copy rather than subscripting
        // with literals, which is the classic Data foot-gun.
        let header = [UInt8](buffer.prefix(SpringMotionFraming.headerSize))
        let length = Int(UInt32(header[0]) << 24 | UInt32(header[1]) << 16
                         | UInt32(header[2]) << 8 | UInt32(header[3]))
        guard length <= SpringMotionFraming.maximumMessageSize else {
            throw SpringMotionFraming.FramingError.messageTooLarge(length)
        }
        guard buffer.count >= SpringMotionFraming.headerSize + length else { return nil }
        buffer.removeFirst(SpringMotionFraming.headerSize)
        let payload = buffer.prefix(length)
        buffer.removeFirst(length)
        return .message(payload)
    }

    /// Buffer and drain in one call — for a reader that never expects blobs
    /// (the device serves them, it is never sent them).
    public mutating func feed(_ incoming: Data) throws -> [Output] {
        append(incoming)
        var out: [Output] = []
        while let unit = try next() { out.append(unit) }
        return out
    }
}
