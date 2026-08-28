import Foundation
import Testing
@testable import SpringMotionDeviceWire

/// The framing is the one piece both ends implement against each other, so it
/// carries the risk that a bug shows up as a hang on a device rather than a
/// failure here. These cover the ways a stream actually arrives: split, merged,
/// and byte at a time.
@Suite struct FramingTests {
    private func decodeAll(_ decoder: inout FrameDecoder,
                           _ chunks: [Data]) throws -> [FrameDecoder.Output] {
        try chunks.flatMap { try decoder.feed($0) }
    }

    @Test func roundTripsOneMessage() throws {
        let payload = Data("hello".utf8)
        var decoder = FrameDecoder()
        let out = try decoder.feed(SpringMotionFraming.frame(payload))
        #expect(out == [.message(payload)])
    }

    @Test func decodesTwoMessagesArrivingInOneRead() throws {
        let a = Data("first".utf8), b = Data("second".utf8)
        var decoder = FrameDecoder()
        let merged = try SpringMotionFraming.frame(a) + SpringMotionFraming.frame(b)
        #expect(try decoder.feed(merged) == [.message(a), .message(b)])
    }

    /// The case that breaks naive implementations: a header split across reads.
    @Test func decodesAMessageArrivingOneByteAtATime() throws {
        let payload = Data("a longer payload, several bytes past the header".utf8)
        let framed = try SpringMotionFraming.frame(payload)
        var decoder = FrameDecoder()
        var out: [FrameDecoder.Output] = []
        for byte in framed {
            out += try decoder.feed(Data([byte]))
        }
        #expect(out == [.message(payload)])
    }

    /// `Data` slices keep their parent's indices, so a decoder that subscripts
    /// with literals after `removeFirst` reads garbage. This is that regression.
    @Test func staysCorrectAcrossManySequentialMessages() throws {
        var decoder = FrameDecoder()
        var out: [FrameDecoder.Output] = []
        let payloads = (0..<50).map { Data(String(repeating: "x", count: $0).utf8) }
        for payload in payloads {
            out += try decoder.feed(SpringMotionFraming.frame(payload))
        }
        #expect(out == payloads.map { .message($0) })
    }

    @Test func rejectsAnAbsurdLengthHeader() throws {
        var decoder = FrameDecoder()
        // 0x7FFFFFFF — a corrupt or hostile header that would otherwise become
        // a 2GB allocation on a device.
        let header = Data([0x7F, 0xFF, 0xFF, 0xFF])
        #expect(throws: SpringMotionFraming.FramingError.self) {
            _ = try decoder.feed(header)
        }
    }

    @Test func refusesToFrameAnOversizePayload() {
        let huge = Data(count: SpringMotionFraming.maximumMessageSize + 1)
        #expect(throws: SpringMotionFraming.FramingError.self) {
            _ = try SpringMotionFraming.frame(huge)
        }
    }

    // MARK: Blobs

    @Test func readsARawBlobBodyAfterItsAnnouncement() throws {
        let announcement = Data("blob-header".utf8)
        let body = Data((0..<1000).map { UInt8($0 % 251) })
        var decoder = FrameDecoder()

        let announced = try decoder.feed(SpringMotionFraming.frame(announcement))
        #expect(announced == [.message(announcement)])

        decoder.expectRaw(bytes: body.count)
        #expect(decoder.isReadingRaw)

        // Split the body, because a megabyte of video certainly will be.
        var out = try decoder.feed(body.prefix(400))
        out += try decoder.feed(body.dropFirst(400))
        #expect(out == [.raw(body.prefix(400)), .raw(body.dropFirst(400)), .rawFinished])
        #expect(!decoder.isReadingRaw)
    }

    /// Framing must resume the instant the blob's last byte lands, even when
    /// the next message shares the same read.
    @Test func resumesFramingAfterABlobInTheSameRead() throws {
        let body = Data(repeating: 7, count: 16)
        let next = Data("after".utf8)
        var decoder = FrameDecoder()
        decoder.expectRaw(bytes: body.count)
        let out = try decoder.feed(body + SpringMotionFraming.frame(next))
        #expect(out == [.raw(body), .rawFinished, .message(next)])
    }
}

/// The bug this API exists to prevent: a blob's announcement and its first
/// bytes arriving in one read. A decoder that interpreted the whole read at
/// once would parse the body as frames and desynchronise the stream for good.
@Suite struct BlobInterleavingTests {
    @Test func aBlobAnnouncedAndBodiedInOneReadIsReadCorrectly() throws {
        let announcement = Data("header".utf8)
        // Body bytes chosen to look like a plausible length header if misread.
        let body = Data([0x00, 0x00, 0x10, 0x00] + Array(repeating: UInt8(9), count: 60))
        let trailing = Data("after".utf8)

        var decoder = FrameDecoder()
        decoder.append(try SpringMotionFraming.frame(announcement)
                       + body
                       + SpringMotionFraming.frame(trailing))

        // Pull one unit, act on it, THEN pull the next — the real read loop.
        let first = try decoder.next()
        #expect(first == .message(announcement))
        decoder.expectRaw(bytes: body.count)

        var received = Data()
        var sawFinish = false
        var messagesAfter: [Data] = []
        while let unit = try decoder.next() {
            switch unit {
            case .raw(let chunk): received.append(chunk)
            case .rawFinished: sawFinish = true
            case .message(let payload): messagesAfter.append(payload)
            }
        }
        #expect(received == body)
        #expect(sawFinish)
        #expect(messagesAfter == [trailing])
    }
}
