import SwiftUI
import FewerCore

struct ShortcutSettingsView: View {
    @ObservedObject var model: SettingsViewModel
    @State private var helperStatus = PermissionService.shortcutHelperStatus

    private var authorizationStatusText: String {
        if helperStatus.isAccessibilityTrusted {
            return helperStatus.isFresh() ? "已授权" : "已授权（助手未运行）"
        }
        return helperStatus.isFresh() ? "未授权" : "等待助手启动"
    }

    var body: some View {
        Form {
            Section {
                Toggle("启用 Finder 快捷键助手", isOn: Binding(
                    get: { model.settings.shortcutHelperEnabled },
                    set: { model.setShortcutHelperEnabled($0) }
                ))
            }

            Section("默认快捷键") {
                LabeledContent("剪切") { Text("⌘X").monospaced() }
                LabeledContent("粘贴") { Text("⌘V").monospaced() }
            }

            Section {
                LabeledContent("状态", value: authorizationStatusText)
                Button("请求权限") {
                    PermissionService.requestAccessibility()
                }
                Button("打开系统设置") { PermissionService.openAccessibilitySettings() }
            } header: {
                Text("辅助功能权限")
            } footer: {
                Text("请在系统设置中授权 FewerShortcutHelper。助手只在 Finder 位于前台时处理 ⌘X/⌘V，不记录按键历史或文本输入。快捷键粘贴使用 Finder 原生冲突处理。")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("快捷键")
        .task {
            if model.settings.shortcutHelperEnabled {
                PermissionService.launchShortcutHelper()
            }
            while !Task.isCancelled {
                if model.settings.shortcutHelperEnabled {
                    PermissionService.ensureShortcutHelperRunning()
                }
                helperStatus = PermissionService.shortcutHelperStatus
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
