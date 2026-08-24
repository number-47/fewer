import SwiftUI
import FewerCore

struct ShortcutSettingsView: View {
    @ObservedObject var model: SettingsViewModel
    @State private var helperStatus = PermissionService.shortcutHelperStatus
    @State private var activateTask: Task<Void, Never>?

    private var authorizationStatusText: String {
        if helperStatus.isAccessibilityTrusted {
            return helperStatus.isFresh() ? "已授权" : "已授权（助手未运行）"
        }
        return helperStatus.isFresh() ? "未授权" : "等待助手启动"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                FewerSettingsCard {
                    FewerSettingsRow { status("辅助功能权限", "全局快捷键监听所需", helperStatus.isAccessibilityTrusted ? "已授权" : "未授权", helperStatus.isAccessibilityTrusted) }
                    Divider()
                    FewerSettingsRow { status("⌘X 剪切支持", "Finder 中使用 ⌘X 剪切文件", authorizationStatusText, helperStatus.isFresh()) }
                    Divider()
                    FewerSettingsRow { status("⌘V 粘贴支持", "Finder 中使用 ⌘V 粘贴文件", authorizationStatusText, helperStatus.isFresh()) }
                }
                FewerSettingsCard {
                    FewerSettingsRow { Text("截图快捷键").fontWeight(.semibold) }
                    Divider()
                    FewerSettingsRow { Text("区域截图"); Spacer(); Text("⌘⌥A").monospaced().foregroundStyle(.secondary) }
                    Divider()
                    FewerSettingsRow { Text("窗口截图"); Spacer(); Text("⌘⌥W").monospaced().foregroundStyle(.secondary) }
                    Divider()
                    FewerSettingsRow { Text("全屏截图"); Spacer(); Text("⌘⌥F").monospaced().foregroundStyle(.secondary) }
                }
                FewerSettingsCard {
                    FewerSettingsRow {
                        VStack(alignment: .leading, spacing: 2) { Text("快捷键助手"); Text("辅助进程，负责监听与执行全局快捷键").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Toggle("", isOn: Binding(get: { model.settings.shortcutHelperEnabled }, set: { model.setShortcutHelperEnabled($0) })).labelsHidden()
                    }
                    Divider()
                    FewerSettingsRow {
                        VStack(alignment: .leading, spacing: 2) { Text("开机启动助手"); Text("登录时自动启动辅助进程").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Toggle("", isOn: Binding(get: { model.settings.launchHelperAtLogin }, set: { model.setLaunchHelperAtLogin($0) })).labelsHidden()
                    }
                }
            }.padding(.bottom, 24)
        }
        .task {
            if model.settings.shortcutHelperEnabled {
                PermissionService.launchShortcutHelper()
                PermissionService.ensureShortcutHelperRunning()
            }
            helperStatus = PermissionService.shortcutHelperStatus
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            activateTask?.cancel()
            activateTask = Task {
                if model.settings.shortcutHelperEnabled { PermissionService.ensureShortcutHelperRunning() }
                helperStatus = PermissionService.shortcutHelperStatus
            }
        }
        .onDisappear {
            activateTask?.cancel()
            activateTask = nil
        }
    }

    private func status(_ title: String, _ detail: String, _ value: String, _ okay: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title); Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(value).font(.caption).foregroundStyle(okay ? .green : .orange)
        }
    }
}
