import AppKit
import FewerCore
import SwiftUI

/// 截屏设置：权限、快捷键、贴图默认透明度、保存位置。
struct ScreenshotSettingsView: View {
    @State private var settings = ScreenshotSettings.default
    @State private var hasScreenCapturePermission = ScreenshotCapture.hasPermission
    @State private var permissionWasRequested = ScreenshotCapture.permissionWasRequested
    private let store = ScreenshotSettingsStore()

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                FewerSettingsCard {
                    FewerSettingsRow {
                        VStack(alignment: .leading, spacing: 2) { Text("屏幕录制权限"); Text("截图功能所需").font(.caption).foregroundStyle(.secondary) }
                        Spacer(); Text(hasScreenCapturePermission ? "已授权" : "未授权").font(.caption).foregroundStyle(hasScreenCapturePermission ? .green : .orange)
                    }
                }
                FewerSettingsCard {
                    FewerSettingsRow { VStack(alignment: .leading, spacing: 2) { Text("滚动截图"); Text("自动拼接长图，支持上下双向滚动").font(.caption).foregroundStyle(.secondary) }; Spacer(); Toggle("", isOn: Binding(get: { settings.rollingCaptureEnabled }, set: { settings.rollingCaptureEnabled = $0 })).labelsHidden() }
                    Divider()
                    FewerSettingsRow { VStack(alignment: .leading, spacing: 2) { Text("自动贴图"); Text("截图后自动以浮动窗口置顶显示").font(.caption).foregroundStyle(.secondary) }; Spacer(); Text("当前版本不支持").font(.caption).foregroundStyle(.secondary) }
                    Divider()
                    FewerSettingsRow { Text("贴图默认透明度"); Spacer(); Slider(value: $settings.pinDefaultOpacity, in: 0.1...1.0).frame(width: 160); Text("\(Int((settings.pinDefaultOpacity * 100).rounded()))%").monospacedDigit().font(.caption) }
                    Divider()
                    FewerSettingsRow {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("保存位置")
                            Text("截图文件的默认保存路径").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("", selection: $settings.saveLocation) { ForEach(ScreenshotSaveLocation.allCases) { Text($0.title).tag($0) } }.labelsHidden().frame(width: 130)
                    }
                }
                FewerSettingsCard {
                    FewerSettingsRow { Text("快捷键录制").fontWeight(.semibold) }
                    Divider(); FewerSettingsRow { HotKeyRecorder(title: "区域截图", spec: $settings.regionHotKey) }
                    Divider(); FewerSettingsRow { HotKeyRecorder(title: "窗口截图", spec: $settings.windowHotKey) }
                    Divider(); FewerSettingsRow { HotKeyRecorder(title: "全屏截图", spec: $settings.fullscreenHotKey) }
                }
            }.padding(.bottom, 24)
        }
        .onAppear {
            settings = store.load()
            refreshScreenCapturePermission()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshScreenCapturePermission()
        }
        .onChange(of: settings) { _, _ in
            store.save(settings)
            reconcileKeycastShortcutConflict()
            // 快捷键可能变化，重新注册全局热键
            if settings.shortcutsEnabled {
                HotKeyManager.shared.install()
            } else {
                HotKeyManager.shared.unregisterAll()
            }
        }
    }

    private func reconcileKeycastShortcutConflict() {
        var inputSettings = InputEnhancementStore().load()
        guard let shortcut = inputSettings.keycast.toggleShortcut else { return }
        let reserved = settings.shortcutsEnabled
            ? [settings.regionHotKey, settings.windowHotKey, settings.fullscreenHotKey].map(InputShortcut.init)
            : []
        guard !InputShortcutSafety.isAllowedGlobalToggle(shortcut, additionalReserved: reserved) else { return }
        inputSettings.keycast.toggleShortcut = nil
        try? InputEnhancementStore().save(inputSettings)
        DistributedNotificationCenter.default().postNotificationName(
            AppGroupConstants.inputEnhancementSettingsDidChangeNotification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    private var permissionStatusText: String {
        if hasScreenCapturePermission {
            return "屏幕录制权限已授予"
        }
        if permissionWasRequested {
            return "权限尚未对当前版本生效；若系统设置已开启，请关闭后重新开启，再重启 Fewer"
        }
        return "需要屏幕录制权限"
    }

    private func requestScreenCapturePermission() {
        _ = ScreenshotCapture.requestPermission()
        permissionWasRequested = true
        refreshScreenCapturePermission()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            refreshScreenCapturePermission()
        }
    }

    private func refreshScreenCapturePermission() {
        ScreenshotCapture.reconcilePermissionState()
        hasScreenCapturePermission = ScreenshotCapture.hasPermission
        permissionWasRequested = ScreenshotCapture.permissionWasRequested
    }

    private func chooseSaveDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择截图保存文件夹"
        panel.prompt = "选择"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if let path = settings.customSaveDirectory {
            panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true)
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.customSaveDirectory = url.standardizedFileURL.path
        settings.saveLocation = .custom
    }
}

/// 快捷键录制行：点击后等待下一次按键组合，Esc 取消。
private struct HotKeyRecorder: View {
    let title: String
    @Binding var spec: HotKeySpec

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            if isRecording {
                endRecording()
            } else {
                startRecording()
            }
        } label: {
            HStack {
                Text(title)
                Spacer()
                Text(isRecording ? "按下新快捷键…" : spec.displayString)
                    .foregroundStyle(.secondary)
                    .font(.system(.body, design: .monospaced))
                    .frame(minWidth: 70, alignment: .trailing)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .background(
            isRecording
                ? RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.15))
                : nil
        )
        .onDisappear {
            // 录制中切换到其他设置页时清理事件监视器，避免泄漏
            endRecording()
        }
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 需要至少一个修饰键，避免纯字母键被误录
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !mods.isEmpty else { return event }
            if event.keyCode == 53 { // Esc 取消录制
                endRecording()
                return nil
            }
            spec = HotKeySpec(
                keyCode: UInt32(event.keyCode),
                modifiers: Self.mask(from: mods)
            )
            endRecording()
            return nil
        }
    }

    private func endRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        isRecording = false
    }

    private static func mask(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.command) { mask |= HotKeySpec.command }
        if flags.contains(.shift) { mask |= HotKeySpec.shift }
        if flags.contains(.option) { mask |= HotKeySpec.option }
        if flags.contains(.control) { mask |= HotKeySpec.control }
        return mask
    }
}
