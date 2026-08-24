import Foundation
import Darwin

/// A single known file or directory copied from the legacy root into the new
/// App Group `Shared` root during migration.
public struct SharedStoreMigrationItem: Sendable, Equatable {
    public let relativePath: String
    public let isDirectory: Bool

    public init(relativePath: String, isDirectory: Bool) {
        self.relativePath = relativePath
        self.isDirectory = isDirectory
    }
}

public enum SharedStoreMigrationError: Error, Equatable {
    case lockAcquisitionFailed
    case copyFailed(underlying: String)
    case verificationFailed(path: String)
    case markerWriteFailed(underlying: String)

    public static func == (lhs: SharedStoreMigrationError, rhs: SharedStoreMigrationError) -> Bool {
        switch (lhs, rhs) {
        case (.lockAcquisitionFailed, .lockAcquisitionFailed):
            return true
        case let (.copyFailed(a), .copyFailed(b)):
            return a == b
        case let (.verificationFailed(a), .verificationFailed(b)):
            return a == b
        case let (.markerWriteFailed(a), .markerWriteFailed(b)):
            return a == b
        default:
            return false
        }
    }
}

/// Copies the legacy `~/Library/Application Support/Fewer/Shared` store data into
/// the new App Group `Shared` container without ever deleting the old data.
///
/// Guarantees:
/// - Cross-process safe via an advisory file lock inside the App Group container.
/// - Never overwrites an existing destination file.
/// - The completion marker is published atomically and only after every item is
///   verified to have copied correctly.
/// - Idempotent: re-running reaches the same final state.
/// - Old data is preserved on interruption (staging is cleaned up, no deletes).
public struct SharedStoreMigrator {
    public static let completionMarkerName = ".fewer-migration-done"

    public static let defaultItems: [SharedStoreMigrationItem] = [
        .init(relativePath: "feature-settings.json", isDirectory: false),
        .init(relativePath: "input-enhancement-settings.json", isDirectory: false),
        .init(relativePath: "cut-transaction.json", isDirectory: false),
        .init(relativePath: "module-preferences.json", isDirectory: false),
        .init(relativePath: "shortcut-helper-status.json", isDirectory: false),
        .init(relativePath: "Templates", isDirectory: true),
    ]

    /// Serializes migrators that live in the same process; the file lock guards
    /// across separate processes (App / Helper / Extension).
    private static let inProcessQueue = DispatchQueue(label: "com.number47.fewer.shared-store-migration")

    public let oldRoot: URL
    public let newRoot: URL
    public let lockFileURL: URL
    public let items: [SharedStoreMigrationItem]
    public let fileManager: FileManager

    public init(
        oldRoot: URL,
        newRoot: URL,
        lockFileURL: URL,
        items: [SharedStoreMigrationItem] = defaultItems,
        fileManager: FileManager = .default
    ) {
        self.oldRoot = oldRoot
        self.newRoot = newRoot
        self.lockFileURL = lockFileURL
        self.items = items
        self.fileManager = fileManager
    }

    /// Runs the migration once. Returns `true` when legacy data was present and
    /// migrated (or had already completed), `false` when there was nothing to migrate.
    @discardableResult
    public func run() throws -> Bool {
        let markerURL = newRoot.appendingPathComponent(Self.completionMarkerName)
        if fileManager.fileExists(atPath: markerURL.path) {
            return true
        }

        return try Self.inProcessQueue.sync {
            // Re-check after acquiring the in-process guard.
            if fileManager.fileExists(atPath: markerURL.path) {
                return true
            }
            let hadLegacyData = try withFileLock {
                let hadLegacyData = try performMigration()
                if hadLegacyData {
                    try publishCompletionMarker()
                }
                return hadLegacyData
            }
            return hadLegacyData
        }
    }

    /// Returns `true` when legacy data was present (and the new root is now in the
    /// desired state), `false` when there was nothing to migrate. Never deletes old data.
    private func performMigration() throws -> Bool {
        let sources = items.filter { fileManager.fileExists(atPath: oldRoot.appendingPathComponent($0.relativePath).path) }
        guard !sources.isEmpty else {
            // Nothing to migrate.
            return false
        }

        try fileManager.createDirectory(at: newRoot, withIntermediateDirectories: true)

        var copiedThisRun: [URL] = []
        do {
            for item in sources {
                let source = oldRoot.appendingPathComponent(item.relativePath)
                let destination = newRoot.appendingPathComponent(item.relativePath)
                // Never overwrite a destination that already exists.
                if fileManager.fileExists(atPath: destination.path) {
                    continue
                }
                try fileManager.copyItem(at: source, to: destination)
                try verifyCopied(from: source, to: destination, isDirectory: item.isDirectory)
                copiedThisRun.append(destination)
            }
        } catch {
            // Roll back only what we copied this run; keep old data untouched.
            for url in copiedThisRun {
                try? fileManager.removeItem(at: url)
            }
            throw SharedStoreMigrationError.copyFailed(underlying: String(describing: error))
        }
        return true
    }

    private func verifyCopied(from source: URL, to destination: URL, isDirectory: Bool) throws {
        guard fileManager.fileExists(atPath: destination.path) else {
            throw SharedStoreMigrationError.verificationFailed(path: destination.path)
        }
        guard isDirectory == isDirectoryAt(destination) else {
            throw SharedStoreMigrationError.verificationFailed(path: destination.path)
        }
        if !isDirectory {
            let sourceSize = sizeOfItem(at: source)
            let destinationSize = sizeOfItem(at: destination)
            guard sourceSize == destinationSize else {
                throw SharedStoreMigrationError.verificationFailed(path: destination.path)
            }
        }
    }

    private func isDirectoryAt(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private func sizeOfItem(at url: URL) -> Int64 {
        (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? -1
    }

    /// Atomically publishes the completion marker: write to a staging file in the
    /// same directory, then `rename`. The marker is written only after all items
    /// have been verified in `performMigration`.
    private func publishCompletionMarker() throws {
        let markerURL = newRoot.appendingPathComponent(Self.completionMarkerName)
        let stagingURL = newRoot.appendingPathComponent(Self.completionMarkerName + ".tmp")
        let payload = "migrated-at: \(Date().timeIntervalSince1970)\n"
        do {
            try fileManager.createDirectory(at: newRoot, withIntermediateDirectories: true)
            try payload.write(to: stagingURL, atomically: true, encoding: .utf8)
            try renameAtomically(from: stagingURL, to: markerURL)
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            throw SharedStoreMigrationError.markerWriteFailed(underlying: String(describing: error))
        }
    }

    private func renameAtomically(from source: URL, to destination: URL) throws {
        let result = rename(source.path, destination.path)
        guard result == 0 else {
            throw SharedStoreMigrationError.markerWriteFailed(underlying: "rename failed: \(errno)")
        }
    }

    /// Acquires a cross-process advisory exclusive lock on `lockFileURL` before
    /// running `body`, retrying briefly if another process holds the lock.
    private func withFileLock<T>(_ body: () throws -> T) throws -> T {
        let fd = open(lockFileURL.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else {
            throw SharedStoreMigrationError.lockAcquisitionFailed
        }
        defer { close(fd) }

        var acquired = false
        for _ in 0..<200 {
            if flock(fd, Int32(LOCK_EX | LOCK_NB)) == 0 {
                acquired = true
                break
            }
            if errno == EWOULDBLOCK || errno == EAGAIN {
                usleep(50_000)
                continue
            }
            break
        }
        guard acquired else {
            throw SharedStoreMigrationError.lockAcquisitionFailed
        }
        defer { flock(fd, Int32(LOCK_UN)) }
        return try body()
    }
}
