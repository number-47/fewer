import AppKit
import SwiftUI

@main
@MainActor
enum FewerApp {
    private static let appDelegate = AppDelegate()

    static func main() {
        let application = NSApplication.shared
        application.delegate = appDelegate
        application.run()
    }
}

@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    static let shared = MenuBarController()

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var globalClickMonitor: Any?

    private override init() {
        super.init()
    }

    func setVisible(_ isVisible: Bool) {
        if isVisible {
            installStatusItemIfNeeded()
        } else {
            removeStatusItem()
        }
    }

    private func installStatusItemIfNeeded() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = item.button else {
            NSStatusBar.system.removeStatusItem(item)
            return
        }

        button.image = NSImage(systemSymbolName: "calendar", accessibilityDescription: "日历")
        button.imagePosition = .imageOnly
        button.title = ""
        button.toolTip = "Fewer 日历"
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.sendAction(on: [.leftMouseUp])
        statusItem = item
    }

    private func removeStatusItem() {
        popover?.performClose(nil)
        popover?.contentViewController = nil
        popover = nil

        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        let popover = calendarPopover()
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }

    private func calendarPopover() -> NSPopover {
        if let popover {
            return popover
        }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentSize = MenuBarCalendarView.preferredSize
        popover.contentViewController = NSHostingController(rootView: MenuBarCalendarView())
        self.popover = popover
        return popover
    }

    /// 监听日历弹窗窗口失去 key 状态：焦点转移到弹窗之外时关闭整个日历。
    /// 在 popoverDidShow 中注册（此时窗口已创建，view.window 才有效）。
    /// 三路兜底：① 弹窗窗口 resign key（应用内切换窗口）；
    /// ② 应用失活（Cmd+Tab / 点击其他应用）；③ 点击弹窗外部（含状态栏其他图标）。
    private func observeFocusLoss(of popover: NSPopover) {
        removeFocusLossObservers()
        guard let window = popover.contentViewController?.view.window else { return }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePopoverWindowResignKey),
            name: NSWindow.didResignKeyNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleApplicationResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
        installGlobalClickMonitor()
    }

    @objc private func handleApplicationResignActive() {
        // 应用失活（Cmd+Tab 或点击其他应用窗口）时关闭日历
        DispatchQueue.main.async { [weak self] in
            self?.closePopoverIfFocusMovedAway()
        }
    }

    private func installGlobalClickMonitor() {
        removeGlobalClickMonitor()
        // 点击日历弹窗之外的任意位置（包括状态栏其他图标）时关闭日历。
        // 仅监听点击，不影响滚动/拖拽。
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.closePopoverIfClickedOutside()
            }
        }
    }

    /// 点击在弹窗体系（日历弹窗 + 月份选择器 + 状态栏按钮）之外时关闭日历。
    private func closePopoverIfClickedOutside() {
        guard let popover, popover.isShown,
              let popoverWindow = popover.contentViewController?.view.window
        else { return }
        let clickLocation = NSEvent.mouseLocation
        // 点击在日历弹窗内、月份选择器内、或状态栏按钮上（由 togglePopover 处理）时不关闭
        if popoverWindow.frame.contains(clickLocation) { return }
        if let monthPickerWindow = NSApp.windows.first(where: {
            $0.identifier == MenuBarCalendarView.monthPickerWindowIdentifier
        }), monthPickerWindow.frame.contains(clickLocation) {
            return
        }
        if let button = statusItem?.button,
           let buttonFrame = button.window?.convertToScreen(button.frame),
           buttonFrame.contains(clickLocation) {
            return
        }
        popover.performClose(nil)
    }

    @objc private func handlePopoverWindowResignKey(_ notification: Notification) {
        // 延迟到下一轮 RunLoop 让 keyWindow 完成切换，并给 togglePopover
        // （状态栏按钮点击的关闭/重新打开）留出处理时间，避免误关刚展开的日历。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.closePopoverIfFocusMovedAway()
        }
    }

    /// 焦点仍停留在日历弹窗体系内（如月份选择器弹窗）时不关闭；
    /// 应用已失活（keyWindow 为空或转移到其他窗口）时关闭日历。
    /// 点击本应用状态栏图标关闭日历的场景由 togglePopover 处理，这里不抢，避免闪开后重新打开。
    private func closePopoverIfFocusMovedAway() {
        guard let popover, popover.isShown else { return }
        if NSApp.keyWindow?.identifier == MenuBarCalendarView.monthPickerWindowIdentifier {
            return
        }
        if NSApp.isActive && NSApp.keyWindow == nil {
            return
        }
        popover.performClose(nil)
    }

    private func removeFocusLossObservers() {
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didResignKeyNotification,
            object: nil
        )
        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
        removeGlobalClickMonitor()
    }

    private func removeGlobalClickMonitor() {
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
            self.globalClickMonitor = nil
        }
    }

    func popoverDidShow(_ notification: Notification) {
        guard let popover else { return }
        observeFocusLoss(of: popover)
    }

    func popoverDidClose(_ notification: Notification) {
        removeFocusLossObservers()
    }

}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    private override init() {}

    func show() {
        let settingsWindow: NSWindow
        if let window {
            settingsWindow = window
            if settingsWindow.contentViewController == nil {
                installSettingsContent(in: settingsWindow)
            }
        } else {
            settingsWindow = makeWindow()
            window = settingsWindow
        }

        NSApp.activate(ignoringOtherApps: true)
        settingsWindow.orderFrontRegardless()
        settingsWindow.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("settings-window")
        window.title = "Fewer"
        window.minSize = NSSize(width: 760, height: 520)
        window.isReleasedWhenClosed = false
        window.delegate = self
        installSettingsContent(in: window)
        window.center()
        return window
    }

    private func installSettingsContent(in window: NSWindow) {
        window.contentViewController = NSHostingController(
            rootView: RootSettingsView()
                .frame(minWidth: 760, minHeight: 520)
        )
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow,
              closingWindow === window else {
            return
        }

        closingWindow.contentViewController = nil
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        installApplicationMenu()
        HotKeyManager.shared.install()
        DispatchQueue.main.async {
            AppPresentationController.shared.restoreStoredMode()
            SettingsWindowController.shared.show()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @objc private func showSettings() {
        SettingsWindowController.shared.show()
    }

    private func installApplicationMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()

        let settingsItem = NSMenuItem(
            title: "设置…",
            action: #selector(showSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "退出 Fewer",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApp
        appMenu.addItem(quitItem)

        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        NSApp.mainMenu = mainMenu
    }
}
