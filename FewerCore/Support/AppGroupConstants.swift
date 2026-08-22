import Foundation
import Darwin

public enum AppGroupConstants {
    public static let groupIdentifier = "group.com.number47.fewer"
    public static let featureSettingsKey = "feature-settings-v1"
    public static let cutTransactionKey = "cut-transaction-v1"
    public static let requestShortcutHelperAccessibilityNotification = Notification.Name(
        "com.number47.fewer.request-shortcut-helper-accessibility"
    )
    public static let inputEnhancementSettingsDidChangeNotification = Notification.Name(
        "com.number47.fewer.input-enhancement-settings-did-change"
    )
    public static let inputEnhancementControlNotification = Notification.Name(
        "com.number47.fewer.input-enhancement-command"
    )
    public static let featureSettingsDidChangeNotification = Notification.Name(
        "com.number47.fewer.feature-settings-did-change"
    )
    public static let cutTransactionDidChangeNotification = Notification.Name(
        "com.number47.fewer.cut-transaction-did-change"
    )
    public static let modulePreferencesDidChangeNotification = Notification.Name(
        "com.number47.fewer.module-preferences-did-change"
    )
    public static let moduleCommandNotification = Notification.Name(
        "com.number47.fewer.module-command"
    )
    /// File-backed state lives outside the App Group container so ad-hoc local builds and
    /// properly provisioned releases share the same deterministic storage contract.
    public static func sharedDataDirectory(fileManager: FileManager = .default) -> URL {
        let accountHome: URL
        if let account = getpwuid(getuid()),
           let homePath = account.pointee.pw_dir {
            accountHome = URL(fileURLWithPath: String(cString: homePath), isDirectory: true)
        } else {
            accountHome = fileManager.homeDirectoryForCurrentUser
        }
        return accountHome
            .appendingPathComponent("Library/Application Support/Fewer/Shared", isDirectory: true)
    }
}
