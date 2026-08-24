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

    public convenience init() throws {
        SharedStoreBootstrap.migrateSharedStoresIfNeeded()
        self.init(
            fileURL: AppGroupConstants.sharedDataDirectory()
                .appendingPathComponent("feature-settings.json")
        )
    }

    public init(defaults: UserDefaults) {
        self.storage = .defaults(defaults)
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    public init(fileURL: URL) {
        self.storage = .file(fileURL)
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
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

public enum SharedSettingsStoreError: Error {
    case appGroupUnavailable
}
