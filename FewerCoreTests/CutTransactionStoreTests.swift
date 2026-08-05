import Foundation
import XCTest
@testable import FewerCore

final class CutTransactionStoreTests: XCTestCase {
    private var directory: URL!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testCreatesAndRestoresMatchingTransaction() throws {
        let store = CutTransactionStore(fileURL: directory.appendingPathComponent("cut.json"), now: { self.now })
        let urls = [directory.appendingPathComponent("A.txt")]
        try Data().write(to: urls[0])

        let started = try store.start(urls: urls, pasteboardChangeCount: 7)
        let restored = try store.load(currentPasteboardChangeCount: 7)

        XCTAssertEqual(restored, started)
    }

    func testPasteboardChangeInvalidatesTransaction() throws {
        let store = CutTransactionStore(fileURL: directory.appendingPathComponent("cut.json"), now: { self.now })
        let source = directory.appendingPathComponent("A.txt")
        try Data().write(to: source)
        _ = try store.start(urls: [source], pasteboardChangeCount: 7)

        XCTAssertNil(try store.load(currentPasteboardChangeCount: 8))
    }

    func testExpiredTransactionIsRemoved() throws {
        var clock = now
        let store = CutTransactionStore(
            fileURL: directory.appendingPathComponent("cut.json"),
            expirationInterval: 60,
            now: { clock }
        )
        _ = try store.start(urls: [directory.appendingPathComponent("A.txt")], pasteboardChangeCount: 7)
        clock = now.addingTimeInterval(61)

        XCTAssertNil(try store.load(currentPasteboardChangeCount: 7))
    }

    func testCompletingItemsKeepsOnlyFailures() throws {
        let store = CutTransactionStore(fileURL: directory.appendingPathComponent("cut.json"), now: { self.now })
        let a = directory.appendingPathComponent("A.txt")
        let b = directory.appendingPathComponent("B.txt")
        try Data().write(to: a)
        try Data().write(to: b)
        let transaction = try store.start(urls: [a, b], pasteboardChangeCount: 7)

        try store.keepRemaining([b], for: transaction.id)
        XCTAssertEqual(try store.load(currentPasteboardChangeCount: 7)?.remainingURLs, [b])
    }
}
