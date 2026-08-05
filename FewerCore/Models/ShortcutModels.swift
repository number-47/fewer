import Foundation

public enum ShortcutKey: Equatable, Sendable {
    case x
    case v
    case other
}

public struct ShortcutModifiers: OptionSet, Equatable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let command = ShortcutModifiers(rawValue: 1 << 0)
    public static let option = ShortcutModifiers(rawValue: 1 << 1)
    public static let shift = ShortcutModifiers(rawValue: 1 << 2)
    public static let control = ShortcutModifiers(rawValue: 1 << 3)
}

public enum FinderShortcutDecision: Equatable, Sendable {
    case passThrough
    case captureCut
    case performFinderMovePaste
}
