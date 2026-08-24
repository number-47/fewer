import Foundation

/// 可回滚替换操作的执行阶段。用于故障注入钩子判断当前所处阶段。
public enum ReplaceOperationPhase: String, Sendable {
    case install
    case rollback
    case cleanup
}

/// 故障注入器：在替换事务的各阶段被同步调用，抛出错误即可模拟该阶段失败。
/// 仅用于测试，生产代码使用 `.none`。
public struct ReplaceFailureInjector: Sendable {
    public let probe: @Sendable (ReplaceOperationPhase) throws -> Void

    public init(probe: @escaping @Sendable (ReplaceOperationPhase) throws -> Void) {
        self.probe = probe
    }

    /// 不注入任何故障的默认值。
    public static let none = ReplaceFailureInjector(probe: { _ in })
}

/// 源文件的协调方式。
/// - `.moving`: 源将被移动/删除，使用 `.forMoving` 写入协调（Apple 推荐的 move 协调方式）。
/// - `.reading`: 源仅被读取/复制，使用读取协调。
public enum SourceCoordination: Sendable {
    case moving
    case reading
}

/// 可回滚文件替换工具。
///
/// 事务顺序：
/// 1. 在同一目录生成唯一备份名，将目标原子重命名为备份（不先移入废纸篓）。
/// 2. 执行 `install` 闭包（将源移动/复制到目标位置）。
/// 3. 成功则删除备份；失败则将备份回滚（重命名回目标位置）。
///    - 回滚成功：返回 `.installFailed`（调用方报告普通操作失败，原文件完好）。
///    - 回滚也失败：返回 `.notRecoverable`。
///
/// `NSFileCoordinator` 同时协调源与目标：
/// - `.moving` 时源用 `.forMoving`（写入）、目标用 `.forReplacing`（写入）。
/// - `.reading` 时源用读取协调、目标用 `.forReplacing`（写入）。
///
/// accessor 仅执行同步文件系统事务。
public enum RecoverableReplace {
    public enum Outcome: Sendable, Equatable {
        case success
        case installFailed
        case notRecoverable
    }

    public static func perform(
        source: URL,
        destination: URL,
        fileManager: FileManager,
        sourceCoordination: SourceCoordination,
        install: (FileManager, URL, URL) throws -> Void,
        failureInjector: ReplaceFailureInjector = .none
    ) -> Outcome {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var outcome: Outcome = .success

        switch sourceCoordination {
        case .moving:
            coordinator.coordinate(
                writingItemAt: source,
                options: .forMoving,
                writingItemAt: destination,
                options: .forReplacing,
                error: &coordinationError
            ) { resolvedSource, resolvedDestination in
                runTransaction(
                    resolvedSource: resolvedSource,
                    resolvedDestination: resolvedDestination,
                    fileManager: fileManager,
                    install: install,
                    failureInjector: failureInjector,
                    outcome: &outcome
                )
            }
        case .reading:
            coordinator.coordinate(
                readingItemAt: source,
                options: [],
                writingItemAt: destination,
                options: .forReplacing,
                error: &coordinationError
            ) { resolvedSource, resolvedDestination in
                runTransaction(
                    resolvedSource: resolvedSource,
                    resolvedDestination: resolvedDestination,
                    fileManager: fileManager,
                    install: install,
                    failureInjector: failureInjector,
                    outcome: &outcome
                )
            }
        }

        if coordinationError != nil {
            return .installFailed
        }
        return outcome
    }

    private static func runTransaction(
        resolvedSource: URL,
        resolvedDestination: URL,
        fileManager: FileManager,
        install: (FileManager, URL, URL) throws -> Void,
        failureInjector: ReplaceFailureInjector,
        outcome: inout Outcome
    ) {
        let directory = resolvedDestination.deletingLastPathComponent()
        let backupURL = uniqueBackupURL(
            for: resolvedDestination,
            in: directory,
            fileManager: fileManager
        )

        // 1. 原子重命名：目标 → 备份
        do {
            try fileManager.moveItem(at: resolvedDestination, to: backupURL)
        } catch {
            outcome = .installFailed
            return
        }

        // 2. 执行安装（移动/复制 源 → 目标）
        do {
            try failureInjector.probe(.install)
            try install(fileManager, resolvedSource, resolvedDestination)
        } catch {
            // 3. 安装失败 → 回滚：备份 → 目标
            do {
                try failureInjector.probe(.rollback)
                try fileManager.moveItem(at: backupURL, to: resolvedDestination)
                outcome = .installFailed
            } catch {
                outcome = .notRecoverable
            }
            return
        }

        // 4. 安装成功 → 清理：删除备份
        do {
            try failureInjector.probe(.cleanup)
            try fileManager.removeItem(at: backupURL)
        } catch {
            // 清理失败：新内容已就位，残留备份为旧内容，非数据丢失。
            // 报告成功——用户操作已完成，清理为尽力而为。
        }
    }

    private static func uniqueBackupURL(
        for destination: URL,
        in directory: URL,
        fileManager: FileManager
    ) -> URL {
        let stem = destination.lastPathComponent
        var candidate = directory.appendingPathComponent(
            ".\(stem).fewer-replace-\(UUID().uuidString)"
        )
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent(
                ".\(stem).fewer-replace-\(UUID().uuidString)"
            )
        }
        return candidate
    }
}
