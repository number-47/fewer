import AppKit
import FewerCore
import Foundation

protocol FewerModule: Sendable {
    var descriptor: ModuleDescriptor { get }
    var commands: [ModuleCommand] { get }
    var permissions: [ModulePermission] { get }
}

struct BuiltInModule: FewerModule, Sendable {
    let descriptor: ModuleDescriptor
    let commands: [ModuleCommand]
    let permissions: [ModulePermission]
}

enum ModuleRegistry {
    static let modules: [any FewerModule] = [
        module(SystemMonitorModuleID.cpu.rawValue, "CPU", "处理器使用率、负载与进程", "cpu", 0, .popover, [.dashboard]),
        module(SystemMonitorModuleID.gpu.rawValue, "GPU", "图形处理器使用率与性能", "memorychip", 10, .popover, [.dashboard]),
        module(SystemMonitorModuleID.memory.rawValue, "内存", "内存压力、交换空间与进程", "memorychip", 20, .popover, [.dashboard]),
        module(SystemMonitorModuleID.disk.rawValue, "磁盘", "容量、读写与健康状态", "internaldrive", 30, .popover, [.dashboard]),
        module(SystemMonitorModuleID.network.rawValue, "网络", "上传、下载与连接信息", "network", 40, .popover, [.dashboard]),
        module("calendar", "日历", "日期、日程与提醒", "calendar", 50, .popover, [.dashboard], [], [
            ModulePermission(id: "calendar", kind: .calendar, title: "日历与提醒", detail: "展示日程和提醒"),
        ]),
        module("screenshot", "智能截图", "区域、窗口、全屏与滚动截图", "camera.viewfinder", 60, .menu, [.dashboard], [
            ("smart", "智能截图", "viewfinder"), ("region", "区域截图", "rectangle.dashed"),
            ("window", "窗口截图", "macwindow"), ("fullscreen", "全屏截图", "display"),
            ("ocr-translate", "截图翻译", "text.viewfinder"),
        ], [ModulePermission(id: "screen", kind: .screenRecording, title: "屏幕录制", detail: "读取屏幕像素")]),
        module("input", "输入增强", "鼠标滚动、轨迹手势与按键展示", "cursorarrow.motionlines", 0, .menu, [.actions], [
            ("toggle-scroll", "切换滚动增强", "scroll"), ("toggle-keycast", "切换按键展示", "keyboard"),
            ("toggle-gesture", "切换鼠标手势", "hand.draw"),
        ], [
            ModulePermission(id: "accessibility", kind: .accessibility, title: "辅助功能", detail: "安全改写输入事件"),
            ModulePermission(id: "input-monitoring", kind: .inputMonitoring, title: "输入监控", detail: "观察键鼠事件"),
        ]),
        module("finder", "Finder 工具", "剪切粘贴、模板、路径与刷新", "folder", 10, .menu, [.actions], [
            ("open-finder", "打开 Finder", "folder"),
        ]),
        module("system", "系统快捷操作", "防休眠、静音、显示器与剪贴板", "switch.2", 20, .menu, [.actions], [
            ("toggle-dark", "切换深色模式", "circle.lefthalf.filled"),
            ("toggle-mute", "切换静音", "speaker.slash"),
            ("toggle-sleep-prevention", "切换防休眠", "moon.zzz"),
            ("sleep-display", "显示器休眠", "display"),
            ("clear-pasteboard", "清空剪贴板", "clipboard"),
        ]),
    ]

    private static func module(
        _ id: String,
        _ title: String,
        _ summary: String,
        _ image: String,
        _ order: Int,
        _ interaction: ModuleInteraction,
        _ surfaces: Set<ModuleSurface>,
        _ commands: [(String, String, String)] = [],
        _ permissions: [ModulePermission] = []
    ) -> BuiltInModule {
        BuiltInModule(
            descriptor: ModuleDescriptor(
                id: id,
                title: title,
                summary: summary,
                systemImage: image,
                order: order,
                interaction: interaction,
                supportedSurfaces: surfaces
            ),
            commands: commands.map {
                ModuleCommand(id: $0.0, moduleID: id, title: $0.1, systemImage: $0.2)
            },
            permissions: permissions
        )
    }
}

@MainActor
final class ModuleHost: ObservableObject {
    static let shared = ModuleHost()

