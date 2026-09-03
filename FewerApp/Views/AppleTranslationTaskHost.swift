#if canImport(Translation)
import AppKit
import FewerCore
import SwiftUI
@preconcurrency import Translation

@available(macOS 15.0, *)
struct AppleTranslationTaskHost: View {
    @ObservedObject var model: OCRTranslationViewModel
    let onTargetLanguageSelected: (String) -> Void
    let onTranslationStateChanged: (OCRTranslationSession.TranslationState, UInt64) -> Void

    @State private var supportedLanguages: [Locale.Language] = []
    @State private var automaticallySelectedLanguageCode: String?

    var body: some View {
        let sourceText = model.sourceText
        let targetLanguageCode = model.targetLanguageCode
        let translationGeneration = model.translationGeneration

        content
            .task {
                let languages = await LanguageAvailability().supportedLanguages
                guard !Task.isCancelled else { return }
                let sortedLanguages = languages.sorted {
                    languageName($0).localizedStandardCompare(languageName($1)) == .orderedAscending
                }
                supportedLanguages = sortedLanguages

                guard let selectedLanguageCode = OCRTranslationLanguage.selectTargetLanguage(
                    preferredTargetCode: targetLanguageCode,
                    sourceLanguageCode: model.sourceLanguageCode,
                    supportedLanguageCodes: sortedLanguages.map(\.minimalIdentifier)
                ),
                selectedLanguageCode != targetLanguageCode,
                automaticallySelectedLanguageCode != selectedLanguageCode
                else { return }

                automaticallySelectedLanguageCode = selectedLanguageCode
                onTargetLanguageSelected(selectedLanguageCode)
            }
            .translationTask(configuration) { session in
                guard let targetLanguageCode else { return }
                await translate(
                    sourceText: sourceText,
                    targetLanguageCode: targetLanguageCode,
                    generation: translationGeneration,
                    session: session
                )
            }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(sourceLanguageLabel)
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                targetPicker
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

    @ViewBuilder
    private var targetPicker: some View {
        if supportedLanguages.isEmpty {
            Text("正在加载语言…")
                .foregroundStyle(.secondary)
        } else {
            Picker("目标语言", selection: Binding(
                get: { selectedTargetLanguageCode ?? "" },
                set: { languageCode in
                    guard !languageCode.isEmpty, languageCode != model.targetLanguageCode else { return }
                    onTargetLanguageSelected(languageCode)
                }
            )) {
                ForEach(supportedLanguages, id: \.minimalIdentifier) { language in
                    Text(languageName(language)).tag(language.minimalIdentifier)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 150)
        }
    }

    private var configuration: TranslationSession.Configuration? {
        guard let sourceLanguageCode = model.sourceLanguageCode,
              let targetLanguageCode = model.targetLanguageCode,
              targetLanguageCode == selectedTargetLanguageCode
        else { return nil }
        return TranslationSession.Configuration(
            source: Locale.Language(identifier: sourceLanguageCode),
            target: Locale.Language(identifier: targetLanguageCode)
        )
    }

    private var selectedTargetLanguageCode: String? {
        OCRTranslationLanguage.selectTargetLanguage(
            preferredTargetCode: model.targetLanguageCode,
            sourceLanguageCode: model.sourceLanguageCode,
            supportedLanguageCodes: supportedLanguages.map(\.minimalIdentifier)
        )
    }

    private func translate(
        sourceText: String,
        targetLanguageCode: String,
        generation: UInt64,
        session: TranslationSession
    ) async {
        let availability: LanguageAvailability.Status
        do {
            availability = try await LanguageAvailability().status(
                for: sourceText,
                to: Locale.Language(identifier: targetLanguageCode)
            )
        } catch is CancellationError {
            return
        } catch {
            if TranslationError.unableToIdentifyLanguage ~= error {
                await report(.languageDetectionFailed, generation: generation)
            } else {
                await report(.availabilityCheckFailed, generation: generation)
            }
            return
        }

        switch availability {
        case .unsupported:
            await report(.unsupportedLanguagePair, generation: generation)
            return
        case .supported:
            await report(.preparing, generation: generation)
            do {
                try await session.prepareTranslation()
            } catch is CancellationError {
                return
            } catch {
                await report(.preparationFailed, generation: generation)
                return
            }
        case .installed:
            break
        @unknown default:
            await report(.unsupportedLanguagePair, generation: generation)
            return
        }

        do {
            try Task.checkCancellation()
            await report(.translating, generation: generation)
            let response = try await session.translate(sourceText)
            try Task.checkCancellation()
            await report(.completed(response.targetText), generation: generation)
        } catch is CancellationError {
            return
        } catch {
            await report(.requestFailed, generation: generation)
        }
    }

    private func report(_ state: OCRTranslationSession.TranslationState, generation: UInt64) async {
        await MainActor.run {
            onTranslationStateChanged(state, generation)
        }
    }

    private func languageName(_ language: Locale.Language) -> String {
        Locale.current.localizedString(forIdentifier: language.minimalIdentifier) ?? language.minimalIdentifier
    }

    private var sourceLanguageLabel: String {
        guard let sourceLanguageCode = model.sourceLanguageCode else { return "自动检测" }
        return Locale.current.localizedString(forIdentifier: sourceLanguageCode) ?? sourceLanguageCode
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
        if case .completed = model.translationState {
            return .primary
        }
        return .secondary
    }

    private func copyButton(text: String) -> some View {
        Button("复制") {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
        .disabled(text.isEmpty)
    }
}
#endif
