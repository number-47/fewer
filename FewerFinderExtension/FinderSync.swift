import AppKit
import FinderSync
import FewerCore
import OSLog

final class FinderSync: FIFinderSync, @unchecked Sendable {
    private let logger = Logger(subsystem: "com.number47.fewer", category: "finder-menu")
    private var actionHandler: FinderActionHandler!
    private var menuAdapter: FinderMenuAdapter!
    private let menuActionRegistry = FinderMenuActionRegistry()
    private let modulePreferencesStore = ModulePreferencesStore()
    private let diagnosticStore = FinderMenuDiagnosticStore()
    private var launchDiagnostic: FinderMenuDiagnostic

    override init() {
        let now = Date()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"
        launchDiagnostic = FinderMenuDiagnostic(
            lastExtensionLaunch: now,
            buildVersion: version,
            buildNumber: build,
            processIdentifier: Int32(ProcessInfo.processInfo.processIdentifier)
        )
        super.init()
        actionHandler = FinderActionHandler()
        menuAdapter = FinderMenuAdapter()
        // directoryURLs 覆盖范围：
        // - /Users：用户主目录、桌面、文档、下载、iCloud Drive（位于 ~/Library/Mobile Documents）
        // - /Volumes：外接卷、挂载的磁盘映像、网络共享
        // 侧栏项指向上述路径下的位置时扩展同样生效。
        FIFinderSyncController.default().directoryURLs = [
            URL(fileURLWithPath: "/Users", isDirectory: true),
            URL(fileURLWithPath: "/Volumes", isDirectory: true),
        ]
        try? diagnosticStore.save(launchDiagnostic)
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        let now = Date()

        guard modulePreferencesStore.isEnabled(moduleID: "finder") else {
            recordMenuRequest(succeeded: false, entryCount: 0, reason: .moduleDisabled, at: now)
            return nil
        }
        guard let context = makeContext(for: menuKind) else {
            logger.error("Unable to resolve Finder menu context for kind \(menuKind.rawValue, privacy: .public)")
            recordMenuRequest(succeeded: false, entryCount: 0, reason: .contextUnavailable, at: now)
            return nil
        }
        guard let services = actionHandler.services else {
            logger.error("Finder services are unavailable")
            recordMenuRequest(succeeded: false, entryCount: 0, reason: .servicesUnavailable, at: now)
            return nil
        }

        let settings = services.settingsStore.load().settings
        let templates = (try? services.templateStore.templates()) ?? TemplateDescriptor.builtIns
        let entries = MenuBuilder().entries(
            for: context,
            settings: settings,
            templates: templates
        )

        guard let menu = menuAdapter.menu(
            from: entries,
            context: context,
            target: self,
            registry: menuActionRegistry
        ) else {
            recordMenuRequest(succeeded: false, entryCount: 0, reason: .emptyEntries, at: now)
            return nil
        }

        recordMenuRequest(succeeded: true, entryCount: entries.count, reason: nil, at: now)
        logger.info("Built Finder menu with \(entries.count, privacy: .public) root entries")
        return menu
    }

    /// 将最近一次菜单请求结果写入诊断心跳，保留启动时间与构建身份不变。
    private func recordMenuRequest(
        succeeded: Bool,
        entryCount: Int,
        reason: FinderMenuReason?,
        at date: Date
    ) {
        let updated = FinderMenuDiagnostic(
            lastExtensionLaunch: launchDiagnostic.lastExtensionLaunch,
            lastMenuRequest: date,
            lastRequestSucceeded: succeeded,
            lastEntryCount: entryCount,
            lastReason: reason,
            buildVersion: launchDiagnostic.buildVersion,
            buildNumber: launchDiagnostic.buildNumber,
            processIdentifier: launchDiagnostic.processIdentifier
        )
        launchDiagnostic = updated
        try? diagnosticStore.save(updated)
    }

    /// 统一菜单命令入口。
    ///
    /// Finder 在其 XPC 端点队列上调用 extension action。此处仅读取序列化的 `tag`（正整数 token），
    /// 不触碰任何 `@MainActor` 隔离的状态，然后跳到 MainActor 通过注册表反查不可变快照执行命令。
    /// 这消除了跨菜单上下文串扰：每个叶子项绑定的快照在构建时即固定，不受后续菜单构建影响。
    @IBAction nonisolated func performCommand(_ sender: AnyObject?) {
        // 在跳转前仅读取序列化的 tag。tag 是进程内唯一且永不复用的正整数 token。
        guard let tagNumber = sender?.value(forKey: "tag") as? NSNumber,
              tagNumber.intValue > 0
        else { return }
        let token = tagNumber.intValue
        Task { @MainActor [weak self] in
            guard let self,
                  let snapshot = menuActionRegistry.snapshot(for: token)
            else { return }
            actionHandler.perform(command: snapshot.command, context: snapshot.context)
        }
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
