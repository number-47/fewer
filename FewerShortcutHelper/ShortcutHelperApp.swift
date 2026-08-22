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
    private var inputEventCoordinator: InputEventCoordinator?
    private var heartbeatTimer: Timer?
    private let statusStore = ShortcutHelperStatusStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        inputEventCoordinator = InputEventCoordinator()
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
        inputEventCoordinator?.stop()
        DistributedNotificationCenter.default().removeObserver(self)
        let status = ShortcutHelperStatus(
            isAccessibilityTrusted: AXIsProcessTrusted(),
            isInputMonitoringTrusted: CGPreflightListenEventAccess(),
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
        inputEventCoordinator?.refreshCachedState()
        let runtimeStatus = inputEventCoordinator?.status() ?? InputEventRuntimeStatus()
        let status = ShortcutHelperStatus(
            isAccessibilityTrusted: isTrusted,
            isInputMonitoringTrusted: CGPreflightListenEventAccess(),
            isEventTapActive: runtimeStatus.isEventTapActive,
            isScrollEngineActive: runtimeStatus.isScrollEngineActive,
            isGestureEngineActive: runtimeStatus.isGestureEngineActive,
            isKeycastActive: runtimeStatus.isKeycastActive,
            detectedScrollDevice: runtimeStatus.detectedScrollDevice,
            emergencyDisabled: runtimeStatus.emergencyDisabled,
            lastError: runtimeStatus.lastError,
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            updatedAt: Date()
        )
        try? statusStore.save(status)
        if isTrusted {
            inputEventCoordinator?.start()
        } else {
            inputEventCoordinator?.stop()
        }
    }
}
