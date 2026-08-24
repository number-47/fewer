import Foundation

public struct MenuBuilder: Sendable {
    public init() {}

    public func entries(
        for context: FinderMenuContext,
        settings: FeatureSettings,
        templates: [TemplateDescriptor]
    ) -> [MenuEntry] {
        settings.menuOrder.compactMap { feature in
            guard settings.enabledFeatures.contains(feature) else { return nil }

            switch (context.kind, feature) {
            case (.container, .newFolder):
                return MenuEntry(
                    command: .newFolder,
                    title: "新建文件夹",
                    isEnabled: context.isTargetWritable
                )

            case (.container, .newFile):
                let children = templates
                    .filter(\.isEnabled)
                    .sorted { $0.order < $1.order }
                    .map {
                        MenuEntry(
                            command: .createFromTemplate($0.id),
                            title: $0.displayName,
                            isEnabled: context.isTargetWritable
                        )
                    }
                return MenuEntry(
                    command: .newFile,
                    title: "新建文件",
                    isEnabled: context.isTargetWritable,
                    children: children
                )

            case (.container, .paste) where context.hasCutTransaction:
                return MenuEntry(
                    command: .pasteHere,
                    title: "粘贴到此处",
                    isEnabled: context.isTargetWritable
                )

            case (.items, .copyPath) where !context.selectedURLs.isEmpty:
                return MenuEntry(command: .copyPath, title: "复制路径")

            case (.items, .copyAs) where !context.selectedURLs.isEmpty:
                return copyAsMenu()

            case (.container, .copyAs):
                return copyAsMenu()

            case (.items, .openInTerminal) where !context.selectedURLs.isEmpty:
                return MenuEntry(command: .openInTerminal, title: "在终端打开")

            case (.container, .openInTerminal):
                return MenuEntry(command: .openInTerminal, title: "在终端打开")

            case (.items, .openWith) where !context.selectedURLs.isEmpty:
                let children = settings.openWithApplications
                    .filter { application in
                        application.applicableExtensions.isEmpty || context.selectedURLs.allSatisfy {
                            application.applicableExtensions.contains($0.pathExtension.lowercased())
                        }
                    }
                    .map {
                        MenuEntry(
                            command: .openWith(bundleIdentifier: $0.bundleIdentifier),
                            title: $0.displayName
                        )
                    }
                guard !children.isEmpty else { return nil }
                return MenuEntry(
                    command: .openWith(bundleIdentifier: ""),
                    title: "用应用打开",
                    children: children
                )

            case (.container, .copyPath):
                // 空白处右键：复制当前文件夹路径
                return MenuEntry(command: .copyPath, title: "复制路径")

            case (.items, .cut) where !context.selectedURLs.isEmpty:
                return MenuEntry(command: .cut, title: "剪切")

            case (.items, .paste)
                where context.hasCutTransaction && context.isSingleSelectedItemDirectory:
                return MenuEntry(
                    command: .pasteIntoFolder,
                    title: "粘贴到文件夹",
                    isEnabled: context.isTargetWritable
                )

            case (.sidebar, .copyPath):
                return MenuEntry(command: .copyPath, title: "复制路径")

            case (.sidebar, .openInTerminal):
                return MenuEntry(command: .openInTerminal, title: "在终端打开")

            case (.container, .refresh):
                return MenuEntry(command: .refresh, title: "刷新")

            case (.items, .refresh) where !context.selectedURLs.isEmpty:
                return MenuEntry(command: .refresh, title: "刷新")

            default:
                return nil
            }
        }
    }

    private func copyAsMenu() -> MenuEntry {
        MenuEntry(
            command: .copyAs(.absolutePath),
            title: "复制为",
            children: FinderCopyFormat.allCases.map { format in
                MenuEntry(command: .copyAs(format), title: format.menuTitle)
            }
        )
    }
}
