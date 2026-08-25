import AppKit
import FewerCore
import SwiftUI

@main
@MainActor
enum FewerApp {
    private static let appDelegate = AppDelegate()

    static func main() {
        let application = NSApplication.shared
        if AppLaunchMode.isUITesting {
            application.setActivationPolicy(.regular)
        }
        application.delegate = appDelegate
        application.run()
    }
}

private enum AppLaunchMode {
    static let isUITesting = ProcessInfo.processInfo.arguments.contains("--ui-testing")
}

@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    static let shared = MenuBarController()
    private static let calendarPopoverAnchorOffset: CGFloat = 8

    private var mainStatusItem: NSStatusItem?
    private var statusBarItems: [String: NSStatusItem] = [:]
    private var installedStatusBarOrder: [String] = []
    private var popover: NSPopover?
    private var popoverModuleID: String?
    private var globalClickMonitor: Any?
    private var preferencesObserver: Bool?
    private var metricsTimer: Timer?
    private var metricsTimerInterval: TimeInterval?

    private override init() {
        super.init()
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    func setVisible(_ isVisible: Bool) {
        if isVisible {
            installStatusItems()
        } else {
            removeStatusItems()
        }
    }

    // MARK: - Installation

    private func installStatusItems() {
        // Main toolbox icon
        if mainStatusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            configureStatusItem(item, symbol: "square.grid.2x2", tooltip: "Fewer 工具箱", action: #selector(toggleToolboxPopover(_:)))
            item.button?.identifier = NSUserInterfaceItemIdentifier("toolbox")
            mainStatusItem = item
        }
        installModuleStatusItems()
        observePreferencesChange()
        refreshMetricsSampling()
    }

    private func installModuleStatusItems() {
        let host = ModuleHost.shared
        let availableIDs = Set(host.modules.map(\.descriptor.id))
        let desiredIDs = host.preferences.statusBarModuleOrder.filter {
            availableIDs.contains($0)
                && host.preferences.enabledModuleIDs.contains($0)
                && host.preferences.statusBarModuleIDs.contains($0)
        }
        if installedStatusBarOrder != desiredIDs {
            closePopover()
            for (_, item) in statusBarItems {
                NSStatusBar.system.removeStatusItem(item)
            }
            statusBarItems.removeAll()
            installedStatusBarOrder = []
        }
        for id in desiredIDs {
            let isEnabled = host.preferences.enabledModuleIDs.contains(id)
            let hasStatusBarIcon = host.preferences.statusBarModuleIDs.contains(id)
            let shouldShow = isEnabled && hasStatusBarIcon
            let exists = statusBarItems[id] != nil

            if shouldShow && !exists {
                let monitorID = SystemMonitorModuleID(rawValue: id)
                let length = monitorID == nil ? NSStatusItem.squareLength : NSStatusItem.variableLength
                let item = NSStatusBar.system.statusItem(withLength: length)
                if let monitorID {
                    configureMonitorStatusItem(item, moduleID: monitorID)
                } else {
                    configureStatusItem(item, symbol: "calendar", tooltip: "日历", action: #selector(showModuleMenu(_:)))
                }
                item.button?.identifier = NSUserInterfaceItemIdentifier(id)
                statusBarItems[id] = item
            } else if !shouldShow && exists {
                if let item = statusBarItems.removeValue(forKey: id) {
                    NSStatusBar.system.removeStatusItem(item)
                }
            }
        }
        installedStatusBarOrder = desiredIDs
    }

    private func configureStatusItem(_ item: NSStatusItem, symbol: String, tooltip: String, action: Selector) {
        guard let button = item.button else {
            NSStatusBar.system.removeStatusItem(item)
            return
        }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.imagePosition = .imageOnly
        button.title = ""
        button.toolTip = tooltip
        button.target = self
        button.action = action
        button.sendAction(on: [.leftMouseUp])
    }

    private func configureMonitorStatusItem(_ item: NSStatusItem, moduleID: SystemMonitorModuleID) {
        let view = MonitorStatusItemView()
        view.toolTip = monitorTitle(for: moduleID)
        view.onClick = { [weak self] in
            self?.showMonitorPopover(moduleID: moduleID, anchor: view)
        }
        item.view = view
        updateMonitorStatusItem(moduleID)
    }

    private func startMetricsTimer(interval: TimeInterval?) {
        guard let interval else {
            stopMetricsTimer()
            return
        }
        guard metricsTimer == nil || metricsTimerInterval != interval else { return }
        stopMetricsTimer()
        metricsTimerInterval = interval
        metricsTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMonitorStatusItems() }
        }
    }

    private func stopMetricsTimer() {
        metricsTimer?.invalidate()
        metricsTimer = nil
        metricsTimerInterval = nil
    }

    private func updateMonitorStatusItems() {
        for moduleID in SystemMonitorModuleID.allCases {
            updateMonitorStatusItem(moduleID)
        }
    }

    private func updateMonitorStatusItem(_ moduleID: SystemMonitorModuleID) {
        guard let view = statusBarItems[moduleID.rawValue]?.view as? MonitorStatusItemView else { return }
        let preferences = ModuleHost.shared.preferences.monitorPreferences(for: moduleID)
        view.content = monitorContent(for: moduleID, widgets: preferences.widgets, color: color(for: preferences.color))
    }

    private func refreshMetricsSampling() {
        let host = ModuleHost.shared
        let enabledModules = host.preferences.enabledModuleIDs
        let statusBarModules = Set(statusBarItems.keys.compactMap { SystemMonitorModuleID(rawValue: $0) })
        let popoverModule = popoverModuleID.flatMap { SystemMonitorModuleID(rawValue: $0) }
        var activeModules = statusBarModules
        if let popoverModule {
            activeModules.insert(popoverModule)
        }
        activeModules = Set(activeModules.filter { enabledModules.contains($0.rawValue) })

        let preferences = Dictionary(uniqueKeysWithValues: SystemMonitorModuleID.allCases.map {
            ($0, host.preferences.monitorPreferences(for: $0))
        })
        let configuration = MonitorSamplingConfiguration(
            activeModules: activeModules,
            preferences: preferences
        )
        SystemMetricsService.shared.configureSampling(configuration)
        startMetricsTimer(interval: statusBarModules.isEmpty ? nil : configuration.refreshInterval)
        updateMonitorStatusItems()
    }

    private func monitorContent(
        for moduleID: SystemMonitorModuleID,
        widgets: [MonitorWidgetKind],
        color: NSColor
    ) -> MonitorStatusItemContent {
        let metrics = SystemMetricsService.shared.current
        let history = SystemMetricsService.shared.history
        let percentage: Double? = switch moduleID {
        case .cpu: metrics.cpu?.total
        case .gpu: metrics.gpu?.selectedDevice?.utilization
        case .memory: metrics.memory?.usageRatio
        case .disk: metrics.disk?.usageRatio
        case .network: nil
        }
        var texts: [String] = []
        var chartKind: MonitorWidgetKind?
        for widget in widgets {
            switch widget {
            case .label:
                if moduleID == .gpu,
                   ModuleHost.shared.preferences.monitorPreferences(for: .gpu).showsItemType,
                   let type = metrics.gpu?.selectedDevice?.type {
                    texts.append(type.menuBarPrefix)
                } else {
                    texts.append(monitorTitle(for: moduleID))
                }
            case .miniPercentage:
                texts.append(percentage.map(formatPercentage) ?? "—")
            case .lineChart, .barChart, .pieChart, .gauge, .throughputChart:
                chartKind = widget
            case .uploadSpeed:
                texts.append("↑ \(formatRate(metrics.networkOutBytesPerSecond))")
            case .downloadSpeed:
                texts.append("↓ \(formatRate(metrics.networkInBytesPerSecond))")
            case .connectionStatus:
                texts.append(SystemMetricsService.shared.localIPAddress == "未连接" ? "未连接" : "已连接")
            case .ipAddress:
                texts.append(SystemMetricsService.shared.localIPAddress)
            case .capacity where moduleID == .memory:
                texts.append(formatMemory(metrics.memory?.usedBytes))
            case .capacity where moduleID == .disk:
                texts.append(formatDiskCapacity(metrics.disk))
            case .status where moduleID == .memory:
                texts.append(metrics.memory?.pressure?.level.rawValue ?? "不可用")
            case .readWriteSpeed where moduleID == .disk:
                texts.append(formatDiskRates(metrics.disk))
            case .text where moduleID == .disk:
                texts.append(metrics.disk?.volumeName ?? "不可用")
            case .capacity, .status, .readWriteSpeed, .text:
                texts.append("—")
            }
        }
        let vertical: Bool = switch moduleID {
        case .cpu, .gpu, .memory, .disk: texts.count >= 2
        case .network: texts.count >= 2
        }
        return MonitorStatusItemContent(
            texts: texts.isEmpty ? ["—"] : texts,
            chartValue: chartKind == nil ? nil : chartValue(for: moduleID, kind: chartKind, metrics: metrics, percentage: percentage),
            chartHistory: monitorHistory(for: moduleID, kind: chartKind, metrics: metrics, history: history),
            chartKind: chartKind,
            color: color,
            vertical: vertical
        )
    }

    private func monitorHistory(
        for moduleID: SystemMonitorModuleID,
        kind: MonitorWidgetKind?,
        metrics: SystemMetricsSnapshot,
        history: [SystemMetricsSnapshot]
    ) -> [Double] {
        switch moduleID {
        case .cpu:
            return history.compactMap { $0.cpu?.total }
        case .gpu:
            guard let deviceID = metrics.gpu?.selectedDevice?.id else { return [] }
            return history.compactMap { $0.gpu?.device(id: deviceID)?.utilization }
        case .memory:
            return history.compactMap { $0.memory?.usageRatio }
        case .disk:
            if kind == .throughputChart {
                return history.compactMap { diskThroughputLevel($0.disk) }
            }
            return history.compactMap { $0.disk?.usageRatio }
        case .network:
            return []
        }
    }

    private func chartValue(
        for moduleID: SystemMonitorModuleID,
        kind: MonitorWidgetKind?,
        metrics: SystemMetricsSnapshot,
        percentage: Double?
    ) -> Double? {
        guard moduleID == .disk, kind == .throughputChart else { return percentage }
        return diskThroughputLevel(metrics.disk)
    }

    private func diskThroughputLevel(_ disk: DiskSnapshot?) -> Double? {
        guard let disk else { return nil }
        let rate = max(disk.readBytesPerSecond ?? 0, disk.writeBytesPerSecond ?? 0)
        guard rate > 0 else { return disk.readBytesPerSecond == nil && disk.writeBytesPerSecond == nil ? nil : 0 }
        return min(rate / (100 * 1_024 * 1_024), 1)
    }

    private func monitorTitle(for moduleID: SystemMonitorModuleID) -> String {
        switch moduleID {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: "内存"
        case .disk: "磁盘"
        case .network: "网络"
        }
    }

    private func formatPercentage(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private func formatRate(_ value: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file) + "/s"
    }

    private func formatMemory(_ value: UInt64?) -> String {
        guard let value else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }

    private func formatDiskCapacity(_ disk: DiskSnapshot?) -> String {
        guard let disk else { return "不可用" }
        return "\(formatMemory(disk.usedBytes)) / \(formatMemory(disk.totalBytes))"
    }

    private func formatDiskRates(_ disk: DiskSnapshot?) -> String {
        guard let disk else { return "不可用" }
        guard let read = disk.readBytesPerSecond, let write = disk.writeBytesPerSecond else { return "不可用" }
        return "R \(formatRate(read)) W \(formatRate(write))"
    }

    private func color(for color: MonitorWidgetColor) -> NSColor {
        switch color {
        case .system: .controlAccentColor
        case .blue: .systemBlue
        case .green: .systemGreen
        case .orange: .systemOrange
        case .red: .systemRed
        case .purple: .systemPurple
        }
    }

    private func removeStatusItems() {
        stopMetricsTimer()
        closePopover()
        for (_, item) in statusBarItems {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusBarItems.removeAll()
        installedStatusBarOrder.removeAll()
        if let mainStatusItem {
            NSStatusBar.system.removeStatusItem(mainStatusItem)
            self.mainStatusItem = nil
        }
        removePreferencesObserver()
        SystemMetricsService.shared.stop()
    }

    // MARK: - Preferences change

    private func observePreferencesChange() {
        guard preferencesObserver == nil else { return }
        preferencesObserver = true
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(modulePreferencesDidChange),
            name: AppGroupConstants.modulePreferencesDidChangeNotification,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    private func removePreferencesObserver() {
        guard preferencesObserver != nil else { return }
        preferencesObserver = nil
        DistributedNotificationCenter.default().removeObserver(
            self,
            name: AppGroupConstants.modulePreferencesDidChangeNotification,
            object: nil
        )
    }

    @objc private func modulePreferencesDidChange() {
        installModuleStatusItems()
        refreshMetricsSampling()
    }

    // MARK: - Main toolbox popover

    @objc private func toggleToolboxPopover(_ sender: NSStatusBarButton) {
        // If toolbox popover is already shown, toggle it closed
        if popover?.isShown == true, popoverModuleID == nil {
            popover?.close()
            return
        }
        // Close any existing popover (module or stale) before showing toolbox
        closePopover()
        let popover = toolboxPopover(for: sender.window?.screen)
        popover.show(
            relativeTo: sender.bounds.offsetBy(dx: 0, dy: Self.calendarPopoverAnchorOffset),
            of: sender,
            preferredEdge: .minY
        )
    }

    private func toolboxPopover(for screen: NSScreen?) -> NSPopover {
        let availableHeight = (screen ?? NSScreen.main)?.visibleFrame.height ?? 720
        let height = min(780, max(520, availableHeight - 64))

        let hostingController = NSHostingController(
            rootView: AnyView(
                ToolboxPanelView()
                    .frame(width: ToolboxLayout.width, height: height)
            )
        )

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentSize = NSSize(width: ToolboxLayout.width, height: height)
        popover.contentViewController = hostingController
        self.popover = popover
        self.popoverModuleID = nil
        return popover
    }

    // MARK: - Module popovers

    @objc private func showModuleMenu(_ sender: Any?) {
        guard let button = sender as? NSStatusBarButton,
              button.identifier?.rawValue == "calendar"
        else { return }
        showPopover(
            moduleID: "calendar",
            anchor: button,
            size: MenuBarCalendarView.preferredSize,
            content: AnyView(
                MenuBarPopoverChrome(
                    title: "日历",
                    systemImage: "calendar",
                    openSettings: { [weak self] in
                        self?.closePopover()
                        SettingsWindowController.shared.show()
                    },
                    quitAction: { [weak self] in
                        self?.closePopover()
                        NSApp.terminate(nil)
                    }
                ) {
                    MenuBarCalendarView(presentation: .standalone)
                }
            )
        )
    }

    private func showMonitorPopover(moduleID: SystemMonitorModuleID, anchor: NSView) {
        let size: NSSize = switch moduleID {
        case .cpu: NSSize(width: 360, height: 470)
        case .memory: NSSize(width: 360, height: 500)
        case .gpu: NSSize(width: 360, height: 420)
        case .network: NSSize(width: 360, height: 360)
        case .disk: NSSize(width: 360, height: 500)
        }
        let openActivityMonitor: (() -> Void)? = switch moduleID {
        case .cpu, .disk, .network: { [weak self] in
            self?.closePopover()
            NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"),
                configuration: NSWorkspace.OpenConfiguration()
            )
        }
        case .gpu, .memory: nil
        }
        showPopover(
            moduleID: moduleID.rawValue,
            anchor: anchor,
            size: size,
            content: AnyView(MonitorModulePopoverView(
                moduleID: moduleID,
                openSettings: { [weak self] in
                    self?.closePopover()
                    SettingsWindowController.shared.show()
                },
                openActivityMonitor: openActivityMonitor
            ))
        )
    }

    private func showPopover(moduleID: String, anchor: NSView, size: NSSize, content: AnyView) {
        if popover?.isShown == true, popoverModuleID == moduleID {
            closePopover()
            return
        }
       closePopover()
       let popover = NSPopover()
       popover.behavior = .transient
        popover.animates = false
       popover.delegate = self
        // Clamp height to available screen space below the anchor
        var clampedSize = size
        if let screen = anchor.window?.screen ?? NSScreen.main {
            let anchorBottom = anchor.window?.convertToScreen(anchor.bounds).minY ?? screen.visibleFrame.minY
            let availableHeight = anchorBottom - screen.visibleFrame.minY - 8
            if availableHeight > 0 {
                clampedSize.height = min(size.height, availableHeight)
            }
        }
        popover.contentSize = clampedSize
        popover.contentViewController = NSHostingController(rootView: content)
        self.popover = popover
        self.popoverModuleID = moduleID
        refreshMetricsSampling()
        let positioningRect = moduleID == "calendar"
            ? anchor.bounds.offsetBy(dx: 0, dy: Self.calendarPopoverAnchorOffset)
            : anchor.bounds
        popover.show(relativeTo: positioningRect, of: anchor, preferredEdge: .minY)
    }

    // MARK: - Close helpers

   func closePopover() {
        popover?.close()
       popover?.contentViewController = nil
        popover = nil
        popoverModuleID = nil
        refreshMetricsSampling()
    }

    /// 监听弹窗窗口失去 key 状态：焦点转移到弹窗之外时关闭。
    private func observeFocusLoss(of popover: NSPopover) {
        removeFocusLossObservers()
        guard let window = popover.contentViewController?.view.window else { return }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePopoverWindowResignKey),
            name: NSWindow.didResignKeyNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleApplicationResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
        installGlobalClickMonitor()
    }

    @objc private func handleApplicationResignActive() {
        DispatchQueue.main.async { [weak self] in
            self?.closePopoverIfFocusMovedAway()
        }
    }

    private func installGlobalClickMonitor() {
        removeGlobalClickMonitor()
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.closePopoverIfClickedOutside()
            }
        }
    }

    private func closePopoverIfClickedOutside() {
        guard let popover, popover.isShown,
              let popoverWindow = popover.contentViewController?.view.window
        else { return }
        let clickLocation = NSEvent.mouseLocation
        if popoverWindow.frame.contains(clickLocation) { return }
        if let monthPickerWindow = NSApp.windows.first(where: {
            $0.identifier == MenuBarCalendarView.monthPickerWindowIdentifier
        }), monthPickerWindow.frame.contains(clickLocation) {
            return
        }
        // Check main toolbox button
        if let button = mainStatusItem?.button,
           let buttonFrame = button.window?.convertToScreen(button.frame),
           buttonFrame.contains(clickLocation) {
            return
        }
        // Check module status bar buttons
        for (_, item) in statusBarItems {
            if let button = item.button,
               let buttonFrame = button.window?.convertToScreen(button.frame),
               buttonFrame.contains(clickLocation) {
                return
            }
        }
        popover.close()
    }

    @objc private func handlePopoverWindowResignKey(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.closePopoverIfFocusMovedAway()
        }
    }

    private func closePopoverIfFocusMovedAway() {
        guard let popover, popover.isShown else { return }
        if NSApp.keyWindow?.identifier == MenuBarCalendarView.monthPickerWindowIdentifier {
            return
        }
        if NSApp.isActive && NSApp.keyWindow == nil {
            return
        }
        popover.close()
    }

    private func removeFocusLossObservers() {
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didResignKeyNotification,
            object: nil
        )
        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
        removeGlobalClickMonitor()
    }

    private func removeGlobalClickMonitor() {
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
            self.globalClickMonitor = nil
        }
    }

    // MARK: - NSPopoverDelegate

    func popoverDidShow(_ notification: Notification) {
        guard let popover else { return }
        observeFocusLoss(of: popover)
    }

    func popoverDidClose(_ notification: Notification) {
        removeFocusLossObservers()
        popoverModuleID = nil
        refreshMetricsSampling()
    }

}

