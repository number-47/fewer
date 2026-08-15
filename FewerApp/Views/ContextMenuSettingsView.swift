import AppKit
import FewerCore
import SwiftUI

struct ContextMenuSettingsView: View {
    @ObservedObject var model: SettingsViewModel
    /// 是否处于"自定义…"输入状态（与存储值分离：选择自定义后由输入框修改真实值）。
    @State private var isCustomTerminal: Bool

    /// "自定义…"选项的 tag（不写入存储，仅用于 Picker 选中态）。
    private static let customTerminalTag = "fewer.custom-terminal"

    init(model: SettingsViewModel) {
        self.model = model
        _isCustomTerminal = State(
            initialValue: CommonTerminal.commonTerminal(matchingBundleID: model.settings.terminalBundleID) == nil
        )
    }

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

            Section("在终端打开") {
                Picker("终端应用", selection: terminalSelection) {
                    ForEach(CommonTerminal.all) { terminal in
                        Text(terminal.name).tag(terminal.bundleIdentifier)
                    }
                    Text("自定义…").tag(Self.customTerminalTag)
                }
                if isCustomTerminal {
                    TextField("Bundle Identifier", text: customTerminalInput)
                        .textFieldStyle(.roundedBorder)
                }
                if let availability = terminalAvailability {
                    Text(availability.text)
                        .font(.callout)
                        .foregroundStyle(availability.isError ? .red : .secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("右键菜单")
    }

    /// Picker 选中态：内置终端显示其 Bundle Identifier，自定义状态显示占位 tag。
    /// 选择"自定义…"仅切换输入状态，不修改存储值（由输入框写回）。
    private var terminalSelection: Binding<String> {
        Binding(
            get: { isCustomTerminal ? Self.customTerminalTag : model.settings.terminalBundleID },
            set: { newValue in
                if newValue == Self.customTerminalTag {
                    isCustomTerminal = true
                } else {
                    isCustomTerminal = false
                    model.setTerminalBundleID(newValue)
                }
            }
        )
    }

    /// 自定义 Bundle Identifier 输入框（直接写回存储）。
    private var customTerminalInput: Binding<String> {
        Binding(
            get: { model.settings.terminalBundleID },
            set: { model.setTerminalBundleID($0) }
        )
    }

    /// 所选终端未安装时给出回退提示。
    private var terminalAvailability: (text: String, isError: Bool)? {
        let bundleID = model.settings.terminalBundleID
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) == nil {
            let name = CommonTerminal.commonTerminal(matchingBundleID: bundleID)?.name ?? bundleID
            return ("未找到 \(name)（\(bundleID)），打开时将回退到 Terminal.app", true)
        }
        return nil
    }
}

private extension FewerFeature {
    var title: String {
        switch self {
        case .newFile: "新建文件"
        case .copyPath: "复制路径"
        case .cut: "剪切"
        case .paste: "粘贴"
        case .openInTerminal: "在终端打开"
        case .refresh: "刷新"
        }
    }
}
