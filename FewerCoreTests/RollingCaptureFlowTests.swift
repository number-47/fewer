import XCTest
@testable import FewerCore

final class RollingCaptureFlowTests: XCTestCase {
    func testManualCaptureCanPauseResumeAndComplete() {
        var phase = RollingCapturePhase.idle
        phase = RollingCaptureTransitions.next(from: phase, event: .start)!
        phase = RollingCaptureTransitions.next(from: phase, event: .firstFrameCaptured)!
        phase = RollingCaptureTransitions.next(from: phase, event: .pause)!
        phase = RollingCaptureTransitions.next(from: phase, event: .resume)!
        phase = RollingCaptureTransitions.next(from: phase, event: .beginFinishing)!
        phase = RollingCaptureTransitions.next(from: phase, event: .complete)!
        XCTAssertEqual(phase, .completed)
    }

    func testPausedCaptureCanFinishExistingFrames() {
        XCTAssertEqual(
            RollingCaptureTransitions.next(from: .paused, event: .beginFinishing),
            .finishing
        )
    }

    func testPreparationFailureCanPauseAndRetry() {
        let paused = RollingCaptureTransitions.next(from: .preparing, event: .pause)!
        XCTAssertEqual(paused, .paused)
        XCTAssertEqual(
            RollingCaptureTransitions.next(from: paused, event: .retryPreparation),
            .preparing
        )
    }

    func testCaptureCanCancelFromEveryActivePhase() {
        for phase in [
            RollingCapturePhase.preparing,
            .capturing,
            .paused,
            .finishing,
        ] {
            XCTAssertEqual(RollingCaptureTransitions.next(from: phase, event: .cancel), .cancelled)
        }
    }

    func testInvalidTransitionsAreRejected() {
        XCTAssertNil(RollingCaptureTransitions.next(from: .idle, event: .complete))
        XCTAssertNil(RollingCaptureTransitions.next(from: .completed, event: .resume))
        XCTAssertNil(RollingCaptureTransitions.next(from: .cancelled, event: .start))
    }

    func testFrameBufferDeliversBridgeFramesInCaptureOrder() {
        var buffer = RollingFrameBuffer<Int>(capacity: 3)
        buffer.append(1)
        buffer.append(2)
        buffer.append(3)

        XCTAssertEqual(buffer.removeNext(), 1)
        XCTAssertEqual(buffer.removeNext(), 2)
        XCTAssertEqual(buffer.removeNext(), 3)
        XCTAssertNil(buffer.removeNext())
    }

    func testFrameBufferDropsOnlyOldestFrameWhenCapacityIsExceeded() {
        var buffer = RollingFrameBuffer<Int>(capacity: 2)
        buffer.append(1)
        buffer.append(2)
        buffer.append(3)

        XCTAssertEqual(buffer.removeNext(), 2)
        XCTAssertEqual(buffer.removeNext(), 3)
    }

    func testFrameBufferCanDiscardFramesFromBeforeScrollBoundary() {
        var buffer = RollingFrameBuffer<Int>(capacity: 3)
        buffer.append(1)
        buffer.append(2)

        buffer.removeAll()
        buffer.append(3)

        XCTAssertEqual(buffer.removeNext(), 3)
        XCTAssertNil(buffer.removeNext())
    }
}
