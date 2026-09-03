import AppKit
import FewerCore

/// 管理当前 OCR generation 与结果浮窗，所有 OCR 文本只保留在当前会话内。
@MainActor
final class OCRTranslationCoordinator {
    static let shared = OCRTranslationCoordinator()

    private var session = OCRTranslationSession()
    private var generation: UInt64 = 0
    private var recognitionTask: Task<Void, Never>?
    private var aiTranslationTask: Task<Void, Never>?

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
        aiTranslationTask?.cancel()
        aiTranslationTask = nil
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
            provider: session.provider,
            translationState: session.translationState,
            translationGeneration: session.translationGeneration,
            selection: selection,
            screen: screen,
            onDismiss: { [weak self] in self?.dismissed(generation: generation) },
            onTargetLanguageSelected: { [weak self] languageCode in
                self?.selectTargetLanguage(languageCode)
            },
            onProviderSelected: { [weak self] provider in
                self?.selectProvider(provider)
            },
            onRetryRequested: { [weak self] in
                self?.retryTranslation()
            },
            onOpenScreenshotSettings: {
                SettingsWindowController.shared.show(section: .screenshot)
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
        aiTranslationTask?.cancel()
        aiTranslationTask = nil
        session.cancel()
    }

    private func selectTargetLanguage(_ languageCode: String) {
        aiTranslationTask?.cancel()
        aiTranslationTask = nil
        guard let translationGeneration = session.selectTargetLanguage(languageCode) else { return }
        presentCurrentTranslation(generation: translationGeneration)
        if session.provider == .ai {
            startAITranslation(generation: translationGeneration)
        }
    }

    private func selectProvider(_ provider: OCRTranslationProvider) {
        aiTranslationTask?.cancel()
        aiTranslationTask = nil
        guard let translationGeneration = session.selectProvider(provider) else {
            presentCurrentTranslation(generation: session.translationGeneration)
            return
        }
        presentCurrentTranslation(generation: translationGeneration)
        if provider == .ai {
            startAITranslation(generation: translationGeneration)
        }
    }

    private func retryTranslation() {
        aiTranslationTask?.cancel()
        aiTranslationTask = nil
        guard let translationGeneration = session.beginTranslation() else { return }
        presentCurrentTranslation(generation: translationGeneration)
        if session.provider == .ai {
            startAITranslation(generation: translationGeneration)
        }
    }

    private func startAITranslation(generation: UInt64) {
        guard session.provider == .ai,
              let sourceText = session.sourceText,
              let targetLanguageCode = session.targetLanguageCode
        else { return }

        let credentials: AITranslationCredentials
        do {
            guard let storedCredentials = try AITranslationSettingsStore().loadCredentials() else {
                updateTranslation(.aiConfigurationUnavailable, generation: generation)
                return
            }
            credentials = storedCredentials
        } catch {
            updateTranslation(.aiConfigurationUnavailable, generation: generation)
            return
        }

        let sourceLanguageCode = session.sourceLanguageCode
        let client = AITranslationClient()
        aiTranslationTask = Task { [weak self] in
            do {
                let translation = try await client.translate(
                    sourceText: sourceText,
                    sourceLanguageCode: sourceLanguageCode,
                    targetLanguageCode: targetLanguageCode,
                    credentials: credentials
                )
                guard !Task.isCancelled else { return }
                self?.updateTranslation(.completed(translation), generation: generation)
            } catch let error as AITranslationError {
                guard !Task.isCancelled else { return }
                self?.updateTranslation(.aiRequestFailed(error), generation: generation)
            } catch {
                guard !Task.isCancelled else { return }
                self?.updateTranslation(.aiRequestFailed(.networkFailure), generation: generation)
            }
        }
    }

    private func presentCurrentTranslation(generation: UInt64) {
        OCRTranslationWindowController.shared.updateTranslation(
            session.translationState,
            provider: session.provider,
            sourceLanguageCode: session.sourceLanguageCode,
            targetLanguageCode: session.targetLanguageCode,
            translationGeneration: generation
        )
    }

    private func updateTranslation(_ state: OCRTranslationSession.TranslationState, generation: UInt64) {
        session.updateTranslation(state, generation: generation)
        guard session.translationGeneration == generation else { return }
        presentCurrentTranslation(generation: generation)
    }
}
