import AppKit
import FewerCore
import SwiftUI

/// 权限与扩展设置页：集中展示需要授权的进程、授权状态与下一步动作。
/// 状态刷新由窗口激活、授权动作完成和手动按钮触发，不在 MainActor 上轮询 pluginkit。
struct PermissionsSettingsView: View {
    @State private var helperStatus = PermissionService.shortcutHelperStatus
    @State private var hasScreenCapturePermission = ScreenshotCapture.hasPermission
    @State private var calendarState = SystemCalendarService.shared.authorizationState
    @State private var extensionStatus: ExtensionStatus = .unknown
    @State private var isRefreshingExtension = false
    @State private var finderMenuDiagnostic: FinderMenuDiagnostic?
    @State private var showingFinderRestartAlert = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                group("Fewer 主应用") {
                    row(screenRecordingRow)
                    Divider()
                    row(calendarRemindersRow)
                }
                group("FewerShortcutHelper") {
                    row(accessibilityRow)
                    Divider()
                    row(inputMonitoringRow)
                    Divider()
                    eventTapDiagnosticRow
                }
                group("Finder 扩展") {
                    row(finderExtensionRow)
                    if extensionStatus != .enabled {
                        Divider()
                        manualPathRow
                    }
                    if let diagnostic = finderMenuDiagnostic {
                        Divider()
                        finderDiagnosticRow(diagnostic)
                    }
                    if extensionStatus == .enabled {
                        Divider()
                        finderRestartRow
                    }
                }
                Button("重新检测全部") { refresh() }
                    .controlSize(.regular)
                    .padding(.top, 4)
            }
            .padding(.bottom, 24)
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    // MARK: - Rows

    private var screenRecordingRow: PermissionRow {
        PermissionRow(
            kind: .screenRecording,
            title: "屏幕录制",
            purpose: "截图与滚动截图功能所需",
            principal: "Fewer",
            status: hasScreenCapturePermission ? .authorized : .notAuthorized
        )
    }

    private var calendarRemindersRow: PermissionRow {
        let authorized = calendarState == .fullAccess
        return PermissionRow(
            kind: .calendarReminders,
            title: "日历与提醒事项",
            purpose: "日历模块读取日程与提醒",
            principal: "Fewer",
            status: authorized ? .authorized : .notAuthorized
        )
    }

    private var accessibilityRow: PermissionRow {
        PermissionRow(
            kind: .accessibility,
            title: "辅助功能",
            purpose: "全局快捷键与鼠标手势所需",
            principal: "FewerShortcutHelper",
            status: helperRowStatus(trusted: helperStatus.isAccessibilityTrusted)
        )
    }

    private var inputMonitoringRow: PermissionRow {
        PermissionRow(
            kind: .inputMonitoring,
            title: "输入监控",
            purpose: "鼠标滚轮增强与手势识别所需",
            principal: "FewerShortcutHelper",
            status: helperRowStatus(trusted: helperStatus.isInputMonitoringTrusted)
        )
    }

    private var finderExtensionRow: PermissionRow {
        PermissionRow(
            kind: .finderExtension,
            title: "Finder 扩展",
            purpose: "右键菜单文件操作功能",
            principal: "Finder 扩展",
            status: extensionRowStatus
        )
    }

    private func helperRowStatus(trusted: Bool) -> PermissionRow.Status {
        helperStatus.isFresh() ? (trusted ? .authorized : .notAuthorized) : .helperNotRunning
    }

    private var extensionRowStatus: PermissionRow.Status {
        switch extensionStatus {
        case .enabled: .authorized
        case .notEnabled: .notEnabled
        case .unknown: .unknown
        }
    }

    // MARK: - Row rendering

    @ViewBuilder
    private func row(_ model: PermissionRow) -> some View {
        FewerSettingsRow {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title).font(.body)
                Text(model.purpose).font(.caption).foregroundStyle(.secondary)
                Text(model.principal).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            statusBadge(model.status)
            actionButtons(model)
        }
    }

    @ViewBuilder
    private var eventTapDiagnosticRow: some View {
        FewerSettingsRow {
            VStack(alignment: .leading, spacing: 2) {
                Text("Event Tap 运行状态").font(.body)
                Text("输入监听是否实际生效（运行时诊断）").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            let active = helperStatus.isFresh() && helperStatus.isEventTapActive
            Text(active ? "运行中" : (helperStatus.isFresh() ? "未激活" : "助手未运行"))
                .font(.caption.weight(.medium))
                .foregroundStyle(active ? .green : .secondary)
        }
    }

    @ViewBuilder
    private var manualPathRow: some View {
        FewerSettingsRow {
            VStack(alignment: .leading, spacing: 2) {
                Text("手动启用路径").font(.caption.weight(.medium))
                Text("系统设置 → 隐私与安全性 → 扩展 → Finder 扩展").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func finderDiagnosticRow(_ diagnostic: FinderMenuDiagnostic) -> some View {
        FewerSettingsRow {
            VStack(alignment: .leading, spacing: 4) {
                Text("扩展诊断").font(.caption.weight(.medium))
                Text("构建：\(diagnostic.buildVersion) (\(diagnostic.buildNumber))\(buildMismatchSuffix(diagnostic))")
                    .font(.caption2).foregroundStyle(.secondary)
                Text("最近启动：\(formatRelative(diagnostic.lastExtensionLaunch))")
                    .font(.caption2).foregroundStyle(.secondary)
                if let request = diagnostic.lastMenuRequest {
                    Text("最近菜单请求：\(formatRelative(request)) — \(menuRequestSummary(diagnostic))")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("尚无菜单请求（扩展已启动但未收到右键调用）")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var finderRestartRow: some View {
        FewerSettingsRow {
            VStack(alignment: .leading, spacing: 2) {
                Text("Finder 未显示菜单？").font(.caption.weight(.medium))
                Text("扩展已启用但菜单不出现时可尝试重启 Finder").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button("重启 Finder") {
                showingFinderRestartAlert = true
            }.controlSize(.small)
        }
        .alert("确认重启 Finder", isPresented: $showingFinderRestartAlert) {
            Button("重启 Finder", role: .destructive) { restartFinder() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("Finder 将关闭并重新打开。未保存的 Finder 操作可能丢失。")
        }
    }

    private func menuRequestSummary(_ diagnostic: FinderMenuDiagnostic) -> String {
        if diagnostic.lastRequestSucceeded {
            return "成功（\(diagnostic.lastEntryCount) 项）"
        } else if let reason = diagnostic.lastReason {
            return reason.displayDescription
        } else {
            return "未知"
        }
    }

    private func buildMismatchSuffix(_ diagnostic: FinderMenuDiagnostic) -> String {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
        let appBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"
        if diagnostic.buildVersion != appVersion || diagnostic.buildNumber != appBuild {
            return " — 与主应用不匹配（可能为旧构建）"
        } else {
            return ""
        }
    }

    private func formatRelative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func restartFinder() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Finder"]
        try? process.run()
        Task { try? await Task.sleep(for: .seconds(2)); refresh() }
    }

    private func statusBadge(_ status: PermissionRow.Status) -> some View {
        let text: String
        let color: Color
        switch status {
        case .authorized:
            text = "已授权"; color = .green
        case .notAuthorized:
            text = "未授权"; color = .orange
        case .unknown:
            text = "无法确认"; color = .secondary
        case .helperNotRunning:
            text = "助手未运行"; color = .orange
        case .notEnabled:
            text = "未启用"; color = .orange
        }
        return Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
    }

    // MARK: - Action buttons

    @ViewBuilder
    private func actionButtons(_ model: PermissionRow) -> some View {
        HStack(spacing: 8) {
            switch model.status {
            case .authorized:
                Button("重新检测") { refresh() }.controlSize(.small)
            case .notAuthorized:
                if let request = requestAction(for: model.kind) {
                    Button("请求授权", action: request).controlSize(.small)
                }
                Button("打开系统设置") { openSystemSettings(for: model.kind) }.controlSize(.small)
            case .unknown:
                Button("重新检测") { refresh() }.controlSize(.small)
                Button("打开系统设置") { openSystemSettings(for: model.kind) }.controlSize(.small)
            case .helperNotRunning:
                Button("启动助手") {
                    PermissionService.launchShortcutHelper()
                    Task { try? await Task.sleep(for: .seconds(1)); refresh() }
                }.controlSize(.small)
                Button("打开系统设置") { openSystemSettings(for: model.kind) }.controlSize(.small)
            case .notEnabled:
                Button("打开扩展设置") { openExtensionsSettings() }.controlSize(.small)
            }
        }
    }

    /// 返回可编程请求的闭包；无法编程请求的权限返回 nil。
    private func requestAction(for kind: PermissionRow.Kind) -> (() -> Void)? {
        switch kind {
        case .accessibility:
            { PermissionService.requestAccessibility(); scheduleRefresh() }
        case .screenRecording:
            { _ = ScreenshotCapture.requestPermission(); scheduleRefresh() }
        case .calendarReminders:
            { Task { await SystemCalendarService.shared.requestFullAccess(); refresh() } }
        case .inputMonitoring:
            // 输入监控权限归属于 FewerShortcutHelper 进程，主应用无法代为请求。
            // 用户需在系统设置中手动为 FewerShortcutHelper 开启。
            nil
        case .finderExtension:
            // Finder 扩展启用是系统扩展开关，非 TCC 授权，无法编程请求。
            nil
        }
    }

    private func openSystemSettings(for kind: PermissionRow.Kind) {
        switch kind {
        case .accessibility:
            PermissionService.openAccessibilitySettings()
        case .inputMonitoring:
            PermissionService.openInputMonitoringSettings()
        case .screenRecording:
            ScreenshotCapture.openPermissionSettings()
        case .calendarReminders:
            SystemCalendarService.shared.openPrivacySettings()
        case .finderExtension:
            openExtensionsSettings()
        }
    }

    private func openExtensionsSettings() {
        // macOS 不提供直达 Finder 扩展列表的可靠深链接，打开扩展面板作为最近落点。
        if let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Refresh

    private func refresh() {
        helperStatus = PermissionService.shortcutHelperStatus
        hasScreenCapturePermission = ScreenshotCapture.hasPermission
        calendarState = SystemCalendarService.shared.authorizationState
        finderMenuDiagnostic = ExtensionStatusService.finderMenuDiagnostic()
        refreshExtensionStatus()
    }

    private func scheduleRefresh() {
        Task { try? await Task.sleep(for: .seconds(0.5)); refresh() }
    }

    private func refreshExtensionStatus() {
        guard !isRefreshingExtension else { return }
        isRefreshingExtension = true
        Task {
            let status = await ExtensionStatusService.cachedStatus()
            if !Task.isCancelled { extensionStatus = status }
            isRefreshingExtension = false
        }
    }

    // MARK: - Layout

    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            FewerSettingsRow {
                Text(title).font(.headline)
                Spacer()
            }
            Divider()
            content()
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color(nsColor: .separatorColor)))
    }
}
