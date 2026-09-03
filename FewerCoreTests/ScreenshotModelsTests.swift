import Carbon.HIToolbox
import XCTest
@testable import FewerCore

final class ScreenshotModelsTests: XCTestCase {
    // MARK: - PinItem

    func testPinItemClampsScale() {
        XCTAssertEqual(PinItem(imageData: Data(), scale: 5.0).scale, 4.0)
        XCTAssertEqual(PinItem(imageData: Data(), scale: 0.01).scale, 0.1)
        XCTAssertEqual(PinItem(imageData: Data(), scale: 1.5).scale, 1.5)
    }

    func testPinItemClampsOpacity() {
        XCTAssertEqual(PinItem(imageData: Data(), opacity: 0.0).opacity, 0.1)
        XCTAssertEqual(PinItem(imageData: Data(), opacity: 1.5).opacity, 1.0)
        XCTAssertEqual(PinItem(imageData: Data(), opacity: 0.6).opacity, 0.6)
    }

    func testPinItemDisplaySize() {
        let item = PinItem(imageData: Data(), scale: 2.0)
        XCTAssertEqual(item.displaySize(originalSize: CGSize(width: 100, height: 50)), CGSize(width: 200, height: 100))
    }

    // MARK: - MarkupHistory

    func testMarkupHistoryPushAndUndo() {
        var history = MarkupHistory()
        XCTAssertFalse(history.canUndo)

        let arrow = MarkupElement(shape: .arrow(start: .zero, end: CGPoint(x: 10, y: 10)), color: .red)
        history.push(arrow)
        let rect = MarkupElement(shape: .rect(CGRect(x: 0, y: 0, width: 10, height: 10)), color: .blue)
        history.push(rect)

        XCTAssertTrue(history.canUndo)
        XCTAssertEqual(history.elements.count, 2)

        let removed = history.undo()
        XCTAssertEqual(removed?.id, rect.id)
        XCTAssertEqual(history.elements.count, 1)

        _ = history.undo()
        XCTAssertFalse(history.canUndo)
        XCTAssertNil(history.undo())
    }

    func testMarkupElementMosaicShape() {
        let points = [CGPoint(x: 5, y: 5), CGPoint(x: 55, y: 55)]
        let mosaic = MarkupElement(shape: .mosaic(points: points, areaShape: .rectangle), color: .black)
        XCTAssertEqual(mosaic.strokeWidth, 3)
        XCTAssertEqual(mosaic.strokeStyle, .solid)
        if case .mosaic(let storedPoints, let areaShape) = mosaic.shape {
            XCTAssertEqual(storedPoints, points)
            XCTAssertEqual(areaShape, .rectangle)
        } else {
            XCTFail("应为 mosaic 形状")
        }
    }

    func testMarkupSupportsAdvancedShapesAndLineStyles() {
        let polyline = MarkupElement(
            shape: .polyline([.zero, CGPoint(x: 10, y: 4), CGPoint(x: 18, y: 20)]),
            color: .orange,
            strokeWidth: 5,
            strokeStyle: .dashed
        )
        XCTAssertEqual(polyline.strokeStyle, .dashed)

        let blur = MarkupElement(
            shape: .blur(points: [.zero, CGPoint(x: 30, y: 30)], areaShape: .ellipse),
            color: .black
        )
        if case .blur(_, let areaShape) = blur.shape {
            XCTAssertEqual(areaShape, .ellipse)
        } else {
            XCTFail("应为椭圆模糊区域")
        }
    }

    func testMarkupShapesTranslateWithoutChangingContent() {
        let text = MarkupShape.text("直接输入", origin: CGPoint(x: 10, y: 20))
            .translated(by: CGSize(width: 15, height: -5))
        XCTAssertEqual(text, .text("直接输入", origin: CGPoint(x: 25, y: 15)))

        let mosaic = MarkupShape.mosaic(
            points: [CGPoint(x: 1, y: 2), CGPoint(x: 20, y: 30)],
            areaShape: .ellipse
        ).translated(by: CGSize(width: 4, height: 6))
        XCTAssertEqual(
            mosaic,
            .mosaic(
                points: [CGPoint(x: 5, y: 8), CGPoint(x: 24, y: 36)],
                areaShape: .ellipse
            )
        )
    }

    func testMarkupSnapshotHistoryUndoesAndRedoesPropertyAndMoveChanges() {
        let original = MarkupElement(
            shape: .rect(CGRect(x: 0, y: 0, width: 20, height: 10)),
            color: .red
        )
        var movedAndRecolored = original
        movedAndRecolored.shape = movedAndRecolored.shape.translated(by: CGSize(width: 12, height: 8))
        movedAndRecolored.color = .blue

        var history = MarkupSnapshotHistory()
        history.record([original])
        XCTAssertTrue(history.canUndo)

        let undone = history.undo(current: [movedAndRecolored])
        XCTAssertEqual(undone, [original])
        XCTAssertTrue(history.canRedo)

        let redone = history.redo(current: undone ?? [])
        XCTAssertEqual(redone, [movedAndRecolored])
    }

    // MARK: - ScreenshotSettings

