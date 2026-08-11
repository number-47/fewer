import Foundation
import XCTest
@testable import FewerCore

final class ShortcutHelperStatusStoreTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        fileURL = directory.appendingPathComponent("helper-status.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        fileURL = nil
        directory = nil
        super.tearDown()
    }

    func testRoundTripsHelperStatus() throws {
        let store = ShortcutHelperStatusStore(fileURL: fileURL)
        let status = ShortcutHelperStatus(
            isAccessibilityTrusted: true,
            processIdentifier: 47,
            updatedAt: Date(timeIntervalSince1970: 1_234)
        )

        try store.save(status)

        XCTAssertEqual(store.load(), status)
    }

    func testCorruptStatusReturnsNil() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: fileURL)

        XCTAssertNil(ShortcutHelperStatusStore(fileURL: fileURL).load())
    }

    func testFreshnessRequiresRunningProcessAndRecentHeartbeat() {
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(ShortcutHelperStatus(
            isAccessibilityTrusted: false,
            processIdentifier: 47,
            updatedAt: now.addingTimeInterval(-4)
        ).isFresh(at: now))
        XCTAssertFalse(ShortcutHelperStatus(
            isAccessibilityTrusted: true,
            processIdentifier: 0,
            updatedAt: now
        ).isFresh(at: now))
        XCTAssertFalse(ShortcutHelperStatus(
            isAccessibilityTrusted: true,
            processIdentifier: 47,
            updatedAt: now.addingTimeInterval(-6)
        ).isFresh(at: now))
    }
}
