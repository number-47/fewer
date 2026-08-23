import SwiftUI

/// 菜单栏弹窗共用的标题栏和材质外壳。
struct MenuBarPopoverChrome<Content: View>: View {
    let title: String
    let systemImage: String
    let openSettings: (() -> Void)?
    let quitAction: (() -> Void)?
    @ViewBuilder let content: Content

    init(
        title: String,
        systemImage: String,
        openSettings: (() -> Void)? = nil,
        quitAction: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.openSettings = openSettings
        self.quitAction = quitAction
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24, height: 24)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                Text(title)
                    .font(.system(size: 14, weight: .semibold))

                Spacer(minLength: 0)

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
            .padding(.vertical, 10)

            Divider()

            content
        }
        .background(.regularMaterial)
    }
}

private struct MenuBarPopoverIconButton: View {
    let systemImage: String
    let help: String
    let identifier: String
    let action: () -> Void
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(
                    isHovering || isFocused ? Color.primary.opacity(0.08) : .clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .overlay {
                    if isFocused {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.65))
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(MenuBarPopoverIconButtonStyle())
        .onHover { isHovering = $0 }
        .focusable(true)
        .focused($isFocused)
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
