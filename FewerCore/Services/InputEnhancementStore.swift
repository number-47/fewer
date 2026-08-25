import Foundation

public final class InputEnhancementStore: @unchecked Sendable {
    private enum Storage {
        case defaults(UserDefaults)
        case file(URL)
        case unavailable
    }

    private let storage: Storage
    private let access: SharedPreferenceAccess
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// The shortcut helper still persists its emergency-stop and keycast-position
    /// updates until T036 moves those mutations through authenticated XPC.
    public convenience init(access: SharedPreferenceAccess = .mainAppWriter) {
        SharedStoreBootstrap.migrateSharedStoresIfNeeded()
        guard let defaults = try? AppGroupConstants.sharedUserDefaults() else {
            self.init(storage: .unavailable, access: access)
            return
        }
        self.init(defaults: defaults, access: access)
        if access == .mainAppWriter {
            SharedStoreBootstrap.migratePreferenceIfNeeded(
                in: defaults,
                key: AppGroupConstants.inputEnhancementSettingsKey,
                legacyFileName: "input-enhancement-settings.json"
            )
        }
    }

    public convenience init(defaults: UserDefaults, access: SharedPreferenceAccess = .mainAppWriter) {
        self.init(storage: .defaults(defaults), access: access)
    }

    public convenience init(fileURL: URL, access: SharedPreferenceAccess = .mainAppWriter) {
        self.init(storage: .file(fileURL), access: access)
    }

    private init(storage: Storage, access: SharedPreferenceAccess) {
        self.storage = storage
        self.access = access
    }

    public func load() -> InputEnhancementSettings {
        lock.lock()
        defer { lock.unlock() }
        let data: Data?
        switch storage {
        case let .defaults(defaults):
            data = defaults.data(forKey: AppGroupConstants.inputEnhancementSettingsKey)
        case let .file(fileURL):
            data = try? Data(contentsOf: fileURL)
        case .unavailable:
            data = nil
        }
        guard let data,
              var settings = try? decoder.decode(InputEnhancementSettings.self, from: data)
        else { return .default }
        settings.scroll.normalize()
        settings.keycast.customPosition = settings.keycast.customPosition.map {
            KeycastNormalizedPosition(x: $0.x, y: $0.y)
        }
        settings.schemaVersion = InputEnhancementSettings.currentSchemaVersion
        return settings
    }

    public func save(_ settings: InputEnhancementSettings) throws {
        guard access == .mainAppWriter else { throw SharedPreferenceStoreError.readOnly }
        lock.lock()
        defer { lock.unlock() }
        var normalized = settings
        normalized.schemaVersion = InputEnhancementSettings.currentSchemaVersion
        normalized.scroll.normalize()
        normalized.keycast.customPosition = normalized.keycast.customPosition.map {
            KeycastNormalizedPosition(x: $0.x, y: $0.y)
        }
        let data = try encoder.encode(normalized)
        switch storage {
        case let .defaults(defaults):
            defaults.set(data, forKey: AppGroupConstants.inputEnhancementSettingsKey)
        case let .file(fileURL):
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        case .unavailable:
            throw AppGroupStoreError.containerUnavailable(identifier: AppGroupConstants.groupIdentifier)
        }
    }
}
