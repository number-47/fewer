import Foundation

public enum FewerFeature: String, Codable, CaseIterable, Identifiable, Sendable {
    case newFile
    case copyPath
    case cut
    case paste
    case openInTerminal
    case refresh

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
    /// 当前配置结构版本：v2 起新增"在终端打开"功能；v3 起支持自定义终端应用；v4 起新增"刷新"功能。
    public static let currentSchemaVersion = 4

    /// "在终端打开"默认使用的终端应用 Bundle Identifier。
    public static let defaultTerminalBundleID = "com.apple.Terminal"

    public var schemaVersion: Int
    public var enabledFeatures: Set<FewerFeature>
    public var menuOrder: [FewerFeature]
    public var pathFormat: PathOutputFormat
    public var conflictPolicy: ConflictPolicy
    public var notificationsEnabled: Bool
    public var shortcutHelperEnabled: Bool
    public var launchHelperAtLogin: Bool
    public var terminalBundleID: String

    public init(
        schemaVersion: Int = currentSchemaVersion,
        enabledFeatures: Set<FewerFeature> = Set(FewerFeature.allCases),
        menuOrder: [FewerFeature] = FewerFeature.allCases,
        pathFormat: PathOutputFormat = .posix,
        conflictPolicy: ConflictPolicy = .keepBoth,
        notificationsEnabled: Bool = true,
        shortcutHelperEnabled: Bool = true,
        launchHelperAtLogin: Bool = false,
        terminalBundleID: String = defaultTerminalBundleID
    ) {
        self.schemaVersion = schemaVersion
        self.enabledFeatures = enabledFeatures
        self.menuOrder = menuOrder
        self.pathFormat = pathFormat
        self.conflictPolicy = conflictPolicy
        self.notificationsEnabled = notificationsEnabled
        self.shortcutHelperEnabled = shortcutHelperEnabled
        self.launchHelperAtLogin = launchHelperAtLogin
        self.terminalBundleID = terminalBundleID
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
        case terminalBundleID
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
        terminalBundleID = try values.decodeIfPresent(String.self, forKey: .terminalBundleID)
            ?? defaults.terminalBundleID

        migrateIfNeeded()
    }

    /// 旧版本配置缺少后续新增的功能项（如 v1 → v2 的"在终端打开"），
    /// 解码后按版本补全：新功能默认启用并追加到菜单末尾，不破坏用户已有开关与排序。
    private mutating func migrateIfNeeded() {
        if schemaVersion < 2 {
            enabledFeatures.insert(.openInTerminal)
            if !menuOrder.contains(.openInTerminal) {
                menuOrder.append(.openInTerminal)
            }
        }
        if schemaVersion < 4 {
            enabledFeatures.insert(.refresh)
            if !menuOrder.contains(.refresh) {
                menuOrder.append(.refresh)
            }
        }
        if schemaVersion < Self.currentSchemaVersion {
            schemaVersion = Self.currentSchemaVersion
        }
    }
}
