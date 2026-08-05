import SwiftUI

struct ShortcutSettingsView: View {
    @ObservedObject var model: SettingsViewModel
    @State private var accessibilityTrusted = PermissionService.isAccessibilityTrusted

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
                LabeledContent("状态", value: accessibilityTrusted ? "已授权" : "未授权")
                Button("请求权限") {
                    PermissionService.requestAccessibility()
                    accessibilityTrusted = PermissionService.isAccessibilityTrusted
                }
                Button("打开系统设置") { PermissionService.openAccessibilitySettings() }
            } header: {
                Text("辅助功能权限")
            } footer: {
                Text("助手只在 Finder 位于前台时处理 ⌘X/⌘V，不记录按键历史或文本输入。快捷键粘贴使用 Finder 原生冲突处理。")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("快捷键")
    }
}
