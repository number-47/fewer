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

    func testTargetSelectionMatchesPreferredLanguageByMinimalIdentifier() {
        let selected = OCRTranslationLanguage.selectTargetLanguage(
            preferredTargetCode: "en-US",
            sourceLanguageCode: "zh-Hans",
            supportedLanguageCodes: ["zh-Hans", "en"]
        )

        XCTAssertEqual(selected, "en")
    }

    func testTargetSelectionFallsBackToLanguageDifferentFromSource() {
        let selected = OCRTranslationLanguage.selectTargetLanguage(
            preferredTargetCode: "ko",
            sourceLanguageCode: "en-US",
            supportedLanguageCodes: ["en", "ja", "zh-Hans"]
        )

        XCTAssertEqual(selected, "ja")
    }

    func testTargetSelectionReturnsNilWithoutValidCandidate() {
        XCTAssertNil(OCRTranslationLanguage.selectTargetLanguage(
            preferredTargetCode: nil,
            sourceLanguageCode: "en",
            supportedLanguageCodes: []
        ))
        XCTAssertNil(OCRTranslationLanguage.selectTargetLanguage(
            preferredTargetCode: "ko",
            sourceLanguageCode: "en",
            supportedLanguageCodes: ["en-US"]
        ))
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

    func testAIProviderAllowsUndetectedSourceLanguageAndInvalidatesSystemGeneration() throws {
        var session = OCRTranslationSession()
        session.beginRecognition()
        XCTAssertTrue(session.receiveOCRText("Recognized text", detectedLanguageCode: nil))

        let aiGeneration = try XCTUnwrap(session.selectProvider(.ai))
        XCTAssertEqual(session.provider, .ai)
        XCTAssertEqual(session.translationState, .preparing)

        session.updateTranslation(.completed("AI 译文"), generation: aiGeneration)
        XCTAssertEqual(session.translationState, .completed("AI 译文"))

        XCTAssertNil(session.selectProvider(.system))
        XCTAssertGreaterThan(session.translationGeneration, aiGeneration)
        XCTAssertEqual(session.translationState, .languageDetectionFailed)
        session.updateTranslation(.completed("过期 AI 译文"), generation: aiGeneration)
        XCTAssertEqual(session.translationState, .languageDetectionFailed)
    }

    func testNewRecognitionResetsProviderToSystem() throws {
        var session = OCRTranslationSession()
        session.beginRecognition()
        XCTAssertTrue(session.receiveOCRText("Recognized text", detectedLanguageCode: "en"))
        _ = try XCTUnwrap(session.selectProvider(.ai))

        session.beginRecognition()

        XCTAssertEqual(session.provider, .system)
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

    func testWindowUsesFixedScreenAnchors() {
        let visibleFrame = CGRect(x: 100, y: 200, width: 1_000, height: 700)
        let windowSize = CGSize(width: 200, height: 100)

        XCTAssertEqual(
            OCRTranslationWindowLayout.frame(
                selection: .zero,
                visibleFrame: visibleFrame,
                windowSize: windowSize,
                position: .topLeading
            ).origin,
            CGPoint(x: 108, y: 792)
        )
        XCTAssertEqual(
            OCRTranslationWindowLayout.frame(
                selection: .zero,
                visibleFrame: visibleFrame,
                windowSize: windowSize,
                position: .center
            ).origin,
            CGPoint(x: 500, y: 500)
        )
        XCTAssertEqual(
            OCRTranslationWindowLayout.frame(
                selection: .zero,
                visibleFrame: visibleFrame,
                windowSize: windowSize,
                position: .bottomTrailing
            ).origin,
            CGPoint(x: 892, y: 208)
        )
    }

    func testFixedWindowAnchorClampsOversizedWindowToVisibleFrame() {
        let visibleFrame = CGRect(x: 100, y: 200, width: 300, height: 180)
        let frame = OCRTranslationWindowLayout.frame(
            selection: .zero,
            visibleFrame: visibleFrame,
            windowSize: CGSize(width: 600, height: 400),
            position: .topTrailing
        )

        XCTAssertEqual(frame, CGRect(x: 108, y: 208, width: 284, height: 164))
    }
}
