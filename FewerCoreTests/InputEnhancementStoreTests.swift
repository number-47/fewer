import Foundation
import XCTest
@testable import FewerCore

final class InputEnhancementStoreTests: XCTestCase {
    func testRoundTripAndNormalization() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = InputEnhancementStore(fileURL: directory.appendingPathComponent("input.json"))
        var settings = InputEnhancementSettings.default
        settings.scroll.isEnabled = true
        settings.scroll.vertical.speedGain = 99
        settings.scroll.horizontal.speedGain = 4
        settings.gestureRules = [MouseGestureRule(
            triggerButton: 2,
            directions: [.up, .right],
            action: .spaceRight
        )]
        settings.keycast.position = .custom
        settings.keycast.customPosition = KeycastNormalizedPosition(x: 1.4, y: -0.5)

        try store.save(settings)
        let loaded = store.load()

        XCTAssertTrue(loaded.scroll.isEnabled)
        XCTAssertEqual(loaded.scroll.vertical.speedGain, 8)
        XCTAssertEqual(loaded.scroll.horizontal.speedGain, 4)
        XCTAssertEqual(loaded.gestureRules.count, 1)
        XCTAssertEqual(loaded.keycast.position, .custom)
        XCTAssertEqual(loaded.keycast.customPosition, KeycastNormalizedPosition(x: 1, y: 0))
    }

    func testMissingOrCorruptFileReturnsDefaults() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        XCTAssertEqual(InputEnhancementStore(fileURL: fileURL).load(), .default)
        try Data("broken".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        XCTAssertEqual(InputEnhancementStore(fileURL: fileURL).load(), .default)
    }

    func testMigratesSchemaOneWithoutGestureExclusions() throws {
        let data = Data(#"{"schemaVersion":1,"scroll":{"isEnabled":false,"vertical":{"smoothEnabled":true,"reversed":false},"horizontal":{"smoothEnabled":true,"reversed":false},"minimumStep":3,"speedGain":1,"response":0.18,"simulatesTrackpad":false},"applicationOverrides":[],"gestureRules":[],"keycast":{"isEnabled":false,"mode":"shortcutsOnly","showsMouseClicks":false,"opacity":0.88,"fontSize":24,"displayDuration":1.8,"maximumVisibleEvents":5,"excludedBundleIdentifiers":[]},"emergencyDisabled":false}"#.utf8)
        let settings = try JSONDecoder().decode(InputEnhancementSettings.self, from: data)

        XCTAssertTrue(settings.gestureExcludedBundleIdentifiers.isEmpty)
    }

    func testDefaultIncludesBABPresetGestures() {
        let settings = InputEnhancementSettings.default

        XCTAssertEqual(settings.gestureRules.count, 8)
        XCTAssertTrue(settings.gestureRules.allSatisfy { $0.triggerButton == 1 })
        XCTAssertEqual(settings.gestureRules.map(\.directions), [
            [.left],
            [.right],
            [.up],
            [.down],
            [.downRight],
            [.upRight],
            [.downLeft],
            [.upLeft],
        ])
    }

    func testKeycastPositionDefaultsToBottomAndDecodesLegacyPayload() throws {
        let data = Data(#"{"schemaVersion":2,"scroll":{"isEnabled":false,"vertical":{"smoothEnabled":true,"reversed":false},"horizontal":{"smoothEnabled":true,"reversed":false},"simulatesTrackpad":false},"applicationOverrides":[],"gestureRules":[],"gestureExcludedBundleIdentifiers":[],"keycast":{"isEnabled":false,"mode":"shortcutsOnly","showsMouseClicks":false,"opacity":0.88,"fontSize":24,"displayDuration":1.8,"maximumVisibleEvents":5,"excludedBundleIdentifiers":[]},"emergencyDisabled":false}"#.utf8)
        let settings = try JSONDecoder().decode(InputEnhancementSettings.self, from: data)

        XCTAssertEqual(settings.keycast.position, .bottom)
        XCTAssertNil(settings.keycast.customPosition)
    }
}
