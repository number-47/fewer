import AppKit
import FewerCore

/// 管理当前 OCR generation 与结果浮窗，所有 OCR 文本只保留在当前会话内。
@MainActor
final class OCRTranslationCoordinator {
    static let shared = OCRTranslationCoordinator()

    private var session = OCRTranslationSession()
    private var generation: UInt64 = 0
    private var recognitionTask: Task<Void, Never>?

    private init() {}

    func start() {
        cancel()
        generation &+= 1
        session.beginRecognition()
    }

    func recognize(image: CGImage, selection: CGRect, on screen: NSScreen?) {
        guard session.phase == .recognizing else { return }
        let currentGeneration = generation
        recognitionTask = Task { [weak self] in
            do {
                let result = try await VisionOCRService.shared.recognize(image: image)
                guard !Task.isCancelled else { return }
                self?.receive(result, selection: selection, screen: screen, generation: currentGeneration)
            } catch {
                guard !Task.isCancelled else { return }
                self?.fail(selection: selection, screen: screen, generation: currentGeneration)
            }
        }
    }

    func cancel() {
        generation &+= 1
        recognitionTask?.cancel()
        recognitionTask = nil
        session.cancel()
        OCRTranslationWindowController.shared.close()
    }

    private func receive(_ result: OCRResult, selection: CGRect, screen: NSScreen?, generation: UInt64) {
        guard generation == self.generation else { return }
        recognitionTask = nil
        guard session.receiveOCRText(result.fullText, detectedLanguageCode: result.detectedLanguageCode),
              let sourceText = session.sourceText
        else {
            OCRTranslationWindowController.shared.showFeedback("未识别到文字", near: selection, on: screen)
            return
        }
        if #available(macOS 15.0, *) {
            _ = session.beginTranslation()
        } else {
            session.markSystemUnavailable()
        }
        OCRTranslationWindowController.shared.show(
            sourceText: sourceText,
            sourceLanguageCode: session.sourceLanguageCode,
            targetLanguageCode: session.targetLanguageCode,
            translationState: session.translationState,
            translationGeneration: session.translationGeneration,
            selection: selection,
            screen: screen,
            onDismiss: { [weak self] in self?.dismissed(generation: generation) },
            onTargetLanguageSelected: { [weak self] languageCode in
                self?.selectTargetLanguage(languageCode)
            },
            onTranslationStateChanged: { [weak self] state, translationGeneration in
                self?.updateTranslation(state, generation: translationGeneration)
            }
        )
    }

    private func fail(selection: CGRect, screen: NSScreen?, generation: UInt64) {
        guard generation == self.generation else { return }
        recognitionTask = nil
        session.failRecognition()
        OCRTranslationWindowController.shared.showFeedback("文字识别失败", near: selection, on: screen)
    }

    private func dismissed(generation: UInt64) {
        guard generation == self.generation else { return }
        session.cancel()
    }

    private func selectTargetLanguage(_ languageCode: String) {
        guard #available(macOS 15.0, *), let translationGeneration = session.selectTargetLanguage(languageCode) else { return }
        OCRTranslationWindowController.shared.updateTranslation(
            session.translationState,
            sourceLanguageCode: session.sourceLanguageCode,
            targetLanguageCode: session.targetLanguageCode,
            translationGeneration: translationGeneration
        )
    }

    private func updateTranslation(_ state: OCRTranslationSession.TranslationState, generation: UInt64) {
        session.updateTranslation(state, generation: generation)
        guard session.translationGeneration == generation else { return }
        OCRTranslationWindowController.shared.updateTranslation(
            session.translationState,
            sourceLanguageCode: session.sourceLanguageCode,
            targetLanguageCode: session.targetLanguageCode,
            translationGeneration: generation
        )
    }
}
