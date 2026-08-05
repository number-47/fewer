import Foundation
import XCTest
@testable import FewerCore

final class PathFormatterTests: XCTestCase {
    func testMultiplePOSIXPathsUseOneLinePerItem() {
        let urls = [URL(fileURLWithPath: "/tmp/One"), URL(fileURLWithPath: "/tmp/Two")]
        XCTAssertEqual(PathFormatter.string(for: urls, format: .posix), "/tmp/One\n/tmp/Two")
    }

    func testQuotedPathEscapesSingleQuoteForShell() {
        let url = URL(fileURLWithPath: "/tmp/It's here")
        XCTAssertEqual(PathFormatter.string(for: [url], format: .quoted), "'/tmp/It'\\''s here'")
    }

    func testFileURLUsesAbsoluteString() {
        let url = URL(fileURLWithPath: "/tmp/A File")
        XCTAssertEqual(PathFormatter.string(for: [url], format: .fileURL), "file:///tmp/A%20File")
    }
}
