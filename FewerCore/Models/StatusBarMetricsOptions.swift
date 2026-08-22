import Foundation

/// 仅用于读取 schema 4 之前的菜单栏指标配置并完成一次性迁移。
/// 新的运行时配置使用 `MonitorModulePreferences`。
public struct StatusBarMetricsOptions: Codable, Equatable, Sendable {
    public var cpu: Bool
    public var ram: Bool
    public var ssd: Bool
    public var upload: Bool
    public var download: Bool

    public init(
        cpu: Bool = true,
        ram: Bool = true,
        ssd: Bool = true,
        upload: Bool = true,
        download: Bool = true
    ) {
        self.cpu = cpu
        self.ram = ram
        self.ssd = ssd
        self.upload = upload
        self.download = download
    }

    public static let `default` = StatusBarMetricsOptions()
}
