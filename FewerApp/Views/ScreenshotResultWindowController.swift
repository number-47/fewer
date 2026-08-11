import AppKit
import FewerCore
import SwiftUI

/// 截图完成后的结果窗口。标注画布和编辑工具栏直接嵌在当前窗口中，
/// 不再通过“编辑”按钮关闭当前窗口后另开页面。
@MainActor
final class ScreenshotResultWindowController: NSObject, NSWindowDelegate {
    static let shared = ScreenshotResultWindowController()

    private var window: NSWindow?

    private override init() {}

    func show(pngData: Data) {
        close()
        guard let source = MarkupImageSource(pngData: pngData) else { return }

        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let contentSize = NSSize(
            width: min(max(source.displaySize.width + 32, 760), visibleFrame.width * 0.92),
            height: min(max(source.displaySize.height + 150, 560), visibleFrame.height * 0.92)
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("screenshot-result")
        window.title = "截图结果"
        window.minSize = NSSize(width: 720, height: 520)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: MarkupEditorView(
            source: source,
            onComplete: { [weak self] editedData in
                self?.close()
                PinWindowController.shared.pin(pngData: editedData)
            },
            onCancel: { [weak self] in self?.close() }
        ))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func close() {
        guard let window else { return }
        window.delegate = nil
        window.contentViewController = nil
        window.close()
        self.window = nil
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow, closingWindow === window else { return }
        closingWindow.contentViewController = nil
        window = nil
    }
}
