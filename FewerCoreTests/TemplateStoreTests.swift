import Foundation
import XCTest
@testable import FewerCore

final class TemplateStoreTests: XCTestCase {
    private var root: URL!
    private var builtIns: URL!
    private var userTemplates: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        builtIns = root.appendingPathComponent("BuiltIns", isDirectory: true)
        userTemplates = root.appendingPathComponent("User", isDirectory: true)
        try FileManager.default.createDirectory(at: builtIns, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: userTemplates, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testImportCopiesSourceAndSurvivesSourceDeletion() throws {
        let source = root.appendingPathComponent("Example.json")
        try Data("{}\n".utf8).write(to: source)
        let store = TemplateStore(builtInDirectory: builtIns, userDirectory: userTemplates)

        let descriptor = try store.importTemplate(from: source, displayName: "API JSON")
        try FileManager.default.removeItem(at: source)

        XCTAssertTrue(FileManager.default.fileExists(atPath: try store.fileURL(for: descriptor).path))
        XCTAssertEqual(try store.templates().map(\.id), [descriptor.id])
    }

    func testUpdatesMetadataWithoutRenamingStableFile() throws {
        let source = root.appendingPathComponent("Example.txt")
        try Data().write(to: source)
        let store = TemplateStore(builtInDirectory: builtIns, userDirectory: userTemplates)
        var descriptor = try store.importTemplate(from: source, displayName: "Example")
        let originalURL = try store.fileURL(for: descriptor)

        descriptor.displayName = "Renamed"
        descriptor.isEnabled = false
        try store.update(descriptor)

        XCTAssertEqual(try store.templates().first?.displayName, "Renamed")
        XCTAssertEqual(try store.fileURL(for: descriptor), originalURL)
    }

    func testBuiltInTemplateCannotBeDeleted() throws {
        let store = TemplateStore(builtInDirectory: builtIns, userDirectory: userTemplates)
        XCTAssertThrowsError(try store.delete(.builtInPlainText))
    }
}
