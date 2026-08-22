import AppKit
import FewerCore

final class FinderMenuAdapter {
    /// openWith 菜单项的 tag → bundleIdentifier 映射。
    /// Finder Sync 的 NSMenuItem 跨 XPC 传递时 representedObject 不被序列化,
    /// 改用 tag 做索引,action 触发时从该字典查找 bundleIdentifier。
    private(set) var openWithBundleIDs: [Int: String] = [:]
    private var nextTag = 1

    init() {}

    func menu(from entries: [MenuEntry], target: AnyObject) -> NSMenu? {
        guard !entries.isEmpty else { return nil }
        openWithBundleIDs.removeAll()
        nextTag = 1
        let menu = NSMenu(title: "Fewer")
        entries.forEach { menu.addItem(makeItem(from: $0, target: target)) }
        return menu
    }

    private func makeItem(from entry: MenuEntry, target: AnyObject) -> NSMenuItem {
        let item = NSMenuItem(
            title: entry.title,
            action: entry.children.isEmpty ? selector(for: entry.command) : nil,
            keyEquivalent: ""
        )
        item.target = target
        item.isEnabled = entry.isEnabled
        if case let .openWith(bundleIdentifier) = entry.command, !bundleIdentifier.isEmpty {
            let tag = nextTag
            nextTag += 1
            item.tag = tag
            openWithBundleIDs[tag] = bundleIdentifier
        }

        if !entry.children.isEmpty {
            let submenu = NSMenu(title: entry.title)
            entry.children.forEach { submenu.addItem(makeItem(from: $0, target: target)) }
            item.submenu = submenu
        }
        return item
    }

    private func selector(for command: MenuCommand) -> Selector {
        switch command {
        case .newFolder:
            NSSelectorFromString("newFolderCommand:")
        case .copyPath:
            NSSelectorFromString("copyPathCommand:")
        case .copyAs:
            NSSelectorFromString("copyAsCommand:")
        case .cut:
            NSSelectorFromString("cutCommand:")
        case .pasteHere, .pasteIntoFolder:
            NSSelectorFromString("pasteCommand:")
        case .openInTerminal:
            NSSelectorFromString("openInTerminalCommand:")
        case .openWith:
            NSSelectorFromString("openWithCommand:")
        case .refresh:
            NSSelectorFromString("refreshCommand:")
        case .createFromTemplate:
            NSSelectorFromString("createFromTemplateCommand:")
        case .newFile:
            NSSelectorFromString("newFileCommand:")
        }
    }
}
