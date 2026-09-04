import AppKit
import FewerCore
import SwiftUI

/// OCR 翻译结果只保留一个可交互浮窗；关闭时立即释放会话文本。
@MainActor
final class OCRTranslationWindowController: NSObject, NSWindowDelegate {
    static let shared = OCRTranslationWindowController()

    private var panel: NSPanel?
    private var feedbackPanel: NSPanel?
    private var feedbackDismissTask: Task<Void, Never>?
    private var viewModel: OCRTranslationViewModel?
    private var onDismiss: (() -> Void)?
    private var isDismissalSuppressed = false
    private let screenshotSettingsStore = ScreenshotSettingsStore()

    private override init() {}

    func show(
        sourceText: String,
        sourceLanguageCode: String?,
        targetLanguageCode: String?,
        provider: OCRTranslationProvider,
        translationState: OCRTranslationSession.TranslationState,
        translationGeneration: UInt64,
        selection: CGRect,
        screen: NSScreen?,
        onDismiss: @escaping () -> Void,
        onTargetLanguageSelected: @escaping (String) -> Void,
        onProviderSelected: @escaping (OCRTranslationProvider) -> Void,
        onRetryRequested: @escaping () -> Void,
        onOpenScreenshotSettings: @escaping () -> Void,
        onTranslationStateChanged: @escaping (OCRTranslationSession.TranslationState, UInt64) -> Void
    ) {
        closeResultWindow(notify: true)

        let visibleFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1_200, height: 800)
        let maximumSize = NSSize(
            width: max(visibleFrame.width - 16, 1),
            height: max(visibleFrame.height - 16, 1)
        )
        let initialSize = NSSize(
            width: min(maximumSize.width, max(420, maximumSize.width * 0.55)),
            height: min(maximumSize.height, max(500, visibleFrame.height * 0.85))
        )
        let viewModel = OCRTranslationViewModel(
            sourceText: sourceText,
            sourceLanguageCode: sourceLanguageCode,
            targetLanguageCode: targetLanguageCode,
            provider: provider,
            translationState: translationState,
            translationGeneration: translationGeneration
        )
        let panel = OCRTranslationPanel(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.identifier = NSUserInterfaceItemIdentifier("ocr-translation-result")
        panel.title = "截图翻译"
        panel.minSize = NSSize(
            width: min(360, maximumSize.width),
            height: min(260, maximumSize.height)
        )
        panel.maxSize = maximumSize
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentViewController = NSHostingController(rootView: OCRTranslationView(
            model: viewModel,
            onTargetLanguageSelected: onTargetLanguageSelected,
            onProviderSelected: onProviderSelected,
            onRetryRequested: onRetryRequested,
            onOpenScreenshotSettings: onOpenScreenshotSettings,
            onTranslationStateChanged: onTranslationStateChanged
        ))

        let frameSize = panel.frame.size
        let frame = OCRTranslationWindowLayout.frame(
            selection: selection,
            visibleFrame: visibleFrame,
            windowSize: frameSize,
            position: screenshotSettingsStore.load().ocrTranslationWindowPosition
        )
        panel.setFrame(frame, display: false)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.panel = panel
        self.viewModel = viewModel
        self.onDismiss = onDismiss
    }

    func updateTranslation(
        _ state: OCRTranslationSession.TranslationState,
        provider: OCRTranslationProvider,
        sourceLanguageCode: String?,
        targetLanguageCode: String?,
        translationGeneration: UInt64
    ) {
        viewModel?.updateTranslation(
            state,
            provider: provider,
            sourceLanguageCode: sourceLanguageCode,
            targetLanguageCode: targetLanguageCode,
            translationGeneration: translationGeneration
        )
    }

    func setDismissalSuppressed(_ suppressed: Bool) {
        isDismissalSuppressed = suppressed
        guard let panel else { return }
        panel.level = suppressed
            ? NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
            : .floating
        panel.ignoresMouseEvents = suppressed
    }

    func showFeedback(_ message: String, near selection: CGRect, on screen: NSScreen?) {
        closeFeedback()
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 180, height: 44)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.contentViewController = NSHostingController(rootView: Text(message)
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)))

        let visibleFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1_200, height: 800)
        let frame = OCRTranslationWindowLayout.frame(
            selection: selection,
            visibleFrame: visibleFrame,
            windowSize: panel.frame.size
        )
        panel.setFrame(frame, display: false)
        panel.orderFrontRegardless()
        feedbackPanel = panel
        feedbackDismissTask = Task { [weak self, weak panel] in
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled, self?.feedbackPanel === panel else { return }
            self?.closeFeedback()
        }
    }

    func close() {
        closeFeedback()
        closeResultWindow(notify: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingPanel = notification.object as? NSPanel, closingPanel === panel else { return }
        releaseResultWindow(notify: true)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let resigningPanel = notification.object as? NSPanel, resigningPanel === panel else { return }
        Task { @MainActor [weak self, weak resigningPanel] in
            await Task.yield()
            guard let self, let resigningPanel, let currentPanel = self.panel,
                  let viewModel = self.viewModel,
                  currentPanel === resigningPanel,
                  !viewModel.isPinned,
                  !self.isDismissalSuppressed,
                  !currentPanel.isKeyWindow else { return }
            self.closeResultWindow(notify: true)
        }
    }

    private func closeResultWindow(notify: Bool) {
        guard let panel else { return }
        panel.delegate = nil
        releaseResultWindow(notify: notify)
        panel.close()
    }

    private func releaseResultWindow(notify: Bool) {
        guard let panel else { return }
        panel.contentViewController = nil
        self.panel = nil
        isDismissalSuppressed = false
        viewModel?.clear()
        viewModel = nil
        let handler = onDismiss
        onDismiss = nil
        if notify {
            handler?()
        }
    }

    private func closeFeedback() {
        feedbackDismissTask?.cancel()
        feedbackDismissTask = nil
        feedbackPanel?.contentViewController = nil
        feedbackPanel?.close()
        feedbackPanel = nil
    }
}

private final class OCRTranslationPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
