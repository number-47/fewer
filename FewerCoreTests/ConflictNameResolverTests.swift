import Foundation
import XCTest
@testable import FewerCore

final class ConflictNameResolverTests: XCTestCase {
    func testAddsNumberBeforeSimpleExtension() {
        XCTAssertEqual(ConflictNameResolver.numberedName(for: "Report.docx", number: 2), "Report 2.docx")
    }

    func testPreservesKnownCompoundExtension() {
        XCTAssertEqual(ConflictNameResolver.numberedName(for: "Archive.tar.gz", number: 2), "Archive 2.tar.gz")
    }

    func testHandlesHiddenAndExtensionlessNames() {
        XCTAssertEqual(ConflictNameResolver.numberedName(for: ".env", number: 2), ".env 2")
        XCTAssertEqual(ConflictNameResolver.numberedName(for: "README", number: 3), "README 3")
    }

    func testFindsFirstAvailableURL() {
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
        let existing = Set(["Report.txt", "Report 2.txt"])
        let result = ConflictNameResolver.availableURL(
            named: "Report.txt",
            in: directory,
            exists: { existing.contains($0.lastPathComponent) }
        )

        XCTAssertEqual(result.lastPathComponent, "Report 3.txt")
    }
}
