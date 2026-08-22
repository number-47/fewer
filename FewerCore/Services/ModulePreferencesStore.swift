import Foundation

public final class ModulePreferencesStore: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()

    public convenience init() {
        self.init(fileURL: AppGroupConstants.sharedDataDirectory().appendingPathComponent("module-preferences.json"))
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load(descriptors: [ModuleDescriptor]) -> ModulePreferences {
        lock.lock()
        defer { lock.unlock() }
        var preferences: ModulePreferences
        let loadedPreferences: ModulePreferences?
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(ModulePreferences.self, from: data) {
            preferences = decoded
            loadedPreferences = decoded
        } else {
            preferences = ModulePreferences(enabledModuleIDs: Set(descriptors.map(\.id)))
            loadedPreferences = nil
        }
        preferences.reconcile(with: descriptors)
        if preferences != loadedPreferences {
            try? write(preferences)
        }
        return preferences
    }

    public func save(_ preferences: ModulePreferences) throws {
        lock.lock()
        defer { lock.unlock() }
        try write(preferences)
    }

    private func write(_ preferences: ModulePreferences) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(preferences).write(to: fileURL, options: .atomic)
    }

    public func isEnabled(moduleID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL),
              let preferences = try? JSONDecoder().decode(ModulePreferences.self, from: data)
        else {
            return true
        }
        return preferences.enabledModuleIDs.contains(moduleID)
    }
}