private struct ModuleMenuPanelView: View {
    let moduleID: String
    let execute: (String, String) -> Void
    let openSettings: () -> Void

    @ObservedObject private var metrics = SystemMetricsService.shared
    @ObservedObject private var actions = SystemActionsService.shared
    @ObservedObject private var calendarService = SystemCalendarService.shared
    @State private var hovered: String?
    @State private var displayedMonth = Date.now
    private var menuWidth: CGFloat { Self.preferredWidth(for: moduleID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch moduleID {
            case "dashboard": dashboard
            case "calendar": calendar
            case "screenshot": screenshot
            case "input": input
            case "finder": finder
            case "system": system
            default: EmptyView()
            }
        }
        .padding(4)
        .frame(width: menuWidth)
        .background(Color(red: 251 / 255, green: 251 / 255, blue: 253 / 255).opacity(0.96))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .preferredColorScheme(.light)
        .onAppear {
            metrics.start()
            if moduleID == "calendar" { loadCalendar() }
            if moduleID == "system" { actions.refreshRemovableVolumes() }
        }
    }

    private var dashboard: some View {
        Group {
            LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 4) {
                statCard("CPU", percent(metrics.current.cpuUsage), metrics.current.cpuUsage)
                statCard("内存", percent(metrics.current.memoryUsage), metrics.current.memoryUsage)
                statCard("磁盘", percent(metrics.current.diskUsage), metrics.current.diskUsage, warning: metrics.current.diskUsage >= 0.75)
                statCard("网络", rate(metrics.current.networkInBytesPerSecond), metrics.current.networkInBytesPerSecond > 0 ? 0.72 : 0.18)
            }
            .padding(.horizontal, 8).padding(.top, 8)
            divider; section("网络地址")
            item("本地 IP", value: metrics.localIPAddress, icon: nil)
            item("公网 IP", value: metrics.publicIPAddress ?? "未查询", icon: nil)
            divider
            item("快捷操作", icon: "speaker.wave.2", submenu: true)
            settings
        }
    }

    private var calendar: some View {
        let calendar = prototypeCalendar
        let month = CalendarMonth(containing: displayedMonth, calendar: calendar)
        return Group {
            calendarNavigation(month: month, calendar: calendar)
            LazyVGrid(columns: Array(repeating: .init(.flexible(), spacing: 0), count: 7), spacing: 1) {
                ForEach(Array(month.weekdaySymbols.enumerated()), id: \.offset) { _, weekday in
                    Text(weekday).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary).frame(height: 16)
                }
                ForEach(month.days) { day in
                    let hasEvent = !calendarService.events(on: day.date, calendar: calendar).isEmpty
                    VStack(spacing: 0) {
                        Text("\(day.number)").font(.system(size: 11, weight: day.isToday ? .semibold : .regular))
                        Text(day.lunarText).font(.system(size: 7)).lineLimit(1)
                    }
                    .foregroundStyle(day.isInDisplayedMonth ? (day.isToday ? Color.white : Color.primary) : Color.secondary.opacity(0.45))
                    .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36)
                    .background(day.isToday ? Color(red: 0, green: 113 / 255, blue: 227 / 255) : .clear,
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(alignment: .bottom) {
                        if hasEvent {
                            Circle().fill(day.isToday ? Color.white : Color(red: 0, green: 113 / 255, blue: 227 / 255))
                                .frame(width: 3, height: 3).padding(.bottom, 1)
                        }
                    }
                }
            }
            .padding(.horizontal, 8).padding(.bottom, 6)
            divider; section(todaySectionTitle(in: month, calendar: calendar))
            if todayEvents.isEmpty {
                item("暂无日程或尚未授权日历", icon: "calendar.badge.exclamationmark", disabled: true)
            } else {
                ForEach(todayEvents.prefix(6)) { event in
                    item(event.title, value: event.isAllDay ? "全天" : event.startDate.formatted(.dateTime.hour().minute()), icon: "circle.fill", status: Color(red: event.color.red, green: event.color.green, blue: event.color.blue, opacity: event.color.opacity))
                }
            }
            divider
            item("跳转到日期…", icon: "calendar.badge.plus", submenu: true, disabled: true)
            item("打开日历 App", icon: "calendar") { openCalendar() }
            divider; settings
        }
    }

    private var screenshot: some View {
        Group {
            section("截屏模式")
            item("智能截图", value: "⌘⇧A", icon: "viewfinder") { execute("screenshot", "smart") }
            item("区域截图", value: "⌘⌥A", icon: "rectangle.dashed") { execute("screenshot", "region") }
            item("窗口截图", value: "⌘⌥W", icon: "macwindow") { execute("screenshot", "window") }
            item("全屏截图", value: "⌘⌥F", icon: "display") { execute("screenshot", "fullscreen") }
            divider; section("最近截图")
            item("暂无最近截图", icon: "photo.on.rectangle", disabled: true)
            divider
            item("保存位置", value: ScreenshotSettingsStore().load().saveLocation.title, icon: "folder", submenu: true, disabled: true)
            settings
        }
    }

    private var input: some View {
        let input = InputEnhancementStore().load()
        let status = PermissionService.shortcutHelperStatus
        return Group {
            section("输入增强")
            item("平滑滚动", value: input.scroll.isEnabled ? "已开启" : "关闭", icon: "scroll", checked: input.scroll.isEnabled) { execute("input", "toggle-scroll") }
            item("鼠标手势", value: input.gestureRules.contains(where: \.isEnabled) ? "已开启" : "关闭", icon: "hand.draw", checked: input.gestureRules.contains(where: \.isEnabled)) { execute("input", "toggle-gesture") }
            item("按键展示", value: input.keycast.isEnabled ? "已开启" : "关闭", icon: "keyboard", checked: input.keycast.isEnabled) { execute("input", "toggle-keycast") }
            divider; section("应用规则")
            item("当前应用：\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "未检测到")", icon: "app.dashed", submenu: true, disabled: true)
            item("应用规则列表", icon: "list.bullet", submenu: true, disabled: true)
            divider; section("诊断")
            item("辅助功能权限", value: status.isAccessibilityTrusted ? "已授权" : "未授权", icon: "circle.fill", status: status.isAccessibilityTrusted ? .green : .orange, disabled: true)
            item("输入监控权限", value: status.isInputMonitoringTrusted ? "已授权" : "未授权", icon: "circle.fill", status: status.isInputMonitoringTrusted ? .green : .orange, disabled: true)
            item("鼠标设备", value: device(status.detectedScrollDevice), icon: "circle.fill", status: status.detectedScrollDevice == nil ? .orange : .green, disabled: true)
            divider; settings
        }
    }

    private var finder: some View {
        Group {
            section("文件操作")
            item("新建文件", icon: "doc.badge.plus", submenu: true, disabled: true)
            item("新建文件夹", value: "⌘⇧N", icon: "folder.badge.plus", disabled: true)
            divider
            item("复制路径", icon: "document.on.document", submenu: true, disabled: true)
            item("剪切", value: "⌘X", icon: "scissors", disabled: true)
            item("粘贴", value: "⌘V", icon: "doc.on.clipboard", disabled: true)
            divider
            item("在终端打开", icon: "terminal", disabled: true)
            item("用应用打开", icon: "arrow.up.forward.app", submenu: true, disabled: true)
            item("刷新", icon: "arrow.clockwise", disabled: true)
            divider; settings
        }
    }

    private var system: some View {
        Group {
            section("系统快捷操作")
            item("静音", value: actions.isMuted ? "已静音" : "关闭", icon: "speaker.slash", checked: actions.isMuted) { execute("system", "toggle-mute") }
            item("深色模式", icon: "circle.lefthalf.filled") { execute("system", "toggle-dark") }
            item("防休眠", value: actions.preventsSleep ? "已开启" : "关闭", icon: "moon.zzz", checked: actions.preventsSleep) { execute("system", "toggle-sleep-prevention") }
            divider
            item("显示器休眠", icon: "display") { execute("system", "sleep-display") }
            item("清空剪贴板", icon: "clipboard") { execute("system", "clear-pasteboard") }
            if actions.removableVolumes.isEmpty {
                item("推出磁盘", value: "没有可推出设备", icon: "eject", submenu: true, disabled: true)
            } else {
                ForEach(actions.removableVolumes, id: \.self) { volume in
                    item("推出 \(volume.lastPathComponent)", icon: "eject", submenu: true) { actions.eject(volume) }
                }
            }
            divider; settings
        }
    }

    private var settings: some View { item("Fewer 设置…", icon: "gearshape") { openSettings() } }
    private var divider: some View { Rectangle().fill(Color(red: 232 / 255, green: 232 / 255, blue: 237 / 255)).frame(height: 1).padding(.horizontal, 8).padding(.vertical, 4) }

    private func section(_ title: String) -> some View {
        Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.4)
            .foregroundStyle(Color(red: 134 / 255, green: 134 / 255, blue: 139 / 255))
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
    }

    private func calendarNavigation(month: CalendarMonth, calendar: Calendar) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(monthTitle(month, calendar: calendar))
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button { stepDisplayedMonth(-1, calendar: calendar) } label: {
                Image(systemName: "chevron.left").frame(width: 24, height: 24)
            }
            Button { stepDisplayedMonth(1, calendar: calendar) } label: {
                Image(systemName: "chevron.right").frame(width: 24, height: 24)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color(red: 29 / 255, green: 29 / 255, blue: 31 / 255))
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
    }

    private func stepDisplayedMonth(_ offset: Int, calendar: Calendar) {
        displayedMonth = calendar.date(byAdding: .month, value: offset, to: displayedMonth) ?? displayedMonth
        loadCalendar()
    }

    private func monthTitle(_ month: CalendarMonth, calendar: Calendar) -> String {
        let gregorian = month.monthStart.formatted(
            .dateTime.locale(Locale(identifier: "zh_CN")).year().month()
        )
        guard let interval = calendar.dateInterval(of: .month, for: month.monthStart),
              let lastDay = calendar.date(byAdding: .day, value: -1, to: interval.end) else {
            return gregorian
        }
        return "\(gregorian) · 农历\(lunarDateText(interval.start, calendar: calendar))至\(lunarDateText(lastDay, calendar: calendar))"
    }

    private func todaySectionTitle(in month: CalendarMonth, calendar: Calendar) -> String {
        let lunar = month.days.first(where: { calendar.isDate($0.date, inSameDayAs: .now) })?.lunarText ?? ""
        let date = Date.now.formatted(
            .dateTime.locale(Locale(identifier: "zh_CN")).month().day().weekday()
        )
        return lunar.isEmpty ? "今日 · \(date)" : "今日 · \(date) · \(lunar)"
    }

    private func lunarDateText(_ date: Date, calendar: Calendar) -> String {
        var lunar = Calendar(identifier: .chinese)
        lunar.locale = Locale(identifier: "zh_CN")
        lunar.timeZone = calendar.timeZone
        let components = lunar.dateComponents([.month, .day, .isLeapMonth], from: date)
        guard let month = components.month, let day = components.day,
              Self.lunarMonthNames.indices.contains(month - 1),
              Self.lunarDayNames.indices.contains(day - 1) else { return "" }
        let leap = components.isLeapMonth == true ? "闰" : ""
        return "\(leap)\(Self.lunarMonthNames[month - 1])月\(Self.lunarDayNames[day - 1])"
    }

    private func statCard(_ title: String, _ value: String, _ level: Double, warning: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(value)
                    .font(.system(size: title == "网络" ? 14 : 17, weight: .semibold, design: .monospaced))
                    .foregroundStyle(warning ? Color.yellow : Color.primary)
            }
            Sparkline(
                level: level,
                color: warning ? .yellow : Color(red: 0, green: 113 / 255, blue: 227 / 255)
            )
            .frame(height: 30)
        }
        .padding(8)
        .background(Color(red: 245 / 255, green: 245 / 255, blue: 247 / 255), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func item(_ title: String, value: String? = nil, icon: String?, checked: Bool = false, submenu: Bool = false, status: Color? = nil, disabled: Bool = false, action: @escaping () -> Void = {}) -> some View {
        let identifier = "\(moduleID)-\(title)"
        return Button(action: action) {
            HStack(spacing: 8) {
                if status != nil || checked || icon != nil {
                    Group {
                        if let status { Circle().fill(status).frame(width: 7, height: 7) }
                        else if checked { Text("✓").font(.system(size: 12, weight: .semibold)) }
                        else if let icon { Image(systemName: icon).font(.system(size: 14)) }
                    }
                    .frame(width: 16, height: 16)
                }
                Text(title).lineLimit(1)
                Spacer(minLength: 4)
                if let value { Text(value).font(.system(size: 12, design: .monospaced)).lineLimit(1) }
                if submenu { Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)) }
            }
            .font(.system(size: 14))
            .foregroundStyle(disabled ? Color(red: 134 / 255, green: 134 / 255, blue: 139 / 255) : (hovered == identifier ? Color.white : Color(red: 29 / 255, green: 29 / 255, blue: 31 / 255)))
            .padding(.horizontal, 12).padding(.vertical, 5).frame(minHeight: 28)
            .background(!disabled && hovered == identifier ? Color(red: 0, green: 113 / 255, blue: 227 / 255) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain).disabled(disabled)
        .onHover { hovered = $0 && !disabled ? identifier : (hovered == identifier ? nil : hovered) }
    }

    private var prototypeCalendar: Calendar { Self.configuredCalendar }
    private static var configuredCalendar: Calendar {
        var calendar = Calendar.autoupdatingCurrent
        calendar.locale = Locale(identifier: "zh_CN")
        calendar.firstWeekday = 1
        return calendar
    }
    private var todayEvents: [CalendarEventItem] { calendarService.events(on: .now, calendar: prototypeCalendar) }
    static func preferredWidth(for moduleID: String) -> CGFloat { moduleID == "calendar" ? 300 : 280 }
    static func preferredHeight(for moduleID: String, calendarEventCount: Int = 0) -> CGFloat {
        switch moduleID {
        case "dashboard": 320
        case "calendar": 430 + CGFloat(max(0, min(6, calendarEventCount) - 1)) * 28
        case "screenshot": 270
        case "input": 370
        case "finder": 312
        case "system": 256
        default: 360
        }
    }
    static func prepareCalendarEvents() -> Int {
        let calendar = configuredCalendar
        guard let interval = calendar.dateInterval(of: .month, for: .now) else { return 0 }
        let service = SystemCalendarService.shared
        service.loadEvents(
            from: interval.start,
            through: calendar.date(byAdding: .day, value: -1, to: interval.end) ?? .now,
            calendar: calendar
        )
        return service.events(on: .now, calendar: calendar).count
    }
    private func loadCalendar() {
        let calendar = prototypeCalendar
        guard let interval = calendar.dateInterval(of: .month, for: displayedMonth) else { return }
        calendarService.loadEvents(from: interval.start, through: calendar.date(byAdding: .day, value: -1, to: interval.end) ?? .now, calendar: calendar)
    }
    private func openCalendar() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }
    private func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
    private func rate(_ value: Double) -> String { ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file) + "/s" }
    private func device(_ value: ScrollInputDevice?) -> String { switch value { case .mouse: "已连接"; case .trackpad: "触控板"; case nil: "未检测到" } }
    private static let lunarMonthNames = ["正", "二", "三", "四", "五", "六", "七", "八", "九", "十", "冬", "腊"]
    private static let lunarDayNames = [
        "初一", "初二", "初三", "初四", "初五", "初六", "初七", "初八", "初九", "初十",
        "十一", "十二", "十三", "十四", "十五", "十六", "十七", "十八", "十九", "二十",
        "廿一", "廿二", "廿三", "廿四", "廿五", "廿六", "廿七", "廿八", "廿九", "三十",
    ]
}

