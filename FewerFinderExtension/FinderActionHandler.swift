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

final class FinderActionHandler: NSObject, @unchecked Sendable {
    private let logger = Logger(subsystem: "com.number47.fewer", category: "finder-actions")
    let services: FinderServices?
    var context: FinderMenuContext?

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

    func perform(_ command: MenuCommand) {
        guard let services,
              let context
        else { return }

        logger.info("Handling Finder menu command: \(String(describing: command), privacy: .public)")

        switch command {
        case .copyPath:
            // 空白处（容器）右键时无选中项，复制当前文件夹路径
            let urls = context.selectedURLs.isEmpty ? [context.targetURL] : context.selectedURLs
            copyPath(urls, settings: services.settingsStore.load().settings)
        case .cut:
            cut(context.selectedURLs, store: services.cutStore)
        case .pasteHere, .pasteIntoFolder:
            paste(to: context.targetURL, services: services)
        case .openInTerminal:
            openInTerminal()
        case let .createFromTemplate(templateID):
            createFile(templateID: templateID, in: context.targetURL, services: services)
        case .newFile:
            break
        }
    }

    func createTemplate(named displayName: String) {
        guard let services,
              let context,
              let descriptor = (try? services.templateStore.templates())?.first(where: {
                  $0.displayName == displayName
              })
        else { return }
        createFile(templateID: descriptor.id, in: context.targetURL, services: services)
    }

    /// 在终端中打开选中的文件夹；选中文件时打开其所在目录。
    /// 多个选中项时以第一个为准；容器（空白处）右键则打开当前文件夹。
    /// 使用设置中选择的终端应用，未安装时回退到 Terminal.app。
    private func openInTerminal() {
        guard let context, let services else { return }
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

    private func copyPath(_ urls: [URL], settings: FeatureSettings) {        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(PathFormatter.string(for: urls, format: settings.pathFormat), forType: .string)
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
