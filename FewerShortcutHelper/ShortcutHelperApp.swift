import AppKit
import ApplicationServices
import FewerCore

@main
enum ShortcutHelperApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = ShortcutHelperDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.prohibited)
        application.run()
        _ = delegate
    }
}

final class ShortcutHelperDelegate: NSObject, NSApplicationDelegate {
    private var eventTapController: EventTapController?
    private var heartbeatTimer: Timer?
    private let statusStore = ShortcutHelperStatusStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        eventTapController = EventTapController()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(requestAccessibility),
            name: AppGroupConstants.requestShortcutHelperAccessibilityNotification,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        heartbeatTimer = Timer.scheduledTimer(
            timeInterval: 1,
            target: self,
            selector: #selector(refreshStatus),
            userInfo: nil,
            repeats: true
        )

        if CommandLine.arguments.contains("--request-accessibility") {
            requestAccessibility()
        } else {
            refreshStatus()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        heartbeatTimer?.invalidate()
        DistributedNotificationCenter.default().removeObserver(self)
        let status = ShortcutHelperStatus(
            isAccessibilityTrusted: AXIsProcessTrusted(),
            processIdentifier: 0,
            updatedAt: Date()
        )
        try? statusStore.save(status)
    }

    @objc private func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refreshStatus()
    }

    @objc private func refreshStatus() {
        let isTrusted = AXIsProcessTrusted()
        let status = ShortcutHelperStatus(
            isAccessibilityTrusted: isTrusted,
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            updatedAt: Date()
        )
        try? statusStore.save(status)
        if isTrusted {
            eventTapController?.start()
        }
    }
}
