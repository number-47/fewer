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
}
