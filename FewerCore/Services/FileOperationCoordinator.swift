import Foundation

public struct BatchRenameRule: Equatable, Sendable {
    public var findText: String
    public var replacementText: String
    public var prefix: String
    public var suffix: String
    public var addsSequenceNumber: Bool
    public var sequenceStart: Int

    public init(
        findText: String = "",
        replacementText: String = "",
        prefix: String = "",
        suffix: String = "",
        addsSequenceNumber: Bool = false,
        sequenceStart: Int = 1
    ) {
        self.findText = findText
        self.replacementText = replacementText
        self.prefix = prefix
        self.suffix = suffix
        self.addsSequenceNumber = addsSequenceNumber
        self.sequenceStart = sequenceStart
    }

    public func renamedName(for originalName: String, isDirectory: Bool, index: Int) -> String {
        let parts = Self.filenameParts(originalName, isDirectory: isDirectory)
        var stem = parts.stem
        if !findText.isEmpty {
            stem = stem.replacingOccurrences(of: findText, with: replacementText)
        }
        stem = prefix + stem + suffix
        if addsSequenceNumber {
            stem += " \(sequenceStart + index)"
        }
        return stem + parts.extensionSuffix
    }

    private static func filenameParts(_ name: String, isDirectory: Bool) -> (stem: String, extensionSuffix: String) {
        guard !isDirectory,
              !(name.hasPrefix(".") && !name.dropFirst().contains("."))
        else {
            return (name, "")
        }
        let pathExtension = (name as NSString).pathExtension
        guard !pathExtension.isEmpty else { return (name, "") }
        return ((name as NSString).deletingPathExtension, ".\(pathExtension)")
    }
}

public struct BatchRenameItem: Equatable, Sendable {
    public let sourceURL: URL
    public let destinationURL: URL

    public init(sourceURL: URL, destinationURL: URL) {
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
    }

    public var hasChange: Bool {
        sourceURL.standardizedFileURL != destinationURL.standardizedFileURL
    }
}

public enum BatchRenamePlanIssue: Equatable, Sendable {
    case requiresMultipleItems
    case noChanges
    case invalidName(sourceURL: URL, proposedName: String)
    case duplicateDestination(URL)
    case destinationExists(URL)

    public var message: String {
        switch self {
        case .requiresMultipleItems:
            return "请至少选择两个项目。"
        case .noChanges:
            return "当前规则不会改变任何名称。"
        case let .invalidName(sourceURL, proposedName):
            return "“\(sourceURL.lastPathComponent)”生成了无效名称“\(proposedName)”。"
        case let .duplicateDestination(url):
            return "多个项目会重命名为“\(url.lastPathComponent)”。"
        case let .destinationExists(url):
            return "目标“\(url.lastPathComponent)”已被未选中的项目占用。"
        }
    }
}

public struct BatchRenamePlan: Equatable, Sendable {
    public let items: [BatchRenameItem]
    public let issues: [BatchRenamePlanIssue]

    public init(items: [BatchRenameItem], issues: [BatchRenamePlanIssue]) {
        self.items = items
        self.issues = issues
    }

    public var changedItems: [BatchRenameItem] {
        items.filter(\.hasChange)
    }

    public var canExecute: Bool {
        issues.isEmpty && !changedItems.isEmpty
    }
}

