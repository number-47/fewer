import Foundation
import XCTest
import os.lock
@testable import FewerCore

final class SharedStoreMigratorTests: XCTestCase {
    private var oldRoot: URL!
    private var newRoot: URL!
    private var lockFile: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("FewerMigratorTests.\(UUID().uuidString)", isDirectory: true)
        oldRoot = base.appendingPathComponent("old", isDirectory: true)
        newRoot = base.appendingPathComponent("new", isDirectory: true)
        lockFile = base.appendingPathComponent(".fewer-migration.lock")
        try FileManager.default.createDirectory(at: oldRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        let base = oldRoot.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: base)
        oldRoot = nil
        newRoot = nil
        lockFile = nil
    }

    // MARK: - Pure resolution (App Group container)

    func testResolveSharedContainerUsesContainerWhenAvailable() {
        let container = URL(fileURLWithPath: "/tmp/container", isDirectory: true)
        let (directory, used) = AppGroupConstants.resolveSharedContainer(
            containerURL: container,
            homeDirectory: URL(fileURLWithPath: "/Users/test", isDirectory: true)
        )
        XCTAssertTrue(used)
        XCTAssertEqual(directory, container.appendingPathComponent("Shared", isDirectory: true))
    }

    func testResolveSharedContainerFallsBackWhenContainerNil() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let (directory, used) = AppGroupConstants.resolveSharedContainer(
            containerURL: nil,
            homeDirectory: home
        )
        XCTAssertFalse(used)
        XCTAssertEqual(
            directory,
            home.appendingPathComponent("Library/Application Support/Fewer/Shared", isDirectory: true)
        )
    }

    // MARK: - Migration behavior

    func testNoOldDataDoesNotCreateMarkerOrFiles() throws {
        let migrator = SharedStoreMigrator(oldRoot: oldRoot, newRoot: newRoot, lockFileURL: lockFile)
        let performed = try migrator.run()

        XCTAssertFalse(performed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: newRoot.path))
        // Old data untouched.
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldRoot.path))
    }

    func testFullMigrationCopiesKnownFilesAndTemplates() throws {
        try writeFile("feature-settings.json", content: "settings")
        try writeFile("input-enhancement-settings.json", content: "input")
        try writeFile("cut-transaction.json", content: "cut")
        try writeFile("module-preferences.json", content: "module")
        try writeFile("shortcut-helper-status.json", content: "status")
        try writeTemplate("tpl.txt", content: "template-body")

        let migrator = SharedStoreMigrator(oldRoot: oldRoot, newRoot: newRoot, lockFileURL: lockFile)
        let performed = try migrator.run()

        XCTAssertTrue(performed)
        for name in ["feature-settings.json", "input-enhancement-settings.json", "cut-transaction.json",
                     "module-preferences.json", "shortcut-helper-status.json"] {
            assertFileCopied(name, expected: nameContent(name))
        }
        assertFileCopied("Templates/tpl.txt", expected: "template-body")
        XCTAssertTrue(markerExists())

        // Old data preserved.
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldRoot.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldRoot.appendingPathComponent("feature-settings.json").path))
    }

    func testDestinationAlreadyExistingIsNotOverwritten() throws {
        try writeFile("feature-settings.json", content: "old-content")
        // Pre-existing, different content in the new root.
        try FileManager.default.createDirectory(at: newRoot, withIntermediateDirectories: true)
        try "new-content".write(
            to: newRoot.appendingPathComponent("feature-settings.json"),
            atomically: true,
            encoding: .utf8
        )

        let migrator = SharedStoreMigrator(oldRoot: oldRoot, newRoot: newRoot, lockFileURL: lockFile)
        _ = try migrator.run()

        let newContent = try String(contentsOf: newRoot.appendingPathComponent("feature-settings.json"), encoding: .utf8)
        XCTAssertEqual(newContent, "new-content", "Existing destination must not be overwritten")
        XCTAssertTrue(markerExists())
    }

    func testRepeatedRunIsIdempotent() throws {
        try writeFile("feature-settings.json", content: "settings")
        try writeTemplate("tpl.txt", content: "template-body")

        let migrator = SharedStoreMigrator(oldRoot: oldRoot, newRoot: newRoot, lockFileURL: lockFile)
        _ = try migrator.run()
        _ = try migrator.run()
        _ = try migrator.run()

        assertFileCopied("feature-settings.json", expected: "settings")
        assertFileCopied("Templates/tpl.txt", expected: "template-body")
        XCTAssertTrue(markerExists())
        // Exactly one copy of the file exists in the destination.
        let enumerator = FileManager.default.enumerator(atPath: newRoot.path)
        var jsonCount = 0
        while let entry = enumerator?.nextObject() as? String {
            if entry.hasSuffix("feature-settings.json") { jsonCount += 1 }
        }
        XCTAssertEqual(jsonCount, 1)
    }

    func testMidFlightFailureDoesNotWriteCompletionMarker() throws {
        try writeFile("feature-settings.json", content: "settings")
        // Make newRoot an existing file so createDirectory inside the migration fails.
        try "blocker".write(to: newRoot, atomically: true, encoding: .utf8)

        let migrator = SharedStoreMigrator(oldRoot: oldRoot, newRoot: newRoot, lockFileURL: lockFile)
        XCTAssertThrowsError(try migrator.run())
        XCTAssertFalse(markerExists())
        // Old data preserved even on failure.
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldRoot.appendingPathComponent("feature-settings.json").path))
    }

    func testConcurrentMigratorsAgree() throws {
        try writeFile("feature-settings.json", content: "settings")
        try writeTemplate("tpl.txt", content: "template-body")

        let group = DispatchGroup()
        let queue = DispatchQueue(label: "concurrent-migration", attributes: .concurrent)
        let resultsLock = OSAllocatedUnfairLock(initialState: [Bool]())

        for _ in 0..<4 {
            queue.async(group: group) {
                let migrator = SharedStoreMigrator(oldRoot: self.oldRoot, newRoot: self.newRoot, lockFileURL: self.lockFile)
                let performed: Bool
                do { performed = try migrator.run() } catch { performed = false }
                resultsLock.withLock { $0.append(performed) }
            }
        }
        group.wait()

        let results = resultsLock.withLock { $0 }
        XCTAssertTrue(results.allSatisfy { $0 })
        assertFileCopied("feature-settings.json", expected: "settings")
        assertFileCopied("Templates/tpl.txt", expected: "template-body")
        XCTAssertTrue(markerExists())
    }

    // MARK: - Helpers

    private func writeFile(_ name: String, content: String) throws {
        try content.write(
            to: oldRoot.appendingPathComponent(name),
            atomically: true,
            encoding: .utf8
        )
    }

    private func writeTemplate(_ name: String, content: String) throws {
        let dir = oldRoot.appendingPathComponent("Templates", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try content.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func nameContent(_ name: String) -> String {
        switch name {
        case "feature-settings.json": return "settings"
        case "input-enhancement-settings.json": return "input"
        case "cut-transaction.json": return "cut"
        case "module-preferences.json": return "module"
        case "shortcut-helper-status.json": return "status"
        default: return ""
        }
    }

    private func assertFileCopied(_ relative: String, expected: String, file: StaticString = #file, line: UInt = #line) {
        let url = newRoot.appendingPathComponent(relative)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "expected \(relative) to exist", file: file, line: line)
        if let content = try? String(contentsOf: url, encoding: .utf8) {
            XCTAssertEqual(content, expected, "content mismatch for \(relative)", file: file, line: line)
        }
    }

    private func markerExists() -> Bool {
        FileManager.default.fileExists(atPath: newRoot.appendingPathComponent(SharedStoreMigrator.completionMarkerName).path)
    }
}
