import Foundation
import XCTest
@testable import FewerCore

final class MenuBuilderTests: XCTestCase {
    private let target = URL(fileURLWithPath: "/tmp", isDirectory: true)

    func testContainerShowsNewFileAndPasteWhenTransactionExists() {
        let context = FinderMenuContext(
            kind: .container,
            selectedURLs: [],
            targetURL: target,
            isTargetWritable: true,
            hasCutTransaction: true
        )

        let entries = MenuBuilder().entries(
            for: context,
            settings: .default,
            templates: [TemplateDescriptor.builtInPlainText]
        )

        XCTAssertEqual(entries.map(\.command), [.newFile, .pasteHere])
        XCTAssertEqual(entries.first?.children.count, 1)
    }

    func testItemsShowCopyAndCut() {
        let context = FinderMenuContext(
            kind: .items,
            selectedURLs: [target.appendingPathComponent("A.txt")],
            targetURL: target,
            isTargetWritable: true,
            hasCutTransaction: false
        )

        let entries = MenuBuilder().entries(for: context, settings: .default, templates: [])
        XCTAssertEqual(entries.map(\.command), [.copyPath, .cut])
    }

    func testDisabledFeatureIsRemovedAndOrderIsRespected() {
        var settings = FeatureSettings.default
        settings.enabledFeatures.remove(.cut)
        settings.menuOrder = [.cut, .copyPath, .newFile, .paste]
        let context = FinderMenuContext(
            kind: .items,
            selectedURLs: [target.appendingPathComponent("A.txt")],
            targetURL: target,
            isTargetWritable: true,
            hasCutTransaction: false
        )

        let entries = MenuBuilder().entries(for: context, settings: settings, templates: [])
        XCTAssertEqual(entries.map(\.command), [.copyPath])
    }

    func testReadOnlyContainerDisablesMutatingEntries() {
        let context = FinderMenuContext(
            kind: .container,
            selectedURLs: [],
            targetURL: target,
            isTargetWritable: false,
            hasCutTransaction: true
        )

        let entries = MenuBuilder().entries(
            for: context,
            settings: .default,
            templates: [TemplateDescriptor.builtInPlainText]
        )

        XCTAssertEqual(entries.map(\.isEnabled), [false, false])
    }

    func testSelectedFolderShowsPasteIntoFolder() {
        let folder = target.appendingPathComponent("Folder", isDirectory: true)
        let context = FinderMenuContext(
            kind: .items,
            selectedURLs: [folder],
            targetURL: target,
            isTargetWritable: true,
            hasCutTransaction: true,
            isSingleSelectedItemDirectory: true
        )

        let entries = MenuBuilder().entries(for: context, settings: .default, templates: [])
        XCTAssertEqual(entries.map(\.command), [.copyPath, .cut, .pasteIntoFolder])
    }
}
