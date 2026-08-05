import XCTest
@testable import FewerCore

final class FinderShortcutRouterTests: XCTestCase {
    func testNonFinderAlwaysPassesThrough() {
        XCTAssertEqual(
            FinderShortcutRouter.decision(
                frontmostBundleID: "com.apple.Safari",
                isEnabled: true,
                isAccessibilityTrusted: true,
                key: .x,
                modifiers: [.command],
                hasValidCutTransaction: false
            ),
            .passThrough
        )
    }

    func testCommandXInFinderCapturesCut() {
        XCTAssertEqual(
            FinderShortcutRouter.decision(
                frontmostBundleID: "com.apple.finder",
                isEnabled: true,
                isAccessibilityTrusted: true,
                key: .x,
                modifiers: [.command],
                hasValidCutTransaction: false
            ),
            .captureCut
        )
    }

    func testCommandVOnlyMovesForValidTransaction() {
        let input = FinderShortcutRouter.decision(
            frontmostBundleID: "com.apple.finder",
            isEnabled: true,
            isAccessibilityTrusted: true,
            key: .v,
            modifiers: [.command],
            hasValidCutTransaction: true
        )
        XCTAssertEqual(input, .performFinderMovePaste)

        let ordinaryPaste = FinderShortcutRouter.decision(
            frontmostBundleID: "com.apple.finder",
            isEnabled: true,
            isAccessibilityTrusted: true,
            key: .v,
            modifiers: [.command],
            hasValidCutTransaction: false
        )
        XCTAssertEqual(ordinaryPaste, .passThrough)
    }

    func testDisabledOrUntrustedPassesThrough() {
        XCTAssertEqual(
            FinderShortcutRouter.decision(
                frontmostBundleID: "com.apple.finder",
                isEnabled: false,
                isAccessibilityTrusted: true,
                key: .x,
                modifiers: [.command],
                hasValidCutTransaction: false
            ),
            .passThrough
        )
    }
}
