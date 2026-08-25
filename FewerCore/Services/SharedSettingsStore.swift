import Foundation

public struct SettingsLoadResult: Equatable, Sendable {
    public let settings: FeatureSettings
    public let recoveryReason: String?

    public init(settings: FeatureSettings, recoveryReason: String? = nil) {
        self.settings = settings
        self.recoveryReason = recoveryReason
    }
}

public final class SharedSettingsStore: @unchecked Sendable {
    private enum Storage {
        case defaults(UserDefaults)
        case file(URL)
    }

    private let storage: Storage
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock = NSLock()
    private let access: SharedPreferenceAccess

    public convenience init(access: SharedPreferenceAccess = .readOnly) throws {
        SharedStoreBootstrap.migrateSharedStoresIfNeeded()
        let defaults = try AppGroupConstants.sharedUserDefaults()
        self.init(defaults: defaults, access: access)
        if access == .mainAppWriter {
            SharedStoreBootstrap.migratePreferenceIfNeeded(
                in: defaults,
                key: AppGroupConstants.featureSettingsKey,
                legacyFileName: "feature-settings.json"
            )
        }
    }

    public init(defaults: UserDefaults, access: SharedPreferenceAccess = .mainAppWriter) {
        self.storage = .defaults(defaults)
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.access = access
    }

    public init(fileURL: URL, access: SharedPreferenceAccess = .mainAppWriter) {
        self.storage = .file(fileURL)
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.access = access
    }

    public func load() -> SettingsLoadResult {
        lock.lock()
        defer { lock.unlock() }

        let data: Data?
        switch storage {
        case let .defaults(defaults):
            data = defaults.data(forKey: AppGroupConstants.featureSettingsKey)
        case let .file(fileURL):
            data = try? Data(contentsOf: fileURL)
        }

        guard let data else {
            return SettingsLoadResult(settings: .default)
        }

        do {
            return SettingsLoadResult(settings: try decoder.decode(FeatureSettings.self, from: data))
        } catch {
            return SettingsLoadResult(
                settings: .default,
                recoveryReason: "设置数据无法读取，已恢复默认值：\(error.localizedDescription)"
            )
        }
    }

    public func save(_ settings: FeatureSettings) throws {
        guard access == .mainAppWriter else { throw SharedPreferenceStoreError.readOnly }
        lock.lock()
        defer { lock.unlock() }

        let data = try encoder.encode(settings)
        switch storage {
        case let .defaults(defaults):
            defaults.set(data, forKey: AppGroupConstants.featureSettingsKey)
        case let .file(fileURL):
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        }
    }
}

public enum SharedPreferenceAccess: Sendable {
    case readOnly
    case mainAppWriter
}

public enum SharedPreferenceStoreError: LocalizedError, Equatable {
    case readOnly

    public var errorDescription: String? {
        "Only the main Fewer app may write shared preferences."
    }
}

public enum SharedSettingsStoreError: Error {
    case appGroupUnavailable
}
