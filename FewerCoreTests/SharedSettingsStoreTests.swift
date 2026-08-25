import Foundation
import XCTest
@testable import FewerCore

final class SharedSettingsStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "FewerCoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testDefaultsExposeEveryInitialFeatureInStableOrder() throws {
        let store = SharedSettingsStore(defaults: defaults)
        let result = store.load()

        XCTAssertNil(result.recoveryReason)
        XCTAssertEqual(result.settings.menuOrder, FewerFeature.allCases)
        XCTAssertEqual(result.settings.enabledFeatures, Set(FewerFeature.allCases))
        XCTAssertEqual(result.settings.conflictPolicy, .keepBoth)
        XCTAssertEqual(result.settings.pathFormat, .posix)
    }

    func testSaveAndLoadRoundTrip() throws {
        let store = SharedSettingsStore(defaults: defaults)
        var settings = FeatureSettings.default
        settings.enabledFeatures.remove(.paste)
        settings.pathFormat = .quoted
        settings.conflictPolicy = .skip

        try store.save(settings)
        let result = store.load()

        XCTAssertEqual(result.settings, settings)
        XCTAssertNil(result.recoveryReason)
    }

    func testCorruptPayloadRecoversDefaultsAndReportsReason() {
        defaults.set(Data("not-json".utf8), forKey: AppGroupConstants.featureSettingsKey)
        let result = SharedSettingsStore(defaults: defaults).load()

        XCTAssertEqual(result.settings, .default)
        XCTAssertNotNil(result.recoveryReason)
    }

    func testMissingFieldsDecodeWithCurrentDefaults() throws {
        let legacy = Data(#"{"schemaVersion":0,"enabledFeatures":["copyPath"]}"#.utf8)
        defaults.set(legacy, forKey: AppGroupConstants.featureSettingsKey)

        let result = SharedSettingsStore(defaults: defaults).load()

        XCTAssertEqual(result.settings.enabledFeatures, [
            .copyPath, .openInTerminal, .refresh, .newFolder, .copyAs, .openWith,
        ])
        XCTAssertEqual(result.settings.menuOrder, FewerFeature.allCases)
        XCTAssertEqual(result.settings.conflictPolicy, .keepBoth)
        XCTAssertEqual(result.settings.terminalBundleID, FeatureSettings.defaultTerminalBundleID)
    }

    func testV1PayloadMigratesOpenInTerminalWithoutTouchingUserChoices() throws {
        // v1 配置：用户自定义了开关与排序（无 openInTerminal）
        let v1 = Data(#"{"schemaVersion":1,"enabledFeatures":["copyPath","cut","paste"],"menuOrder":["cut","copyPath","paste"]}"#.utf8)
        defaults.set(v1, forKey: AppGroupConstants.featureSettingsKey)

        let result = SharedSettingsStore(defaults: defaults).load()

        // 新功能默认启用并追加到菜单末尾；用户已有开关与排序保持不变
        XCTAssertEqual(result.settings.schemaVersion, FeatureSettings.currentSchemaVersion)
        XCTAssertEqual(result.settings.enabledFeatures, [
            .copyPath, .cut, .paste, .openInTerminal, .refresh, .newFolder, .copyAs, .openWith,
        ])
        XCTAssertEqual(result.settings.menuOrder, [
            .cut, .copyPath, .paste, .openInTerminal, .refresh, .newFolder, .copyAs, .openWith,
        ])
        XCTAssertEqual(result.settings.terminalBundleID, FeatureSettings.defaultTerminalBundleID)
    }

    func testV2PayloadGetsDefaultTerminalApp() throws {
        // v2 配置：无 terminalBundleID 字段 → 回退默认终端
        let v2 = Data(#"{"schemaVersion":2,"enabledFeatures":["copyPath","openInTerminal"],"menuOrder":["copyPath","openInTerminal"]}"#.utf8)
        defaults.set(v2, forKey: AppGroupConstants.featureSettingsKey)

        let result = SharedSettingsStore(defaults: defaults).load()

        XCTAssertEqual(result.settings.schemaVersion, FeatureSettings.currentSchemaVersion)
        XCTAssertEqual(result.settings.terminalBundleID, FeatureSettings.defaultTerminalBundleID)
    }

    func testV3PayloadMigratesRefresh() throws {
        // v3 配置：无 refresh 功能项 -> 迁移后默认启用并追加到菜单末尾
        let v3 = Data(#"{"schemaVersion":3,"enabledFeatures":["copyPath","openInTerminal"],"menuOrder":["copyPath","openInTerminal"]}"#.utf8)
        defaults.set(v3, forKey: AppGroupConstants.featureSettingsKey)

        let result = SharedSettingsStore(defaults: defaults).load()

        XCTAssertEqual(result.settings.schemaVersion, FeatureSettings.currentSchemaVersion)
        XCTAssertTrue(result.settings.enabledFeatures.contains(.refresh))
        XCTAssertEqual(result.settings.menuOrder, [
            .copyPath, .openInTerminal, .refresh, .newFolder, .copyAs, .openWith,
        ])
        XCTAssertEqual(result.settings.terminalBundleID, FeatureSettings.defaultTerminalBundleID)
    }

    func testV4PayloadMigratesFinderAdditionsWithoutReorderingChoices() throws {
        let v4 = Data(#"{"schemaVersion":4,"enabledFeatures":["copyPath"],"menuOrder":["copyPath"]}"#.utf8)
        defaults.set(v4, forKey: AppGroupConstants.featureSettingsKey)

        let settings = SharedSettingsStore(defaults: defaults).load().settings

        XCTAssertEqual(settings.enabledFeatures, [.copyPath, .newFolder, .copyAs, .openWith])
        XCTAssertEqual(settings.menuOrder, [.copyPath, .newFolder, .copyAs, .openWith])
        XCTAssertFalse(settings.openWithApplications.isEmpty)
    }

    func testCustomTerminalBundleIDRoundTrips() throws {
        let store = SharedSettingsStore(defaults: defaults)
        var settings = FeatureSettings.default
        settings.terminalBundleID = "com.googlecode.iterm2"

        try store.save(settings)
        let result = store.load()

        XCTAssertEqual(result.settings.terminalBundleID, "com.googlecode.iterm2")
        XCTAssertNil(result.recoveryReason)
    }

    func testFileBackedStoreRoundTripsAcrossInstances() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("settings.json")
        var settings = FeatureSettings.default
        settings.pathFormat = .fileURL

        try SharedSettingsStore(fileURL: fileURL).save(settings)

        XCTAssertEqual(SharedSettingsStore(fileURL: fileURL).load().settings, settings)
    }

    func testReadOnlyStoreRejectsWrites() {
        let store = SharedSettingsStore(defaults: defaults, access: .readOnly)

        XCTAssertThrowsError(try store.save(.default)) { error in
            XCTAssertEqual(error as? SharedPreferenceStoreError, .readOnly)
        }
    }

    func testPreferenceMigrationPreservesExistingAppGroupValue() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacyURL = directory.appendingPathComponent("feature-settings.json")
        let legacyData = Data("legacy".utf8)
        try legacyData.write(to: legacyURL)
        let currentData = Data("current".utf8)
        defaults.set(currentData, forKey: AppGroupConstants.featureSettingsKey)

        SharedStoreBootstrap.migratePreferenceIfNeeded(
            in: defaults,
            key: AppGroupConstants.featureSettingsKey,
            legacyFileName: legacyURL.lastPathComponent,
            sharedRoot: directory.appendingPathComponent("Shared", isDirectory: true),
            legacyFileURLs: [legacyURL]
        )

        XCTAssertEqual(defaults.data(forKey: AppGroupConstants.featureSettingsKey), currentData)
        XCTAssertEqual(try Data(contentsOf: legacyURL), legacyData)
    }

    func testPreferenceMigrationCopiesLegacyDataOnlyWhenNewValueIsMissing() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacyURL = directory.appendingPathComponent("feature-settings.json")
        let legacyData = Data("legacy".utf8)
        try legacyData.write(to: legacyURL)

        SharedStoreBootstrap.migratePreferenceIfNeeded(
            in: defaults,
            key: AppGroupConstants.featureSettingsKey,
            legacyFileName: legacyURL.lastPathComponent,
            sharedRoot: directory.appendingPathComponent("Shared", isDirectory: true),
            legacyFileURLs: [legacyURL]
        )

        XCTAssertEqual(defaults.data(forKey: AppGroupConstants.featureSettingsKey), legacyData)
        XCTAssertEqual(try Data(contentsOf: legacyURL), legacyData)
    }
}
