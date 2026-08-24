import Foundation

/// Finder 扩展 `menu(for:)` 返回 nil 的稳定原因码。
/// 用于诊断心跳，不记录用户文件名或完整路径（隐私红线）。
public enum FinderMenuReason: String, Codable, Sendable {
    /// Finder 模块被用户在设置中关闭。
    case moduleDisabled
    /// `makeContext(for:)` 无法解析菜单上下文（如不支持的 menuKind 或无 targetURL）。
    case contextUnavailable
    /// `FinderActionHandler.services` 初始化失败，无法访问设置/模板/剪贴板存储。
    case servicesUnavailable
    /// MenuBuilder 返回空 entries，FinderMenuAdapter 生成不出任何菜单项。
    case emptyEntries

    /// 供设置页展示的中文说明。
    public var displayDescription: String {
        switch self {
        case .moduleDisabled: "Finder 模块已关闭"
        case .contextUnavailable: "菜单上下文不可用"
        case .servicesUnavailable: "扩展服务初始化失败"
        case .emptyEntries: "当前场景无可用菜单项"
        }
    }
}

/// Finder 扩展诊断心跳：记录扩展启动、最近一次菜单请求结果与构建身份。
/// 扩展进程写入共享 Store，主应用读取以区分「未启用 / 模块关闭 / 旧构建 / 上下文或服务失败」。
public struct FinderMenuDiagnostic: Codable, Equatable, Sendable {
    /// 扩展进程最近一次启动时间。
    public let lastExtensionLaunch: Date
    /// 最近一次 `menu(for:)` 调用时间；nil 表示启动后尚未被 Finder 请求过菜单。
    public let lastMenuRequest: Date?
    /// 最近一次菜单请求是否成功返回非空菜单。
    public let lastRequestSucceeded: Bool
    /// 最近一次成功请求的根菜单项数量（失败时为 0）。
    public let lastEntryCount: Int
    /// 最近一次失败的原因码；成功时为 nil。
    public let lastReason: FinderMenuReason?
    /// 扩展构建版本号（CFBundleShortVersionString）。
    public let buildVersion: String
    /// 扩展构建编号（CFBundleVersion）。
    public let buildNumber: String
    /// 扩展进程 PID，用于判断扩展是否仍在运行。
    public let processIdentifier: Int32

    public init(
        lastExtensionLaunch: Date,
        lastMenuRequest: Date? = nil,
        lastRequestSucceeded: Bool = false,
        lastEntryCount: Int = 0,
        lastReason: FinderMenuReason? = nil,
        buildVersion: String,
        buildNumber: String,
        processIdentifier: Int32
    ) {
        self.lastExtensionLaunch = lastExtensionLaunch
        self.lastMenuRequest = lastMenuRequest
        self.lastRequestSucceeded = lastRequestSucceeded
        self.lastEntryCount = lastEntryCount
        self.lastReason = lastReason
        self.buildVersion = buildVersion
        self.buildNumber = buildNumber
        self.processIdentifier = processIdentifier
    }

    /// 向前兼容：旧版本心跳可能缺少新字段，缺失时使用安全默认值。
    private enum CodingKeys: String, CodingKey {
        case lastExtensionLaunch
        case lastMenuRequest
        case lastRequestSucceeded
        case lastEntryCount
        case lastReason
        case buildVersion
        case buildNumber
        case processIdentifier
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lastExtensionLaunch = try container.decode(Date.self, forKey: .lastExtensionLaunch)
        lastMenuRequest = try container.decodeIfPresent(Date.self, forKey: .lastMenuRequest)
        lastRequestSucceeded = try container.decodeIfPresent(Bool.self, forKey: .lastRequestSucceeded) ?? false
        lastEntryCount = try container.decodeIfPresent(Int.self, forKey: .lastEntryCount) ?? 0
        lastReason = try container.decodeIfPresent(FinderMenuReason.self, forKey: .lastReason)
        buildVersion = try container.decode(String.self, forKey: .buildVersion)
        buildNumber = try container.decode(String.self, forKey: .buildNumber)
        processIdentifier = try container.decode(Int32.self, forKey: .processIdentifier)
    }
}
