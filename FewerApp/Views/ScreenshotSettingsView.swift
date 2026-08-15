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
        Form {
            Section("立即截屏") {
                HStack {
                    Button {
                        ScreenshotService.shared.begin(.region)
                    } label: {
                        Label("区域", systemImage: "viewfinder")
                    }
                    Button {
                        ScreenshotService.shared.begin(.window)
                    } label: {
                        Label("窗口", systemImage: "macwindow")
                    }
                    Button {
                        ScreenshotService.shared.begin(.fullscreen)
                    } label: {
                        Label("全屏", systemImage: "rectangle.inset.filled")
                    }
                }
                Text("快捷键冲突或未记住时，可从这里直接开始截屏。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Label(
                        permissionStatusText,
                        systemImage: hasScreenCapturePermission ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(hasScreenCapturePermission ? .green : .orange)
                    Spacer()
                    if !hasScreenCapturePermission {
                        if permissionWasRequested {
                            Button("重新启动 Fewer") {
                                ScreenshotCapture.restartApplication()
                            }
                        } else {
                            Button("请求权限") {
                                requestScreenCapturePermission()
                            }
                        }
                        Button("打开系统设置") {
                            ScreenshotCapture.openPermissionSettings()
                        }
                        Button("重新检查") {
                            refreshScreenCapturePermission()
                        }
                    }
                }
                .font(.caption)
            }

            Section("快捷键") {
                Toggle("启用截屏快捷键", isOn: Binding(
                    get: { settings.shortcutsEnabled },
                    set: { settings.shortcutsEnabled = $0 }
                ))
                HotKeyRecorder(title: "区域截屏", spec: $settings.regionHotKey)
                HotKeyRecorder(title: "窗口截屏", spec: $settings.windowHotKey)
                HotKeyRecorder(title: "全屏截屏", spec: $settings.fullscreenHotKey)
                Text("录制快捷键时需包含至少一个修饰键；Esc 取消录制。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("滚动截图") {
                Toggle("在区域截图工具条显示滚动截图", isOn: Binding(
                    get: { settings.rollingCaptureEnabled },
                    set: { settings.rollingCaptureEnabled = $0 }
                ))
                Text("选中后立即开始录制，可自行上下滚动；点击停止并生成后，会先处理已经捕获的剩余画面再生成长图。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("贴图") {
                HStack {
                    Text("默认透明度")
                    Slider(
                        value: Binding(
                            get: { settings.pinDefaultOpacity },
                            set: { settings.pinDefaultOpacity = $0 }
                        ),
                        in: 0.1...1.0
                    )
                    Text("\(Int((settings.pinDefaultOpacity * 100).rounded()))%")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
            }

            Section("保存") {
                Picker("保存位置", selection: Binding(
                    get: { settings.saveLocation },
                    set: { settings.saveLocation = $0 }
                )) {
                    ForEach(ScreenshotSaveLocation.allCases) { location in
                        Text(location.title).tag(location)
                    }
                }

                if settings.saveLocation == .custom {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("自定义文件夹")
                            Text(settings.customSaveDirectory ?? "尚未选择")
                                .font(.caption)
                                .foregroundStyle(settings.customSaveDirectory == nil ? .red : .secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Button("选择…") {
                            chooseSaveDirectory()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("截屏")
        .onAppear {
            settings = store.load()
            refreshScreenCapturePermission()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshScreenCapturePermission()
        }
        .onChange(of: settings) { _, _ in
            store.save(settings)
            // 快捷键可能变化，重新注册全局热键
            if settings.shortcutsEnabled {
                HotKeyManager.shared.install()
            } else {
                HotKeyManager.shared.unregisterAll()
            }
        }
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