public enum BatchRenamePlanner {
    public static func plan(
        urls: [URL],
        rule: BatchRenameRule,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
        isDirectory: (URL) -> Bool = {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    ) -> BatchRenamePlan {
        guard urls.count >= 2 else {
            return BatchRenamePlan(items: [], issues: [.requiresMultipleItems])
        }

        var issues: [BatchRenamePlanIssue] = []
        let items = urls.enumerated().map { index, sourceURL in
            let proposedName = rule.renamedName(
                for: sourceURL.lastPathComponent,
                isDirectory: isDirectory(sourceURL),
                index: index
            )
            if !isValidFilename(proposedName) {
                issues.append(.invalidName(sourceURL: sourceURL, proposedName: proposedName))
            }
            return BatchRenameItem(
                sourceURL: sourceURL,
                destinationURL: sourceURL.deletingLastPathComponent().appendingPathComponent(proposedName)
            )
        }

        var destinationKeys = Set<String>()
        for item in items {
            let key = pathKey(item.destinationURL)
            if !destinationKeys.insert(key).inserted {
                issues.append(.duplicateDestination(item.destinationURL))
            }
        }

        let selectedSourceKeys = Set(urls.map(pathKey))
        for item in items where item.hasChange {
            let destinationKey = pathKey(item.destinationURL)
            if fileExists(item.destinationURL), !selectedSourceKeys.contains(destinationKey) {
                issues.append(.destinationExists(item.destinationURL))
            }
        }

        if issues.isEmpty, !items.contains(where: \.hasChange) {
            issues.append(.noChanges)
        }
        return BatchRenamePlan(items: items, issues: issues)
    }

    private static func isValidFilename(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && trimmed != "."
            && trimmed != ".."
            && !name.contains("/")
            && !name.contains(":")
            && !name.contains("\0")
    }

    private static func pathKey(_ url: URL) -> String {
        url.standardizedFileURL.path
            .precomposedStringWithCanonicalMapping
            .lowercased()
    }
}

public enum BatchRenameExecutionPhase: Equatable, Sendable {
    case stage(Int)
    case install(Int)
}

public struct BatchRenameFailureInjector: Sendable {
    private let action: @Sendable (BatchRenameExecutionPhase) throws -> Void

    public init(action: @escaping @Sendable (BatchRenameExecutionPhase) throws -> Void) {
        self.action = action
    }

    public func callAsFunction(_ phase: BatchRenameExecutionPhase) throws {
        try action(phase)
    }

    public static let none = BatchRenameFailureInjector { _ in }
}

public enum BatchRenameExecutionOutcome: Equatable, Sendable {
    case success
    case invalidPlan
    case failedRolledBack
    case failedRollbackIncomplete
}

public struct BatchRenameExecutionResult: Equatable, Sendable {
    public let outcome: BatchRenameExecutionOutcome
    public let renamedCount: Int
    public let failedItem: BatchRenameItem?

    public init(
        outcome: BatchRenameExecutionOutcome,
        renamedCount: Int,
        failedItem: BatchRenameItem?
    ) {
        self.outcome = outcome
        self.renamedCount = renamedCount
        self.failedItem = failedItem
    }
}

private struct StagedRenameItem {
    let item: BatchRenameItem
    let temporaryURL: URL
}

public actor FileOperationCoordinator {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func move(
        _ sourceURLs: [URL],
        to targetDirectory: URL,
        policy: ConflictPolicy,
        replaceFailureInjector: ReplaceFailureInjector = .none
    ) -> FileOperationBatchResult {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: targetDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return FileOperationBatchResult(items: sourceURLs.map {
                FileOperationItemResult(sourceURL: $0, destinationURL: nil, status: .failed, error: .targetNotDirectory)
            })
        }

        return FileOperationBatchResult(items: sourceURLs.map { sourceURL in
            moveOne(sourceURL, to: targetDirectory, policy: policy, failureInjector: replaceFailureInjector)
        })
    }

    public func batchRename(
        _ plan: BatchRenamePlan,
        failureInjector: BatchRenameFailureInjector = .none
    ) -> BatchRenameExecutionResult {
        guard plan.canExecute else {
            return BatchRenameExecutionResult(outcome: .invalidPlan, renamedCount: 0, failedItem: nil)
        }

        var staged: [StagedRenameItem] = []
        for (index, item) in plan.changedItems.enumerated() {
            let temporaryURL = availableTemporaryURL(for: item.sourceURL)
            do {
                try failureInjector(.stage(index))
                try fileManager.moveItem(at: item.sourceURL, to: temporaryURL)
                staged.append(StagedRenameItem(item: item, temporaryURL: temporaryURL))
            } catch {
                let rollbackSucceeded = restoreOriginals(staged)
                return BatchRenameExecutionResult(
                    outcome: rollbackSucceeded ? .failedRolledBack : .failedRollbackIncomplete,
                    renamedCount: 0,
                    failedItem: item
                )
            }
        }

        var installed: [StagedRenameItem] = []
        for (index, stagedItem) in staged.enumerated() {
            do {
                try failureInjector(.install(index))
                try fileManager.moveItem(at: stagedItem.temporaryURL, to: stagedItem.item.destinationURL)
                installed.append(stagedItem)
            } catch {
                let returnedToTemporary = moveInstalledItemsBackToTemporary(installed)
                let restoredOriginals = restoreOriginals(staged)
                return BatchRenameExecutionResult(
                    outcome: returnedToTemporary && restoredOriginals
                        ? .failedRolledBack
                        : .failedRollbackIncomplete,
                    renamedCount: 0,
                    failedItem: stagedItem.item
                )
            }
        }

        return BatchRenameExecutionResult(
            outcome: .success,
            renamedCount: staged.count,
            failedItem: nil
        )
    }

