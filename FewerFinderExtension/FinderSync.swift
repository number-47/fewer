import AppKit
import FinderSync
import FewerCore
import OSLog

final class FinderSync: FIFinderSync, @unchecked Sendable {
    private let logger = Logger(subsystem: "com.number47.fewer", category: "finder-menu")
    private var actionHandler: FinderActionHandler!
    private var menuAdapter: FinderMenuAdapter!

    override init() {
        super.init()
        actionHandler = FinderActionHandler()
        menuAdapter = FinderMenuAdapter()
        FIFinderSyncController.default().directoryURLs = [
            URL(fileURLWithPath: "/Users", isDirectory: true),
            URL(fileURLWithPath: "/Volumes", isDirectory: true),
        ]
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard let context = makeContext(for: menuKind) else {
            logger.error("Unable to resolve Finder menu context for kind \(menuKind.rawValue, privacy: .public)")
            return nil
        }
        guard let services = actionHandler.services else {
            logger.error("Finder services are unavailable")
            return nil
        }

        let settings = services.settingsStore.load().settings
        let templates = (try? services.templateStore.templates()) ?? TemplateDescriptor.builtIns
        let entries = MenuBuilder().entries(
            for: context,
            settings: settings,
            templates: templates
        )
        actionHandler.context = context
        logger.info("Built Finder menu with \(entries.count, privacy: .public) root entries")
        return menuAdapter.menu(from: entries)
    }

    @IBAction nonisolated func copyPathCommand(_ sender: AnyObject?) {
        Task { @MainActor [weak self] in
            self?.actionHandler.perform(.copyPath)
        }
    }

    @IBAction nonisolated func cutCommand(_ sender: AnyObject?) {
        Task { @MainActor [weak self] in
            self?.actionHandler.perform(.cut)
        }
    }

    @IBAction nonisolated func pasteCommand(_ sender: AnyObject?) {
        Task { @MainActor [weak self] in
            guard let self,
                  let context = actionHandler.context
            else { return }
            actionHandler.perform(context.kind == .container ? .pasteHere : .pasteIntoFolder)
        }
    }

    @IBAction nonisolated func createFromTemplateCommand(_ sender: AnyObject?) {
        // Finder invokes extension actions on its XPC endpoint queue. Read the serialized
        // menu title before hopping to AppKit's main actor; retaining the proxy menu item
        // across the hop is unsafe.
        guard let title = sender?.value(forKey: "title") as? String else { return }
        Task { @MainActor [weak self] in
            self?.actionHandler.createTemplate(named: title)
        }
    }

    @IBAction nonisolated func newFileCommand(_ sender: AnyObject?) {
        // The parent item owns a submenu and is not directly actionable.
    }

    private func makeContext(for menuKind: FIMenuKind) -> FinderMenuContext? {
        let controller = FIFinderSyncController.default()
        let selectedURLs = controller.selectedItemURLs() ?? []
        let targetURL = controller.targetedURL()

        let kind: FinderMenuKind
        switch menuKind {
        case .contextualMenuForContainer:
            kind = .container
        case .contextualMenuForItems:
            kind = .items
        case .contextualMenuForSidebar:
            kind = .sidebar
        default:
            return nil
        }

        let resolvedTarget: URL?
        if kind == .items,
           selectedURLs.count == 1,
           isDirectory(selectedURLs[0]) {
            resolvedTarget = selectedURLs[0]
        } else {
            resolvedTarget = targetURL
        }
        guard let resolvedTarget else { return nil }

        let cutTransactionExists: Bool
        if let cutStore = actionHandler.services?.cutStore {
            cutTransactionExists = ((try? cutStore.load(
                currentPasteboardChangeCount: NSPasteboard.general.changeCount
            )) ?? nil) != nil
        } else {
            cutTransactionExists = false
        }

        return FinderMenuContext(
            kind: kind,
            selectedURLs: selectedURLs,
            targetURL: resolvedTarget,
            // Finder only invokes the extension for a user-visible target URL. A sandboxed
            // Finder Sync process can report a false negative from isWritableFile before
            // the command actually opens the URL, so execution remains the authority.
            isTargetWritable: true,
            hasCutTransaction: cutTransactionExists,
            isSingleSelectedItemDirectory: selectedURLs.count == 1 && isDirectory(selectedURLs[0])
        )
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
