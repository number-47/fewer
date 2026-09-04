import AppKit
import FinderSync
import FewerCore
import OSLog
import SwiftUI

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
        case .batchRename:
            batchRename(context.selectedURLs, services: services)
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

    @MainActor
    private func batchRename(_ urls: [URL], services: FinderServices) {
        guard let rule = BatchRenameDialog.rule(for: urls) else { return }
        let plan = BatchRenamePlanner.plan(urls: urls, rule: rule)
        guard plan.canExecute else {
            BatchRenameDialog.showValidationError(plan.issues.first?.message ?? "重命名方案无效。")
            return
        }

        Task {
            let securityScopedURLs = Array(Set(urls + urls.map { $0.deletingLastPathComponent() }))
            let accessedURLs = securityScopedURLs.filter { $0.startAccessingSecurityScopedResource() }
            defer {
                for url in accessedURLs {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let result = await services.fileCoordinator.batchRename(plan)
            let directories = Set(urls.map { $0.deletingLastPathComponent() })
            for directory in directories {
                NSWorkspace.shared.noteFileSystemChanged(directory.path)
            }
            presentBatchRenameResult(result)
        }
    }

    @MainActor
    private func presentBatchRenameResult(_ result: BatchRenameExecutionResult) {
        let alert = NSAlert()
        switch result.outcome {
        case .success:
            alert.alertStyle = .informational
            alert.messageText = "批量重命名完成"
            alert.informativeText = "已重命名 \(result.renamedCount) 个项目。"
        case .invalidPlan:
            alert.alertStyle = .warning
            alert.messageText = "无法批量重命名"
            alert.informativeText = "文件状态已经变化，请重新打开批量重命名。"
        case .failedRolledBack:
            alert.alertStyle = .warning
            alert.messageText = "批量重命名失败"
            alert.informativeText = "未能重命名“\(result.failedItem?.sourceURL.lastPathComponent ?? "项目")”，已恢复原名称。"
        case .failedRollbackIncomplete:
            alert.alertStyle = .critical
            alert.messageText = "批量重命名未完整恢复"
            alert.informativeText = "未能重命名“\(result.failedItem?.sourceURL.lastPathComponent ?? "项目")”，部分项目可能仍使用临时或新名称，请立即检查当前文件夹。"
        }
        alert.addButton(withTitle: "好")
        alert.runModal()
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

@MainActor
private final class BatchRenameDialogModel: ObservableObject {
    let urls: [URL]
    @Published var findText = ""
    @Published var replacementText = ""
    @Published var prefix = ""
    @Published var suffix = ""
    @Published var addsSequenceNumber = false
    @Published var sequenceStart = 1

    init(urls: [URL]) {
        self.urls = urls
    }

    var rule: BatchRenameRule {
        BatchRenameRule(
            findText: findText,
            replacementText: replacementText,
            prefix: prefix,
            suffix: suffix,
            addsSequenceNumber: addsSequenceNumber,
            sequenceStart: sequenceStart
        )
    }

    var plan: BatchRenamePlan {
        BatchRenamePlanner.plan(urls: urls, rule: rule)
    }
}

private struct BatchRenameDialogView: View {
    @ObservedObject var model: BatchRenameDialogModel

    var body: some View {
        let plan = model.plan
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("查找")
                    TextField("可留空", text: $model.findText)
                    Text("替换为")
                    TextField("可留空", text: $model.replacementText)
                }
                GridRow {
                    Text("前缀")
                    TextField("可留空", text: $model.prefix)
                    Text("后缀")
                    TextField("可留空", text: $model.suffix)
                }
            }

            HStack {
                Toggle("添加顺序编号", isOn: $model.addsSequenceNumber)
                Spacer()
                if model.addsSequenceNumber {
                    Stepper("起始 \(model.sequenceStart)", value: $model.sequenceStart, in: 0...999_999)
                }
            }

            Divider()
            Text("预览").font(.headline)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(plan.items.prefix(12).enumerated()), id: \.offset) { _, item in
                        HStack(spacing: 8) {
                            Text(item.sourceURL.lastPathComponent)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            Image(systemName: "arrow.right")
                                .foregroundStyle(.secondary)
                            Text(item.destinationURL.lastPathComponent)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.system(size: 12))
                    }
                    if plan.items.count > 12 {
                        Text("另有 \(plan.items.count - 12) 个项目")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(height: 150)

            if let issue = plan.issues.first {
                Label(issue.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text("将重命名 \(plan.changedItems.count) 个项目；文件扩展名保持不变。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(4)
        .frame(width: 560, height: 330)
    }
}

@MainActor
private enum BatchRenameDialog {
    static func rule(for urls: [URL]) -> BatchRenameRule? {
        let model = BatchRenameDialogModel(urls: urls)
        while true {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "批量重命名"
            alert.informativeText = "设置规则并确认预览。不会覆盖未选中的文件。"
            alert.addButton(withTitle: "重命名")
            alert.addButton(withTitle: "取消")

            let hostingView = NSHostingView(rootView: BatchRenameDialogView(model: model))
            hostingView.frame = NSRect(x: 0, y: 0, width: 560, height: 330)
            alert.accessoryView = hostingView

            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            let plan = model.plan
            if plan.canExecute {
                return model.rule
            }
            showValidationError(plan.issues.first?.message ?? "重命名方案无效。")
        }
    }

    static func showValidationError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "无法执行批量重命名"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}
