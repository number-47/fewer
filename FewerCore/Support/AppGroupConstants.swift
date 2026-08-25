import Foundation
import Darwin
import os

public enum AppGroupConstants {
    private static let legacyGroupIdentifier = "group.com.number47.fewer"
    public static let groupIdentifier: String = {
        guard let configuredIdentifier = Bundle.main.object(forInfoDictionaryKey: "FewerAppGroupIdentifier") as? String else {
            os_log(.error, "Fewer: FewerAppGroupIdentifier is missing. A Team ID-prefixed App Group is required.")
            return ""
        }
        let identifier = configuredIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isTeamPrefixedGroupIdentifier(identifier) else {
            os_log(.error, "Fewer: FewerAppGroupIdentifier is not a Team ID-prefixed App Group: %{public}s", identifier)
            return ""
        }
        return identifier
    }()
    public static let featureSettingsKey = "feature-settings-v1"
    public static let inputEnhancementSettingsKey = "input-enhancement-settings-v1"
    public static let modulePreferencesKey = "module-preferences-v1"
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
    /// so the app, Finder extension, and shortcut helper share one store. Unsigned
    /// Debug builds may fall back to `~/Library/Application Support/Fewer/Shared`;
    /// Release builds log the missing container and fail fast.
    public static func sharedDataDirectory(fileManager: FileManager = .default) -> URL {
        let home = homeDirectory(for: fileManager)
        let containerURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier)
        let (directory, usedContainer) = resolveSharedContainer(containerURL: containerURL, homeDirectory: home)
        if !usedContainer {
            logContainerFallback()
            #if !DEBUG
            fatalError("Fewer App Group container is required in Release builds.")
            #endif
        }
        return directory
    }

    /// Returns the App Group defaults suite used for shared preferences. Release
    /// builds must have both a valid Team ID-prefixed identifier and its container.
    public static func sharedUserDefaults(fileManager: FileManager = .default) throws -> UserDefaults {
        guard !groupIdentifier.isEmpty else {
            throw AppGroupStoreError.invalidIdentifier
        }

        #if !DEBUG
        guard fileManager.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier) != nil else {
            logContainerFallback()
            throw AppGroupStoreError.containerUnavailable(identifier: groupIdentifier)
        }
        #endif

        guard let defaults = UserDefaults(suiteName: groupIdentifier) else {
            throw AppGroupStoreError.defaultsUnavailable(identifier: groupIdentifier)
        }
        return defaults
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

    static func isTeamPrefixedGroupIdentifier(_ identifier: String) -> Bool {
        let components = identifier.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 4,
              components[1] == "group",
              !components[0].isEmpty,
              components.dropFirst(2).allSatisfy({ !$0.isEmpty })
        else { return false }
        return !identifier.contains("$(")
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
        // A signed release should always have the container; this error precedes
        // the fail-fast in sharedDataDirectory().
        os_log(
            .error,
            "Fewer: App Group container for %{public}s unavailable in a signed build; terminating. Verify the entitlement is present.",
            groupIdentifier
        )
        #endif
    }
}

public enum AppGroupStoreError: LocalizedError, Equatable {
    case invalidIdentifier
    case containerUnavailable(identifier: String)
    case defaultsUnavailable(identifier: String)

    public var errorDescription: String? {
        switch self {
        case .invalidIdentifier:
            return "Fewer App Group identifier is missing or invalid."
        case let .containerUnavailable(identifier):
            return "Fewer App Group container is unavailable: \(identifier)"
        case let .defaultsUnavailable(identifier):
            return "Fewer App Group UserDefaults suite is unavailable: \(identifier)"
        }
    }
}
