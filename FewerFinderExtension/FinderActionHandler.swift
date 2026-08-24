import AppKit
import FinderSync
import FewerCore
import OSLog

struct FinderServices: Sendable {
    let settingsStore: SharedSettingsStore
    let templateStore: TemplateStore
    let cutStore: CutTransactionStore
    let fileCoordinator: FileOperationCoordinator
}

/// Finder 菜单命令执行器。
///
/// 不再持有可变的 `context`。每次执行都接收显式的 `FinderMenuContext` 与 `MenuCommand`，
/// 由调用方通过 token 注册表反查快照后传入，消除跨菜单上下文串扰。
final class FinderActionHandler: NSObject, @unchecked Sendable {
    private let logger = Logger(subsystem: "com.number47.fewer", category: "finder-actions")
    let services: FinderServices?

    override init() {
        do {
            let resourceDirectory = Bundle.main.resourceURL ?? Bundle.main.bundleURL
            services = FinderServices(
                settingsStore: try SharedSettingsStore(),
                templateStore: try TemplateStore(builtInDirectory: resourceDirectory),
                cutStore: try CutTransactionStore(),
                fileCoordinator: FileOperationCoordinator()
            )
        } catch {
            services = nil
        }
        super.init()
    }

    /// 在 MainActor 上执行命令。调用方负责提供来自快照的 context 与 command。
    @MainActor
    func perform(command: MenuCommand, context: FinderMenuContext) {
        guard let services else {
            logger.error("perform aborted: services is nil")
            return
        }

        logger.info("Handling Finder menu command: \(String(describing: command), privacy: .public)")

        switch command {
        case .newFolder:
            createFolder(in: context.targetURL)
        case .copyPath:
            // 空白处（容器）右键时无选中项，复制当前文件夹路径
            let urls = context.selectedURLs.isEmpty ? [context.targetURL] : context.selectedURLs
            copyPath(urls, settings: services.settingsStore.load().settings)
        case let .copyAs(format):
            let urls = context.selectedURLs.isEmpty ? [context.targetURL] : context.selectedURLs
            let relativeBase = context.kind == .container
                ? context.targetURL
                : (context.selectedURLs.first?.deletingLastPathComponent() ?? context.targetURL)
            copy(urls, as: format, relativeTo: relativeBase)
        case .cut:
            cut(context.selectedURLs, store: services.cutStore)
        case .pasteHere, .pasteIntoFolder:
            paste(to: context.targetURL, services: services)
        case .openInTerminal:
            openInTerminal(context: context, services: services)
        case let .openWith(bundleIdentifier):
            openWithApplication(bundleIdentifier: bundleIdentifier, context: context)
        case .refresh:
            refreshDirectory(context: context)
        case let .createFromTemplate(templateID):
            createFile(templateID: templateID, in: context.targetURL, services: services)
        case .newFile:
            break
        }
    }

