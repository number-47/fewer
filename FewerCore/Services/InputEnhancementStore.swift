import Foundation

public final class InputEnhancementStore: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public convenience init() {
        SharedStoreBootstrap.migrateSharedStoresIfNeeded()
        self.init(
            fileURL: AppGroupConstants.sharedDataDirectory()
                .appendingPathComponent("input-enhancement-settings.json")
        )
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() -> InputEnhancementSettings {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL),
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
        lock.lock()
        defer { lock.unlock() }
        var normalized = settings
        normalized.schemaVersion = InputEnhancementSettings.currentSchemaVersion
        normalized.scroll.normalize()
        normalized.keycast.customPosition = normalized.keycast.customPosition.map {
            KeycastNormalizedPosition(x: $0.x, y: $0.y)
        }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(normalized).write(to: fileURL, options: .atomic)
    }
}
