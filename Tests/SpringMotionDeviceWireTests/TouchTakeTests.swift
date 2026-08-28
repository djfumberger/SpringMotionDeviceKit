import Foundation
import Testing
@testable import SpringMotionDeviceWire

@Suite struct TouchTakeTests {
    private func stroke(_ id: Int, from: TimeInterval, to: TimeInterval,
                        x: Float = 0.5, y: Float = 0.5) -> TouchTake.Stroke {
        TouchTake.Stroke(id: id, samples: [
            .init(t: from, x: x, y: y),
            .init(t: to, x: x, y: y),
        ])
    }

    @Test func aTakeSurvivesAJSONRoundTrip() throws {
        var take = TouchTake()
        take.strokes = [stroke(0, from: 0.5, to: 0.8)]
        take.duration = 4
        take.screen = .init(width: 393, height: 852, scale: 3,
                            pixelWidth: 1179, pixelHeight: 2556)
        take.device = .init(name: "Test", machine: "iPhone17,1")
        take.video = .init(firstFramePTS: 1234.5, firstFrameArrival: 1234.51)

        let decoded = try JSONDecoder().decode(
            TouchTake.self, from: JSONEncoder().encode(take))
        #expect(decoded == take)
    }

    // MARK: Concurrency counting — this is what decides how many touch
    // indicator layers Studio creates, so it has to be exact at the edges.

    @Test func countsOneFingerAsOneLane() {
        var take = TouchTake()
        take.strokes = [stroke(0, from: 0, to: 1), stroke(1, from: 2, to: 3)]
        #expect(take.maximumConcurrentStrokes == 1)
    }

    @Test func countsAPinchAsTwo() {
        var take = TouchTake()
        take.strokes = [stroke(0, from: 0, to: 1.5), stroke(1, from: 0.1, to: 1.4)]
        #expect(take.maximumConcurrentStrokes == 2)
    }

    @Test func countsAThreeFingerSwipeAsThree() {
        var take = TouchTake()
        take.strokes = [
            stroke(0, from: 0, to: 1),
            stroke(1, from: 0.02, to: 1.01),
            stroke(2, from: 0.04, to: 0.99),
        ]
        #expect(take.maximumConcurrentStrokes == 3)
    }

    /// A finger lifting at the exact instant another lands is ONE finger down.
    /// Counting it as two would spawn a spurious second indicator for every
    /// fast alternating tap sequence.
    @Test func aTouchDownAtTheInstantAnotherLiftsIsNotConcurrent() {
        var take = TouchTake()
        take.strokes = [stroke(0, from: 0, to: 1), stroke(1, from: 1, to: 2)]
        #expect(take.maximumConcurrentStrokes == 1)
    }

    @Test func anEmptyTakeNeedsNoLanes() {
        #expect(TouchTake().maximumConcurrentStrokes == 0)
    }

    // MARK: Taps

    @Test func aBriefStationaryStrokeIsATap() {
        let screen = SIMD2<Float>(393, 852)
        let tap = stroke(0, from: 0, to: 0.08)
        #expect(tap.isTap(screenSize: screen))
    }

    @Test func aDragIsNotATap() {
        let screen = SIMD2<Float>(393, 852)
        let drag = TouchTake.Stroke(id: 0, samples: [
            .init(t: 0, x: 0.2, y: 0.5),
            .init(t: 0.2, x: 0.8, y: 0.5),
        ])
        #expect(!drag.isTap(screenSize: screen))
    }

    @Test func aLongHoldIsNotATap() {
        let screen = SIMD2<Float>(393, 852)
        #expect(!stroke(0, from: 0, to: 2).isTap(screenSize: screen))
    }
}
