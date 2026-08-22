import Carbon.HIToolbox
import FewerCore

/// 截屏模式。
enum ScreenshotMode: Equatable {
    case region
    case smart
    case window
    case fullscreen
}

/// Carbon 全局热键管理：注册/刷新区域、窗口、全屏截屏快捷键。
/// RegisterEventHotKey 为系统级热键，无需任何权限，回调经事件分发目标投递。
@MainActor
final class HotKeyManager {
    static let shared = HotKeyManager()

    private let store = ScreenshotSettingsStore()
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var modeByID: [UInt32: ScreenshotMode] = [:]
    private var rollingEscapeRef: EventHotKeyRef?
    private var rollingEscapeHandler: (() -> Void)?
    private var eventHandlerRef: EventHandlerRef?

    private static let hotKeySignature: OSType = 0x4657_4552 // 'FWER'

    private init() {}

    /// 注册全部热键（含事件分发器安装）。重复调用安全（先反注册）。
    func install() {
        unregisterAll()
        installEventHandlerIfNeeded()

        guard ModulePreferencesStore().isEnabled(moduleID: "screenshot") else { return }
        let settings = store.load()
        guard settings.shortcutsEnabled else { return }
        register(id: 1, spec: settings.regionHotKey, mode: .smart)
        register(id: 2, spec: settings.windowHotKey, mode: .window)
        register(id: 3, spec: settings.fullscreenHotKey, mode: .fullscreen)
    }

    func unregisterAll() {
        for (_, ref) in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
        modeByID.removeAll()
    }

    func installRollingEscapeHandler(_ handler: @escaping () -> Void) {
        removeRollingEscapeHandler()
        installEventHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: 99)
        guard RegisterEventHotKey(
            UInt32(kVK_Escape),
            0,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &ref
        ) == noErr else { return }
        rollingEscapeRef = ref
        rollingEscapeHandler = handler
    }

    func removeRollingEscapeHandler() {
        if let rollingEscapeRef { UnregisterEventHotKey(rollingEscapeRef) }
        rollingEscapeRef = nil
        rollingEscapeHandler = nil
    }

    private func register(id: UInt32, spec: HotKeySpec, mode: ScreenshotMode) {
        guard !spec.isEmpty else { return }
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: id)
        let status = RegisterEventHotKey(
            spec.keyCode,
            spec.modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        Self.debugLog("register id=\(id) status=\(status) ref=\(ref == nil ? "nil" : "ok")")
        guard status == noErr, let ref else { return }
        hotKeyRefs[id] = ref
        modeByID[id] = mode
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            Self.eventHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
        _ = status
    }

    /// Carbon 回调可能在任何线程，转发到主线程处理。
    fileprivate func handleHotKey(id: UInt32) {
        Self.debugLog("hotkey pressed id=\(id)")
        if id == 99 {
            rollingEscapeHandler?()
            return
        }
        guard let mode = modeByID[id] else { return }
        DispatchQueue.main.async {
            ScreenshotService.shared.begin(mode)
        }
    }

    private static func debugLog(_ message: String) {
        let line = "\(Date()) [HotKeyManager] \(message)\n"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fewer-hotkey.log")
        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8)!)
                try? handle.close()
            }
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static let eventHandler: EventHandlerUPP = { _, event, userData in
        guard let userData else { return noErr }
        let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        if status == noErr {
            manager.handleHotKey(id: hotKeyID.id)
        }
        return noErr
    }
}
