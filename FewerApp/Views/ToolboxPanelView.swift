import FewerCore
import SwiftUI

/// 主工具箱按独立监控模块组织，其余工具入口保持不变。
struct ToolboxPanelView: View {
    private let prototypeAccent = Color(red: 0, green: 113 / 255, blue: 227 / 255)
    private enum Tab: String, CaseIterable, Identifiable {
        case cpu, gpu, memory, disk, network, calendar, screenshot, input, finder, system

        var id: String { rawValue }

        var title: String {
            switch self {
            case .cpu: "CPU"
            case .gpu: "GPU"
            case .memory: "内存"
            case .disk: "磁盘"
            case .network: "网络"
            case .calendar: "日历"
            case .screenshot: "截图"
            case .input: "输入"
            case .finder: "Finder"
            case .system: "系统"
            }
        }

        var systemImage: String {
            switch self {
            case .cpu: "cpu"
            case .gpu, .memory: "memorychip"
            case .disk: "internaldrive"
            case .network: "network"
            case .calendar: "calendar"
            case .screenshot: "camera.viewfinder"
            case .input: "cursorarrow.motionlines"
            case .finder: "folder"
            case .system: "switch.2"
            }
        }
    }

    @State private var tab: Tab = .calendar
    @State private var screenshotSettings = ScreenshotSettings.default
    @ObservedObject private var input = InputEnhancementViewModel.shared
    @ObservedObject private var metrics = SystemMetricsService.shared
    @ObservedObject private var actions = SystemActionsService.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            tabStrip
            Divider()
            ViewThatFits(in: .vertical) {
                moduleContent.padding(.horizontal, 12).padding(.vertical, tab == .calendar ? 0 : 12).frame(maxHeight: .infinity)
                ScrollView { moduleContent.padding(.horizontal, 12).padding(.vertical, tab == .calendar ? 0 : 12) }
            }
            .frame(maxHeight: .infinity)
            footer
        }
        .frame(width: 400)
        .background(Color(red: 251 / 255, green: 251 / 255, blue: 253 / 255))
        .tint(prototypeAccent)
        .preferredColorScheme(.light)
        .onAppear {
            metrics.start()
            screenshotSettings = ScreenshotSettingsStore().load()
        }
        .alert("Fewer", isPresented: Binding(
            get: { actions.lastError != nil },
            set: { if !$0 { actions.lastError = nil } }
        )) { Button("好") { actions.lastError = nil } } message: { Text(actions.lastError ?? "") }
    }

    @ViewBuilder
    private var moduleContent: some View {
        switch tab {
        case .cpu: monitor(.cpu)
        case .gpu: monitor(.gpu)
        case .memory: monitor(.memory)
        case .disk: monitor(.disk)
        case .network: monitor(.network)
        case .calendar: calendar
        case .screenshot: screenshot
        case .input: inputEnhancement
        case .finder: finder
        case .system: system
        }
    }

    private func monitor(_ moduleID: SystemMonitorModuleID) -> some View {
        MonitorModulePopoverView(moduleID: moduleID, openSettings: {
            SettingsWindowController.shared.show()
        })
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.grid.2x2.fill")
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(prototypeAccent, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text("Fewer").font(.system(size: 14, weight: .semibold))
            Spacer()
            Button { SettingsWindowController.shared.show() } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless).frame(width: 28, height: 28).help("设置")
            Button {
                MenuBarController.shared.closePopover()
                NSApp.terminate(nil)
            } label: { Image(systemName: "power") }
                .buttonStyle(.borderless).frame(width: 28, height: 28).help("退出 Fewer（⌘Q）")
        }
        .padding(.top, 16)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var tabStrip: some View {
        HStack(spacing: 2) {
            ForEach(Tab.allCases) { item in
                Button { tab = item } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.systemImage).font(.system(size: 18, weight: .regular))
                        Text(item.title).font(.system(size: 10, weight: tab == item ? .semibold : .regular))
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .foregroundStyle(tab == item ? prototypeAccent : Color.secondary)
                    .background(tab == item ? prototypeAccent.opacity(0.10) : .clear,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(alignment: .bottom) {
                        if tab == item {
                            Capsule().fill(prototypeAccent).frame(width: 20, height: 2).padding(.bottom, 1)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

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

    private var calendar: some View {
        MenuBarCalendarView(availableWidth: 352)
    }

    private var screenshot: some View {
        VStack(spacing: 10) {
            LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 8) {
                captureButton("智能截图", "viewfinder", .smart, "⌘⇧A")
                captureButton("区域截图", "rectangle.dashed", .region, "⌘⌥A")
                captureButton("窗口截图", "macwindow", .window, "⌘⌥W")
                captureButton("全屏截图", "display", .fullscreen, "⌘⌥F")
            }
            card("最近截图", trailing: "暂无") {
                prototypeUnavailable("当前版本未保存最近截图列表")
            }
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
                    .buttonStyle(.plain).foregroundStyle(prototypeAccent)
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
                    .buttonStyle(.plain).foregroundStyle(prototypeAccent)
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
                    prototypeUnavailable("没有可推出的外置磁盘")
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

    private var footer: some View {
        HStack(spacing: 6) {
            Circle().fill(Color.green).frame(width: 6, height: 6)
            Text("Fewer 正在运行").font(.system(size: 10)).foregroundStyle(.secondary)
            Spacer()
            Button("打开设置") { SettingsWindowController.shared.show() }
                .buttonStyle(.plain).font(.system(size: 10, weight: .medium)).foregroundStyle(prototypeAccent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Divider() }
    }

    private func card<Content: View>(_ title: String, trailing: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.24)
                Spacer()
                if let trailing { Text(trailing).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary) }
            }
            content()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color(red: 232 / 255, green: 232 / 255, blue: 237 / 255)))
    }

    private func gauge(_ title: String, value: Double, detail: String) -> some View {
        VStack(spacing: 5) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.15), lineWidth: 6)
                Circle().trim(from: 0, to: max(0.01, value)).stroke(value > 0.85 ? Color.orange : prototypeAccent, style: .init(lineWidth: 6, lineCap: .round)).rotationEffect(.degrees(-90))
                Text(detail).font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit()
            }.frame(width: 62, height: 62)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }

    private func progressRow(_ title: String, value: Double) -> some View {
        HStack {
            Text(title).font(.caption)
            ProgressView(value: value).tint(value > 0.75 ? .orange : prototypeAccent)
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

    private func prototypeUnavailable(_ message: String) -> some View {
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
