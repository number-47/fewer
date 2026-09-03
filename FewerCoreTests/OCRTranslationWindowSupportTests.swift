import CoreGraphics
import XCTest
@testable import FewerCore

final class OCRTranslationWindowSupportTests: XCTestCase {
    func testSessionDisplaysNonemptyOCRTextWhileTranslationIsPending() {
        var session = OCRTranslationSession()

        session.beginRecognition()
        XCTAssertTrue(session.receiveOCRText("Recognized text", detectedLanguageCode: "en"))

        XCTAssertEqual(session.phase, .displaying)
        XCTAssertEqual(session.sourceText, "Recognized text")
        XCTAssertEqual(session.sourceLanguageCode, "en")
        XCTAssertEqual(session.targetLanguageCode, "zh-Hans")
        XCTAssertEqual(session.translationState, .preparing)
    }

    func testSessionRejectsEmptyOCRTextAndClearsOnCancel() {
        var session = OCRTranslationSession()

        session.beginRecognition()
        XCTAssertFalse(session.receiveOCRText(" \n ", detectedLanguageCode: nil))
        XCTAssertEqual(session.phase, .noText)
        XCTAssertNil(session.sourceText)

        session.cancel()
        XCTAssertEqual(session.phase, .cancelled)
        XCTAssertNil(session.sourceText)
    }

    func testSessionRetainsSourceWhileTranslationStateChanges() {
        var session = OCRTranslationSession()
        session.beginRecognition()
        XCTAssertTrue(session.receiveOCRText("Recognized text", detectedLanguageCode: "en"))

        let generation = try! XCTUnwrap(session.beginTranslation())
        session.updateTranslation(.completed("译文"), generation: generation)
        XCTAssertEqual(session.translationState, .completed("译文"))
        XCTAssertEqual(session.sourceText, "Recognized text")

        session.updateTranslation(.requestFailed, generation: generation)
        XCTAssertEqual(session.translationState, .requestFailed)
    }

    func testDefaultTargetUsesEnglishForChineseAndSimplifiedChineseOtherwise() {
        XCTAssertEqual(OCRTranslationLanguage.defaultTargetCode(for: "zh-Hans"), "en")
        XCTAssertEqual(OCRTranslationLanguage.defaultTargetCode(for: "zh-Hant"), "en")
        XCTAssertEqual(OCRTranslationLanguage.defaultTargetCode(for: "ja"), "zh-Hans")
        XCTAssertEqual(OCRTranslationLanguage.defaultTargetCode(for: nil), "zh-Hans")
    }

    func testSelectingTargetCancelsEarlierTranslationGenerationWithoutClearingOCRText() throws {
        var session = OCRTranslationSession()
        session.beginRecognition()
        XCTAssertTrue(session.receiveOCRText("Recognized text", detectedLanguageCode: "en"))
        let firstGeneration = try XCTUnwrap(session.beginTranslation())

        let secondGeneration = try XCTUnwrap(session.selectTargetLanguage("ja"))
        XCTAssertGreaterThan(secondGeneration, firstGeneration)
        XCTAssertEqual(session.sourceText, "Recognized text")
        XCTAssertEqual(session.targetLanguageCode, "ja")

        session.updateTranslation(.completed("stale"), generation: firstGeneration)
        XCTAssertEqual(session.translationState, .preparing)
        session.updateTranslation(.completed("新译文"), generation: secondGeneration)
        XCTAssertEqual(session.translationState, .completed("新译文"))
    }

    func testMissingDetectedLanguageShowsDetectionFailure() {
        var session = OCRTranslationSession()
        session.beginRecognition()

        XCTAssertTrue(session.receiveOCRText("Recognized text", detectedLanguageCode: nil))
        XCTAssertEqual(session.translationState, .languageDetectionFailed)
        XCTAssertNil(session.beginTranslation())
    }

    func testWindowPrefersRightSideOfSelection() {
        let frame = OCRTranslationWindowLayout.frame(
            selection: CGRect(x: 180, y: 260, width: 220, height: 180),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_200, height: 800),
            windowSize: CGSize(width: 420, height: 380)
        )

        XCTAssertEqual(frame.minX, 412)
        XCTAssertEqual(frame.minY, 60)
    }

    func testWindowUsesLeftSideWhenRightSideDoesNotFit() {
        let frame = OCRTranslationWindowLayout.frame(
            selection: CGRect(x: 820, y: 260, width: 180, height: 180),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_200, height: 800),
            windowSize: CGSize(width: 420, height: 380)
        )

        XCTAssertEqual(frame.minX, 388)
    }

    func testWindowUsesClampedBelowPositionWhenNeitherSideFits() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1_000, height: 700)
        let frame = OCRTranslationWindowLayout.frame(
            selection: CGRect(x: 300, y: 24, width: 400, height: 160),
            visibleFrame: visibleFrame,
            windowSize: CGSize(width: 420, height: 380)
        )

        XCTAssertEqual(frame.minY, 8)
        XCTAssertGreaterThanOrEqual(frame.minX, visibleFrame.minX + 8)
        XCTAssertLessThanOrEqual(frame.maxX, visibleFrame.maxX - 8)
        XCTAssertLessThanOrEqual(frame.maxY, visibleFrame.maxY - 8)
    }
}
