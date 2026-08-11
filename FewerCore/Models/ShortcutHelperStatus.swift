import Foundation

public struct ShortcutHelperStatus: Codable, Equatable, Sendable {
    public static let unavailable = ShortcutHelperStatus(
        isAccessibilityTrusted: false,
        processIdentifier: 0,
        updatedAt: .distantPast
    )

    public let isAccessibilityTrusted: Bool
    public let processIdentifier: Int32
    public let updatedAt: Date

    public init(
        isAccessibilityTrusted: Bool,
        processIdentifier: Int32,
        updatedAt: Date
    ) {
        self.isAccessibilityTrusted = isAccessibilityTrusted
        self.processIdentifier = processIdentifier
        self.updatedAt = updatedAt
    }

    public func isFresh(at date: Date = Date(), timeout: TimeInterval = 5) -> Bool {
        processIdentifier > 0 && date.timeIntervalSince(updatedAt) <= timeout
    }
}
