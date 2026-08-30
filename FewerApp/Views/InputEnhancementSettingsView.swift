import FewerCore
import SwiftUI
import UniformTypeIdentifiers

struct InputEnhancementSettingsView: View {
    private enum Tab: String, CaseIterable, Identifiable {
        case scroll = "滚动"
        case applications = "应用规则"
        case gestures = "鼠标手势"
        case keycast = "按键展示"
        case diagnostics = "诊断"
        var id: String { rawValue }
    }

    @ObservedObject private var model = InputEnhancementViewModel.shared
    @State private var tab: Tab = .scroll
    @State private var temporaryAllKeys = false
    @State private var isPositioningKeycast = false
    var onOpenPermissions: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            ScrollView {
                Group {
                    switch tab {
                    case .scroll: prototypeScroll
                    case .applications: prototypeApplications
                    case .gestures: prototypeGestures
                    case .keycast: prototypeKeycast
                    case .diagnostics: prototypeDiagnostics
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .disabled(model.isLoading)
        .alert("Fewer", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("好") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onDisappear {
            isPositioningKeycast = false
            model.setKeycastPositioning(false)
            model.stopRefreshing()
            model.flushPendingSave()
        }
        .task { await model.startRefreshing() }
    }

    private var prototypeScroll: some View {
        VStack(spacing: 16) {
            FewerSettingsCard {
                FewerSettingsRow { settingToggle("平滑滚动", "模拟触控板惯性滚动", binding(\.scroll.isEnabled)) }
                Divider()
                FewerSettingsRow { settingToggle("反转方向", "自然滚动方向开关", binding(\.scroll.vertical.reversed)) }
                Divider()
                FewerSettingsRow { sliderRow("最小步长", "每次滚动最小像素位移", debouncedBinding(\.scroll.vertical.minimumStep), 0...24, "%.0f") }
                Divider()
                FewerSettingsRow { sliderRow("速度增益", "滚动加速度倍数", debouncedBinding(\.scroll.vertical.speedGain), 0.25...8, "%.2f×") }
                Divider()
                FewerSettingsRow { sliderRow("响应时长", "惯性减速持续时间", debouncedBinding(\.scroll.vertical.response), 0.05...0.8, "%.2fs") }
            }
            prototypeNotice("水平轴与模拟触控板等高级选项保留在现有输入设置中。")
        }.padding(.bottom, 24)
    }

    private var prototypeGestures: some View {
        VStack(spacing: 16) {
            FewerSettingsCard {
                FewerSettingsRow { settingToggle("鼠标手势", "按住右键拖出方向触发动作", gestureMasterBinding) }
                Divider()
                FewerSettingsRow {
                    VStack(alignment: .leading, spacing: 2) { Text("触发按键"); Text("当前规则使用的触发按键").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Picker("", selection: firstGestureButtonBinding) {
                        Text("右键").tag(Int64(1)); Text("中键").tag(Int64(2)); Text("侧键 1").tag(Int64(3)); Text("侧键 2").tag(Int64(4))
                    }.labelsHidden().frame(width: 110)
                }
                Divider()
                FewerSettingsRow {
                    VStack(alignment: .leading, spacing: 2) { Text("排除应用列表"); Text("\(model.settings.gestureExcludedBundleIdentifiers.count) 个应用已排除").font(.caption).foregroundStyle(.secondary) }
                    Spacer(); Button("管理") { chooseExcludedApplication(forKeycast: false) }
                }
            }
            gestureRules
        }.padding(.bottom, 24)
    }

    private var prototypeKeycast: some View {
        VStack(spacing: 16) {
            FewerSettingsCard {
                FewerSettingsRow { settingToggle("按键展示", "屏幕浮动显示按键与组合键", binding(\.keycast.isEnabled)) }
                Divider()
                FewerSettingsRow { settingToggle("显示鼠标点击", "同时显示鼠标点击操作", binding(\.keycast.showsMouseClicks)) }
                Divider()
                FewerSettingsRow {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("展示位置")
                        Text("按键浮层会显示在鼠标所在屏幕").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("", selection: binding(\.keycast.position)) {
                        ForEach(KeycastOverlayPosition.allCases, id: \.self) { position in
                            Text(position.title).tag(position)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }
                if model.settings.keycast.position == .custom {
                    Divider()
                    FewerSettingsRow {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("自定义位置")
                            Text("拖动浮层后将按屏幕可见区域保存").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("拖动调整") {
                            isPositioningKeycast = true
                            model.setKeycastPositioning(true)
                        }
                    }
                }
                Divider()
                FewerSettingsRow {
                    VStack(alignment: .leading, spacing: 2) { Text("排除应用列表"); Text("\(model.settings.keycast.excludedBundleIdentifiers.count) 个应用已排除").font(.caption).foregroundStyle(.secondary) }
                    Spacer(); Button("管理") { chooseExcludedApplication(forKeycast: true) }
                }
            }
            prototypeNotice("展示位置、快捷键与样式等高级设置保留在本页高级设置中。")
        }.padding(.bottom, 24)
    }

    private var prototypeApplications: some View {
        VStack(spacing: 16) {
            FewerSettingsCard {
                FewerSettingsRow { Text("按应用覆盖规则").fontWeight(.semibold); Spacer(); Button("+ 添加规则") { chooseScrollApplication() } }
                ForEach(Array(model.settings.applicationOverrides.enumerated()), id: \.element.id) { index, rule in
                    Divider()
                    FewerSettingsRow {
                        VStack(alignment: .leading, spacing: 2) { Text(rule.displayName); Text(rule.mode == .bypass ? "完全绕过增强" : "自定义滚动参数").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Picker("", selection: applicationModeBinding(index)) {
                            Text("继承全局").tag(ApplicationScrollMode.inherit); Text("自定义").tag(ApplicationScrollMode.override); Text("完全绕过").tag(ApplicationScrollMode.bypass)
                        }.labelsHidden().frame(width: 110)
                    }
                }
                if model.settings.applicationOverrides.isEmpty {
                    Divider(); FewerSettingsRow { Text("尚无应用覆盖规则").foregroundStyle(.secondary) }
                }
            }
        }.padding(.bottom, 24)
    }

    private var prototypeDiagnostics: some View {
        VStack(spacing: 16) {
            FewerSettingsCard {
                FewerSettingsRow { diagnosticRow("辅助功能权限", model.helperStatus.isAccessibilityTrusted, model.helperStatus.isAccessibilityTrusted ? "已授权" : "未授权") }
                Divider()
                FewerSettingsRow { diagnosticRow("输入监控权限", model.helperStatus.isInputMonitoringTrusted, model.helperStatus.isInputMonitoringTrusted ? "已授权" : "未授权") }
                Divider()
                FewerSettingsRow { diagnosticRow("鼠标设备", model.helperStatus.detectedScrollDevice != nil, deviceTitle(model.helperStatus.detectedScrollDevice)) }
                Divider()
                FewerSettingsRow { diagnosticRow("触控板", model.helperStatus.detectedScrollDevice == .trackpad, model.helperStatus.detectedScrollDevice == .trackpad ? "已检测到" : "未检测到") }
            }
            if let onOpenPermissions {
                FewerSettingsCard {
                    FewerSettingsRow {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("权限与扩展")
                            Text("集中管理所有授权状态与操作入口").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("前往") { onOpenPermissions() }
                    }
                }
            }
        }
        .padding(.bottom, 24)
    }

    private func settingToggle(_ title: String, _ detail: String, _ value: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) { Text(title); Text(detail).font(.caption).foregroundStyle(.secondary) }
            Spacer(); Toggle("", isOn: value).labelsHidden()
        }
    }

    private func sliderRow(_ title: String, _ detail: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, _ format: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) { Text(title); Text(detail).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Slider(value: value, in: range).frame(width: 100)
            TextField("", value: value, format: .number)
                .frame(width: 50)
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
                .onChange(of: value.wrappedValue) { _, new in
                    if new < range.lowerBound || new > range.upperBound {
                        value.wrappedValue = min(max(new, range.lowerBound), range.upperBound)
                    }
                }
        }
    }

    private func diagnosticRow(_ title: String, _ okay: Bool, _ detail: String) -> some View {
        HStack {
            Circle().fill(okay ? .green : .orange).frame(width: 7, height: 7)
            Text(title); Spacer(); Text(detail).font(.caption).foregroundStyle(okay ? .green : .orange)
        }
    }

    private func prototypeNotice(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var scrollSettings: some View {
        Form {
            Toggle("启用鼠标滚动增强", isOn: binding(\.scroll.isEnabled))
            if model.settings.emergencyDisabled {
                LabeledContent("紧急停用") {
                    Button("重新启用") { model.clearEmergencyStop() }
                }
            }
            Section("垂直轴") {
                Toggle("平滑滚动", isOn: binding(\.scroll.vertical.smoothEnabled))
                Toggle("反转方向", isOn: binding(\.scroll.vertical.reversed))
                slider("最小步长", value: binding(\.scroll.vertical.minimumStep), range: 0...24, format: "%.0f")
                slider("速度增益", value: binding(\.scroll.vertical.speedGain), range: 0.25...8, format: "%.2f×")
                slider("响应时长", value: binding(\.scroll.vertical.response), range: 0.05...0.8, format: "%.2fs")
            }
            Section("水平轴") {
                Toggle("平滑滚动", isOn: binding(\.scroll.horizontal.smoothEnabled))
                Toggle("反转方向", isOn: binding(\.scroll.horizontal.reversed))
                slider("最小步长", value: binding(\.scroll.horizontal.minimumStep), range: 0...24, format: "%.0f")
                slider("速度增益", value: binding(\.scroll.horizontal.speedGain), range: 0.25...8, format: "%.2f×")
                slider("响应时长", value: binding(\.scroll.horizontal.response), range: 0.05...0.8, format: "%.2fs")
            }
            Toggle("模拟触控板滚动阶段", isOn: binding(\.scroll.simulatesTrackpad))
            Text("触控板及带正常 phase/momentum 的事件始终保持系统原样。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private var applicationRules: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("按前台应用覆盖全局滚动设置").foregroundStyle(.secondary)
                Spacer()
                Button("选择应用…", systemImage: "plus") { chooseScrollApplication() }
            }
            ForEach(Array(model.settings.applicationOverrides.enumerated()), id: \.element.id) { index, rule in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "app")
                        VStack(alignment: .leading) {
                            Text(rule.displayName)
                            Text(rule.bundleIdentifier).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("模式", selection: applicationModeBinding(index)) {
                            Text("继承全局").tag(ApplicationScrollMode.inherit)
                            Text("自定义").tag(ApplicationScrollMode.override)
                            Text("完全绕过").tag(ApplicationScrollMode.bypass)
                        }
                        .frame(width: 150)
                        Button(role: .destructive) {
                            model.settings.applicationOverrides.remove(at: index)
                            model.save()
                        } label: { Image(systemName: "trash") }
                    }
                    if rule.mode == .override {
                        HStack {
                            Toggle("垂直平滑", isOn: applicationScrollBinding(index, \.vertical.smoothEnabled))
                            Toggle("垂直反转", isOn: applicationScrollBinding(index, \.vertical.reversed))
                            Toggle("水平平滑", isOn: applicationScrollBinding(index, \.horizontal.smoothEnabled))
                            Toggle("水平反转", isOn: applicationScrollBinding(index, \.horizontal.reversed))
                        }
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                            GridRow {
                                Text("垂直轴")
                                compactAxisSliders(index, axis: .vertical)
                            }
                            GridRow {
                                Text("水平轴")
                                compactAxisSliders(index, axis: .horizontal)
                            }
                        }
                    }
                }
                .padding(12)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var gestureRules: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("按住右键或侧键并拖出方向轨迹").foregroundStyle(.secondary)
                Spacer()
                Button("添加规则", systemImage: "plus") { model.addGestureRule() }
            }
            Text("使用右键会暂存点击；未达到识别阈值时会在原位置重放右键菜单。")
                .font(.caption).foregroundStyle(.orange)
            exclusionEditor(
                title: "手势排除应用",
                values: model.settings.gestureExcludedBundleIdentifiers,
                add: { chooseExcludedApplication(forKeycast: false) },
                remove: { model.settings.gestureExcludedBundleIdentifiers.remove($0); model.save() }
            )
            ForEach(model.settings.gestureRules) { rule in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Toggle("", isOn: gestureEnabledBinding(rule.id)).labelsHidden()
                        Picker("触发键", selection: gestureButtonBinding(rule.id)) {
                            Text("右键").tag(Int64(1))
                            Text("中键").tag(Int64(2))
                            Text("侧键 1").tag(Int64(3))
                            Text("侧键 2").tag(Int64(4))
                        }.frame(width: 110)
                        GestureRuleRecorder(directions: gestureDirectionsBinding(rule.id))
                        Spacer()
                        Button(role: .destructive) {
                            model.settings.gestureRules.removeAll { $0.id == rule.id }
                            model.save()
                        } label: { Image(systemName: "trash") }
                    }
                    HStack(spacing: 12) {
                        Picker("动作", selection: gestureActionBinding(rule.id)) {
                            Text("后退").tag(InputAction.mouseBack)
                            Text("前进").tag(InputAction.mouseForward)
                            Text("Mission Control").tag(InputAction.missionControl)
                            Text("显示桌面").tag(InputAction.showDesktop)
                            Text("左侧空间").tag(InputAction.spaceLeft)
                            Text("右侧空间").tag(InputAction.spaceRight)
                            Text("关闭标签").tag(InputAction.closeTab)
                            Text("新建标签").tag(InputAction.newTab)
                            Text("刷新").tag(InputAction.reload)
                        Text("滚动到顶").tag(InputAction.scrollToTop)
                        Text("滚动到底").tag(InputAction.scrollToBottom)
                        Text("最小化窗口").tag(InputAction.minimizeWindow)
                        Text("最大化窗口").tag(InputAction.zoomWindow)
                        }.frame(minWidth: 150)
                        TextField("Bundle ID（留空为全局）", text: gestureBundleBinding(rule.id))
                            .frame(maxWidth: 240)
                        Spacer()
                    }
                }
                .padding(12)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var keycastSettings: some View {
        Form {
            Toggle("启用按键展示", isOn: binding(\.keycast.isEnabled))
            Toggle("显示鼠标点击", isOn: binding(\.keycast.showsMouseClicks))
            Toggle("本次临时显示全部按键", isOn: $temporaryAllKeys)
                .onChange(of: temporaryAllKeys) { _, enabled in model.setTemporaryAllKeys(enabled) }
            InputShortcutRecorder(
                title: "全局展示开关",
                shortcut: binding(\.keycast.toggleShortcut),
                additionalReserved: screenshotShortcuts
            )
            Toggle("调整浮层位置", isOn: $isPositioningKeycast)
                .onChange(of: isPositioningKeycast) { _, enabled in model.setKeycastPositioning(enabled) }
            slider("透明度", value: binding(\.keycast.opacity), range: 0.2...1, format: "%.0f%%", multiplier: 100)
            slider("字号", value: binding(\.keycast.fontSize), range: 12...64, format: "%.0fpt")
            slider("停留时间", value: binding(\.keycast.displayDuration), range: 0.5...8, format: "%.1fs")
            Stepper("最近事件数量：\(model.settings.keycast.maximumVisibleEvents)", value: binding(\.keycast.maximumVisibleEvents), in: 1...10)
            exclusionEditor(
                title: "按键展示排除应用",
                values: model.settings.keycast.excludedBundleIdentifiers,
                add: { chooseExcludedApplication(forKeycast: true) },
                remove: { model.settings.keycast.excludedBundleIdentifiers.remove($0); model.save() }
            )
            Text("普通字符默认不展示；原始按键、应用和点击位置不会写入日志、磁盘或网络。")
                .font(.caption).foregroundStyle(.secondary)
        }.formStyle(.grouped)
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 14) {
            statusRow("Helper", ok: model.helperStatus.isFresh(), detail: model.helperStatus.isFresh() ? "运行中" : "未运行")
            statusRow("辅助功能", ok: model.helperStatus.isAccessibilityTrusted, detail: model.helperStatus.isAccessibilityTrusted ? "已授权" : "需要授权")
            statusRow("输入监控", ok: model.helperStatus.isInputMonitoringTrusted, detail: model.helperStatus.isInputMonitoringTrusted ? "已授权" : "需要授权")
            statusRow("Event Tap", ok: model.helperStatus.isEventTapActive, detail: model.helperStatus.isEventTapActive ? "正常" : "未激活")
            statusRow("识别设备", ok: true, detail: deviceTitle(model.helperStatus.detectedScrollDevice))
            if let error = model.helperStatus.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            HStack {
                Button("请求辅助功能权限") { PermissionService.requestAccessibility() }
                Button("打开辅助功能设置") { PermissionService.openAccessibilitySettings() }
                Button("打开输入监控设置") { PermissionService.openInputMonitoringSettings() }
            }
            Text("紧急停用：⌃⌥⌘Esc。触发后滚动增强与鼠标手势立即关闭。")
                .font(.callout.bold()).foregroundStyle(.orange)
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<InputEnhancementSettings, Value>) -> Binding<Value> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { model.settings[keyPath: keyPath] = $0; model.save() }
        )
    }

    private func debouncedBinding<Value>(_ keyPath: WritableKeyPath<InputEnhancementSettings, Value>) -> Binding<Value> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { model.settings[keyPath: keyPath] = $0; model.scheduleSave() }
        )
    }

    private var gestureMasterBinding: Binding<Bool> {
        Binding(
            get: { model.settings.gestureRules.contains(where: \.isEnabled) },
            set: { enabled in
                if model.settings.gestureRules.isEmpty, enabled {
                    model.settings.gestureRules = MouseGesturePresets.defaultRules
                } else {
                    for index in model.settings.gestureRules.indices {
                        model.settings.gestureRules[index].isEnabled = enabled
                    }
                }
                model.save()
            }
        )
    }

    private var firstGestureButtonBinding: Binding<Int64> {
        Binding(
            get: { model.settings.gestureRules.first?.triggerButton ?? 1 },
            set: { button in
                if model.settings.gestureRules.isEmpty {
                    model.settings.gestureRules = MouseGesturePresets.defaultRules
                }
                for index in model.settings.gestureRules.indices {
                    model.settings.gestureRules[index].triggerButton = button
                }
                model.save()
            }
        )
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, format: String, multiplier: Double = 1) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range).frame(width: 220)
                Text(String(format: format, value.wrappedValue * multiplier)).monospacedDigit().frame(width: 60, alignment: .trailing)
            }
        }
    }

    private func applicationModeBinding(_ index: Int) -> Binding<ApplicationScrollMode> {
        Binding(get: { model.settings.applicationOverrides[index].mode }, set: {
            model.settings.applicationOverrides[index].mode = $0
            if $0 == .override { model.settings.applicationOverrides[index].settings.isEnabled = true }
            model.save()
        })
    }

    private func applicationScrollBinding<Value>(
        _ index: Int,
        _ keyPath: WritableKeyPath<ScrollEnhancementSettings, Value>
    ) -> Binding<Value> {
        Binding(
            get: { model.settings.applicationOverrides[index].settings[keyPath: keyPath] },
            set: {
                model.settings.applicationOverrides[index].settings[keyPath: keyPath] = $0
                model.save()
            }
        )
    }

    private enum Axis { case vertical, horizontal }

    private func compactAxisSliders(_ index: Int, axis: Axis) -> some View {
        let step = axis == .vertical
            ? debouncedApplicationScrollBinding(index, \.vertical.minimumStep)
            : debouncedApplicationScrollBinding(index, \.horizontal.minimumStep)
        let gain = axis == .vertical
            ? debouncedApplicationScrollBinding(index, \.vertical.speedGain)
            : debouncedApplicationScrollBinding(index, \.horizontal.speedGain)
        let response = axis == .vertical
            ? debouncedApplicationScrollBinding(index, \.vertical.response)
            : debouncedApplicationScrollBinding(index, \.horizontal.response)
        return HStack {
            Text("步长").font(.caption); Slider(value: step, in: 0...24).frame(width: 80)
            Text("增益").font(.caption); Slider(value: gain, in: 0.25...8).frame(width: 80)
            Text("响应").font(.caption); Slider(value: response, in: 0.05...0.8).frame(width: 80)
        }
    }

    private func debouncedApplicationScrollBinding<Value>(
        _ index: Int,
        _ keyPath: WritableKeyPath<ScrollEnhancementSettings, Value>
    ) -> Binding<Value> {
        Binding(
            get: { model.settings.applicationOverrides[index].settings[keyPath: keyPath] },
            set: {
                model.settings.applicationOverrides[index].settings[keyPath: keyPath] = $0
                model.scheduleSave()
            }
        )
    }

    private func gestureEnabledBinding(_ id: UUID) -> Binding<Bool> {
        Binding(get: {
            model.settings.gestureRules.first(where: { $0.id == id })?.isEnabled ?? false
        }, set: {
            guard let index = model.settings.gestureRules.firstIndex(where: { $0.id == id }) else { return }
            model.settings.gestureRules[index].isEnabled = $0
            model.save()
        })
    }

    private func gestureButtonBinding(_ id: UUID) -> Binding<Int64> {
        Binding(get: {
            model.settings.gestureRules.first(where: { $0.id == id })?.triggerButton ?? 1
        }, set: {
            guard let index = model.settings.gestureRules.firstIndex(where: { $0.id == id }) else { return }
            model.settings.gestureRules[index].triggerButton = $0
            model.save()
        })
    }

    private func gestureDirectionsBinding(_ id: UUID) -> Binding<[MouseGestureDirection]> {
        Binding(get: {
            model.settings.gestureRules.first(where: { $0.id == id })?.directions ?? []
        }, set: {
            guard let index = model.settings.gestureRules.firstIndex(where: { $0.id == id }) else { return }
            model.settings.gestureRules[index].directions = $0
            model.save()
        })
    }

    private func gestureActionBinding(_ id: UUID) -> Binding<InputAction> {
        Binding(get: {
            model.settings.gestureRules.first(where: { $0.id == id })?.action ?? .mouseBack
        }, set: {
            guard let index = model.settings.gestureRules.firstIndex(where: { $0.id == id }) else { return }
            model.settings.gestureRules[index].action = $0
            model.save()
        })
    }

    private func gestureBundleBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { model.settings.gestureRules.first(where: { $0.id == id })?.bundleIdentifier ?? "" },
            set: {
                guard let index = model.settings.gestureRules.firstIndex(where: { $0.id == id }) else { return }
                let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                model.settings.gestureRules[index].bundleIdentifier = value.isEmpty ? nil : value
                model.scheduleSave()
            }
        )
    }

    private func exclusionEditor(
        title: String,
        values: Set<String>,
        add: @escaping () -> Void,
        remove: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text(title).font(.subheadline.bold()); Spacer(); Button("添加…", action: add) }
            ForEach(values.sorted(), id: \.self) { value in
                HStack { Text(value).font(.caption.monospaced()); Spacer(); Button("移除") { remove(value) }.controlSize(.small) }
            }
        }
    }

    private func statusRow(_ title: String, ok: Bool, detail: String) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(ok ? .green : .orange)
            Text(title).frame(width: 110, alignment: .leading)
            Text(detail).foregroundStyle(.secondary)
        }
    }

    private func deviceTitle(_ device: ScrollInputDevice?) -> String {
        switch device {
        case .mouse: "鼠标滚轮"
        case .trackpad: "触控板（已绕过）"
        case nil: "等待滚动事件"
        }
    }

    private func chooseScrollApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { model.addApplication(at: url) }
    }

    private func chooseExcludedApplication(forKeycast: Bool) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundleIdentifier = Bundle(url: url)?.bundleIdentifier
        else { return }
        if forKeycast { model.settings.keycast.excludedBundleIdentifiers.insert(bundleIdentifier) }
        else { model.settings.gestureExcludedBundleIdentifiers.insert(bundleIdentifier) }
        model.save()
    }

    private var screenshotShortcuts: [InputShortcut] {
        let settings = ScreenshotSettingsStore().load()
        guard settings.shortcutsEnabled else { return [] }
        return [settings.regionHotKey, settings.windowHotKey, settings.fullscreenHotKey]
            .map(InputShortcut.init)
    }
}

