import FewerCore
import SwiftUI

struct ContextMenuSettingsView: View {
    @ObservedObject var model: SettingsViewModel

    var body: some View {
        Form {
            Section("菜单项目") {
                List {
                    ForEach(model.settings.menuOrder) { feature in
                        Toggle(feature.title, isOn: Binding(
                            get: { model.settings.enabledFeatures.contains(feature) },
                            set: { model.setFeature(feature, enabled: $0) }
                        ))
                    }
                    .onMove { offsets, destination in
                        model.moveFeatures(from: offsets, to: destination)
                    }
                }
                .frame(minHeight: 190)
            }

            Section("复制路径格式") {
                Picker("格式", selection: Binding(
                    get: { model.settings.pathFormat },
                    set: { model.setPathFormat($0) }
                )) {
                    Text("POSIX 绝对路径").tag(PathOutputFormat.posix)
                    Text("Shell 引号路径").tag(PathOutputFormat.quoted)
                    Text("file:// URL").tag(PathOutputFormat.fileURL)
                }
                Text("多选时固定为一行一个路径。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("右键菜单")
    }
}

private extension FewerFeature {
    var title: String {
        switch self {
        case .newFile: "新建文件"
        case .copyPath: "复制路径"
        case .cut: "剪切"
        case .paste: "粘贴"
        }
    }
}
