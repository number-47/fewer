import FewerCore
import SwiftUI

struct GeneralSettingsView: View {
    @ObservedObject var model: SettingsViewModel
    @ObservedObject private var presentationController = AppPresentationController.shared

    var body: some View {
        Form {
            Section("显示位置") {
                Picker("运行时显示在", selection: presentationModeBinding) {
                    ForEach(AppPresentationMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.systemImage)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(presentationController.mode == .menuBar
                     ? "Fewer 显示在屏幕顶部菜单栏，不占用 Dock 位置。"
                     : "Fewer 显示在 Dock；点击 Dock 图标可重新打开设置。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("重名处理") {
                Picker("新建文件与右键粘贴", selection: Binding(
                    get: { model.settings.conflictPolicy },
                    set: { model.setConflictPolicy($0) }
                )) {
                    Text("保留两者").tag(ConflictPolicy.keepBoth)
                    Text("跳过").tag(ConflictPolicy.skip)
                    Text("替换（移入废纸篓）").tag(ConflictPolicy.replace)
                }
            }

            Section("行为") {
                Toggle("显示操作结果通知", isOn: Binding(
                    get: { model.settings.notificationsEnabled },
                    set: { model.setNotificationsEnabled($0) }
                ))
                Toggle("登录时启动快捷键助手", isOn: Binding(
                    get: { model.settings.launchHelperAtLogin },
                    set: { model.setLaunchHelperAtLogin($0) }
                ))
            }

            Section("关于") {
                LabeledContent("应用", value: "Fewer")
                LabeledContent("版本", value: "\(FewerVersion.current)")
                Text("More tools. Fewer apps.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("通用")
    }

    private var presentationModeBinding: Binding<AppPresentationMode> {
        Binding(
            get: { presentationController.mode },
            set: { mode in
                presentationController.setMode(mode)
            }
        )
    }
}