private struct GestureRuleRecorder: View {
    @Binding var directions: [MouseGestureDirection]
    @State private var recognizer = MouseGestureRecognizer(minimumSegmentLength: 16)
    @State private var isRecording = false
    @State private var dragPoints: [CGPoint] = []

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Canvas { context, size in
                    guard dragPoints.count > 1 else { return }
                    var path = Path()
                    path.move(to: dragPoints[0])
                    for pt in dragPoints.dropFirst() {
                        path.addLine(to: pt)
                    }
                    context.stroke(path, with: .color(.accentColor), lineWidth: 3)
                }
                .frame(width: 120, height: 50)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))

                Text(displayText)
                    .font(.system(size: 13, design: .rounded).monospaced())
                    .foregroundStyle(directions.isEmpty && !isRecording ? .secondary : .primary)
                    .allowsHitTesting(false)
            }
            if !directions.isEmpty || isRecording {
                Button("清除") {
                    directions = []
                    recognizer = MouseGestureRecognizer(minimumSegmentLength: 16)
                    dragPoints = []
                }
                .controlSize(.small)
            }
        }
        .help("在此区域拖动录制方向轨迹")
        .accessibilityLabel("手势轨迹录制器")
        .accessibilityValue(displayText)
        .contentShape(Rectangle())
        .highPriorityGesture(DragGesture(minimumDistance: 0)
            .onChanged { value in
                let point = GesturePoint(x: value.location.x, y: -value.location.y)
                if !isRecording {
                    isRecording = true
                    recognizer.begin(at: point)
                    dragPoints = [value.location]
                } else {
                    _ = recognizer.append(point)
                    dragPoints.append(value.location)
                }
            }
            .onEnded { _ in
                if !recognizer.directions.isEmpty { directions = recognizer.directions }
                isRecording = false
            })
    }

    private var displayText: String {
        let source = isRecording ? recognizer.directions : directions
        return source.isEmpty ? "拖动录制" : source.map(\.symbol).joined()
    }
}

