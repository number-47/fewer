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

    func testManualStopProcessesPendingFramesBeforeCompleting() {
        let finishing = RollingCaptureTransitions.next(from: .capturing, event: .beginFinishing)
        XCTAssertEqual(finishing, .finishing)
        XCTAssertEqual(
            RollingCaptureTransitions.next(from: finishing!, event: .complete),
            .completed
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

    func testFrameBufferDropsOldestFrameWhenCapacityIsExceeded() {
        var buffer = RollingFrameBuffer<Int>(capacity: 2)
        buffer.append(1)
        buffer.append(2)
        buffer.append(3)

        // 队列满时丢弃最旧的待消费帧，让队列始终保留最近捕获的画面，
        // 避免消费端积压耗尽后帧间隔跳变。
        XCTAssertEqual(buffer.removeNext(), 2)
        XCTAssertEqual(buffer.removeNext(), 3)
        XCTAssertNil(buffer.removeNext())
    }

    func testFrameBufferKeepsUniformSequenceWhenContinuouslyOverCapacity() {
        var buffer = RollingFrameBuffer<Int>(capacity: 3)
        for value in 1...6 {
            buffer.append(value)
        }

        XCTAssertEqual(buffer.removeNext(), 4)
        XCTAssertEqual(buffer.removeNext(), 5)
        XCTAssertEqual(buffer.removeNext(), 6)
        XCTAssertNil(buffer.removeNext())
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
