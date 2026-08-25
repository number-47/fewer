import Foundation
import os
import os.lock
import Darwin

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

    /// Imports a legacy JSON preference into the App Group defaults suite once.
    /// Feature and Module stores call this only from their main-app writer mode.
    /// Input remains temporarily multi-writer until T036 moves Helper mutations
    /// through authenticated XPC.
    static func migratePreferenceIfNeeded(
        in defaults: UserDefaults,
        key: String,
        legacyFileName: String,
        sharedRoot: URL? = nil,
        legacyFileURLs: [URL]? = nil,
        fileManager: FileManager = .default
    ) {
        guard defaults.object(forKey: key) == nil else { return }

        let sharedRoot = sharedRoot ?? AppGroupConstants.sharedDataDirectory(fileManager: fileManager)
        let lockURL = sharedRoot.deletingLastPathComponent()
            .appendingPathComponent(".fewer-preferences-migration.lock")
        guard withExclusiveFileLock(at: lockURL, fileManager: fileManager, {
            guard defaults.object(forKey: key) == nil else { return }
            let candidates = legacyFileURLs ?? [
                sharedRoot.appendingPathComponent(legacyFileName),
                AppGroupConstants.legacyAppGroupSharedDataDirectory(fileManager: fileManager)
                    .appendingPathComponent(legacyFileName),
                AppGroupConstants.legacySharedDataDirectory(fileManager: fileManager)
                    .appendingPathComponent(legacyFileName),
            ]
            guard let source = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }),
                  let data = try? Data(contentsOf: source)
            else { return }
            defaults.set(data, forKey: key)
        }) else {
            os_log(.error, "Fewer shared preference migration lock could not be acquired.")
            return
        }
    }

    /// Serializes a short read-modify-write critical section across the App,
    /// Finder extension, and shortcut helper. The caller retains the ownership
    /// policy for its payload; this helper only provides process coordination.
    static func withExclusiveFileLock(
        at lockURL: URL,
        fileManager: FileManager = .default,
        _ body: () -> Void
    ) -> Bool {
        do {
            try fileManager.createDirectory(
                at: lockURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            return false
        }
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        guard flock(descriptor, Int32(LOCK_EX)) == 0 else { return false }
        defer { flock(descriptor, Int32(LOCK_UN)) }
        body()
        return true
    }
}
