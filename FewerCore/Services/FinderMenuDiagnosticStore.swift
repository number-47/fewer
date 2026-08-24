import Foundation

/// Finder 扩展菜单诊断心跳的共享 Store。
/// 扩展进程写入，主应用读取，通过 App Group 共享存储交换数据。
/// 遵循 ShortcutHelperStatusStore 的同一约定。
public final class FinderMenuDiagnosticStore: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public convenience init() {
        SharedStoreBootstrap.migrateSharedStoresIfNeeded()
        self.init(
            fileURL: AppGroupConstants.sharedDataDirectory()
                .appendingPathComponent("finder-menu-diagnostic.json")
        )
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() -> FinderMenuDiagnostic? {
        lock.lock()
        defer { lock.unlock() }

        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? decoder.decode(FinderMenuDiagnostic.self, from: data)
    }

    public func save(_ diagnostic: FinderMenuDiagnostic) throws {
        lock.lock()
        defer { lock.unlock() }

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(diagnostic)
        try data.write(to: fileURL, options: .atomic)
    }
}
