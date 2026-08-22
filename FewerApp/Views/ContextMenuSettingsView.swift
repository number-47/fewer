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
        ScrollView {
            VStack(spacing: 16) {
                FewerSettingsCard {
                    FewerSettingsRow { Text("菜单项排序").fontWeight(.semibold); Spacer(); Text("拖拽排序").font(.caption).foregroundStyle(.secondary) }
                    Divider()
                    List {
                        ForEach(model.settings.menuOrder) { feature in
                            FewerSettingsRow {
                                Image(systemName: "circle.grid.2x3.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.tertiary)
                                    .accessibilityHidden(true)
                                Text(feature.title)
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { model.settings.enabledFeatures.contains(feature) },
                                    set: { model.setFeature(feature, enabled: $0) }
                                ))
                                .labelsHidden()
                            }
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.white)
                        }
                        .onMove { offsets, destination in
                            model.moveFeatures(from: offsets, to: destination)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .frame(height: CGFloat(model.settings.menuOrder.count) * 44)
                }
                FewerSettingsCard {
                    FewerSettingsRow {
                        VStack(alignment: .leading, spacing: 2) { Text("路径格式"); Text("复制路径时使用的格式").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Picker("", selection: Binding(get: { model.settings.pathFormat }, set: { model.setPathFormat($0) })) {
                            Text("POSIX").tag(PathOutputFormat.posix)
                            Text("Shell 引号").tag(PathOutputFormat.quoted)
                            Text("file:// URL").tag(PathOutputFormat.fileURL)
                        }.labelsHidden().frame(width: 130)
                    }
                    Divider()
                    FewerSettingsRow {
                        VStack(alignment: .leading, spacing: 2) { Text("冲突策略"); Text("与系统右键菜单项冲突时的处理方式").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Picker("", selection: Binding(get: { model.settings.conflictPolicy }, set: { model.setConflictPolicy($0) })) {
                            Text("保留两者").tag(ConflictPolicy.keepBoth); Text("跳过").tag(ConflictPolicy.skip); Text("替换").tag(ConflictPolicy.replace)
                        }.labelsHidden().frame(width: 130)
                    }
                    Divider()
                    FewerSettingsRow {
                        VStack(alignment: .leading, spacing: 2) { Text("终端应用"); Text("“在终端打开”使用的应用").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Picker("", selection: terminalSelection) {
                            ForEach(CommonTerminal.all) { Text($0.name).tag($0.bundleIdentifier) }
                            Text("自定义…").tag(Self.customTerminalTag)
                        }.labelsHidden().frame(width: 130)
                    }
                    if isCustomTerminal {
                        Divider()
                        FewerSettingsRow { TextField("Bundle Identifier", text: customTerminalInput).textFieldStyle(.roundedBorder) }
                    }
                }
            }.padding(.bottom, 24)
        }
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

    private func extensionBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { model.settings.openWithApplications[index].applicableExtensions.sorted().joined(separator: ", ") },
            set: { value in
                var applications = model.settings.openWithApplications
                applications[index].applicableExtensions = Set(value.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                }.filter { !$0.isEmpty })
                model.setOpenWithApplications(applications)
            }
        )
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundle = Bundle(url: url),
              let bundleIdentifier = bundle.bundleIdentifier
        else { return }
        var applications = model.settings.openWithApplications
        guard !applications.contains(where: { $0.bundleIdentifier == bundleIdentifier }) else { return }
        applications.append(OpenWithApplication(
            bundleIdentifier: bundleIdentifier,
            displayName: bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? url.deletingPathExtension().lastPathComponent
        ))
        model.setOpenWithApplications(applications)
    }
}

private extension FewerFeature {
    var title: String {
        switch self {
        case .newFile: "新建文件"
        case .newFolder: "新建文件夹"
        case .copyPath: "复制路径"
        case .copyAs: "复制为"
        case .cut: "剪切"
        case .paste: "粘贴"
        case .openInTerminal: "在终端打开"
        case .openWith: "用应用打开"
        case .refresh: "刷新"
        }
    }
}
