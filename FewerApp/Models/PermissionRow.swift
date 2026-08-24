import Foundation

/// 权限与扩展设置页的单行展示模型。仅承载展示数据；按钮由视图按 kind + status 渲染。
/// 不做通用权限框架，仅服务于 PermissionsSettingsView。
struct PermissionRow: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case accessibility
        case inputMonitoring
        case screenRecording
        case calendarReminders
        case finderExtension
    }

    enum Status: String, Equatable, Sendable {
        case authorized
        case notAuthorized
        case unknown
        case helperNotRunning
        case notEnabled
    }

    let kind: Kind
    let title: String
    let purpose: String
    let principal: String
    let status: Status

    var id: String { kind.rawValue }
}
