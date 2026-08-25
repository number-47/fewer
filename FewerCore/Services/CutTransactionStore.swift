import Foundation

private struct CutTransactionEnvelope: Codable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let revision: Int
    let updatedAt: Date
    let payload: CutTransaction
}

public final class CutTransactionStore: @unchecked Sendable {
    private static let inProcessQueue = DispatchQueue(label: "com.number47.fewer.cut-transaction-store")

    private let fileURL: URL
    private let lockFileURL: URL
    private let expirationInterval: TimeInterval
    private let now: () -> Date
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public convenience init() throws {
        SharedStoreBootstrap.migrateSharedStoresIfNeeded()
        self.init(
            fileURL: AppGroupConstants.sharedDataDirectory()
                .appendingPathComponent("cut-transaction.json")
        )
    }

    public init(
        fileURL: URL,
        expirationInterval: TimeInterval = 24 * 60 * 60,
        now: @escaping () -> Date = Date.init
    ) {
        self.fileURL = fileURL
        lockFileURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".cut-transaction.lock")
        self.expirationInterval = expirationInterval
        self.now = now
    }

    @discardableResult
    public func start(urls: [URL], pasteboardChangeCount: Int) throws -> CutTransaction {
        try coordinatedAccess {
            let transaction = CutTransaction(
                sourceURLs: urls,
                createdAt: now(),
                pasteboardChangeCount: pasteboardChangeCount
            )
            try persist(transaction, replacing: try loadEnvelope()?.revision ?? 0)
            return transaction
        }
    }

    public func load(currentPasteboardChangeCount: Int) throws -> CutTransaction? {
        try coordinatedAccess {
            guard let envelope = try loadEnvelope() else { return nil }
            let transaction = envelope.payload
            guard transaction.pasteboardChangeCount == currentPasteboardChangeCount,
                  now().timeIntervalSince(transaction.createdAt) <= expirationInterval,
                  transaction.remainingURLs.contains(where: { FileManager.default.fileExists(atPath: $0.path) })
            else {
                try? FileManager.default.removeItem(at: fileURL)
                return nil
            }
            return transaction
        }
    }

    public func keepRemaining(_ urls: [URL], for transactionID: UUID) throws {
        try coordinatedAccess {
            guard let envelope = try loadEnvelope(), envelope.payload.id == transactionID else { return }
            if urls.isEmpty {
                try? FileManager.default.removeItem(at: fileURL)
            } else {
                var transaction = envelope.payload
                transaction.remainingURLs = urls
                try persist(transaction, replacing: envelope.revision)
            }
        }
    }

    public func clear() throws {
        try coordinatedAccess {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
        }
    }

    func currentRevision() throws -> Int? {
        try coordinatedAccess { try loadEnvelope()?.revision }
    }

    private func loadEnvelope() throws -> CutTransactionEnvelope? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        if let envelope = try? decoder.decode(CutTransactionEnvelope.self, from: data) {
            return envelope
        }
        let transaction = try decoder.decode(CutTransaction.self, from: data)
        return CutTransactionEnvelope(
            schemaVersion: CutTransactionEnvelope.schemaVersion,
            revision: 0,
            updatedAt: transaction.createdAt,
            payload: transaction
        )
    }

    private func persist(_ transaction: CutTransaction, replacing revision: Int) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let envelope = CutTransactionEnvelope(
            schemaVersion: CutTransactionEnvelope.schemaVersion,
            revision: revision + 1,
            updatedAt: now(),
            payload: transaction
        )
        try encoder.encode(envelope).write(to: fileURL, options: .atomic)
    }

    private func coordinatedAccess<T>(_ body: () throws -> T) throws -> T {
        try Self.inProcessQueue.sync {
            var result: Result<T, Error>?
            let locked = SharedStoreBootstrap.withExclusiveFileLock(at: lockFileURL) {
                var coordinationError: NSError?
                let coordinator = NSFileCoordinator()
                coordinator.coordinate(
                    writingItemAt: fileURL,
                    options: .forReplacing,
                    error: &coordinationError
                ) { _ in
                    result = Result { try body() }
                }
                if let coordinationError {
                    result = .failure(coordinationError)
                }
            }
            guard locked else { throw CutTransactionStoreError.lockUnavailable }
            guard let result else { throw CutTransactionStoreError.coordinationFailed }
            return try result.get()
        }
    }
}

public enum CutTransactionStoreError: LocalizedError, Equatable {
    case lockUnavailable
    case coordinationFailed

    public var errorDescription: String? {
        switch self {
        case .lockUnavailable:
            return "The shared cut transaction lock is unavailable."
        case .coordinationFailed:
            return "The shared cut transaction could not be coordinated."
        }
    }
}
