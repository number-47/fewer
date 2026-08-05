import Foundation

public enum FileOperationStatus: String, Codable, Equatable, Sendable {
    case moved
    case skipped
    case failed
}

public enum FileOperationError: String, Codable, Error, Equatable, Sendable {
    case sourceMissing
    case targetNotDirectory
    case sameLocation
    case destinationInsideSource
    case replacementNotRecoverable
    case systemError
}

public struct FileOperationItemResult: Equatable, Sendable {
    public let sourceURL: URL
    public let destinationURL: URL?
    public let status: FileOperationStatus
    public let error: FileOperationError?

    public init(
        sourceURL: URL,
        destinationURL: URL?,
        status: FileOperationStatus,
        error: FileOperationError? = nil
    ) {
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
        self.status = status
        self.error = error
    }
}

public struct FileOperationBatchResult: Equatable, Sendable {
    public let items: [FileOperationItemResult]

    public init(items: [FileOperationItemResult]) {
        self.items = items
    }

    public var successfulSourceURLs: [URL] {
        items.filter { $0.status == .moved }.map(\.sourceURL)
    }

    public var failedSourceURLs: [URL] {
        items.filter { $0.status != .moved }.map(\.sourceURL)
    }
}
