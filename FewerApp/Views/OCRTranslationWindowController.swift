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
    private var pinButton: NSButton?
    private var onDismiss: (() -> Void)?
    private var isDismissalSuppressed = false
    private var isPinned = false
    private var resultWindowLayoutContext: ResultWindowLayoutContext?
    private var lastPreferredContentHeight: CGFloat?
    private var isProgrammaticResize = false
    private var hasUserResized = false
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
        let maximumFrameSize = NSSize(
            width: max(visibleFrame.width - 16, 1),
            height: max(visibleFrame.height - 16, 1)
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
            contentRect: NSRect(origin: .zero, size: NSSize(width: 1, height: 1)),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        let maximumContentSize = panel.contentRect(
            forFrameRect: NSRect(origin: .zero, size: maximumFrameSize)
        ).size
        let initialFrameWidth = min(maximumFrameSize.width, 390)
        let initialContentWidth = max(
            panel.contentRect(
                forFrameRect: NSRect(
                    origin: .zero,
                    size: NSSize(width: initialFrameWidth, height: maximumFrameSize.height)
                )
            ).width,
            1
        )
        let initialContentSize = NSSize(
            width: initialContentWidth,
            height: min(maximumContentSize.height, 360)
        )
        let position = screenshotSettingsStore.load().ocrTranslationWindowPosition
        panel.identifier = NSUserInterfaceItemIdentifier("ocr-translation-result")
        panel.title = "截图翻译"
        installPinButton(on: panel)
        panel.minSize = NSSize(
            width: min(360, maximumFrameSize.width),
            height: min(260, maximumFrameSize.height)
        )
        panel.maxSize = maximumFrameSize
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        let hostingController = NSHostingController(rootView: OCRTranslationView(
            model: viewModel,
            onPreferredContentHeightChange: { [weak self] height in
                Task { @MainActor [weak self] in
                    self?.updatePreferredContentHeight(height)
                }
            },
            onTargetLanguageSelected: onTargetLanguageSelected,
            onProviderSelected: onProviderSelected,
            onRetryRequested: onRetryRequested,
            onOpenScreenshotSettings: onOpenScreenshotSettings,
            onTranslationStateChanged: onTranslationStateChanged
        ))
        hostingController.sizingOptions = []
        panel.contentViewController = hostingController
        panel.setContentSize(initialContentSize)

        let frameSize = panel.frame.size
        let frame = OCRTranslationWindowLayout.frame(
            selection: selection,
            visibleFrame: visibleFrame,
            windowSize: frameSize,
            position: position
        )
        panel.setFrame(frame, display: false)

        self.panel = panel
        self.viewModel = viewModel
        self.onDismiss = onDismiss
        resultWindowLayoutContext = ResultWindowLayoutContext(
            selection: selection,
            visibleFrame: visibleFrame,
            position: position,
            maximumContentHeight: maximumContentSize.height
        )
        setPinned(false)

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
                  currentPanel === resigningPanel,
                  !self.isPinned,
                  !self.isDismissalSuppressed,
                  !currentPanel.isKeyWindow else { return }
            self.closeResultWindow(notify: true)
        }
    }

    func windowDidResize(_ notification: Notification) {
        guard let resizedPanel = notification.object as? NSPanel, resizedPanel === panel,
              !isProgrammaticResize else { return }
        hasUserResized = true
    }

    private func togglePinned() {
        setPinned(!isPinned)
    }

    private func setPinned(_ pinned: Bool) {
        isPinned = pinned
        updatePinButton()
        guard pinned, let panel else { return }
        panel.hidesOnDeactivate = false
        panel.level = isDismissalSuppressed
            ? NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
            : .floating
        panel.orderFrontRegardless()
    }

    @objc private func togglePinnedFromTitlebar(_ sender: NSButton) {
        togglePinned()
    }

    private func installPinButton(on panel: NSPanel) {
        let button = NSButton()
        button.target = self
        button.action = #selector(togglePinnedFromTitlebar(_:))
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.frame = NSRect(x: 0, y: 0, width: 28, height: 22)

        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .right
        accessory.view = button
        panel.addTitlebarAccessoryViewController(accessory)
        pinButton = button
        updatePinButton()
    }

    private func updatePinButton() {
        let label = isPinned ? "取消固定浮窗" : "固定浮窗"
        pinButton?.image = NSImage(
            systemSymbolName: isPinned ? "pin.fill" : "pin",
            accessibilityDescription: label
        )
        pinButton?.toolTip = label
        pinButton?.setAccessibilityLabel(label)
        pinButton?.state = isPinned ? .on : .off
    }

    private func updatePreferredContentHeight(_ preferredContentHeight: CGFloat) {
        guard preferredContentHeight.isFinite,
              !hasUserResized,
              let panel,
              let resultWindowLayoutContext
        else { return }

        let contentHeight = min(
            max(preferredContentHeight, 360),
            resultWindowLayoutContext.maximumContentHeight
        )
        guard lastPreferredContentHeight.map({ abs($0 - contentHeight) >= 1 }) ?? true else { return }
        lastPreferredContentHeight = contentHeight

        let currentContentHeight = panel.contentRect(forFrameRect: panel.frame).height
        guard abs(currentContentHeight - contentHeight) >= 1 else { return }

        isProgrammaticResize = true
        defer { isProgrammaticResize = false }
        panel.setContentSize(NSSize(width: panel.contentView?.bounds.width ?? 1, height: contentHeight))
        let frame = OCRTranslationWindowLayout.frame(
            selection: resultWindowLayoutContext.selection,
            visibleFrame: resultWindowLayoutContext.visibleFrame,
            windowSize: panel.frame.size,
            position: resultWindowLayoutContext.position
        )
        panel.setFrame(frame, display: true)
    }

    private func closeResultWindow(notify: Bool) {
        guard let panel else {
            setPinned(false)
            resetResultWindowSizing()
            return
        }
        panel.delegate = nil
        releaseResultWindow(notify: notify)
        panel.close()
    }

    private func releaseResultWindow(notify: Bool) {
        guard let panel else { return }
        panel.contentViewController = nil
        self.panel = nil
        isDismissalSuppressed = false
        setPinned(false)
        pinButton = nil
        resetResultWindowSizing()
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

    private func resetResultWindowSizing() {
        resultWindowLayoutContext = nil
        lastPreferredContentHeight = nil
        isProgrammaticResize = false
        hasUserResized = false
    }
}

private final class OCRTranslationPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private struct ResultWindowLayoutContext {
    let selection: CGRect
    let visibleFrame: CGRect
    let position: OCRTranslationWindowPosition
    let maximumContentHeight: CGFloat
}
