import FewerCore
import SwiftUI

struct GeneralSettingsView: View {
    @ObservedObject var model: SettingsViewModel

    var body: some View {
        Form {
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
}
