import Foundation

public final class CutTransactionStore: @unchecked Sendable {
    private let fileURL: URL
    private let expirationInterval: TimeInterval
    private let now: () -> Date
    private let lock = NSLock()
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
        self.expirationInterval = expirationInterval
        self.now = now
    }

    @discardableResult
    public func start(urls: [URL], pasteboardChangeCount: Int) throws -> CutTransaction {
        lock.lock()
        defer { lock.unlock() }

        let transaction = CutTransaction(
            sourceURLs: urls,
            createdAt: now(),
            pasteboardChangeCount: pasteboardChangeCount
        )
        try persist(transaction)
        return transaction
    }

    public func load(currentPasteboardChangeCount: Int) throws -> CutTransaction? {
        lock.lock()
        defer { lock.unlock() }

        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let transaction = try decoder.decode(CutTransaction.self, from: Data(contentsOf: fileURL))
        guard transaction.pasteboardChangeCount == currentPasteboardChangeCount,
              now().timeIntervalSince(transaction.createdAt) <= expirationInterval,
              transaction.remainingURLs.contains(where: { FileManager.default.fileExists(atPath: $0.path) })
        else {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
        return transaction
    }

    public func keepRemaining(_ urls: [URL], for transactionID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }

        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        var transaction = try decoder.decode(CutTransaction.self, from: Data(contentsOf: fileURL))
        guard transaction.id == transactionID else { return }
        if urls.isEmpty {
            try? FileManager.default.removeItem(at: fileURL)
        } else {
            transaction.remainingURLs = urls
            try persist(transaction)
        }
    }

    public func clear() throws {
        lock.lock()
        defer { lock.unlock() }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    private func persist(_ transaction: CutTransaction) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(transaction).write(to: fileURL, options: .atomic)
    }
}

public enum CutTransactionStoreError: Error {
    case appGroupUnavailable
}
