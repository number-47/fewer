import AppKit
import FewerCore

@MainActor
enum PermissionService {
    private static let helperBundleIdentifier = "com.number47.fewer.shortcut-helper"
    private static let statusStore = ShortcutHelperStatusStore()
    private static var lastLaunchAttempt = Date.distantPast

    static var shortcutHelperStatus: ShortcutHelperStatus {
        guard let status = statusStore.load(),
              let application = NSRunningApplication(
                processIdentifier: status.processIdentifier
              ),
              isCurrentHelper(application)
        else { return .unavailable }
        return status
    }

    static func requestAccessibility() {
        launchShortcutHelper(requestAccessibility: true)
    }

    static func ensureShortcutHelperRunning() {
        let isRunning = NSRunningApplication.runningApplications(
            withBundleIdentifier: helperBundleIdentifier
        ).contains(where: isCurrentHelper)
        guard !isRunning, Date().timeIntervalSince(lastLaunchAttempt) >= 2 else { return }
        launchShortcutHelper()
    }

    @discardableResult
    static func launchShortcutHelper(requestAccessibility: Bool = false) -> Bool {
        if NSRunningApplication.runningApplications(
            withBundleIdentifier: helperBundleIdentifier
        ).contains(where: isCurrentHelper) {
            if requestAccessibility {
                notifyAccessibilityRequest()
            }
            return true
        }

        let helperURL = currentHelperURL
        guard FileManager.default.fileExists(atPath: helperURL.path) else { return false }
        lastLaunchAttempt = Date()

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        // 嵌套 LoginItem 与已安装版本使用相同 bundle id。强制按当前 bundle URL
        // 创建实例，避免 LaunchServices 静默复用或解析到另一个 Fewer 构建。
        configuration.createsNewApplicationInstance = true
        if requestAccessibility {
            configuration.arguments = ["--request-accessibility"]
        }

        NSWorkspace.shared.openApplication(at: helperURL, configuration: configuration) { _, _ in
            guard requestAccessibility else { return }
            Task { @MainActor in
                notifyAccessibilityRequest()
            }
        }
        return true
    }

    private static var currentHelperURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LoginItems/FewerShortcutHelper.app")
            .standardizedFileURL
    }

    private static func isCurrentHelper(_ application: NSRunningApplication) -> Bool {
        guard !application.isTerminated, let bundleURL = application.bundleURL else {
            return false
        }
        return bundleURL.standardizedFileURL == currentHelperURL
    }

    private static func notifyAccessibilityRequest() {
        DistributedNotificationCenter.default().postNotificationName(
            AppGroupConstants.requestShortcutHelperAccessibilityNotification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }
}
