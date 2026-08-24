import SwiftUI

/// 菜单栏弹窗共用的标题栏和材质外壳。
struct MenuBarPopoverChrome<Content: View>: View {
    let title: String
    let subtitle: String?
    let systemImage: String?
    let openSettings: (() -> Void)?
    let quitAction: (() -> Void)?
    let openActivityMonitor: (() -> Void)?
    @ViewBuilder let content: Content

    init(
        title: String,
        subtitle: String? = nil,
        systemImage: String? = nil,
        openSettings: (() -> Void)? = nil,
        quitAction: (() -> Void)? = nil,
        openActivityMonitor: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.openSettings = openSettings
        self.quitAction = quitAction
        self.openActivityMonitor = openActivityMonitor
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 24, height: 24)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)

                if let openActivityMonitor {
                    MenuBarPopoverIconButton(
                        systemImage: "chart.bar.xaxis",
                        help: "打开活动监视器",
                        identifier: "popover.activity-monitor",
                        action: openActivityMonitor
                    )
                }
                if let openSettings {
                    MenuBarPopoverIconButton(
                        systemImage: "gearshape",
                        help: "打开 Fewer 设置",
                        identifier: "popover.settings",
                        action: openSettings
                    )
                }
                if let quitAction {
                    MenuBarPopoverIconButton(
                        systemImage: "power",
                        help: "退出 Fewer",
                        identifier: "popover.quit",
                        action: quitAction
                    )
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)

            Divider()

            content
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)
    }
}

private struct MenuBarPopoverIconButton: View {
    let systemImage: String
    let help: String
    let identifier: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(
                    isHovering ? Color.primary.opacity(0.08) : .clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(MenuBarPopoverIconButtonStyle())
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
        .accessibilityIdentifier(identifier)
    }
}

private struct MenuBarPopoverIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
    }
}
