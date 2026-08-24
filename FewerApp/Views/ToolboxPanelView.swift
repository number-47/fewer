import FewerCore
import SwiftUI

/// 工具箱布局常量集中管理。
enum ToolboxLayout {
    static let width: CGFloat = 400
    static let horizontalPadding: CGFloat = 14
    static let sectionSpacing: CGFloat = 12
    static let cornerRadius: CGFloat = 10
    static let sectionTitleSize: CGFloat = 12
    static let iconSize: CGFloat = 14
}

/// 工具箱一级导航入口。
private enum ToolboxPrimaryDestination: String, CaseIterable, Identifiable {
    case calendar, monitor, system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .calendar: "日历"
        case .monitor: "监控"
        case .system: "系统"
        }
    }

    var systemImage: String {
        switch self {
        case .calendar: "calendar"
        case .monitor: "chart.line.uptrend.xyaxis"
        case .system: "gearshape.2"
        }
    }
}

/// 工具箱面板：日历、监控和系统三个一级入口。
struct ToolboxPanelView: View {
    @State private var primary: ToolboxPrimaryDestination = .calendar
    @State private var monitorModule: SystemMonitorModuleID = .cpu
    @ObservedObject private var actions = SystemActionsService.shared

    var body: some View {
        MenuBarPopoverChrome(
            title: headerTitle,
            subtitle: headerSubtitle,
            openSettings: { SettingsWindowController.shared.show() },
            quitAction: {
                MenuBarController.shared.closePopover()
                NSApp.terminate(nil)
            }
        ) {
            VStack(spacing: 0) {
                primaryTabBar
                Divider()
                if primary == .monitor {
                    monitorSubTabBar
                    Divider()
                }
                contentArea
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(width: ToolboxLayout.width)
        .alert("Fewer", isPresented: Binding(
            get: { actions.lastError != nil },
            set: { if !$0 { actions.lastError = nil } }
        )) { Button("好") { actions.lastError = nil } } message: { Text(actions.lastError ?? "") }
    }

    // MARK: - Header

    private var headerTitle: String {
        switch primary {
        case .monitor: monitorModule.title
        default: primary.title
        }
    }

    private var headerSubtitle: String {
        switch primary {
        case .monitor: "系统监控"
        default: "工具箱"
        }
    }

    // MARK: - Primary tab bar

    private var primaryTabBar: some View {
        HStack(spacing: 2) {
            ForEach(ToolboxPrimaryDestination.allCases) { item in
                primaryTabButton(for: item)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }

    private func primaryTabButton(for item: ToolboxPrimaryDestination) -> some View {
        let isSelected = primary == item
        return Button {
            primary = item
        } label: {
            VStack(spacing: 1) {
                Image(systemName: item.systemImage)
                    .font(.system(size: ToolboxLayout.iconSize, weight: isSelected ? .semibold : .medium))
                Text(item.title)
                    .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
            }
           .foregroundStyle(isSelected ? Color.accentColor : .secondary)
           .frame(maxWidth: .infinity, minHeight: 30)
           .contentShape(Rectangle())
           .background(
               isSelected ? Color.accentColor.opacity(0.12) : .clear,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.4), lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .help(item.title)
        .accessibilityIdentifier("toolbox.tab.\(item.rawValue)")
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    // MARK: - Monitor sub-tab bar

    private var monitorSubTabBar: some View {
        HStack(spacing: 0) {
            ForEach(SystemMonitorModuleID.allCases, id: \.self) { moduleID in
                monitorTabButton(for: moduleID)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
    }

    private func monitorTabButton(for moduleID: SystemMonitorModuleID) -> some View {
        let isSelected = monitorModule == moduleID
        return Button {
            monitorModule = moduleID
        } label: {
            Text(moduleID.title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
               .frame(maxWidth: .infinity, minHeight: 24)
               .contentShape(Rectangle())
               .overlay(alignment: .bottom) {
                    if isSelected {
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(height: 2)
                            .padding(.horizontal, 8)
                    }
                }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .accessibilityIdentifier("toolbox.monitor.\(moduleID.rawValue)")
        .accessibilityLabel(moduleID.title)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    // MARK: - Content area

    @ViewBuilder
    private var contentArea: some View {
        switch primary {
        case .calendar:
            MenuBarCalendarView(presentation: .embedded, availableWidth: ToolboxLayout.width)
        case .monitor:
            ScrollView {
                MonitorModuleContent(moduleID: monitorModule)
                    .id(monitorModule)
            }
        case .system:
            ScrollView {
                systemContent
                    .padding(.horizontal, ToolboxLayout.horizontalPadding)
                    .padding(.vertical, ToolboxLayout.sectionSpacing)
            }
        }
    }

    // MARK: - System

    private var systemContent: some View {
        VStack(spacing: ToolboxLayout.sectionSpacing) {
            ToolboxSection(title: "系统快捷操作") {
                Toggle("防休眠", isOn: Binding(get: { actions.preventsSleep }, set: { actions.setPreventsSleep($0) }))
                quickActions
            }
            ToolboxSection(title: "外置设备") {
                if actions.removableVolumes.isEmpty {
                    Text("没有可推出的外置磁盘").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(actions.removableVolumes, id: \.self) { volume in
                        Button(volume.lastPathComponent) { actions.eject(volume) }
                    }
                }
            }
        }
        .onAppear { actions.refreshRemovableVolumes() }
    }

    private var quickActions: some View {
        LazyVGrid(columns: Array(repeating: .init(.flexible()), count: 3), spacing: 8) {
            actionButton(actions.isMuted ? "已静音" : "静音", "speaker.slash") { actions.toggleMute() }
            actionButton("深色模式", "circle.lefthalf.filled") { actions.toggleDarkMode() }
            actionButton("显示器休眠", "display") { actions.sleepDisplays() }
            actionButton("清空剪贴板", "clipboard") { actions.clearPasteboard() }
            Menu {
                if actions.removableVolumes.isEmpty { Text("没有可推出的外置磁盘") }
                ForEach(actions.removableVolumes, id: \.self) { volume in Button(volume.lastPathComponent) { actions.eject(volume) } }
            } label: { actionLabel("推出磁盘", "eject") }
            .menuStyle(.borderlessButton)
            actionButton("设置", "gearshape") { SettingsWindowController.shared.show() }
        }
    }

    // MARK: - Shared component helpers

    private func actionButton(_ title: String, _ image: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { actionLabel(title, image) }.buttonStyle(.bordered)
    }

    private func actionLabel(_ title: String, _ image: String) -> some View {
        VStack(spacing: 4) { Image(systemName: image); Text(title).font(.caption2) }
            .frame(maxWidth: .infinity, minHeight: 40)
    }
}

// MARK: - Shared toolbox components

private struct ToolboxSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: ToolboxLayout.sectionTitleSize, weight: .semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: ToolboxLayout.cornerRadius, style: .continuous))
    }
}

// MARK: - Extension for monitor module titles

extension SystemMonitorModuleID {
    var title: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: "内存"
        case .disk: "磁盘"
        case .network: "网络"
        }
    }

    var systemImage: String {
        switch self {
        case .cpu: "cpu"
        case .gpu, .memory: "memorychip"
        case .disk: "internaldrive"
        case .network: "network"
        }
    }
}