    private func moveOne(
        _ sourceURL: URL,
        to targetDirectory: URL,
        policy: ConflictPolicy,
        failureInjector: ReplaceFailureInjector
    ) -> FileOperationItemResult {
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            return FileOperationItemResult(sourceURL: sourceURL, destinationURL: nil, status: .failed, error: .sourceMissing)
        }

        let source = sourceURL.standardizedFileURL
        let target = targetDirectory.standardizedFileURL
        let directDestination = target.appendingPathComponent(source.lastPathComponent)

        if source == directDestination.standardizedFileURL {
            return FileOperationItemResult(sourceURL: sourceURL, destinationURL: directDestination, status: .skipped, error: .sameLocation)
        }

        var sourceIsDirectory: ObjCBool = false
        _ = fileManager.fileExists(atPath: source.path, isDirectory: &sourceIsDirectory)
        if sourceIsDirectory.boolValue {
            let sourcePrefix = source.path.hasSuffix("/") ? source.path : source.path + "/"
            if target.path.hasPrefix(sourcePrefix) {
                return FileOperationItemResult(sourceURL: sourceURL, destinationURL: nil, status: .failed, error: .destinationInsideSource)
            }
        }

        var destination = directDestination
        if fileManager.fileExists(atPath: destination.path) {
            switch policy {
            case .keepBoth:
                destination = ConflictNameResolver.availableURL(
                    named: source.lastPathComponent,
                    in: target,
                    exists: { self.fileManager.fileExists(atPath: $0.path) }
                )
            case .skip:
                return FileOperationItemResult(sourceURL: sourceURL, destinationURL: destination, status: .skipped)
            case .replace:
                let outcome = RecoverableReplace.perform(
                    source: source,
                    destination: destination,
                    fileManager: fileManager,
                    sourceCoordination: .moving,
                    install: { fm, resolvedSource, resolvedDestination in
                        try fm.moveItem(at: resolvedSource, to: resolvedDestination)
                    },
                    failureInjector: failureInjector
                )
                switch outcome {
                case .success:
                    return FileOperationItemResult(sourceURL: sourceURL, destinationURL: destination, status: .moved)
                case .installFailed:
                    return FileOperationItemResult(sourceURL: sourceURL, destinationURL: destination, status: .failed, error: .systemError)
                case .notRecoverable:
                    return FileOperationItemResult(sourceURL: sourceURL, destinationURL: destination, status: .failed, error: .replacementNotRecoverable)
                }
            }
        }

        do {
            try fileManager.moveItem(at: source, to: destination)
            return FileOperationItemResult(sourceURL: sourceURL, destinationURL: destination, status: .moved)
        } catch {
            return FileOperationItemResult(sourceURL: sourceURL, destinationURL: destination, status: .failed, error: .systemError)
        }
    }

    private func availableTemporaryURL(for sourceURL: URL) -> URL {
        let directory = sourceURL.deletingLastPathComponent()
        while true {
            let candidate = directory.appendingPathComponent(".fewer-rename-\(UUID().uuidString)")
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
    }

    private func moveInstalledItemsBackToTemporary(
        _ installed: [StagedRenameItem]
    ) -> Bool {
        var succeeded = true
        for stagedItem in installed.reversed() {
            do {
                try fileManager.moveItem(
                    at: stagedItem.item.destinationURL,
                    to: stagedItem.temporaryURL
                )
            } catch {
                succeeded = false
            }
        }
        return succeeded
    }

    private func restoreOriginals(
        _ staged: [StagedRenameItem]
    ) -> Bool {
        var succeeded = true
        for stagedItem in staged.reversed()
            where fileManager.fileExists(atPath: stagedItem.temporaryURL.path) {
            do {
                try fileManager.moveItem(
                    at: stagedItem.temporaryURL,
                    to: stagedItem.item.sourceURL
                )
            } catch {
                succeeded = false
            }
        }
        return succeeded
    }
}
