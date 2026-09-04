import SwiftUI

/// 设置窗口与原型一致使用固定 200pt 侧栏；各 pane 继续复用现有的真实设置绑定。
struct RootSettingsView: View {
    @StateObject private var model = SettingsViewModel()
    @State private var selection: SettingsSection = .overview

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
        }
        .disabled(model.isLoading)
        .frame(minWidth: 880, minHeight: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(Color(red: 0, green: 113 / 255, blue: 227 / 255))
        .task { await model.load() }
        .onReceive(NotificationCenter.default.publisher(for: SettingsWindowController.navigateNotification)) { notification in
            if let raw = notification.userInfo?["section"] as? String,
               let section = SettingsSection(rawValue: raw) {
                selection = section
            }
        }
        .onDisappear { InputEnhancementViewModel.shared.flushPendingSave() }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach([
                    SettingsSection.overview, .permissions, .contextMenu, .templates, .shortcuts,
                    .screenshot, .aiTranslate, .inputEnhancement, .modules, .general
                ]) { sidebarItem($0) }
                divider
                sidebarItem(.about)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 12)
        }
        .frame(width: 200)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func sidebarItem(_ section: SettingsSection) -> some View {
        Button { selection = section } label: {
           Label(section.title, systemImage: section.systemImage)
               .font(.system(size: 14))
               .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
               .contentShape(Rectangle())
               .padding(.horizontal, 12)
                .foregroundStyle(selection == section ? .white : .primary)
                .background(selection == section ? Color(red: 0, green: 113 / 255, blue: 227 / 255) : .clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var divider: some View {
        Divider().padding(.horizontal, 12).padding(.vertical, 6)
    }

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 24) {
            if selection != .about {
                VStack(alignment: .leading, spacing: 4) {
                    Text(selection.title).font(.system(size: 21, weight: .semibold))
                    Text(selection.subtitle).font(.system(size: 14)).foregroundStyle(.secondary)
                }
            }
            Group {
                switch selection {
                case .overview:
                    OverviewView(model: model, onOpenPermissions: { selection = .permissions })
                case .permissions:
                    PermissionsSettingsView()
                case .contextMenu:
                    ContextMenuSettingsView(model: model)
                case .templates:
                    TemplateSettingsView(model: model)
                case .shortcuts:
                    ShortcutSettingsView(model: model)
                case .screenshot:
                    ScreenshotSettingsView()
                case .aiTranslate:
                    AITranslationSettingsView()
                case .inputEnhancement:
                    InputEnhancementSettingsView(onOpenPermissions: { selection = .permissions })
                case .modules:
                    ModuleSettingsView()
                case .general:
                    GeneralSettingsView(model: model)
                case .about:
                    AboutSettingsView()
                }
            }
            .environment(\.defaultMinListRowHeight, 44)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
        .padding(.vertical, 24)
        .alert("Fewer", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("好") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

private extension SettingsSection {
    var subtitle: String {
        switch self {
        case .overview: "查看组件状态与权限，快速定位需要配置的项目。"
        case .permissions: "集中管理辅助功能、输入监控、屏幕录制与 Finder 扩展授权。"
        case .contextMenu: "配置 Finder 右键菜单项的排序、开关与路径格式。"
        case .templates: "管理“新建文件”可用的模板，支持导入自定义模板。"
        case .shortcuts: "配置全局快捷键与剪切粘贴辅助功能。"
        case .screenshot: "配置截图快捷键、滚动截图与贴图行为。"
        case .aiTranslate: "配置 OpenAI-compatible 翻译服务，支持多个配置与当前使用项切换。"
        case .inputEnhancement: "配置鼠标滚动增强、手势、按键展示与诊断。"
        case .modules: "启用或关闭模块，配置面板显示与菜单栏独立图标。"
        case .general: "配置应用显示模式、通知与启动行为。"
        case .about: "Fewer 版本与应用信息。"
        }
    }
}

struct FewerSettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color(nsColor: .separatorColor)))
    }
}

struct FewerSettingsRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 16) {
            content
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 44)
    }
}
