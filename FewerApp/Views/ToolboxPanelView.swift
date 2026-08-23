import FewerCore
import SwiftUI

/// 工具箱使用瞬态路由；每次新建视图都从日历开始，不写入用户偏好。
struct ToolboxPanelView: View {
    private enum ToolboxDestination: String, CaseIterable, Identifiable {
        case calendar, screenshot, input, cpu, gpu, memory, disk, network, finder, system

        var id: String { rawValue }
        var monitorID: SystemMonitorModuleID? { SystemMonitorModuleID(rawValue: rawValue) }
    }

    @State private var destination: ToolboxDestination = .calendar
    @State private var screenshotSettings = ScreenshotSettings.default
    @ObservedObject private var host = ModuleHost.shared
    @ObservedObject private var input = InputEnhancementViewModel.shared
    @ObservedObject private var metrics = SystemMetricsService.shared
    @ObservedObject private var actions = SystemActionsService.shared

    var body: some View {
        MenuBarPopoverChrome(
            title: destinationTitle,
            systemImage: destinationImage,
            openSettings: { SettingsWindowController.shared.show() },
            quitAction: {
                MenuBarController.shared.closePopover()
                NSApp.terminate(nil)
            }
        ) {
            VStack(spacing: 0) {
                tabBar
                Divider()
                ViewThatFits(in: .vertical) {
                    moduleContent
                        .padding(.horizontal, 12)
                        .padding(.vertical, destination == .calendar ? 0 : 12)
                        .frame(maxHeight: .infinity)

                    ScrollView {
                        moduleContent
                            .padding(.horizontal, 12)
                            .padding(.vertical, destination == .calendar ? 0 : 12)
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(width: 400)
        .onAppear { screenshotSettings = ScreenshotSettingsStore().load() }
        .alert("Fewer", isPresented: Binding(
            get: { actions.lastError != nil },
            set: { if !$0 { actions.lastError = nil } }
        )) { Button("好") { actions.lastError = nil } } message: { Text(actions.lastError ?? "") }
    }

    private var destinationTitle: String {
        descriptor(for: destination)?.title ?? "Fewer"
    }

    private var destinationImage: String {
        descriptor(for: destination)?.systemImage ?? "square.grid.2x2"
    }

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(ToolboxDestination.allCases) { item in
                tabButton(for: item)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func tabButton(for item: ToolboxDestination) -> some View {
        let isSelected = destination == item
        let desc = descriptor(for: item)
        return Button {
            destination = item
        } label: {
            Image(systemName: desc?.systemImage ?? "square.grid.2x2")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .frame(width: 34, height: 28)
                .background(
                    isSelected ? Color.accentColor.opacity(0.12) : .clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .help(desc?.title ?? item.rawValue)
        .accessibilityIdentifier("toolbox.tab.\(item.rawValue)")
        .accessibilityLabel(desc?.title ?? item.rawValue)
    }

    @ViewBuilder
    private var moduleContent: some View {
        switch destination {
        case .cpu, .gpu, .memory, .disk, .network:
            if let monitorID = destination.monitorID {
                MonitorModuleContent(moduleID: monitorID)
                    .id(monitorID)
            }
        case .calendar:
            MenuBarCalendarView(presentation: .embedded, availableWidth: 352)
        case .screenshot:
            screenshot
        case .input:
            inputEnhancement
        case .finder:
            finder
        case .system:
            system
        }
    }

    private func descriptor(for destination: ToolboxDestination) -> ModuleDescriptor? {
        host.descriptor(for: destination.rawValue)
    }

    // 旧仪表盘辅助视图在本次改造前已经未参与路由，保留以避免扩大清理范围。
    private var dashboard: some View {
        VStack(spacing: 10) {
            card("系统状态", trailing: "实时") {
                HStack(spacing: 20) {
                    gauge("CPU", value: metrics.current.cpuUsage, detail: percent(metrics.current.cpuUsage))
                    gauge("内存", value: metrics.current.memoryUsage, detail: percent(metrics.current.memoryUsage))
                }
                progressRow("磁盘 SSD", value: metrics.current.diskUsage)
            }
            card("网络") {
                HStack(spacing: 22) {
                    networkRate("arrow.down", "下载", metrics.current.networkInBytesPerSecond, .green)
                    networkRate("arrow.up", "上传", metrics.current.networkOutBytesPerSecond, .primary)
                }
            }
            card("网络地址") {
                HStack { Text("本地 IP"); Spacer(); Text(metrics.localIPAddress).monospacedDigit().foregroundStyle(.secondary) }
                HStack {
                    Text("公网 IP"); Spacer()
                    Text(metrics.publicIPAddress ?? "未查询").monospacedDigit().foregroundStyle(.secondary)
                    Button { Task { await metrics.refreshPublicIP() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("刷新公网 IP")
                }
            }
            card("快捷操作") { quickActions }
        }
    }

    private var screenshot: some View {
        VStack(spacing: 10) {
            LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 8) {
                captureButton("智能截图", "viewfinder", .smart, "⌘⇧A")
                captureButton("区域截图", "rectangle.dashed", .region, "⌘⌥A")
                captureButton("窗口截图", "macwindow", .window, "⌘⌥W")
                captureButton("全屏截图", "display", .fullscreen, "⌘⌥F")
            }
            card("最近截图", trailing: "暂无") { unavailable("当前版本未保存最近截图列表") }
            card("截图设置") {
                Toggle("滚动截图", isOn: Binding(
                    get: { screenshotSettings.rollingCaptureEnabled },
                    set: { screenshotSettings.rollingCaptureEnabled = $0; saveScreenshotSettings() }
                ))
                HStack { Text("贴图透明度"); Spacer(); Text("\(Int((screenshotSettings.pinDefaultOpacity * 100).rounded()))%").foregroundStyle(.secondary) }
                HStack { Text("保存位置"); Spacer(); Text(screenshotSettings.saveLocation.title).foregroundStyle(.secondary) }
            }
        }
    }

    private var inputEnhancement: some View {
        VStack(spacing: 10) {
            card("输入增强") {
                Toggle("平滑滚动", isOn: inputBinding(\.scroll.isEnabled))
                Toggle("鼠标手势", isOn: gestureBinding)
                Toggle("按键展示", isOn: inputBinding(\.keycast.isEnabled))
            }
            card("应用规则") {
                HStack { Text("当前应用"); Spacer(); Text(NSWorkspace.shared.frontmostApplication?.localizedName ?? "未检测到").foregroundStyle(.secondary) }
                Button("管理应用规则") { SettingsWindowController.shared.show() }
                    .buttonStyle(.plain).foregroundStyle(Color.accentColor)
            }
            card("诊断") {
                statusRow("辅助功能权限", input.helperStatus.isAccessibilityTrusted ? "已授权" : "未授权", input.helperStatus.isAccessibilityTrusted)
                statusRow("输入监听", input.helperStatus.isEventTapActive ? "正常" : "需要检查", input.helperStatus.isEventTapActive)
                statusRow("鼠标设备", deviceTitle, input.helperStatus.detectedScrollDevice != nil)
            }
        }
    }

    private var finder: some View {
        VStack(spacing: 10) {
            card("文件操作") {
                Label("新建文件、复制路径、剪切粘贴与用应用打开", systemImage: "folder")
                Text("这些操作需要 Finder 提供目标路径，因此在 Finder 右键菜单中执行。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("打开 Finder") { ModuleHost.shared.execute(moduleID: "finder", commandID: "open-finder") }
                    .buttonStyle(.bordered)
            }
            card("右键菜单") {
                Button("打开 Finder 设置") { SettingsWindowController.shared.show() }
                    .buttonStyle(.plain).foregroundStyle(Color.accentColor)
            }
        }
    }

    private var system: some View {
        VStack(spacing: 10) {
            card("系统快捷操作") {
                Toggle("防休眠", isOn: Binding(get: { actions.preventsSleep }, set: { actions.setPreventsSleep($0) }))
                quickActions
            }
            card("外置设备") {
                if actions.removableVolumes.isEmpty {
                    unavailable("没有可推出的外置磁盘")
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

    private func card<Content: View>(_ title: String, trailing: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).tracking(0.24)
                Spacer()
                if let trailing { Text(trailing).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary) }
            }
            content()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }

    private func gauge(_ title: String, value: Double, detail: String) -> some View {
        VStack(spacing: 5) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.15), lineWidth: 6)
                Circle().trim(from: 0, to: max(0.01, value)).stroke(value > 0.85 ? Color.orange : Color.accentColor, style: .init(lineWidth: 6, lineCap: .round)).rotationEffect(.degrees(-90))
                Text(detail).font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit()
            }.frame(width: 62, height: 62)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }

    private func progressRow(_ title: String, value: Double) -> some View {
        HStack {
            Text(title).font(.caption)
            ProgressView(value: value).tint(value > 0.75 ? .orange : Color.accentColor)
            Text(percent(value)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
        }
    }

    private func networkRate(_ image: String, _ title: String, _ value: Double, _ color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: image).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(bytes(value) + "/s").font(.system(size: 13, weight: .semibold, design: .monospaced))
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusRow(_ title: String, _ value: String, _ okay: Bool) -> some View {
        HStack { Circle().fill(okay ? .green : .orange).frame(width: 7, height: 7); Text(title); Spacer(); Text(value).font(.caption).foregroundStyle(.secondary) }
    }

    private func unavailable(_ message: String) -> some View {
        Text(message).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func captureButton(_ title: String, _ image: String, _ mode: ScreenshotMode, _ shortcut: String) -> some View {
        Button {
            MenuBarController.shared.closePopover()
            ScreenshotService.shared.begin(mode)
        } label: {
            VStack(spacing: 5) {
                Image(systemName: image).font(.title3)
                Text(title).font(.caption.weight(.medium))
                Text(shortcut).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, minHeight: 72)
        }.buttonStyle(.bordered)
    }

    private func actionButton(_ title: String, _ image: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { actionLabel(title, image) }.buttonStyle(.bordered)
    }

    private func actionLabel(_ title: String, _ image: String) -> some View {
        VStack(spacing: 4) { Image(systemName: image); Text(title).font(.caption2) }
            .frame(maxWidth: .infinity, minHeight: 40)
    }

    private func inputBinding(_ keyPath: WritableKeyPath<InputEnhancementSettings, Bool>) -> Binding<Bool> {
        Binding(get: { input.settings[keyPath: keyPath] }, set: { value in
            input.settings[keyPath: keyPath] = value
            if value { input.settings.emergencyDisabled = false }
            input.save()
        })
    }

    private var gestureBinding: Binding<Bool> {
        Binding(get: { input.settings.gestureRules.contains(where: \.isEnabled) }, set: { enabled in
            if input.settings.gestureRules.isEmpty, enabled { input.settings.gestureRules = MouseGesturePresets.defaultRules }
            else { for index in input.settings.gestureRules.indices { input.settings.gestureRules[index].isEnabled = enabled } }
            input.save()
        })
    }

    private var deviceTitle: String {
        switch input.helperStatus.detectedScrollDevice {
        case .mouse: "鼠标滚轮"
        case .trackpad: "触控板（绕过）"
        case nil: "等待识别"
        }
    }

    private func saveScreenshotSettings() { ScreenshotSettingsStore().save(screenshotSettings) }
    private func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
    private func bytes(_ value: Double) -> String { ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file) }
}
