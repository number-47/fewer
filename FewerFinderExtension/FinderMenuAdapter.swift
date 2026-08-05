import AppKit
import FewerCore

final class FinderMenuAdapter {
    init() {}

    func menu(from entries: [MenuEntry]) -> NSMenu? {
        guard !entries.isEmpty else { return nil }
        let menu = NSMenu(title: "Fewer")
        entries.forEach { menu.addItem(makeItem(from: $0)) }
        return menu
    }

    private func makeItem(from entry: MenuEntry) -> NSMenuItem {
        let item = NSMenuItem(
            title: entry.title,
            action: entry.children.isEmpty ? selector(for: entry.command) : nil,
            keyEquivalent: ""
        )
        item.isEnabled = entry.isEnabled

        if !entry.children.isEmpty {
            let submenu = NSMenu(title: entry.title)
            entry.children.forEach { submenu.addItem(makeItem(from: $0)) }
            item.submenu = submenu
        }
        return item
    }

    private func selector(for command: MenuCommand) -> Selector {
        switch command {
        case .copyPath:
            NSSelectorFromString("copyPathCommand:")
        case .cut:
            NSSelectorFromString("cutCommand:")
        case .pasteHere, .pasteIntoFolder:
            NSSelectorFromString("pasteCommand:")
        case .createFromTemplate:
            NSSelectorFromString("createFromTemplateCommand:")
        case .newFile:
            NSSelectorFromString("newFileCommand:")
        }
    }
}
