import FewerCore
import SwiftUI

struct ModuleSettingsView: View {
    @ObservedObject private var host = ModuleHost.shared
    private let monitorIDs = SystemMonitorModuleID.allCases
    private let otherIDs = ["calendar", "screenshot", "input", "finder", "system"]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let message = host.modulePreferencesRecoveryMessage {
                    recoveryCard(message)
                }
                statusBarOrderCard
                ForEach(monitorIDs, id: \.self) { monitorID in
                    monitorCard(monitorID)
                }
                ForEach(otherIDs, id: \.self) { moduleID in
                    if let descriptor = host.descriptor(for: moduleID) {
                        standardModuleCard(descriptor)
                    }
                }
            }
            .padding(.bottom, 24)
        }
    }

    private func recoveryCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("模块偏好需要恢复")
                    .fontWeight(.semibold)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("修改任一模块设置即可保存新配置，或恢复默认设置。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("恢复默认") {
                host.restoreDefaultModulePreferences()
            }
        }
        .padding(16)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var statusBarOrderCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            FewerSettingsRow {
                Label("菜单栏顺序", systemImage: "arrow.left.arrow.right")
                    .fontWeight(.semibold)
                Spacer()
            }
            Divider()
            ForEach(Array(host.preferences.statusBarModuleOrder.enumerated()), id: \.element) { index, moduleID in
                if let descriptor = host.descriptor(for: moduleID) {
                    HStack {
                        Label(descriptor.title, systemImage: descriptor.systemImage)
                        Spacer()
                        Button { host.moveStatusBarIcon(moduleID: moduleID, offset: -1) } label: {
                            Image(systemName: "chevron.up")
                        }
                        .buttonStyle(.borderless)
                        .disabled(index == 0)
                        Button { host.moveStatusBarIcon(moduleID: moduleID, offset: 1) } label: {
                            Image(systemName: "chevron.down")
                        }
                        .buttonStyle(.borderless)
                        .disabled(index == host.preferences.statusBarModuleOrder.count - 1)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    if index < host.preferences.statusBarModuleOrder.count - 1 { Divider() }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color(nsColor: .separatorColor)))
    }

    private func monitorCard(_ monitorID: SystemMonitorModuleID) -> some View {
        let id = monitorID.rawValue
        let descriptor = host.descriptor(for: id)
        return VStack(alignment: .leading, spacing: 0) {
            FewerSettingsRow {
                Label(descriptor?.title ?? id, systemImage: descriptor?.systemImage ?? "gauge")
                    .fontWeight(.semibold)
                Spacer()
            }
            Divider()
            moduleRow("启用模块", "采样与弹窗可用", isEnabledBinding(id))
            Divider()
            moduleRow("菜单栏状态项", "在菜单栏独立显示", statusItemBinding(id))
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                MonitorModuleSettingsView(moduleID: monitorID)
            }
            .padding(16)
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color(nsColor: .separatorColor)))
    }

    private func standardModuleCard(_ descriptor: ModuleDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            FewerSettingsRow {
                Label(descriptor.title, systemImage: descriptor.systemImage).fontWeight(.semibold)
                Spacer()
            }
            Divider()
            moduleRow("启用模块", descriptor.summary, isEnabledBinding(descriptor.id))
            if descriptor.id == "calendar" {
                Divider()
                moduleRow("菜单栏独立图标", "点击显示完整日历", statusItemBinding(descriptor.id))
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color(nsColor: .separatorColor)))
    }

    private func isEnabledBinding(_ moduleID: String) -> Binding<Bool> {
        Binding(
            get: { host.preferences.enabledModuleIDs.contains(moduleID) },
            set: { host.setEnabled($0, moduleID: moduleID) }
        )
    }

    private func statusItemBinding(_ moduleID: String) -> Binding<Bool> {
        Binding(
            get: { host.isStatusBarIcon(moduleID: moduleID) },
            set: { host.setStatusBarIcon($0, moduleID: moduleID) }
        )
    }

    private func moduleRow(_ title: String, _ detail: String, _ value: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: value).labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
    }
}

struct AboutSettingsView: View {
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "square.grid.2x2.fill")
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(Color(red: 0, green: 113 / 255, blue: 227 / 255),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.bottom, 12)
            Text("Fewer").font(.system(size: 28, weight: .semibold))
            Text(versionText)
                .font(.system(size: 14)).foregroundStyle(.secondary)
            VStack(spacing: 8) {
                Button("检查更新") { }
                Button("用户手册") { }
                Button("反馈问题") { }
                Button("隐私政策") { }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color(red: 0, green: 113 / 255, blue: 227 / 255))
            .disabled(true)
            .padding(.top, 20)
        }
        .padding(.vertical, 32)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var versionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"
        return "版本 \(version) (Build \(build))"
    }
}
