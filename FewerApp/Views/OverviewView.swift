import FewerCore
import SwiftUI

/// 原型概览页的五项状态全部来自 Finder、截图与快捷键服务，不展示示例状态。
struct OverviewView: View {
    @ObservedObject var model: SettingsViewModel
    var onOpenPermissions: (() -> Void)?
    @State private var extensionStatus: ExtensionStatus = .unknown
    @State private var helperStatus = PermissionService.shortcutHelperStatus
    @State private var activateTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                group {
                    statusRow("Finder 扩展", "右键菜单文件操作功能", extensionStatus.title, extensionStatus == .enabled)
                    Divider()
                    statusRow("辅助功能权限", "全局快捷键与鼠标手势所需", helperStatus.isAccessibilityTrusted ? "已授权" : "未授权", helperStatus.isAccessibilityTrusted)
                    Divider()
                    statusRow("输入监控权限", "鼠标滚轮增强与手势识别所需", helperStatus.isInputMonitoringTrusted ? "已授权" : "未授权", helperStatus.isInputMonitoringTrusted)
                    Divider()
                    statusRow("屏幕录制权限", "截图与滚动截图功能所需", ScreenshotCapture.hasPermission ? "已授权" : "未授权", ScreenshotCapture.hasPermission)
                    Divider()
                    statusRow("日历权限", "日历模块读取日程与提醒事项", SystemCalendarService.shared.authorizationState == .fullAccess ? "已授权" : "未授权", SystemCalendarService.shared.authorizationState == .fullAccess)
                }
                if let onOpenPermissions {
                    FewerSettingsCard {
                        FewerSettingsRow {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("权限与扩展")
                                Text("前往集中管理所有授权状态与操作入口").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("前往") { onOpenPermissions() }
                        }
                    }
                }
                group {
                    statusRow("辅助进程状态", "FewerShortcutHelper — 快捷键、剪切粘贴、滚轮增强", helperStatus.isFresh() ? "运行中" : "未运行", helperStatus.isFresh())
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("辅助进程开机启动")
                            Text("登录时自动启动辅助进程").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { model.settings.launchHelperAtLogin },
                            set: { model.setLaunchHelperAtLogin($0) }
                        )).labelsHidden()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(minHeight: 44)
                }
            }
            .padding(.bottom, 24)
        }
        .task {
            if model.settings.shortcutHelperEnabled {
                PermissionService.launchShortcutHelper()
                PermissionService.ensureShortcutHelperRunning()
            }
            await refreshStatuses()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            activateTask?.cancel()
            activateTask = Task { await refreshStatuses() }
        }
        .onDisappear {
            activateTask?.cancel()
            activateTask = nil
        }
    }

    private func refreshStatuses() async {
        helperStatus = PermissionService.shortcutHelperStatus
        let status = await ExtensionStatusService.cachedStatus()
        if !Task.isCancelled { extensionStatus = status }
    }

    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(red: 232 / 255, green: 232 / 255, blue: 237 / 255)))
    }

    private func statusRow(_ title: String, _ detail: String, _ status: String, _ okay: Bool) -> some View {
        HStack(spacing: 10) {
            Circle().fill(okay ? .green : .orange).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(status).font(.caption.weight(.medium)).foregroundStyle(okay ? .green : .orange)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 44)
    }
}