private struct InputShortcutRecorder: View {
    let title: String
    @Binding var shortcut: InputShortcut?
    let additionalReserved: [InputShortcut]
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Button(isRecording ? "按下快捷键…" : displayString) {
                isRecording ? stop() : start()
            }
            if shortcut != nil { Button("清除") { shortcut = nil }.controlSize(.small) }
        }
        .onDisappear { stop() }
    }

    private var displayString: String {
        guard let shortcut else { return "未分配" }
        return KeycastEventFilter.displayString(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers)
    }

    private func start() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if event.keyCode == 53, flags.isEmpty { stop(); return nil }
            guard !flags.isEmpty else { return event }
            var modifiers: ShortcutModifiers = []
            if flags.contains(.command) { modifiers.insert(.command) }
            if flags.contains(.option) { modifiers.insert(.option) }
            if flags.contains(.shift) { modifiers.insert(.shift) }
            if flags.contains(.control) { modifiers.insert(.control) }
            guard !(event.keyCode == 53 && modifiers.contains([.command, .option, .control])) else {
                return nil
            }
            let candidate = InputShortcut(keyCode: event.keyCode, modifiers: modifiers)
            guard InputShortcutSafety.isAllowedGlobalToggle(
                candidate,
                additionalReserved: additionalReserved
            ) else { return nil }
            shortcut = candidate
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        isRecording = false
    }
}

private extension MouseGestureDirection {
    var symbol: String {
        switch self {
        case .up: "↑"
        case .down: "↓"
        case .left: "←"
        case .right: "→"
        case .upRight: "↗"
        case .downRight: "↘"
        case .upLeft: "↖"
        case .downLeft: "↙"
        }
    }
}
