import AppKit
import Combine
import FewerCore
import SwiftUI

@MainActor
final class OCRTranslationViewModel: ObservableObject {
    @Published private(set) var sourceText: String
    @Published private(set) var sourceLanguageCode: String?
    @Published private(set) var targetLanguageCode: String?
    @Published private(set) var translationState: OCRTranslationSession.TranslationState
    @Published private(set) var translationGeneration: UInt64

    init(
        sourceText: String,
        sourceLanguageCode: String?,
        targetLanguageCode: String?,
        translationState: OCRTranslationSession.TranslationState,
        translationGeneration: UInt64
    ) {
        self.sourceText = sourceText
        self.sourceLanguageCode = sourceLanguageCode
        self.targetLanguageCode = targetLanguageCode
        self.translationState = translationState
        self.translationGeneration = translationGeneration
    }

    func updateTranslation(
        _ state: OCRTranslationSession.TranslationState,
        sourceLanguageCode: String?,
        targetLanguageCode: String?,
        translationGeneration: UInt64
    ) {
        translationState = state
        self.sourceLanguageCode = sourceLanguageCode
        self.targetLanguageCode = targetLanguageCode
        self.translationGeneration = translationGeneration
    }

    func clear() {
        sourceText = ""
        sourceLanguageCode = nil
        targetLanguageCode = nil
        translationState = .preparing
        translationGeneration = 0
    }
}

struct OCRTranslationView: View {
    @ObservedObject var model: OCRTranslationViewModel
    let onTargetLanguageSelected: (String) -> Void
    let onTranslationStateChanged: (OCRTranslationSession.TranslationState, UInt64) -> Void

    var body: some View {
        VStack(spacing: 0) {
            textSection(title: "原文", text: model.sourceText, canCopy: true)
                .frame(maxHeight: .infinity)

            Divider()

            translationSection
        }
        .frame(minWidth: 360, minHeight: 260, maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var translationSection: some View {
#if canImport(Translation)
        if #available(macOS 15.0, *) {
            AppleTranslationTaskHost(
                model: model,
                onTargetLanguageSelected: onTargetLanguageSelected,
                onTranslationStateChanged: onTranslationStateChanged
            )
        } else {
            translationContent
        }
#else
        translationContent
#endif
    }

    private var translationContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(sourceLanguageLabel)
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                Text(targetLanguageLabel)
                    .foregroundStyle(.secondary)
                Spacer()
                if case .completed(let text) = model.translationState {
                    copyButton(text: text)
                }
            }

            ScrollView {
                Text(translationText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(translationColor)
                    .textSelection(.enabled)
                    .padding(.bottom, 2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func textSection(title: String, text: String, canCopy: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                if canCopy {
                    copyButton(text: text)
                }
            }

            ScrollView {
                Text(text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.bottom, 2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func copyButton(text: String) -> some View {
        Button("复制") {
            OCRTranslationClipboard.copy(text)
        }
        .disabled(text.isEmpty)
    }

    private var translationText: String {
        switch model.translationState {
        case .preparing:
            "正在准备翻译语言…"
        case .translating:
            "正在翻译…"
        case .completed(let text):
            text
        case .unsupportedSystem:
            "截图翻译需要 macOS 15 或更高版本"
        case .languageDetectionFailed:
            "无法识别原文语言"
        case .availabilityCheckFailed:
            "翻译可用性检查失败"
        case .unsupportedLanguagePair:
            "当前语言组合暂不支持系统翻译"
        case .preparationFailed:
            "翻译语言准备失败"
        case .requestFailed:
            "翻译请求失败"
        }
    }

    private var translationColor: Color {
        switch model.translationState {
        case .completed:
            .primary
        case .preparing, .translating, .unsupportedSystem, .languageDetectionFailed,
             .availabilityCheckFailed, .unsupportedLanguagePair, .preparationFailed, .requestFailed:
            .secondary
        }
    }

    private var sourceLanguageLabel: String {
        languageName(for: model.sourceLanguageCode, fallback: "自动检测")
    }

    private var targetLanguageLabel: String {
        languageName(for: model.targetLanguageCode, fallback: "自动检测")
    }

    private func languageName(for languageCode: String?, fallback: String) -> String {
        guard let languageCode else { return fallback }
        return Locale.current.localizedString(forIdentifier: languageCode) ?? languageCode
    }
}

private enum OCRTranslationClipboard {
    static func copy(_ text: String) {
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