    @Published private(set) var preferences: ModulePreferences
    @Published private(set) var modulePreferencesRecoveryMessage: String?
    let modules = ModuleRegistry.modules
    private let store = ModulePreferencesStore(access: .mainAppWriter)

    private init() {
        preferences = store.load(descriptors: modules.map(\.descriptor))
        modulePreferencesRecoveryMessage = store.recoveryMessage
    }

    func modules(on surface: ModuleSurface) -> [any FewerModule] {
        let order = surface == .dashboard ? preferences.dashboardOrder : preferences.actionOrder
        let hidden = surface == .dashboard
            ? preferences.hiddenDashboardModuleIDs
            : preferences.hiddenActionModuleIDs
        return modules
            .filter {
                preferences.enabledModuleIDs.contains($0.descriptor.id)
                    && $0.descriptor.supportedSurfaces.contains(surface)
                    && !hidden.contains($0.descriptor.id)
            }
            .sorted {
                (order.firstIndex(of: $0.descriptor.id) ?? .max)
                    < (order.firstIndex(of: $1.descriptor.id) ?? .max)
            }
    }

    func allModules(on surface: ModuleSurface) -> [any FewerModule] {
        let order = surface == .dashboard ? preferences.dashboardOrder : preferences.actionOrder
        return modules
            .filter { $0.descriptor.supportedSurfaces.contains(surface) }
            .sorted {
                (order.firstIndex(of: $0.descriptor.id) ?? .max)
                    < (order.firstIndex(of: $1.descriptor.id) ?? .max)
            }
    }

    func setEnabled(_ enabled: Bool, moduleID: String) {
        if enabled {
            preferences.enabledModuleIDs.insert(moduleID)
        } else {
            preferences.enabledModuleIDs.remove(moduleID)
        }
        if !enabled, moduleID == "system" { SystemActionsService.shared.setPreventsSleep(false) }
        save()
        if moduleID == "screenshot" { HotKeyManager.shared.install() }
    }

    func restoreDefaultModulePreferences() {
        preferences = ModulePreferences(enabledModuleIDs: Set(modules.map(\.descriptor.id)))
        preferences.reconcile(with: modules.map(\.descriptor))
        save()
    }

    var commands: [ModuleCommand] {
        modules
            .filter { preferences.enabledModuleIDs.contains($0.descriptor.id) }
            .flatMap(\.commands)
    }

    func permissions(for moduleID: String) -> [ModulePermission] {
        modules.first { $0.descriptor.id == moduleID }?.permissions ?? []
    }

    func state(for moduleID: String) -> ModuleState {
        let enabled = preferences.enabledModuleIDs.contains(moduleID)
        switch moduleID {
        case "input":
            let status = PermissionService.shortcutHelperStatus
            return ModuleState(
                isEnabled: enabled,
                statusText: status.isEventTapActive ? "输入监听正常" : "等待权限或 Helper",
                errorMessage: status.lastError
            )
        case "screenshot":
            return ModuleState(isEnabled: enabled, statusText: ScreenshotCapture.hasPermission ? "屏幕录制已授权" : "需要屏幕录制权限")
        default:
            return ModuleState(isEnabled: enabled, statusText: enabled ? "已启用" : "已停用")
        }
    }

