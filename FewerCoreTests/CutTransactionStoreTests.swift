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

    func testLegacyTransactionIsUpgradedToRevisionEnvelopeOnNextWrite() throws {
        let fileURL = directory.appendingPathComponent("cut.json")
        let source = directory.appendingPathComponent("A.txt")
        try Data().write(to: source)
        let legacy = CutTransaction(sourceURLs: [source], createdAt: now, pasteboardChangeCount: 7)
        try JSONEncoder().encode(legacy).write(to: fileURL)
        let store = CutTransactionStore(fileURL: fileURL, now: { self.now })

        try store.keepRemaining([source], for: legacy.id)

        XCTAssertEqual(try store.currentRevision(), 1)
    }

    func testMultipleStoreInstancesSerializeRevisionAdvances() throws {
        let fileURL = directory.appendingPathComponent("cut.json")
        let source = directory.appendingPathComponent("A.txt")
        try Data().write(to: source)
        let store = CutTransactionStore(fileURL: fileURL, now: { self.now })
        _ = try store.start(urls: [source], pasteboardChangeCount: 7)
        let fixedNow = now

        let group = DispatchGroup()
        let queue = DispatchQueue(label: "cut-store-test", attributes: .concurrent)
        for _ in 0..<4 {
            group.enter()
            queue.async {
                defer { group.leave() }
                _ = try? CutTransactionStore(fileURL: fileURL, now: { fixedNow })
                    .start(urls: [source], pasteboardChangeCount: 7)
            }
        }
        group.wait()

        XCTAssertEqual(try store.currentRevision(), 5)
    }

    func testSeparateProcessLockBlocksTransactionMutation() throws {
        let fileURL = directory.appendingPathComponent("cut.json")
        let source = directory.appendingPathComponent("A.txt")
        let lockURL = directory.appendingPathComponent(".cut-transaction.lock")
        let readyURL = directory.appendingPathComponent("worker-ready")
        let releaseURL = directory.appendingPathComponent("worker-release")
        try Data().write(to: source)

        let worker = Process()
        worker.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        worker.arguments = [
            "-e",
            "use Fcntl qw(:flock); open my $lock, '>>', $ARGV[0] or exit 1; flock($lock, LOCK_EX) or exit 2; open my $ready, '>', $ARGV[1] or exit 3; close $ready; select undef, undef, undef, 0.01 while !-e $ARGV[2]; exit 0;",
            lockURL.path,
            readyURL.path,
            releaseURL.path,
        ]
        try worker.run()
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: readyURL.path) {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: readyURL.path))

        let finished = DispatchSemaphore(value: 0)
        let fixedNow = now
        DispatchQueue.global().async {
            _ = try? CutTransactionStore(fileURL: fileURL, now: { fixedNow })
                .start(urls: [source], pasteboardChangeCount: 7)
            finished.signal()
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 0.1), .timedOut)

        try Data().write(to: releaseURL)
        worker.waitUntilExit()
        XCTAssertEqual(worker.terminationStatus, 0)
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)

        XCTAssertEqual(try CutTransactionStore(fileURL: fileURL, now: { self.now }).currentRevision(), 1)
    }
}
