import FinderSync
import SwiftUI

struct OverviewView: View {
    @State private var extensionStatus: ExtensionStatus = .unknown
    @State private var accessibilityTrusted = PermissionService.isAccessibilityTrusted

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
                LabeledContent("快捷键辅助功能", value: accessibilityTrusted ? "已授权" : "未授权")
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
        .task { refresh() }
    }

    private func refresh() {
        extensionStatus = ExtensionStatusService.finderExtensionStatus()
        accessibilityTrusted = PermissionService.isAccessibilityTrusted
    }
}