    @discardableResult
    func execute(moduleID: String, commandID: String) -> Bool {
        guard preferences.enabledModuleIDs.contains(moduleID),
              commands.contains(where: { $0.moduleID == moduleID && $0.id == commandID })
        else { return false }
        switch (moduleID, commandID) {
        case ("screenshot", "smart"): ScreenshotService.shared.begin(.smart)
        case ("screenshot", "region"): ScreenshotService.shared.begin(.region)
        case ("screenshot", "window"): ScreenshotService.shared.begin(.window)
        case ("screenshot", "fullscreen"): ScreenshotService.shared.begin(.fullscreen)
        case ("screenshot", "ocr-translate"): ScreenshotService.shared.beginOCRTranslation()
        case ("input", "toggle-scroll"), ("input", "toggle-keycast"), ("input", "toggle-gesture"):
            let inputStore = InputEnhancementStore(access: .mainAppWriter)
            var settings = inputStore.load()
            if commandID == "toggle-scroll" { settings.scroll.isEnabled.toggle() }
            else if commandID == "toggle-keycast" { settings.keycast.isEnabled.toggle() }
            else {
                let anyGesture = settings.gestureRules.contains(where: \.isEnabled)
                if settings.gestureRules.isEmpty, !anyGesture {
                    settings.gestureRules = MouseGesturePresets.defaultRules
                } else {
                    for index in settings.gestureRules.indices {
                        settings.gestureRules[index].isEnabled.toggle()
                    }
                }
            }
            try? inputStore.save(settings)
            DistributedNotificationCenter.default().postNotificationName(
                AppGroupConstants.inputEnhancementSettingsDidChangeNotification,
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
        case ("finder", "open-finder"): NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory()))
        case ("system", "toggle-dark"): SystemActionsService.shared.toggleDarkMode()
        case ("system", "toggle-mute"): SystemActionsService.shared.toggleMute()
        case ("system", "toggle-sleep-prevention"):
            SystemActionsService.shared.setPreventsSleep(!SystemActionsService.shared.preventsSleep)
        case ("system", "sleep-display"): SystemActionsService.shared.sleepDisplays()
        case ("system", "clear-pasteboard"): SystemActionsService.shared.clearPasteboard()
        default: return false
        }
        return true
    }

    func isVisible(moduleID: String, on surface: ModuleSurface) -> Bool {
        guard preferences.enabledModuleIDs.contains(moduleID) else { return false }
        let hidden = surface == .dashboard
            ? preferences.hiddenDashboardModuleIDs
            : preferences.hiddenActionModuleIDs
        return !hidden.contains(moduleID)
    }

    func setVisible(_ visible: Bool, moduleID: String, on surface: ModuleSurface) {
        if surface == .dashboard {
            if visible { preferences.hiddenDashboardModuleIDs.remove(moduleID) }
            else { preferences.hiddenDashboardModuleIDs.insert(moduleID) }
        } else {
            if visible { preferences.hiddenActionModuleIDs.remove(moduleID) }
            else { preferences.hiddenActionModuleIDs.insert(moduleID) }
        }
        save()
    }

    func commands(for moduleID: String) -> [ModuleCommand] {
        modules.first { $0.descriptor.id == moduleID }?.commands ?? []
    }

    func isStatusBarIcon(moduleID: String) -> Bool {
        preferences.statusBarModuleIDs.contains(moduleID)
    }

    func setStatusBarIcon(_ enabled: Bool, moduleID: String) {
        if enabled {
            preferences.statusBarModuleIDs.insert(moduleID)
        } else {
            preferences.statusBarModuleIDs.remove(moduleID)
        }
        save()
    }

    func moveStatusBarIcon(moduleID: String, offset: Int) {
        var order = preferences.statusBarModuleOrder
        guard let index = order.firstIndex(of: moduleID) else { return }
        let destination = min(max(index + offset, 0), order.count - 1)
        guard destination != index else { return }
        order.remove(at: index)
        order.insert(moduleID, at: destination)
        preferences.statusBarModuleOrder = order
        save()
    }

    func setMonitorPreferences(
        _ value: MonitorModulePreferences,
        for moduleID: SystemMonitorModuleID
    ) {
        preferences.monitorPreferences[moduleID.rawValue] = value
        save()
    }

    func descriptor(for moduleID: String) -> ModuleDescriptor? {
        modules.first { $0.descriptor.id == moduleID }?.descriptor
    }

    func move(moduleID: String, offset: Int, on surface: ModuleSurface) {
        var order = surface == .dashboard ? preferences.dashboardOrder : preferences.actionOrder
        guard let index = order.firstIndex(of: moduleID) else { return }
        let destination = min(max(index + offset, 0), order.count - 1)
        guard destination != index else { return }
        order.remove(at: index)
        order.insert(moduleID, at: destination)
        if surface == .dashboard { preferences.dashboardOrder = order }
        else { preferences.actionOrder = order }
        save()
    }

    private func save() {
        do {
            try store.save(preferences)
            modulePreferencesRecoveryMessage = nil
        } catch {
            return
        }
        DistributedNotificationCenter.default().postNotificationName(
            AppGroupConstants.modulePreferencesDidChangeNotification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        objectWillChange.send()
    }
}
