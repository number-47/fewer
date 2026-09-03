import CoreGraphics
import Foundation

/// OCR 翻译会话仅保留当前窗口所需的内存文本和展示状态。
public struct OCRTranslationSession: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        case recognizing
        case displaying
        case noText
        case failed
        case cancelled
    }

    public enum TranslationState: Equatable, Sendable {
        case preparing
        case translating
        case completed(String)
        case unsupportedSystem
        case languageDetectionFailed
        case availabilityCheckFailed
        case unsupportedLanguagePair
        case preparationFailed
        case requestFailed
    }

    public private(set) var phase: Phase = .idle
    public private(set) var sourceText: String?
    public private(set) var sourceLanguageCode: String?
    public private(set) var targetLanguageCode: String?
    public private(set) var translationState: TranslationState = .preparing
    public private(set) var translationGeneration: UInt64 = 0

    public init() {}

    public mutating func beginRecognition() {
        sourceText = nil
        sourceLanguageCode = nil
        targetLanguageCode = nil
        translationState = .preparing
        phase = .recognizing
    }

    /// 返回 `false` 时调用方应显示轻量反馈，而不是打开空结果窗口。
    @discardableResult
    public mutating func receiveOCRText(_ text: String, detectedLanguageCode: String?) -> Bool {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            sourceText = nil
            sourceLanguageCode = nil
            targetLanguageCode = nil
            phase = .noText
            return false
        }
        sourceText = trimmedText
        sourceLanguageCode = detectedLanguageCode
        targetLanguageCode = OCRTranslationLanguage.defaultTargetCode(for: detectedLanguageCode)
        translationState = detectedLanguageCode == nil ? .languageDetectionFailed : .preparing
        phase = .displaying
        return true
    }

    @discardableResult
    public mutating func beginTranslation() -> UInt64? {
        guard sourceText != nil, phase == .displaying else { return nil }
        translationGeneration &+= 1
        guard sourceLanguageCode != nil, targetLanguageCode != nil else {
            translationState = .languageDetectionFailed
            return nil
        }
        translationState = .preparing
        return translationGeneration
    }

    @discardableResult
    public mutating func selectTargetLanguage(_ languageCode: String) -> UInt64? {
        guard sourceText != nil, phase == .displaying else { return nil }
        targetLanguageCode = languageCode
        return beginTranslation()
    }

    public mutating func updateTranslation(_ state: TranslationState, generation: UInt64) {
        guard generation == translationGeneration else { return }
        guard sourceText != nil, phase == .displaying else { return }
        translationState = state
    }

    public mutating func markSystemUnavailable() {
        guard sourceText != nil, phase == .displaying else { return }
        translationState = .unsupportedSystem
    }

    public mutating func failRecognition() {
        sourceText = nil
        sourceLanguageCode = nil
        targetLanguageCode = nil
        translationState = .preparing
        phase = .failed
    }

    public mutating func cancel() {
        translationGeneration &+= 1
        sourceText = nil
        sourceLanguageCode = nil
        targetLanguageCode = nil
        translationState = .preparing
        phase = .cancelled
    }
}

public enum OCRTranslationLanguage {
    public static func defaultTargetCode(for sourceLanguageCode: String?) -> String {
        switch sourceLanguageCode?.lowercased() {
        case "zh", "zh-hans", "zh-hant":
            "en"
        default:
            "zh-Hans"
        }
    }
}

/// 在 AppKit 全局坐标系内，将 OCR 结果浮窗放在选区附近并约束到可见区域。
public enum OCRTranslationWindowLayout {
    public static func frame(
        selection: CGRect,
        visibleFrame: CGRect,
        windowSize: CGSize,
        spacing: CGFloat = 12,
        margin: CGFloat = 8
    ) -> CGRect {
        let maximumSize = CGSize(
            width: max(visibleFrame.width - margin * 2, 1),
            height: max(visibleFrame.height - margin * 2, 1)
        )
        let size = CGSize(
            width: min(max(windowSize.width, 1), maximumSize.width),
            height: min(max(windowSize.height, 1), maximumSize.height)
        )
        let alignedY = selection.maxY - size.height
        let right = CGRect(x: selection.maxX + spacing, y: alignedY, width: size.width, height: size.height)
        if right.maxX <= visibleFrame.maxX - margin {
            return clamped(right, within: visibleFrame, margin: margin)
        }

        let left = CGRect(x: selection.minX - spacing - size.width, y: alignedY, width: size.width, height: size.height)
        if left.minX >= visibleFrame.minX + margin {
            return clamped(left, within: visibleFrame, margin: margin)
        }

        let below = CGRect(
            x: selection.midX - size.width / 2,
            y: selection.minY - spacing - size.height,
            width: size.width,
            height: size.height
        )
        return clamped(below, within: visibleFrame, margin: margin)
    }

    private static func clamped(_ frame: CGRect, within visibleFrame: CGRect, margin: CGFloat) -> CGRect {
        let minimumX = visibleFrame.minX + margin
        let minimumY = visibleFrame.minY + margin
        let maximumX = max(minimumX, visibleFrame.maxX - margin - frame.width)
        let maximumY = max(minimumY, visibleFrame.maxY - margin - frame.height)
        return CGRect(
            x: min(max(frame.minX, minimumX), maximumX),
            y: min(max(frame.minY, minimumY), maximumY),
            width: frame.width,
            height: frame.height
        )
    }
}
