import Foundation
import os
import os.lock

/// Single shared bootstrap that the App, Finder Extension, and Shortcut Helper
/// all call once before creating any file-backed Store. Ensures every process
/// migrates legacy shared data into the App Group container using the same path
/// and the same (idempotent, non-destructive) migrator.
public enum SharedStoreBootstrap {
    private static let runLock = OSAllocatedUnfairLock(initialState: false)

    public static func migrateSharedStoresIfNeeded() {
        guard Self.runLock.withLock({ !$0 }) else { return }
        Self.runLock.withLock { $0 = true }

        let newRoot = AppGroupConstants.sharedDataDirectory()
        let completionMarkerURL = newRoot.appendingPathComponent(SharedStoreMigrator.completionMarkerName)
        guard !FileManager.default.fileExists(atPath: completionMarkerURL.path) else { return }

        let oldAppGroupRoot = AppGroupConstants.legacyAppGroupSharedDataDirectory()
        let oldRoot = FileManager.default.fileExists(atPath: oldAppGroupRoot.path)
            ? oldAppGroupRoot
            : AppGroupConstants.legacySharedDataDirectory()
        let containerRoot = newRoot.deletingLastPathComponent()
        let lockFileURL = containerRoot.appendingPathComponent(".fewer-migration.lock")

        let migrator = SharedStoreMigrator(oldRoot: oldRoot, newRoot: newRoot, lockFileURL: lockFileURL)
        do {
            _ = try migrator.run()
        } catch {
            // Best-effort and strictly non-destructive: never delete old data.
            os_log(.error, "Fewer shared store migration did not complete: %{public}s. Legacy data is preserved.", String(describing: error))
        }
    }
}
