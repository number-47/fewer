import Foundation

public struct CutTransaction: Codable, Equatable, Sendable {
    public let id: UUID
    public let sourceURLs: [URL]
    public var remainingURLs: [URL]
    public let createdAt: Date
    public let pasteboardChangeCount: Int

    public init(
        id: UUID = UUID(),
        sourceURLs: [URL],
        remainingURLs: [URL]? = nil,
        createdAt: Date = Date(),
        pasteboardChangeCount: Int
    ) {
        self.id = id
        self.sourceURLs = sourceURLs
        self.remainingURLs = remainingURLs ?? sourceURLs
        self.createdAt = createdAt
        self.pasteboardChangeCount = pasteboardChangeCount
    }
}
