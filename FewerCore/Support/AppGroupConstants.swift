import Foundation
import Darwin
import os

public enum AppGroupConstants {
    private static let legacyGroupIdentifier = "group.com.number47.fewer"
    public static let groupIdentifier: String = {
        guard let configuredIdentifier = Bundle.main.object(forInfoDictionaryKey: "FewerAppGroupIdentifier") as? String else {
            return legacyGroupIdentifier
        }
        let identifier = configuredIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        return identifier.isEmpty ? legacyGroupIdentifier : identifier
    }()
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

    /// Current shared storage root. File-backed Stores resolve here.
    ///
    /// Preferred location is the configured App Group container's `Shared` directory
    /// so the app, Finder extension, and shortcut helper share one store. When the
    /// container URL is unavailable (unsigned local builds without the entitlement)
    /// it falls back to `~/Library/Application Support/Fewer/Shared` and logs a
    /// diagnosable error in signed builds so a release can prove the container was used.
    public static func sharedDataDirectory(fileManager: FileManager = .default) -> URL {
        let home = homeDirectory(for: fileManager)
        let containerURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier)
        let (directory, usedContainer) = resolveSharedContainer(containerURL: containerURL, homeDirectory: home)
        if !usedContainer {
            logContainerFallback()
        }
        return directory
    }

    /// Previous shared storage location. Used only by the migrator to find
    /// pre-migration data; new code must use ``sharedDataDirectory()``.
    public static func legacySharedDataDirectory(fileManager: FileManager = .default) -> URL {
        homeDirectory(for: fileManager)
            .appendingPathComponent("Library/Application Support/Fewer/Shared", isDirectory: true)
    }

    /// Previous App Group storage location, used only while migrating to the
    /// Team ID-prefixed App Group identifier.
    static func legacyAppGroupSharedDataDirectory(fileManager: FileManager = .default) -> URL {
        resolveLegacyAppGroupSharedDirectory(homeDirectory: homeDirectory(for: fileManager))
    }

    static func resolveLegacyAppGroupSharedDirectory(homeDirectory: URL) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Group Containers/\(legacyGroupIdentifier)/Shared", isDirectory: true)
    }

    /// Pure resolution of the shared data directory. Returns the resolved directory
    /// and whether the App Group container was actually used (vs. the fallback).
    public static func resolveSharedContainer(
        containerURL: URL?,
        homeDirectory: URL
    ) -> (directory: URL, usedContainer: Bool) {
        if let containerURL {
            return (containerURL.appendingPathComponent("Shared", isDirectory: true), true)
        }
        return (
            homeDirectory
                .appendingPathComponent("Library/Application Support/Fewer/Shared", isDirectory: true),
            false
        )
    }

    private static func homeDirectory(for fileManager: FileManager) -> URL {
        if let account = getpwuid(getuid()),
           let homePath = account.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: homePath), isDirectory: true)
        }
        return fileManager.homeDirectoryForCurrentUser
    }

    private static func logContainerFallback() {
        #if DEBUG
        // Unsigned local dev without the entitlement: the fallback is expected.
        os_log(.info, "Fewer: App Group container unavailable; using ~/Library/Application Support/Fewer/Shared (unsigned local dev).")
        #else
        // A signed release should always have the container; surface this as an error.
        os_log(
            .error,
            "Fewer: App Group container for %{public}s unavailable in a signed build; falling back to ~/Library/Application Support/Fewer/Shared. Verify the entitlement is present.",
            groupIdentifier
        )
        #endif
    }
}
