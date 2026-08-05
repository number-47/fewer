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

            case (.items, .cut) where !context.selectedURLs.isEmpty:
                return MenuEntry(command: .cut, title: "剪切")

            case (.items, .paste)
                where context.hasCutTransaction && context.isSingleSelectedItemDirectory:
                return MenuEntry(
                    command: .pasteIntoFolder,
                    title: "粘贴到文件夹",
                    isEnabled: context.isTargetWritable
                )

            default:
                return nil
            }
        }
    }
}