    private func createFolder(in directory: URL) {
        let accessing = directory.startAccessingSecurityScopedResource()
        defer { if accessing { directory.stopAccessingSecurityScopedResource() } }
        let url = ConflictNameResolver.availableURL(named: "新建文件夹", in: directory) {
            FileManager.default.fileExists(atPath: $0.path)
        }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            NSWorkspace.shared.noteFileSystemChanged(directory.path)
        } catch {
            logger.error("Unable to create folder: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 重新加载当前 Finder 文件夹视图：空白处刷新当前文件夹，选中项时刷新其所在目录。
    /// 通过 NSWorkspace 通知 Finder 目标目录内容已变化，让外部新增/删除/修改的文件立即显示。
    @MainActor
    private func refreshDirectory(context: FinderMenuContext) {
        let targetURL: URL
        if context.kind == .container {
            targetURL = context.targetURL
        } else if let firstSelected = context.selectedURLs.first {
            targetURL = firstSelected.hasDirectoryPath
                ? firstSelected
                : firstSelected.deletingLastPathComponent()
        } else {
            targetURL = context.targetURL
        }
        NSWorkspace.shared.noteFileSystemChanged(targetURL.path)
        logger.info("Finder refresh requested for \(targetURL.path, privacy: .public)")
    }

    /// 在终端中打开选中的文件夹；选中文件时打开其所在目录。
    /// 多个选中项时以第一个为准；容器（空白处）右键则打开当前文件夹。
    /// 使用设置中选择的终端应用，未安装时回退到 Terminal.app。
    @MainActor
    private func openInTerminal(context: FinderMenuContext, services: FinderServices) {
        let url = context.selectedURLs.first ?? context.targetURL
        let directory = url.hasDirectoryPath ? url : url.deletingLastPathComponent()

        let preferredBundleID = services.settingsStore.load().settings.terminalBundleID
        guard let terminalApp = NSWorkspace.shared.urlForApplication(withBundleIdentifier: preferredBundleID)
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: FeatureSettings.defaultTerminalBundleID)
        else {
            logger.error("No terminal application available (preferred: \(preferredBundleID, privacy: .public))")
            return
        }
        NSWorkspace.shared.open(
            [directory],
            withApplicationAt: terminalApp,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    @MainActor
    private func openWithApplication(bundleIdentifier: String, context: FinderMenuContext) {
        guard !bundleIdentifier.isEmpty,
              let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        else { return }
        NSWorkspace.shared.open(
            context.selectedURLs,
            withApplicationAt: applicationURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    private func copyPath(_ urls: [URL], settings: FeatureSettings) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(PathFormatter.string(for: urls, format: settings.pathFormat), forType: .string)
    }

    private func copy(_ urls: [URL], as format: FinderCopyFormat, relativeTo baseURL: URL) {
        let values = urls.map { url -> String in
            switch format {
            case .name:
                url.lastPathComponent
            case .absolutePath:
                url.path
            case .relativePath:
                relativePath(from: baseURL, to: url)
            case .shellEscapedPath:
                "'\(url.path.replacingOccurrences(of: "'", with: "'\\''"))'"
            case .fileURL:
                url.absoluteString
            }
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(values.joined(separator: "\n"), forType: .string)
    }

    private func relativePath(from baseURL: URL, to url: URL) -> String {
        let base = baseURL.standardizedFileURL.pathComponents
        let target = url.standardizedFileURL.pathComponents
        var common = 0
        while common < min(base.count, target.count), base[common] == target[common] { common += 1 }
        let upward = Array(repeating: "..", count: base.count - common)
        let downward = Array(target.dropFirst(common))
        let result = (upward + downward).joined(separator: "/")
        return result.isEmpty ? "." : result
    }

    private func cut(_ urls: [URL], store: CutTransactionStore) {
        guard !urls.isEmpty else {
            logger.error("Finder cut command has no selected URLs")
            return
        }
        do {
            // Keep Finder's clipboard untouched. The transaction is invalidated if the
            // user copies something else before choosing Fewer's Paste command.
            try store.start(
                urls: urls,
                pasteboardChangeCount: NSPasteboard.general.changeCount
            )
            DistributedNotificationCenter.default().postNotificationName(
                AppGroupConstants.cutTransactionDidChangeNotification,
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
            logger.info("Finder cut transaction persisted")
        } catch {
            logger.error("Unable to persist Finder cut transaction: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func paste(to targetURL: URL, services: FinderServices) {
        let changeCount = NSPasteboard.general.changeCount
        guard let transaction = (try? services.cutStore.load(
            currentPasteboardChangeCount: changeCount
        )) ?? nil else { return }
        let policy = services.settingsStore.load().settings.conflictPolicy

        Task {
            let accessingTarget = targetURL.startAccessingSecurityScopedResource()
            defer { if accessingTarget { targetURL.stopAccessingSecurityScopedResource() } }
            let result = await services.fileCoordinator.move(
                transaction.remainingURLs,
                to: targetURL,
                policy: policy
            )
            try? services.cutStore.keepRemaining(result.failedSourceURLs, for: transaction.id)
            DistributedNotificationCenter.default().postNotificationName(
                AppGroupConstants.cutTransactionDidChangeNotification,
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
            self.logger.info("Finder paste finished with \(result.items.count, privacy: .public) item results")
            _ = targetURL
        }
    }

    private func createFile(templateID: UUID, in directory: URL, services: FinderServices) {
        guard let descriptor = (try? services.templateStore.templates())?.first(where: { $0.id == templateID }),
              let sourceURL = try? services.templateStore.fileURL(for: descriptor)
        else { return }

        let policy = services.settingsStore.load().settings.conflictPolicy
        let accessingTarget = directory.startAccessingSecurityScopedResource()
        defer { if accessingTarget { directory.stopAccessingSecurityScopedResource() } }
        do {
            _ = try TemplateFileCreator().create(
                from: sourceURL,
                descriptor: descriptor,
                in: directory,
                policy: policy
            )
            logger.info("Template file creation completed")
        } catch {
            logger.error("Template file creation failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
