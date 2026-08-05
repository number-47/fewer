import Foundation

public enum FewerFeature: String, Codable, CaseIterable, Identifiable, Sendable {
    case newFile
    case copyPath
    case cut
    case paste

    public var id: String { rawValue }
}

public enum PathOutputFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case posix
    case quoted
    case fileURL

    public var id: String { rawValue }
}

public enum ConflictPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case keepBoth
    case skip
    case replace

    public var id: String { rawValue }
}

public struct FeatureSettings: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var enabledFeatures: Set<FewerFeature>
    public var menuOrder: [FewerFeature]
    public var pathFormat: PathOutputFormat
    public var conflictPolicy: ConflictPolicy
    public var notificationsEnabled: Bool
    public var shortcutHelperEnabled: Bool
    public var launchHelperAtLogin: Bool

    public init(
        schemaVersion: Int = currentSchemaVersion,
        enabledFeatures: Set<FewerFeature> = Set(FewerFeature.allCases),
        menuOrder: [FewerFeature] = FewerFeature.allCases,
        pathFormat: PathOutputFormat = .posix,
        conflictPolicy: ConflictPolicy = .keepBoth,
        notificationsEnabled: Bool = true,
        shortcutHelperEnabled: Bool = true,
        launchHelperAtLogin: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.enabledFeatures = enabledFeatures
        self.menuOrder = menuOrder
        self.pathFormat = pathFormat
        self.conflictPolicy = conflictPolicy
        self.notificationsEnabled = notificationsEnabled
        self.shortcutHelperEnabled = shortcutHelperEnabled
        self.launchHelperAtLogin = launchHelperAtLogin
    }

    public static let `default` = FeatureSettings()

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case enabledFeatures
        case menuOrder
        case pathFormat
        case conflictPolicy
        case notificationsEnabled
        case shortcutHelperEnabled
        case launchHelperAtLogin
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = FeatureSettings.default

        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? defaults.schemaVersion
        enabledFeatures = try values.decodeIfPresent(Set<FewerFeature>.self, forKey: .enabledFeatures)
            ?? defaults.enabledFeatures
        menuOrder = try values.decodeIfPresent([FewerFeature].self, forKey: .menuOrder)
            ?? defaults.menuOrder
        pathFormat = try values.decodeIfPresent(PathOutputFormat.self, forKey: .pathFormat)
            ?? defaults.pathFormat
        conflictPolicy = try values.decodeIfPresent(ConflictPolicy.self, forKey: .conflictPolicy)
            ?? defaults.conflictPolicy
        notificationsEnabled = try values.decodeIfPresent(Bool.self, forKey: .notificationsEnabled)
            ?? defaults.notificationsEnabled
        shortcutHelperEnabled = try values.decodeIfPresent(Bool.self, forKey: .shortcutHelperEnabled)
            ?? defaults.shortcutHelperEnabled
        launchHelperAtLogin = try values.decodeIfPresent(Bool.self, forKey: .launchHelperAtLogin)
            ?? defaults.launchHelperAtLogin
    }
}