private struct Sparkline: View {
    let level: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            let points: [CGFloat] = [0.72, 0.52, 0.65, 0.34, 0.56, 0.28, 0.42, max(0.12, min(0.88, 1 - level))]
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: proxy.size.height))
                    for (index, point) in points.enumerated() {
                        let x = proxy.size.width * CGFloat(index) / CGFloat(points.count - 1)
                        let y = proxy.size.height * point
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                    path.addLine(to: CGPoint(x: proxy.size.width, y: proxy.size.height))
                    path.closeSubpath()
                }
                .fill(color.opacity(0.10))
                Path { path in
                    for (index, point) in points.enumerated() {
                        let x = proxy.size.width * CGFloat(index) / CGFloat(points.count - 1)
                        let y = proxy.size.height * point
                        if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                        else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }
        }
    }
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    static let navigateNotification = Notification.Name("FewerSettingsNavigate")

    private override init() {}

    func show() {
        show(section: nil)
    }

    func show(section: SettingsSection?) {
        let settingsWindow: NSWindow
        if let window {
            settingsWindow = window
            if settingsWindow.contentViewController == nil {
                installSettingsContent(in: settingsWindow)
            }
        } else {
            settingsWindow = makeWindow()
            window = settingsWindow
        }

        NSApp.activate(ignoringOtherApps: true)
        settingsWindow.orderFrontRegardless()
        settingsWindow.makeKeyAndOrderFront(nil)
        if let section {
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: Self.navigateNotification,
                    object: nil,
                    userInfo: ["section": section.rawValue]
                )
            }
        }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("settings-window")
        window.title = "Fewer 设置"
        window.minSize = NSSize(width: 880, height: 640)
        window.isReleasedWhenClosed = false
        window.delegate = self
        installSettingsContent(in: window)
        window.center()
        return window
    }

    private func installSettingsContent(in window: NSWindow) {
        window.contentViewController = NSHostingController(
            rootView: RootSettingsView()
                .frame(minWidth: 880, minHeight: 600)
        )
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow,
              closingWindow === window else {
            return
        }

        closingWindow.contentViewController = nil
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if !AppLaunchMode.isUITesting {
            ModuleCommandObserver.shared.start()
            HotKeyManager.shared.install()
        }
        installApplicationMenu()
        DispatchQueue.main.async {
            if !AppLaunchMode.isUITesting {
                AppPresentationController.shared.restoreStoredMode()
            }
            SettingsWindowController.shared.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if !AppLaunchMode.isUITesting {
            ModuleCommandObserver.shared.stop()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @objc private func showSettings() {
        SettingsWindowController.shared.show()
    }

    private func installApplicationMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()

        let settingsItem = NSMenuItem(
            title: "设置…",
            action: #selector(showSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "退出 Fewer",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApp
        appMenu.addItem(quitItem)

        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        NSApp.mainMenu = mainMenu
    }
}
