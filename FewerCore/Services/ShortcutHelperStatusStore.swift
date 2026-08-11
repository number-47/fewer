import Foundation

public final class ShortcutHelperStatusStore: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public convenience init() {
        self.init(
            fileURL: AppGroupConstants.sharedDataDirectory()
                .appendingPathComponent("shortcut-helper-status.json")
        )
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() -> ShortcutHelperStatus? {
        lock.lock()
        defer { lock.unlock() }

        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? decoder.decode(ShortcutHelperStatus.self, from: data)
    }

    public func save(_ status: ShortcutHelperStatus) throws {
        lock.lock()
        defer { lock.unlock() }

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(status)
        try data.write(to: fileURL, options: .atomic)
    }
}
