import Foundation
import os

/// 不可变的 Finder 菜单动作快照。
///
/// 每个 Finder 菜单叶子项在构建时绑定一份快照，包含触发该命令所需的全部上下文与指令。
/// 回调通过 `FinderMenuActionRegistry` 以正整数 token 反查快照，避免跨菜单的上下文串扰。
public struct FinderMenuActionSnapshot: Sendable, Equatable {
    public let context: FinderMenuContext
    public let command: MenuCommand

    public init(context: FinderMenuContext, command: MenuCommand) {
        self.context = context
        self.command = command
    }
}

/// Finder 菜单动作 token 注册表。
///
/// 每个叶子菜单项注册一份 `FinderMenuActionSnapshot`，获得一个进程内唯一且永不复用的正整数 token，
/// 该 token 写入 `NSMenuItem.tag`。回调读取 token 后跳到 MainActor 反查快照再执行命令。
///
/// 线程安全：内部使用 `OSAllocatedUnfairLock` 保护可变状态，注册表本身是 `Sendable`。
/// `menu(for:)` 在主线程注册快照，`performCommand` 的 `Task { @MainActor }` 反查快照，
/// 两者通过锁保证一致性。
///
/// 回收策略：保留最近 `retentionCount` 份快照，超出部分按 token 升序（最旧优先）淘汰。
/// token 由单调递增计数器分配，被淘汰的 token 永不重新分配，因此仍有效的 token 不会被复用。
/// 默认 `retentionCount = 128`，足以覆盖连续构建多个菜单（每个菜单通常 < 10 个叶子项）的可见窗口。
public final class FinderMenuActionRegistry: Sendable {
    /// 默认保留的快照数量。
    public static let defaultRetentionCount = 128

    private let retentionCount: Int
    private let state: OSAllocatedUnfairLock<State>

    private struct State {
        var snapshots: [Int: FinderMenuActionSnapshot] = [:]
        var nextToken: Int = 1
    }

    public init(retentionCount: Int = FinderMenuActionRegistry.defaultRetentionCount) {
        precondition(retentionCount > 0, "retentionCount must be positive")
        self.retentionCount = retentionCount
        self.state = OSAllocatedUnfairLock(initialState: State())
    }

    /// 注册一份快照，返回进程内唯一的正整数 token。
    @discardableResult
    public func register(_ snapshot: FinderMenuActionSnapshot) -> Int {
        state.withLock { state in
            let token = state.nextToken
            state.nextToken &+= 1
            state.snapshots[token] = snapshot
            if state.snapshots.count > retentionCount {
                let evictCount = state.snapshots.count - retentionCount
                let oldestTokens = state.snapshots.keys.sorted().prefix(evictCount)
                for token in oldestTokens {
                    state.snapshots.removeValue(forKey: token)
                }
            }
            return token
        }
    }

    /// 根据 token 反查快照。无效或已淘汰的 token 返回 nil。
    public func snapshot(for token: Int) -> FinderMenuActionSnapshot? {
        state.withLock { $0.snapshots[token] }
    }

    /// 当前存活的快照数量（用于测试与诊断）。
    public var liveCount: Int {
        state.withLock { $0.snapshots.count }
    }
}
