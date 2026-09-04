import Foundation
import XCTest
@testable import FewerCore

final class FileOperationCoordinatorTests: XCTestCase {
    private var root: URL!
    private var source: URL!
    private var target: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        source = root.appendingPathComponent("Source", isDirectory: true)
        target = root.appendingPathComponent("Target", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testMovesMultipleItemsInOrder() async throws {
        let a = source.appendingPathComponent("A.txt")
        let b = source.appendingPathComponent("B.txt")
        try Data("A".utf8).write(to: a)
        try Data("B".utf8).write(to: b)

        let result = await FileOperationCoordinator().move([a, b], to: target, policy: .keepBoth)

        XCTAssertEqual(result.items.map(\.status), [.moved, .moved])
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("A.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("B.txt").path))
    }

    func testKeepBothUsesNumberedName() async throws {
        let item = source.appendingPathComponent("Report.txt")
        try Data("new".utf8).write(to: item)
        try Data("old".utf8).write(to: target.appendingPathComponent("Report.txt"))

        let result = await FileOperationCoordinator().move([item], to: target, policy: .keepBoth)

        XCTAssertEqual(result.items.first?.destinationURL?.lastPathComponent, "Report 2.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("Report 2.txt").path))
    }

    func testSkipLeavesSourceUntouched() async throws {
        let item = source.appendingPathComponent("Report.txt")
        try Data("new".utf8).write(to: item)
        try Data("old".utf8).write(to: target.appendingPathComponent("Report.txt"))

        let result = await FileOperationCoordinator().move([item], to: target, policy: .skip)

        XCTAssertEqual(result.items.first?.status, .skipped)
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.path))
    }

    func testRejectsMovingFolderIntoItsDescendant() async throws {
        let folder = source.appendingPathComponent("Folder", isDirectory: true)
        let child = folder.appendingPathComponent("Child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)

        let result = await FileOperationCoordinator().move([folder], to: child, policy: .keepBoth)

        XCTAssertEqual(result.items.first?.status, .failed)
        XCTAssertEqual(result.items.first?.error, .destinationInsideSource)
    }

    // MARK: - Batch rename

    func testBatchRenameRulePreservesExtension() {
        let rule = BatchRenameRule(
            findText: "Report",
            replacementText: "Invoice",
            prefix: "2026-",
            suffix: "-final",
            addsSequenceNumber: true,
            sequenceStart: 3
        )

        XCTAssertEqual(
            rule.renamedName(for: "Report.txt", isDirectory: false, index: 0),
            "2026-Invoice-final 3.txt"
        )
        XCTAssertEqual(
            rule.renamedName(for: "Folder.name", isDirectory: true, index: 1),
            "2026-Folder.name-final 4"
        )
    }

    func testBatchRenamePlannerRejectsDuplicateDestinations() {
        let first = source.appendingPathComponent("A.txt")
        let second = source.appendingPathComponent("B.txt")
        let rule = BatchRenameRule(findText: "A", replacementText: "B")

        let plan = BatchRenamePlanner.plan(
            urls: [first, second],
            rule: rule,
            fileExists: { _ in false },
            isDirectory: { _ in false }
        )

        XCTAssertFalse(plan.canExecute)
        XCTAssertTrue(plan.issues.contains {
            if case .duplicateDestination = $0 { return true }
            return false
        })
    }

    func testBatchRenamePlannerRejectsInvalidAndExternalDestination() {
        let first = source.appendingPathComponent("A.txt")
        let second = source.appendingPathComponent("B.txt")
        let invalid = BatchRenamePlanner.plan(
            urls: [first, second],
            rule: BatchRenameRule(prefix: "/"),
            fileExists: { _ in false },
            isDirectory: { _ in false }
        )
        XCTAssertTrue(invalid.issues.contains {
            if case .invalidName = $0 { return true }
            return false
        })

        let external = BatchRenamePlanner.plan(
            urls: [first, second],
            rule: BatchRenameRule(prefix: "New-"),
            fileExists: { $0.lastPathComponent == "New-A.txt" },
            isDirectory: { _ in false }
        )
        XCTAssertTrue(external.issues.contains {
            if case .destinationExists = $0 { return true }
            return false
        })
    }

    func testBatchRenamePlannerRejectsEmptyNameAndNoChanges() {
        let first = source.appendingPathComponent("A")
        let second = source.appendingPathComponent("B")
        let emptyName = BatchRenamePlanner.plan(
            urls: [first, second],
            rule: BatchRenameRule(findText: "A", replacementText: ""),
            fileExists: { _ in false },
            isDirectory: { _ in false }
        )
        XCTAssertTrue(emptyName.issues.contains {
            if case let .invalidName(sourceURL, proposedName) = $0 {
                return sourceURL == first && proposedName.isEmpty
            }
            return false
        })

        let noChanges = BatchRenamePlanner.plan(
            urls: [first, second],
            rule: BatchRenameRule(),
            fileExists: { _ in false },
            isDirectory: { _ in false }
        )
        XCTAssertEqual(noChanges.issues, [.noChanges])
        XCTAssertFalse(noChanges.canExecute)
    }

    func testBatchRenameSupportsNameSwap() async throws {
        let a = source.appendingPathComponent("A.txt")
        let b = source.appendingPathComponent("B.txt")
        try Data("A".utf8).write(to: a)
        try Data("B".utf8).write(to: b)
        let plan = BatchRenamePlan(
            items: [
                BatchRenameItem(sourceURL: a, destinationURL: b),
                BatchRenameItem(sourceURL: b, destinationURL: a),
            ],
            issues: []
        )

        let result = await FileOperationCoordinator().batchRename(plan)

        XCTAssertEqual(result.outcome, .success)
        XCTAssertEqual(try Data(contentsOf: a), Data("B".utf8))
        XCTAssertEqual(try Data(contentsOf: b), Data("A".utf8))
        XCTAssertFalse(hasRenameRemnant(in: source))
    }

    func testBatchRenameInstallFailureRollsBackOriginalNames() async throws {
        let a = source.appendingPathComponent("A.txt")
        let b = source.appendingPathComponent("B.txt")
        try Data("A".utf8).write(to: a)
        try Data("B".utf8).write(to: b)
        let plan = BatchRenamePlan(
            items: [
                BatchRenameItem(sourceURL: a, destinationURL: source.appendingPathComponent("One.txt")),
                BatchRenameItem(sourceURL: b, destinationURL: source.appendingPathComponent("Two.txt")),
            ],
            issues: []
        )
        let injector = BatchRenameFailureInjector { phase in
            if phase == .install(1) {
                throw TestReplaceError.simulated
            }
        }

        let result = await FileOperationCoordinator().batchRename(plan, failureInjector: injector)

        XCTAssertEqual(result.outcome, .failedRolledBack)
        XCTAssertEqual(try Data(contentsOf: a), Data("A".utf8))
        XCTAssertEqual(try Data(contentsOf: b), Data("B".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.appendingPathComponent("One.txt").path))
        XCTAssertFalse(hasRenameRemnant(in: source))
    }

    // MARK: - Recoverable replace

    private enum TestReplaceError: Error { case simulated }

    func testReplaceSucceedsWithCorrectContentAndNoBackup() async throws {
        let item = source.appendingPathComponent("Report.txt")
        try Data("new content".utf8).write(to: item)
        try Data("old content".utf8).write(to: target.appendingPathComponent("Report.txt"))

        let result = await FileOperationCoordinator().move([item], to: target, policy: .replace)

        XCTAssertEqual(result.items.first?.status, .moved)
        let dest = target.appendingPathComponent("Report.txt")
        XCTAssertEqual(try Data(contentsOf: dest), Data("new content".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.path))
        XCTAssertFalse(hasBackupRemnant(in: target), "不应残留备份文件")
    }

    func testReplaceInstallFailureRecoversOriginalByteForByte() async throws {
        let item = source.appendingPathComponent("Report.txt")
        let oldData = Data("old content".utf8)
        try Data("new content".utf8).write(to: item)
        try oldData.write(to: target.appendingPathComponent("Report.txt"))

        let injector = ReplaceFailureInjector { phase in
            if phase == .install { throw TestReplaceError.simulated }
        }

        let result = await FileOperationCoordinator().move([item], to: target, policy: .replace, replaceFailureInjector: injector)

        let first = result.items.first!
        XCTAssertEqual(first.status, .failed)
        XCTAssertEqual(first.error, .systemError)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("Report.txt")), oldData)
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.path), "源文件未被移动")
        XCTAssertFalse(hasBackupRemnant(in: target), "回滚成功后不应残留备份")
    }

    func testReplaceRollbackFailureReturnsNotRecoverable() async throws {
        let item = source.appendingPathComponent("Report.txt")
        let oldData = Data("old content".utf8)
        try Data("new content".utf8).write(to: item)
        try oldData.write(to: target.appendingPathComponent("Report.txt"))

        let injector = ReplaceFailureInjector { phase in
            switch phase {
            case .install, .rollback: throw TestReplaceError.simulated
            case .cleanup: break
            }
        }

        let result = await FileOperationCoordinator().move([item], to: target, policy: .replace, replaceFailureInjector: injector)

        let first = result.items.first!
        XCTAssertEqual(first.status, .failed)
        XCTAssertEqual(first.error, .replacementNotRecoverable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("Report.txt").path), "目标已被重命名为备份，回滚失败后目标不存在")
        let backups = backupRemnants(in: target)
        XCTAssertEqual(backups.count, 1, "应保留唯一备份（旧内容）")
        XCTAssertEqual(try Data(contentsOf: backups[0]), oldData, "备份包含旧内容")
    }

    func testReplaceCleanupFailureLeavesNewContentAndBackup() async throws {
        let item = source.appendingPathComponent("Report.txt")
        try Data("new content".utf8).write(to: item)
        try Data("old content".utf8).write(to: target.appendingPathComponent("Report.txt"))

        let injector = ReplaceFailureInjector { phase in
            if phase == .cleanup { throw TestReplaceError.simulated }
        }

        let result = await FileOperationCoordinator().move([item], to: target, policy: .replace, replaceFailureInjector: injector)

        let first = result.items.first!
        XCTAssertEqual(first.status, .moved, "安装成功后报告 moved")
        let dest = target.appendingPathComponent("Report.txt")
        XCTAssertEqual(try Data(contentsOf: dest), Data("new content".utf8), "目标已含新内容")
        let backups = backupRemnants(in: target)
        XCTAssertEqual(backups.count, 1, "清理失败后残留一个备份")
        XCTAssertEqual(try Data(contentsOf: backups[0]), Data("old content".utf8), "备份含旧内容")
    }

    func testReplaceDirectorySucceeds() async throws {
        let srcDir = source.appendingPathComponent("Project", isDirectory: true)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try Data("new file".utf8).write(to: srcDir.appendingPathComponent("file.txt"))

        let destDir = target.appendingPathComponent("Project", isDirectory: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        try Data("old file".utf8).write(to: destDir.appendingPathComponent("legacy.txt"))

        let result = await FileOperationCoordinator().move([srcDir], to: target, policy: .replace)

        XCTAssertEqual(result.items.first?.status, .moved)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destDir.appendingPathComponent("file.txt").path))
        XCTAssertEqual(try Data(contentsOf: destDir.appendingPathComponent("file.txt")), Data("new file".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destDir.appendingPathComponent("legacy.txt").path), "旧目录内容应被替换")
        XCTAssertFalse(hasBackupRemnant(in: target), "不应残留备份目录")
    }

    // MARK: - Helpers

    private func hasBackupRemnant(in directory: URL) -> Bool {
        !backupRemnants(in: directory).isEmpty
    }

    private func hasRenameRemnant(in directory: URL) -> Bool {
        let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return entries.contains { $0.lastPathComponent.hasPrefix(".fewer-rename-") }
    }

    private func backupRemnants(in directory: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return entries.filter { $0.lastPathComponent.contains(".fewer-replace-") }
    }
}