    func testDefaultSettings() {
        let settings = ScreenshotSettings.default
        XCTAssertTrue(settings.shortcutsEnabled)
        XCTAssertEqual(settings.regionHotKey, .regionDefault)
        XCTAssertEqual(settings.windowHotKey, .windowDefault)
        XCTAssertEqual(settings.fullscreenHotKey, .fullscreenDefault)
        XCTAssertEqual(settings.ocrTranslateHotKey, .ocrTranslateDefault)
        XCTAssertEqual(settings.afterAction, .editThenPin)
        XCTAssertTrue(settings.rollingCaptureEnabled)
        XCTAssertEqual(settings.pinDefaultOpacity, 1.0)
        XCTAssertEqual(settings.saveLocation, .desktop)
        XCTAssertNil(settings.customSaveDirectory)
        XCTAssertEqual(settings.ocrTranslationWindowPosition, .nearSelection)
    }

    func testDefaultHotKeySpecs() {
        XCTAssertEqual(HotKeySpec.regionDefault.keyCode, UInt32(kVK_ANSI_A))
        XCTAssertEqual(HotKeySpec.regionDefault.modifiers, HotKeySpec.command | HotKeySpec.option)
        XCTAssertEqual(HotKeySpec.windowDefault.keyCode, UInt32(kVK_ANSI_W))
        XCTAssertEqual(HotKeySpec.fullscreenDefault.keyCode, UInt32(kVK_ANSI_F))
        XCTAssertEqual(HotKeySpec.ocrTranslateDefault.keyCode, UInt32(kVK_ANSI_T))
        XCTAssertEqual(HotKeySpec.ocrTranslateDefault.modifiers, HotKeySpec.command | HotKeySpec.option)
    }

    func testHotKeySpecIsEmpty() {
        XCTAssertTrue(HotKeySpec(keyCode: 1, modifiers: 0).isEmpty)
        XCTAssertFalse(HotKeySpec(keyCode: 1, modifiers: HotKeySpec.command).isEmpty)
    }

    func testSettingsEncodeDecodeRoundTrip() throws {
        var settings = ScreenshotSettings.default
        settings.shortcutsEnabled = false
        settings.afterAction = .pin
        settings.pinDefaultOpacity = 0.5
        settings.saveLocation = .downloads
        settings.customSaveDirectory = "/tmp/Fewer Screenshots"
        settings.rollingCaptureEnabled = false
        settings.regionHotKey = HotKeySpec(keyCode: 0x12, modifiers: HotKeySpec.option)
        settings.ocrTranslationWindowPosition = .bottomTrailing

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(ScreenshotSettings.self, from: data)
        XCTAssertEqual(decoded, settings)
    }

    func testSettingsDecodeMissingFieldsFallsBackToDefaults() throws {
        // 只编码部分字段（模拟旧版本数据），缺失字段应回退默认
        let partial: [String: Any] = ["shortcutsEnabled": false]
        let data = try JSONSerialization.data(withJSONObject: partial)
        let decoded = try JSONDecoder().decode(ScreenshotSettings.self, from: data)
        XCTAssertFalse(decoded.shortcutsEnabled)
        XCTAssertEqual(decoded.regionHotKey, .regionDefault)
        XCTAssertEqual(decoded.ocrTranslateHotKey, .ocrTranslateDefault)
        XCTAssertEqual(decoded.afterAction, .editThenPin)
        XCTAssertTrue(decoded.rollingCaptureEnabled)
        XCTAssertEqual(decoded.saveLocation, .desktop)
        XCTAssertNil(decoded.customSaveDirectory)
        XCTAssertEqual(decoded.ocrTranslationWindowPosition, .nearSelection)
    }

    func testSettingsDecodeLegacyJSONUsesOCRTranslateDefault() throws {
        let data = try JSONEncoder().encode(ScreenshotSettings.default)
        var legacyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacyObject.removeValue(forKey: "ocrTranslateHotKey")

        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let decoded = try JSONDecoder().decode(ScreenshotSettings.self, from: legacyData)

        XCTAssertEqual(decoded.ocrTranslateHotKey, .ocrTranslateDefault)
    }

    func testSettingsDecodeLegacyJSONUsesNearSelectionForOCRTranslationWindowPosition() throws {
        let data = try JSONEncoder().encode(ScreenshotSettings.default)
        var legacyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacyObject.removeValue(forKey: "ocrTranslationWindowPosition")

        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let decoded = try JSONDecoder().decode(ScreenshotSettings.self, from: legacyData)

        XCTAssertEqual(decoded.ocrTranslationWindowPosition, .nearSelection)
    }

    func testCustomSaveDirectoryRoundTrip() throws {
        var settings = ScreenshotSettings.default
        settings.saveLocation = .custom
        settings.customSaveDirectory = "/tmp/Fewer Screenshots"

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(ScreenshotSettings.self, from: data)

        XCTAssertEqual(decoded.saveLocation, .custom)
        XCTAssertEqual(decoded.customSaveDirectory, "/tmp/Fewer Screenshots")
    }

    func testSettingsStoreSaveAndLoad() throws {
        let suiteName = "ScreenshotSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = ScreenshotSettingsStore(defaults: defaults)

        // 无数据 → 默认
        XCTAssertEqual(store.load(), .default)

        var settings = ScreenshotSettings.default
        settings.afterAction = .pin
        store.save(settings)
        XCTAssertEqual(store.load(), settings)

        defaults.removePersistentDomain(forName: suiteName)
    }

    func testSettingsStoreEmptyDataLoadsDefault() {
        let suiteName = "ScreenshotSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(Data([0x01, 0x02]), forKey: ScreenshotSettings.storageKey) // 非法数据

        let store = ScreenshotSettingsStore(defaults: defaults)
        XCTAssertEqual(store.load(), .default)
        defaults.removePersistentDomain(forName: suiteName)
    }
}
