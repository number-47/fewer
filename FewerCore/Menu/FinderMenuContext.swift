import Foundation

public enum FinderMenuKind: Equatable, Sendable {
    case container
    case items
    case sidebar
}

public struct FinderMenuContext: Sendable, Equatable {
    public let kind: FinderMenuKind
    public let selectedURLs: [URL]
    public let targetURL: URL
    public let isTargetWritable: Bool
    public let hasCutTransaction: Bool
    public let isSingleSelectedItemDirectory: Bool

    public init(
        kind: FinderMenuKind,
        selectedURLs: [URL],
        targetURL: URL,
        isTargetWritable: Bool,
        hasCutTransaction: Bool,
        isSingleSelectedItemDirectory: Bool = false
    ) {
        self.kind = kind
        self.selectedURLs = selectedURLs
        self.targetURL = targetURL
        self.isTargetWritable = isTargetWritable
        self.hasCutTransaction = hasCutTransaction
        self.isSingleSelectedItemDirectory = isSingleSelectedItemDirectory
    }
}
