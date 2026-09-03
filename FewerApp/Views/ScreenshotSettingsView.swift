import AppKit
import FewerCore
import SwiftUI

/// 截屏设置：权限、快捷键、贴图默认透明度、保存位置。
struct ScreenshotSettingsView: View {
    @State private var settings = ScreenshotSettings.default
    @State private var hasScreenCapturePermission = ScreenshotCapture.hasPermission
    @State private var permissionWasRequested = ScreenshotCapture.permissionWasRequested
    @State private var aiEndpoint = ""
    @State private var aiModel = ""
    @State private var aiAPIKey = ""
    @State private var isTestingAIConfiguration = false
    @State private var showsClearAIConfigurationConfirmation = false
    @State private var aiConfigurationMessage: String?
    private let store = ScreenshotSettingsStore()
    private let aiConfigurationService = AITranslationConfigurationService()

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
                    FewerSettingsRow { VStack(alignment: .leading, spacing: 2) { Text("自动贴图"); Text("开启后跳过标注和区域截图的滚动截图入口，直接以浮动窗口置顶显示").font(.caption).foregroundStyle(.secondary) }; Spacer(); Toggle("", isOn: Binding(get: { settings.afterAction == .pin }, set: { settings.afterAction = $0 ? .pin : .editThenPin })).labelsHidden() }
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
                    Divider()
                    FewerSettingsRow {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("翻译结果位置")
                            Text("截图翻译结果窗的打开位置").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("", selection: $settings.ocrTranslationWindowPosition) {
                            ForEach(OCRTranslationWindowPosition.allCases) {
                                Text($0.title).tag($0)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 130)
                    }
                }
                FewerSettingsCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("AI 翻译")
                            .fontWeight(.semibold)
                        Text("启用后，只有你在截图翻译结果中切换到 AI 时，Fewer 才会向你配置的服务发送 OCR 文本、原文语言和目标语言；不会发送截图、文字坐标或其他屏幕信息。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("完整 Chat Completions 地址", text: $aiEndpoint)
                            .textFieldStyle(.roundedBorder)
                        TextField("模型", text: $aiModel)
                            .textFieldStyle(.roundedBorder)
                        SecureField("API 密钥（本机服务可留空）", text: $aiAPIKey)
                            .textFieldStyle(.roundedBorder)
                        HStack {
                            Button(isTestingAIConfiguration ? "正在测试连接…" : "保存并测试连接") {
                                saveAndTestAIConfiguration()
                            }
                            .disabled(isTestingAIConfiguration)
                            Button("清除配置", role: .destructive) {
                                showsClearAIConfigurationConfirmation = true
                            }
                            .disabled(isTestingAIConfiguration || !hasAIConfiguration)
                            Spacer()
                        }
                        if let aiConfigurationMessage {
                            Text(aiConfigurationMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(16)
                }
                FewerSettingsCard {
                    FewerSettingsRow { Text("快捷键录制").fontWeight(.semibold) }
                    Divider(); FewerSettingsRow { HotKeyRecorder(title: "区域截图", spec: $settings.regionHotKey) }
                    Divider(); FewerSettingsRow { HotKeyRecorder(title: "窗口截图", spec: $settings.windowHotKey) }
                    Divider(); FewerSettingsRow { HotKeyRecorder(title: "全屏截图", spec: $settings.fullscreenHotKey) }
                    Divider(); FewerSettingsRow { HotKeyRecorder(title: "截图翻译", spec: $settings.ocrTranslateHotKey) }
                }
            }.padding(.bottom, 24)
        }
        .onAppear {
            settings = store.load()
            refreshScreenCapturePermission()
            loadAIConfiguration()
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
        .onDisappear {
            aiAPIKey = ""
        }
        .alert("清除 AI 翻译配置？", isPresented: $showsClearAIConfigurationConfirmation) {
            Button("取消", role: .cancel) {}
            Button("清除", role: .destructive) {
                clearAIConfiguration()
            }
        } message: {
            Text("将删除服务地址、模型和保存在钥匙串中的 API 密钥。")
        }
    }

    private func reconcileKeycastShortcutConflict() {
        let inputStore = InputEnhancementStore(access: .mainAppWriter)
        var inputSettings = inputStore.load()
        guard let shortcut = inputSettings.keycast.toggleShortcut else { return }
        let reserved = settings.shortcutsEnabled
            ? [settings.regionHotKey, settings.windowHotKey, settings.fullscreenHotKey, settings.ocrTranslateHotKey].map(InputShortcut.init)
            : []
        guard !InputShortcutSafety.isAllowedGlobalToggle(shortcut, additionalReserved: reserved) else { return }
        inputSettings.keycast.toggleShortcut = nil
        try? inputStore.save(inputSettings)
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

    private var hasAIConfiguration: Bool {
        !aiEndpoint.isEmpty || !aiModel.isEmpty
    }

    private func loadAIConfiguration() {
        guard let configuration = AITranslationSettingsStore().loadConfiguration() else { return }
        aiEndpoint = configuration.endpoint.absoluteString
        aiModel = configuration.model
        aiConfigurationMessage = "已配置；重新保存远程服务时需要再次输入 API 密钥。"
    }

    private func saveAndTestAIConfiguration() {
        let draft = AITranslationConfigurationDraft(
            endpoint: aiEndpoint,
            model: aiModel,
            apiKey: aiAPIKey
        )
        isTestingAIConfiguration = true
        aiConfigurationMessage = nil
        Task {
            do {
                try await aiConfigurationService.testAndSave(draft)
                guard !Task.isCancelled else { return }
                aiAPIKey = ""
                aiConfigurationMessage = "AI 翻译服务已保存。"
            } catch {
                guard !Task.isCancelled else { return }
                aiConfigurationMessage = error.localizedDescription
            }
            isTestingAIConfiguration = false
        }
    }

    private func clearAIConfiguration() {
        isTestingAIConfiguration = true
        aiConfigurationMessage = nil
        Task {
            do {
                try await aiConfigurationService.clear()
                guard !Task.isCancelled else { return }
                aiEndpoint = ""
                aiModel = ""
                aiAPIKey = ""
                aiConfigurationMessage = "AI 翻译配置已清除。"
            } catch {
                guard !Task.isCancelled else { return }
                aiConfigurationMessage = error.localizedDescription
            }
            isTestingAIConfiguration = false
        }
    }
}

/// 快捷键录制行：点击后等待下一次按键组合，Esc 取消。
struct HotKeyRecorder: View {
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
