import Foundation

public final class ModulePreferencesStore: @unchecked Sendable {
    private static let recoveryDefaultsKey = "module-preferences-recovery-v1"
    private static let recoveryMarkerFileName = "module-preferences-recovery-v1"

    private enum Storage {
        case defaults(UserDefaults)
        case file(URL)
        case unavailable
    }

    private let storage: Storage
    private let access: SharedPreferenceAccess
    private let recoveryDirectory: URL?
    private let backupTimestamp: () -> String
    private let lock = NSLock()
    private var recoveryReason: String?

    public convenience init(access: SharedPreferenceAccess = .readOnly) {
        SharedStoreBootstrap.migrateSharedStoresIfNeeded()
        guard let defaults = try? AppGroupConstants.sharedUserDefaults() else {
            self.init(
                storage: .unavailable,
                access: access,
                recoveryDirectory: nil,
                backupTimestamp: Self.makeBackupTimestamp
            )
            return
        }
        self.init(
            storage: .defaults(defaults),
            access: access,
            recoveryDirectory: AppGroupConstants.sharedDataDirectory()
                .appendingPathComponent("Recovery", isDirectory: true),
            backupTimestamp: Self.makeBackupTimestamp
        )
        if access == .mainAppWriter {
            SharedStoreBootstrap.migratePreferenceIfNeeded(
                in: defaults,
                key: AppGroupConstants.modulePreferencesKey,
                legacyFileName: "module-preferences.json"
            )
        }
    }

    public convenience init(
        defaults: UserDefaults,
        access: SharedPreferenceAccess = .mainAppWriter,
        recoveryDirectory: URL? = nil
    ) {
        self.init(
            storage: .defaults(defaults),
            access: access,
            recoveryDirectory: recoveryDirectory,
            backupTimestamp: Self.makeBackupTimestamp
        )
    }

    public convenience init(
        fileURL: URL,
        access: SharedPreferenceAccess = .mainAppWriter,
        recoveryDirectory: URL? = nil
    ) {
        self.init(
            storage: .file(fileURL),
            access: access,
            recoveryDirectory: recoveryDirectory ?? fileURL.deletingLastPathComponent()
                .appendingPathComponent("Recovery", isDirectory: true),
            backupTimestamp: Self.makeBackupTimestamp
        )
    }

    convenience init(
        defaults: UserDefaults,
        access: SharedPreferenceAccess = .mainAppWriter,
        recoveryDirectory: URL,
        backupTimestamp: @escaping () -> String
    ) {
        self.init(
            storage: .defaults(defaults),
            access: access,
            recoveryDirectory: recoveryDirectory,
            backupTimestamp: backupTimestamp
        )
    }

    convenience init(
        fileURL: URL,
        access: SharedPreferenceAccess = .mainAppWriter,
        recoveryDirectory: URL,
        backupTimestamp: @escaping () -> String
    ) {
        self.init(
            storage: .file(fileURL),
            access: access,
            recoveryDirectory: recoveryDirectory,
            backupTimestamp: backupTimestamp
        )
    }

    private init(
        storage: Storage,
        access: SharedPreferenceAccess,
        recoveryDirectory: URL?,
        backupTimestamp: @escaping () -> String
    ) {
        self.storage = storage
        self.access = access
        self.recoveryDirectory = recoveryDirectory
        self.backupTimestamp = backupTimestamp
    }

    public var recoveryMessage: String? {
        lock.lock()
        defer { lock.unlock() }
        return recoveryReason
    }

    public func load(descriptors: [ModuleDescriptor]) -> ModulePreferences {
        lock.lock()
        defer { lock.unlock() }
        recoveryReason = nil
        guard !hasRecoveryMarker() else {
            recoverPendingFileBackupIfNeeded()
            recoveryReason = "模块偏好数据无法读取，所有模块已安全停用。"
            return disabledPreferences(descriptors: descriptors)
        }

        let payload = readPayload()
        var preferences: ModulePreferences
        let loadedPreferences: ModulePreferences?
        switch payload {
        case .missing:
            preferences = freshPreferences(descriptors: descriptors)
            loadedPreferences = nil
        case let .data(data):
            if let decoded = try? JSONDecoder().decode(ModulePreferences.self, from: data) {
                preferences = decoded
                loadedPreferences = decoded
            } else {
                recoverCorruptPayload()
                recoveryReason = "模块偏好数据无法读取，所有模块已安全停用。"
                return disabledPreferences(descriptors: descriptors)
            }
        case .unreadable:
            recoverCorruptPayload()
            recoveryReason = "模块偏好数据无法读取，所有模块已安全停用。"
            return disabledPreferences(descriptors: descriptors)
        }
        preferences.reconcile(with: descriptors)
        if access == .mainAppWriter, preferences != loadedPreferences {
            try? write(preferences)
        }
        return preferences
    }

    public func save(_ preferences: ModulePreferences) throws {
        guard access == .mainAppWriter else { throw SharedPreferenceStoreError.readOnly }
        lock.lock()
        defer { lock.unlock() }
        try write(preferences)
    }

    private func write(_ preferences: ModulePreferences) throws {
        let data = try JSONEncoder().encode(preferences)
        switch storage {
        case let .defaults(defaults):
            defaults.set(data, forKey: AppGroupConstants.modulePreferencesKey)
        case let .file(fileURL):
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        case .unavailable:
            throw AppGroupStoreError.containerUnavailable(identifier: AppGroupConstants.groupIdentifier)
        }
        clearRecoveryMarker()
        recoveryReason = nil
    }

