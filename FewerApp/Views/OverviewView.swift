import FinderSync
import FewerCore
import SwiftUI

struct OverviewView: View {
    @ObservedObject var model: SettingsViewModel
    @State private var extensionStatus: ExtensionStatus = .unknown
    @State private var helperStatus = PermissionService.shortcutHelperStatus

    private var authorizationStatusText: String {
        if helperStatus.isAccessibilityTrusted {
            return helperStatus.isFresh() ? "已授权" : "已授权（助手未运行）"
        }
        return helperStatus.isFresh() ? "未授权" : "等待助手启动"
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("More tools. Fewer apps.")
                        .font(.title2.weight(.semibold))
                    Text("第一版为 Finder 增加新建文件、复制路径、剪切与粘贴。")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }

            Section("组件状态") {
                LabeledContent("Finder 右键扩展", value: extensionStatus.title)
                LabeledContent("快捷键辅助功能", value: authorizationStatusText)
            }

            Section {
                Button("管理 Finder 扩展") {
                    FIFinderSyncController.showExtensionManagementInterface()
                }
                Button("请求辅助功能权限") {
                    PermissionService.requestAccessibility()
                    refresh()
                }
                Button("打开辅助功能设置") {
                    PermissionService.openAccessibilitySettings()
                }
            } footer: {
                Text("未授予辅助功能权限时，右键菜单仍可使用；Command-X 与 Command-V 不会生效。")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("概览")
        .task {
            if model.settings.shortcutHelperEnabled {
                PermissionService.launchShortcutHelper()
            }
            while !Task.isCancelled {
                if model.settings.shortcutHelperEnabled {
                    PermissionService.ensureShortcutHelperRunning()
                }
                refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func refresh() {
        extensionStatus = ExtensionStatusService.finderExtensionStatus()
        helperStatus = PermissionService.shortcutHelperStatus
    }
}
