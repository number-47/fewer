import Foundation
import XCTest
@testable import FewerCore

final class TemplateFileCreatorTests: XCTestCase {
    private var root: URL!
    private var templateDir: URL!
    private var target: URL!

    private enum TestReplaceError: Error { case simulated }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        templateDir = root.appendingPathComponent("Templates", isDirectory: true)
        target = root.appendingPathComponent("Target", isDirectory: true)
        try FileManager.default.createDirectory(at: templateDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeTemplate(content: String) throws -> (URL, TemplateDescriptor) {
        let url = templateDir.appendingPathComponent("Template.txt")
        try Data(content.utf8).write(to: url)
        let descriptor = TemplateDescriptor(
            id: UUID(),
            displayName: "Note",
            fileExtension: "txt",
            resourceName: "Template",
            source: .user
        )
        return (url, descriptor)
    }

    func testCreateReplacesExistingFile() throws {
        let (templateURL, descriptor) = try makeTemplate(content: "new template")
        let dest = target.appendingPathComponent("新建 Note.txt")
        try Data("old content".utf8).write(to: dest)

        let result = try TemplateFileCreator().create(from: templateURL, descriptor: descriptor, in: target, policy: .replace)

        XCTAssertEqual(result, dest)
        XCTAssertEqual(try Data(contentsOf: dest), Data("new template".utf8))
        XCTAssertFalse(hasBackupRemnant(in: target), "不应残留备份文件")
        XCTAssertTrue(FileManager.default.fileExists(atPath: templateURL.path), "模板源文件保留")
    }

    func testCreateReplaceInstallFailureThrowsSystemErrorAndRecoversOriginal() throws {
        let (templateURL, descriptor) = try makeTemplate(content: "new template")
        let oldData = Data("old content".utf8)
        try oldData.write(to: target.appendingPathComponent("新建 Note.txt"))

        let injector = ReplaceFailureInjector { phase in
            if phase == .install { throw TestReplaceError.simulated }
        }

        XCTAssertThrowsError(try TemplateFileCreator().create(from: templateURL, descriptor: descriptor, in: target, policy: .replace, replaceFailureInjector: injector)) { error in
            XCTAssertEqual(error as? FileOperationError, .systemError)
        }
        let dest = target.appendingPathComponent("新建 Note.txt")
        XCTAssertEqual(try Data(contentsOf: dest), oldData, "原文件字节级恢复")
        XCTAssertFalse(hasBackupRemnant(in: target), "回滚成功后不应残留备份")
    }

    func testCreateReplaceRollbackFailureThrowsNotRecoverable() throws {
        let (templateURL, descriptor) = try makeTemplate(content: "new template")
        let oldData = Data("old content".utf8)
        try oldData.write(to: target.appendingPathComponent("新建 Note.txt"))

        let injector = ReplaceFailureInjector { phase in
            switch phase {
            case .install, .rollback: throw TestReplaceError.simulated
            case .cleanup: break
            }
        }

        XCTAssertThrowsError(try TemplateFileCreator().create(from: templateURL, descriptor: descriptor, in: target, policy: .replace, replaceFailureInjector: injector)) { error in
            XCTAssertEqual(error as? FileOperationError, .replacementNotRecoverable)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("新建 Note.txt").path), "目标已被重命名为备份")
        let backups = backupRemnants(in: target)
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: backups[0]), oldData, "备份含旧内容")
    }

    // MARK: - Helpers

    private func hasBackupRemnant(in directory: URL) -> Bool {
        !backupRemnants(in: directory).isEmpty
    }

    private func backupRemnants(in directory: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return entries.filter { $0.lastPathComponent.contains(".fewer-replace-") }
    }
}
