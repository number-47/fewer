import AppKit
import FewerCore

/// 将 `MenuEntry` 树转换为 `NSMenu`，为每个叶子项绑定不可变快照。
///
/// 不再解析标题或维护 `openWithBundleIDs` 映射。每个叶子项通过 `FinderMenuActionRegistry`
/// 注册一份 `FinderMenuActionSnapshot`，获得进程内唯一的正整数 token，写入 `NSMenuItem.tag`。
/// 所有叶子项共享同一个 `performCommand:` action，回调读取 token 后跳到 MainActor 反查快照。
final class FinderMenuAdapter {
    init() {}

    /// 构建 NSMenu。每个叶子项注册一份快照并将 token 写入 tag。
    func menu(
        from entries: [MenuEntry],
        context: FinderMenuContext,
        target: AnyObject,
        registry: FinderMenuActionRegistry
    ) -> NSMenu? {
        guard !entries.isEmpty else { return nil }
        let menu = NSMenu(title: "Fewer")
        for entry in entries {
            menu.addItem(makeItem(from: entry, context: context, target: target, registry: registry))
        }
        return menu
    }

    private func makeItem(
        from entry: MenuEntry,
        context: FinderMenuContext,
        target: AnyObject,
        registry: FinderMenuActionRegistry
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: entry.title,
            action: entry.children.isEmpty ? #selector(FinderSync.performCommand(_:)) : nil,
            keyEquivalent: ""
        )
        item.target = target
        item.isEnabled = entry.isEnabled

        if entry.children.isEmpty {
            // 叶子项：注册快照，写入 token。非叶子项（如「新建文件」「用应用打开」）不绑定 action。
            let snapshot = FinderMenuActionSnapshot(context: context, command: entry.command)
            let token = registry.register(snapshot)
            item.tag = token
        }

        if !entry.children.isEmpty {
            let submenu = NSMenu(title: entry.title)
            for child in entry.children {
                submenu.addItem(makeItem(from: child, context: context, target: target, registry: registry))
            }
            item.submenu = submenu
        }
        return item
    }
}
