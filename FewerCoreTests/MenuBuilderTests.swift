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

        XCTAssertEqual(entries.map(\.command), [
            .newFile, .newFolder, .copyPath, .copyAs(.absolutePath),
            .pasteHere, .openInTerminal, .refresh,
        ])
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
        XCTAssertEqual(entries.map(\.command), [
            .copyPath, .copyAs(.absolutePath), .cut, .openInTerminal,
            .openWith(bundleIdentifier: ""), .refresh,
        ])
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

        // 复制路径是读操作，只读容器下仍可用
        XCTAssertEqual(entries.map(\.isEnabled), [false, false, true, true, false, true, true])
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
        XCTAssertEqual(entries.map(\.command), [
            .copyPath, .copyAs(.absolutePath), .cut, .pasteIntoFolder,
            .openInTerminal, .openWith(bundleIdentifier: ""), .refresh,
        ])
    }

    func testOpenInTerminalCanBeDisabledAndRepositioned() {
        var settings = FeatureSettings.default
        settings.enabledFeatures.remove(.openInTerminal)
        settings.menuOrder = [.openInTerminal, .copyPath]
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
    func testContainerShowsRefreshInDefaultOrder() {
        let context = FinderMenuContext(
            kind: .container,
            selectedURLs: [],
            targetURL: target,
            isTargetWritable: true,
            hasCutTransaction: false
        )

        let entries = MenuBuilder().entries(for: context, settings: .default, templates: [])

        // 默认排序下「刷新」追加到菜单末尾
        XCTAssertEqual(entries.last?.command, .refresh)
    }

    func testItemsShowRefresh() {
        let context = FinderMenuContext(
            kind: .items,
            selectedURLs: [target.appendingPathComponent("A.txt")],
            targetURL: target,
            isTargetWritable: true,
            hasCutTransaction: false
        )

        let entries = MenuBuilder().entries(for: context, settings: .default, templates: [])
        XCTAssertTrue(entries.contains(where: { $0.command == .refresh }))
    }

    func testReadOnlyContainerKeepsRefreshEnabled() {
        let context = FinderMenuContext(
            kind: .container,
            selectedURLs: [],
            targetURL: target,
            isTargetWritable: false,
            hasCutTransaction: false
        )

        let entries = MenuBuilder().entries(for: context, settings: .default, templates: [])

        // 刷新是只读操作，只读容器下仍可用
        let refreshEntry = entries.first(where: { $0.command == .refresh })
        XCTAssertNotNil(refreshEntry)
        XCTAssertEqual(refreshEntry?.isEnabled, true)
    }

    func testRefreshRespectsMenuOrder() {
        var settings = FeatureSettings.default
        settings.menuOrder = [.refresh, .copyPath]
        let context = FinderMenuContext(
            kind: .container,
            selectedURLs: [],
            targetURL: target,
            isTargetWritable: true,
            hasCutTransaction: false
        )

        let entries = MenuBuilder().entries(for: context, settings: settings, templates: [])
        XCTAssertEqual(entries.first?.command, .refresh)
    }

    func testRefreshCanBeDisabled() {
        var settings = FeatureSettings.default
        settings.enabledFeatures.remove(.refresh)
        let context = FinderMenuContext(
            kind: .container,
            selectedURLs: [],
            targetURL: target,
            isTargetWritable: true,
            hasCutTransaction: false
        )

        let entries = MenuBuilder().entries(for: context, settings: settings, templates: [])
        XCTAssertFalse(entries.contains(where: { $0.command == .refresh }))
    }

    func testCopyAsContainsAllPrivacySafeFormats() {
        let context = FinderMenuContext(
            kind: .items,
            selectedURLs: [target.appendingPathComponent("A.txt")],
            targetURL: target,
            isTargetWritable: true,
            hasCutTransaction: false
        )

        let entry = MenuBuilder().entries(for: context, settings: .default, templates: [])
            .first { $0.command == .copyAs(.absolutePath) }

        XCTAssertEqual(entry?.children.map(\.command), [
            .copyAs(.name), .copyAs(.absolutePath), .copyAs(.relativePath),
            .copyAs(.shellEscapedPath), .copyAs(.fileURL),
        ])
    }

    func testOpenWithFiltersBySelectedExtensions() {
        var settings = FeatureSettings.default
        settings.openWithApplications = [
            OpenWithApplication(bundleIdentifier: "com.example.swift", displayName: "Swift", applicableExtensions: ["swift"]),
            OpenWithApplication(bundleIdentifier: "com.example.image", displayName: "Image", applicableExtensions: ["png"]),
        ]
        let context = FinderMenuContext(
            kind: .items,
            selectedURLs: [target.appendingPathComponent("A.swift")],
            targetURL: target,
            isTargetWritable: true,
            hasCutTransaction: false
        )

        let entry = MenuBuilder().entries(for: context, settings: settings, templates: [])
            .first { $0.command == .openWith(bundleIdentifier: "") }

        XCTAssertEqual(entry?.children.map(\.command), [.openWith(bundleIdentifier: "com.example.swift")])
    }
}
