import Foundation
import XCTest
@testable import FewerCore

final class TerminalAppTests: XCTestCase {
    func testBuiltInCatalogContainsTerminalAndITerm2() {
        XCTAssertEqual(CommonTerminal.all.count, 2)
        XCTAssertEqual(CommonTerminal.all[0].name, "Terminal")
        XCTAssertEqual(CommonTerminal.all[0].bundleIdentifier, "com.apple.Terminal")
        XCTAssertEqual(CommonTerminal.all[1].name, "iTerm2")
        XCTAssertEqual(CommonTerminal.all[1].bundleIdentifier, "com.googlecode.iterm2")
    }

    func testBuiltInBundleIdentifiersAreUnique() {
        let identifiers = CommonTerminal.all.map(\.bundleIdentifier)
        XCTAssertEqual(Set(identifiers).count, identifiers.count)
    }

    func testMatchBuiltInTerminalByBundleIdentifier() {
        XCTAssertEqual(
            CommonTerminal.commonTerminal(matchingBundleID: "com.googlecode.iterm2")?.name,
            "iTerm2"
        )
    }

    func testUnknownBundleIdentifierDoesNotMatchBuiltIn() {
        XCTAssertNil(CommonTerminal.commonTerminal(matchingBundleID: "com.example.custom"))
    }
}
