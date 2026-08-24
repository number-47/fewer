import CoreGraphics
import XCTest
@testable import FewerCore

final class StitchByteBudgetTests: XCTestCase {

    func testByteBudgetRejectsExcessiveOutput() {
        let config = StitchConfiguration(
            maximumPixelCount: 100_000_000,
            maximumHeight: 32_000,
            maximumFrameCount: 120,
            outputByteBudget: 1_000_000
        )
        // 500 * 200 * 4 = 400,000 bytes → within budget
        XCTAssertNil(StitchEngine.validateOutput(width: 500, height: 200, frameCount: 1, configuration: config))
        // 1000 * 1000 * 4 = 4,000,000 bytes → exceeds budget
        XCTAssertEqual(
            StitchEngine.validateOutput(width: 1000, height: 1000, frameCount: 1, configuration: config),
            .outputLimitExceeded
        )
    }

    func testByteBudgetAllowsWithinLimit() {
        let config = StitchConfiguration(outputByteBudget: 768_000_000)
        // 1920 * 1080 * 4 = 8,294,400 bytes → well within 768MB
        XCTAssertNil(StitchEngine.validateOutput(width: 1920, height: 1080, frameCount: 1, configuration: config))
    }

    func testByteBudgetOverflowSafe() {
        let config = StitchConfiguration(
            maximumPixelCount: Int.max,
            maximumHeight: Int.max,
            maximumFrameCount: 120,
            outputByteBudget: Int.max
        )
        // width * height * 4 would overflow Int → should return outputLimitExceeded
        XCTAssertEqual(
            StitchEngine.validateOutput(width: Int.max / 2, height: Int.max / 2, frameCount: 1, configuration: config),
            .outputLimitExceeded
        )
    }

    func testDefaultByteBudgetMatches64MPixels() {
        XCTAssertEqual(StitchConfiguration.default.outputByteBudget, 768_000_000)
    }

    func testByteBudgetZeroRejectsEverything() {
        let config = StitchConfiguration(
            maximumPixelCount: 100_000_000,
            maximumHeight: 32_000,
            maximumFrameCount: 120,
            outputByteBudget: 0
        )
        XCTAssertEqual(
            StitchEngine.validateOutput(width: 100, height: 100, frameCount: 1, configuration: config),
            .outputLimitExceeded
        )
    }
}
