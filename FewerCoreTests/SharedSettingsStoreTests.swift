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
        XCTAssertEqual(result.settings.menuOrder, [.newFile, .copyPath, .cut, .paste])
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

        XCTAssertEqual(result.settings.enabledFeatures, [.copyPath])
        XCTAssertEqual(result.settings.menuOrder, [.newFile, .copyPath, .cut, .paste])
        XCTAssertEqual(result.settings.conflictPolicy, .keepBoth)
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
}
