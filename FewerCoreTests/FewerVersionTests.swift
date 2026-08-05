import XCTest
@testable import FewerCore

final class FewerVersionTests: XCTestCase {
    func testCurrentVersionMatchesInitialRelease() {
        XCTAssertEqual(FewerVersion.current, "0.1.0")
    }
}
