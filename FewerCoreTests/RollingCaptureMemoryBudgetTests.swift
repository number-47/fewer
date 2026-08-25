import XCTest
@testable import FewerCore

final class RollingCaptureMemoryBudgetTests: XCTestCase {
    func testDefaultBudgetIs256MiB() {
        XCTAssertEqual(RollingCaptureMemoryBudget.defaultByteLimit, 256 * 1024 * 1024)
    }

    func testResidentBytesCountsSharedBackingOnce() {
        let budget = RollingCaptureMemoryBudget(byteLimit: 400)
        let images = [
            image(token: 0, backing: 1, bytes: 400, originY: 0, removable: false),
            image(token: -1, backing: 1, bytes: 400, originY: 100, removable: false),
        ]

        XCTAssertEqual(budget.residentBytes(for: images), 400)
        XCTAssertEqual(budget.plan(for: images, maximumSnapshotGap: 200), .withinBudget)
    }

    func testPendingPromotionDoesNotDoubleCountItsBacking() {
        let budget = RollingCaptureMemoryBudget(byteLimit: 800)
        let images = [
            image(token: 0, backing: 1, bytes: 400, originY: 0, removable: false),
            image(token: 1, backing: 2, bytes: 400, originY: 200, removable: true),
            image(token: -2, backing: 2, bytes: 400, originY: 200, removable: false),
        ]

        XCTAssertEqual(budget.residentBytes(for: images), 800)
        XCTAssertEqual(budget.plan(for: images, maximumSnapshotGap: 400), .withinBudget)
    }

    func testIndependentPendingBackingAtStoredOriginStillCounts() {
        let budget = RollingCaptureMemoryBudget(byteLimit: 400)
        let images = [
            image(token: 0, backing: 1, bytes: 400, originY: 0, removable: false),
            image(
                token: -1,
                backing: 2,
                bytes: 400,
                originY: 0,
                removable: false,
                participatesInSnapshotChain: false
            ),
        ]

        XCTAssertEqual(budget.residentBytes(for: images), 800)
        XCTAssertEqual(budget.plan(for: images, maximumSnapshotGap: 400), .limitExceeded)
    }

    func testThinningRemovesOnlySafeMiddleKeyframeForDownwardCapture() {
        let budget = RollingCaptureMemoryBudget(byteLimit: 800)
        let images = [
            image(token: 0, backing: 1, bytes: 400, originY: 0, removable: false),
            image(token: 1, backing: 2, bytes: 400, originY: 200, removable: true),
            image(token: 2, backing: 3, bytes: 400, originY: 400, removable: false),
        ]

        XCTAssertEqual(
            budget.plan(for: images, maximumSnapshotGap: 400),
            .thin(keyframeTokens: [1])
        )
    }

    func testThinningRemovesOnlySafeMiddleKeyframeForUpwardCapture() {
        let budget = RollingCaptureMemoryBudget(byteLimit: 800)
        let images = [
            image(token: 0, backing: 1, bytes: 400, originY: -400, removable: false),
            image(token: 1, backing: 2, bytes: 400, originY: -200, removable: true),
            image(token: 2, backing: 3, bytes: 400, originY: 0, removable: false),
        ]

        XCTAssertEqual(
            budget.plan(for: images, maximumSnapshotGap: 400),
            .thin(keyframeTokens: [1])
        )
    }

    func testBudgetFailsWhenRemovingMiddleKeyframeWouldBreakSnapshotChain() {
        let budget = RollingCaptureMemoryBudget(byteLimit: 800)
        let images = [
            image(token: 0, backing: 1, bytes: 400, originY: 0, removable: false),
            image(token: 1, backing: 2, bytes: 400, originY: 400, removable: true),
            image(token: 2, backing: 3, bytes: 400, originY: 800, removable: false),
        ]

        XCTAssertEqual(budget.plan(for: images, maximumSnapshotGap: 500), .limitExceeded)
    }

    func testPreviewBackingDoesNotBecomeASnapshotBoundary() {
        let budget = RollingCaptureMemoryBudget(byteLimit: 900)
        let images = [
            image(token: 0, backing: 1, bytes: 400, originY: 0, removable: false),
            image(token: 1, backing: 2, bytes: 400, originY: 200, removable: true),
            image(token: 2, backing: 3, bytes: 400, originY: 400, removable: false),
            image(
                token: -3,
                backing: 4,
                bytes: 100,
                originY: 0,
                removable: false,
                participatesInSnapshotChain: false
            ),
        ]

        XCTAssertEqual(
            budget.plan(for: images, maximumSnapshotGap: 400),
            .thin(keyframeTokens: [1])
        )
    }

    func testResidentByteCountSaturatesOnOverflow() {
        let budget = RollingCaptureMemoryBudget()
        let images = [
            image(token: 0, backing: 1, bytes: Int.max, height: 2, originY: 0, removable: false),
        ]

        XCTAssertEqual(budget.residentBytes(for: images), Int.max)
    }

    private func image(
        token: Int,
        backing: UInt64,
        bytes: Int,
        height: Int = 1,
        originY: Int,
        removable: Bool,
        participatesInSnapshotChain: Bool = true
    ) -> RollingCaptureMemoryBudget.Image {
        RollingCaptureMemoryBudget.Image(
            token: token,
            backingIdentifier: backing,
            bytesPerRow: bytes,
            height: height,
            originY: originY,
            isRemovableKeyframe: removable,
            participatesInSnapshotChain: participatesInSnapshotChain
        )
    }
}
