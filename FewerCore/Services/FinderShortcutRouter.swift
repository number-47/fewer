import Foundation

public enum FinderShortcutRouter {
    public static func decision(
        frontmostBundleID: String?,
        isEnabled: Bool,
        isAccessibilityTrusted: Bool,
        key: ShortcutKey,
        modifiers: ShortcutModifiers,
        hasValidCutTransaction: Bool
    ) -> FinderShortcutDecision {
        guard frontmostBundleID == "com.apple.finder",
              isEnabled,
              isAccessibilityTrusted,
              modifiers == [.command]
        else { return .passThrough }

        switch key {
        case .x:
            return .captureCut
        case .v where hasValidCutTransaction:
            return .performFinderMovePaste
        default:
            return .passThrough
        }
    }
}