    public func isEnabled(moduleID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !hasRecoveryMarker() else { return false }
        switch readPayload() {
        case .missing:
            return true
        case let .data(data):
            guard let preferences = try? JSONDecoder().decode(ModulePreferences.self, from: data) else {
                return false
            }
            return preferences.enabledModuleIDs.contains(moduleID)
        case .unreadable:
            return false
        }
    }

    private enum Payload {
        case missing
        case data(Data)
        case unreadable
    }

    private func readPayload() -> Payload {
        switch storage {
        case let .defaults(defaults):
            guard let object = defaults.object(forKey: AppGroupConstants.modulePreferencesKey) else {
                return .missing
            }
            return (object as? Data).map(Payload.data) ?? .unreadable
        case let .file(fileURL):
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return .missing }
            return (try? Data(contentsOf: fileURL)).map(Payload.data) ?? .unreadable
        case .unavailable:
            return .missing
        }
    }

    private func freshPreferences(descriptors: [ModuleDescriptor]) -> ModulePreferences {
        ModulePreferences(enabledModuleIDs: Set(descriptors.map(\.id)))
    }

    private func disabledPreferences(descriptors: [ModuleDescriptor]) -> ModulePreferences {
        var preferences = ModulePreferences(enabledModuleIDs: [])
        preferences.reconcile(with: descriptors)
        return preferences
    }

    private func recoverCorruptPayload() {
        guard access == .mainAppWriter else { return }
        switch storage {
        case let .defaults(defaults):
            guard let data = defaults.data(forKey: AppGroupConstants.modulePreferencesKey),
                  backup(data: data)
            else { return }
            setRecoveryMarker()
            defaults.removeObject(forKey: AppGroupConstants.modulePreferencesKey)
        case let .file(fileURL):
            guard setRecoveryMarker() else { return }
            moveFileToBackup(fileURL)
        case .unavailable:
            break
        }
    }

    private func recoverPendingFileBackupIfNeeded() {
        guard access == .mainAppWriter,
              case let .file(fileURL) = storage,
              FileManager.default.fileExists(atPath: fileURL.path)
        else { return }
        moveFileToBackup(fileURL)
    }

    private func moveFileToBackup(_ fileURL: URL) {
        guard let recoveryDirectory else { return }
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
            while true {
                let destination = uniqueBackupURL(in: recoveryDirectory, fileManager: fileManager)
                do {
                    try fileManager.moveItem(at: fileURL, to: destination)
                    return
                } catch CocoaError.fileWriteFileExists {
                    continue
                }
            }
        } catch {
            return
        }
    }

    private func backup(data: Data) -> Bool {
        guard let recoveryDirectory else { return false }
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
            let temporaryURL = recoveryDirectory.appendingPathComponent(".module-preferences-\(UUID().uuidString).tmp")
            try data.write(to: temporaryURL, options: .atomic)
            defer { try? fileManager.removeItem(at: temporaryURL) }
            while true {
                let destination = uniqueBackupURL(in: recoveryDirectory, fileManager: fileManager)
                do {
                    try fileManager.moveItem(at: temporaryURL, to: destination)
                    return true
                } catch CocoaError.fileWriteFileExists {
                    continue
                }
            }
        } catch {
            return false
        }
    }

    private func uniqueBackupURL(in directory: URL, fileManager: FileManager) -> URL {
        let baseName = "module-preferences.corrupt-\(backupTimestamp())"
        var suffix = 0
        while true {
            let name = suffix == 0 ? "\(baseName).json" : "\(baseName)-\(suffix).json"
            let candidate = directory.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            suffix += 1
        }
    }

    private func hasRecoveryMarker() -> Bool {
        switch storage {
        case let .defaults(defaults):
            return defaults.bool(forKey: Self.recoveryDefaultsKey)
        case .file:
            guard let recoveryDirectory else { return false }
            return FileManager.default.fileExists(
                atPath: recoveryDirectory.appendingPathComponent(Self.recoveryMarkerFileName).path
            )
        case .unavailable:
            return false
        }
    }

    @discardableResult
    private func setRecoveryMarker() -> Bool {
        switch storage {
        case let .defaults(defaults):
            defaults.set(true, forKey: Self.recoveryDefaultsKey)
            return true
        case .file:
            guard let recoveryDirectory else { return false }
            do {
                try FileManager.default.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
                try Data().write(
                    to: recoveryDirectory.appendingPathComponent(Self.recoveryMarkerFileName),
                    options: .atomic
                )
                return true
            } catch {
                return false
            }
        case .unavailable:
            return false
        }
    }

    private func clearRecoveryMarker() {
        switch storage {
        case let .defaults(defaults):
            defaults.removeObject(forKey: Self.recoveryDefaultsKey)
        case .file:
            guard let recoveryDirectory else { return }
            try? FileManager.default.removeItem(
                at: recoveryDirectory.appendingPathComponent(Self.recoveryMarkerFileName)
            )
        case .unavailable:
            break
        }
    }

    private static func makeBackupTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmssSSS"
        return formatter.string(from: Date())
    }
}
