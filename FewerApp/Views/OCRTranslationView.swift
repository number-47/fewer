import AppKit
import Combine
import FewerCore
import SwiftUI

@MainActor
final class OCRTranslationViewModel: ObservableObject {
    @Published private(set) var sourceText: String
    @Published private(set) var sourceLanguageCode: String?
    @Published private(set) var targetLanguageCode: String?
    @Published private(set) var provider: OCRTranslationProvider
    @Published private(set) var translationState: OCRTranslationSession.TranslationState
    @Published private(set) var translationGeneration: UInt64
    @Published private(set) var isPinned = false

    init(
        sourceText: String,
        sourceLanguageCode: String?,
        targetLanguageCode: String?,
        provider: OCRTranslationProvider,
        translationState: OCRTranslationSession.TranslationState,
        translationGeneration: UInt64
    ) {
        self.sourceText = sourceText
        self.sourceLanguageCode = sourceLanguageCode
        self.targetLanguageCode = targetLanguageCode
        self.provider = provider
        self.translationState = translationState
        self.translationGeneration = translationGeneration
    }

    func updateTranslation(
        _ state: OCRTranslationSession.TranslationState,
        provider: OCRTranslationProvider,
        sourceLanguageCode: String?,
        targetLanguageCode: String?,
        translationGeneration: UInt64
    ) {
        translationState = state
        self.provider = provider
        self.sourceLanguageCode = sourceLanguageCode
        self.targetLanguageCode = targetLanguageCode
        self.translationGeneration = translationGeneration
    }

    func setPinned(_ isPinned: Bool) {
        self.isPinned = isPinned
    }

    func clear() {
        sourceText = ""
        sourceLanguageCode = nil
        targetLanguageCode = nil
        provider = .system
        translationState = .preparing
        translationGeneration = 0
        isPinned = false
    }
}

enum OCRTranslationContentHeightMetric: Hashable, Sendable {
    case sourceHeader
    case sourceText
    case translationHeader
    case translationText
    case translationActions
}

struct OCRTranslationContentHeightPreferenceKey: PreferenceKey {
    static let defaultValue: [OCRTranslationContentHeightMetric: CGFloat] = [:]

    static func reduce(
        value: inout [OCRTranslationContentHeightMetric: CGFloat],
        nextValue: () -> [OCRTranslationContentHeightMetric: CGFloat]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

extension View {
    func reportsOCRTranslationContentHeight(_ metric: OCRTranslationContentHeightMetric) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: OCRTranslationContentHeightPreferenceKey.self,
                    value: [metric: proxy.size.height]
                )
            }
        )
    }
}

struct OCRTranslationView: View {
    @ObservedObject var model: OCRTranslationViewModel
    let onPinToggleRequested: () -> Void
    let onPreferredContentHeightChange: (CGFloat) -> Void
    let onTargetLanguageSelected: (String) -> Void
    let onProviderSelected: (OCRTranslationProvider) -> Void
    let onRetryRequested: () -> Void
    let onOpenScreenshotSettings: () -> Void
    let onTranslationStateChanged: (OCRTranslationSession.TranslationState, UInt64) -> Void
    @State private var lastReportedPreferredContentHeight: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let sectionHeight = max((geometry.size.height - 1) / 2, 0)
            VStack(spacing: 0) {
                textSection(title: "原文", text: model.sourceText, canCopy: true)
                    .frame(height: sectionHeight)

                Divider()

                translationSection
                    .frame(height: sectionHeight)
            }
        }
        .frame(minWidth: 360, maxWidth: .infinity, minHeight: 260, maxHeight: .infinity)
        .onPreferenceChange(OCRTranslationContentHeightPreferenceKey.self) { measurements in
            let preferredContentHeight = preferredContentHeight(for: measurements)
            guard lastReportedPreferredContentHeight.map({
                abs($0 - preferredContentHeight) >= 1
            }) ?? true else { return }
            lastReportedPreferredContentHeight = preferredContentHeight
            onPreferredContentHeightChange(preferredContentHeight)
        }
    }

    @ViewBuilder
    private var translationSection: some View {
#if canImport(Translation)
        if #available(macOS 15.0, *) {
            AppleTranslationTaskHost(
                model: model,
                onTargetLanguageSelected: onTargetLanguageSelected,
                onProviderSelected: onProviderSelected,
                onRetryRequested: onRetryRequested,
                onOpenScreenshotSettings: onOpenScreenshotSettings,
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
                providerPicker
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
            .reportsOCRTranslationContentHeight(.translationHeader)

            ScrollView {
                Text(translationText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(translationColor)
                    .textSelection(.enabled)
                    .padding(.bottom, 2)
                    .reportsOCRTranslationContentHeight(.translationText)
            }

            translationActions
                .reportsOCRTranslationContentHeight(.translationActions)
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
                Button {
                    onPinToggleRequested()
                } label: {
                    Image(systemName: model.isPinned ? "pin.slash" : "pin")
                }
                .buttonStyle(.borderless)
                .help(model.isPinned ? "取消固定浮窗" : "固定浮窗")
                .accessibilityLabel(model.isPinned ? "取消固定浮窗" : "固定浮窗")
                if canCopy {
                    copyButton(text: text)
                }
            }
            .reportsOCRTranslationContentHeight(.sourceHeader)

            ScrollView {
                Text(text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.bottom, 2)
                    .reportsOCRTranslationContentHeight(.sourceText)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func copyButton(text: String) -> some View {
        Button("复制") {
            OCRTranslationClipboard.copy(text)
        }
        .disabled(text.isEmpty)
    }

    private var providerPicker: some View {
        Picker("翻译源", selection: Binding(
            get: { model.provider },
            set: { provider in onProviderSelected(provider) }
        )) {
            Text("系统").tag(OCRTranslationProvider.system)
            Text("AI").tag(OCRTranslationProvider.ai)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 116)
    }

    @ViewBuilder
    private var translationActions: some View {
        switch model.translationState {
        case .aiConfigurationUnavailable:
            Button("前往截屏设置", action: onOpenScreenshotSettings)
        case .aiRequestFailed:
            HStack {
                Button("重试", action: onRetryRequested)
                Button("切回系统") { onProviderSelected(.system) }
            }
        default:
            EmptyView()
        }
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
        case .aiConfigurationUnavailable:
            "尚未配置 AI 翻译服务"
        case let .aiRequestFailed(error):
            error.errorDescription ?? "AI 翻译请求失败"
        }
    }

    private var translationColor: Color {
        switch model.translationState {
        case .completed:
            .primary
        case .preparing, .translating, .unsupportedSystem, .languageDetectionFailed,
             .availabilityCheckFailed, .unsupportedLanguagePair, .preparationFailed, .requestFailed,
             .aiConfigurationUnavailable, .aiRequestFailed:
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

    private func preferredContentHeight(
        for measurements: [OCRTranslationContentHeightMetric: CGFloat]
    ) -> CGFloat {
        let sourceSectionHeight = measurements[.sourceHeader, default: 0]
            + 10
            + measurements[.sourceText, default: 0]
            + 32
        var translationSectionHeight = measurements[.translationHeader, default: 0]
            + 10
            + measurements[.translationText, default: 0]
            + 32
        if let actionsHeight = measurements[.translationActions], actionsHeight > 0 {
            translationSectionHeight += 10 + actionsHeight
        }
        return max(360, max(sourceSectionHeight, translationSectionHeight) * 2 + 1)
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
