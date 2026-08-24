import Foundation
import XCTest
@testable import FewerCore

@MainActor
final class FinderMenuActionRegistryTests: XCTestCase {
    private func makeContext(kind: FinderMenuKind = .container) -> FinderMenuContext {
        FinderMenuContext(
            kind: kind,
            selectedURLs: [],
            targetURL: URL(fileURLWithPath: "/tmp", isDirectory: true),
            isTargetWritable: true,
            hasCutTransaction: false
        )
    }

    // MARK: - Token uniqueness & positivity

    func testRegisteredTokensArePositiveIntegers() {
        let registry = FinderMenuActionRegistry()
        let snapshot = FinderMenuActionSnapshot(context: makeContext(), command: .copyPath)
        let token = registry.register(snapshot)

        XCTAssertGreaterThan(token, 0)
    }

    func testConsecutiveRegistrationsYieldUniqueTokens() {
        let registry = FinderMenuActionRegistry()
        var tokens: Set<Int> = []

        for _ in 0..<50 {
            let snapshot = FinderMenuActionSnapshot(context: makeContext(), command: .copyPath)
            let token = registry.register(snapshot)
            XCTAssertFalse(tokens.contains(token), "token \(token) was reused")
            tokens.insert(token)
        }
        XCTAssertEqual(tokens.count, 50)
    }

    // MARK: - Snapshot lookup

    func testLookupReturnsRegisteredSnapshot() {
        let registry = FinderMenuActionRegistry()
        let context = makeContext()
        let snapshot = FinderMenuActionSnapshot(context: context, command: .newFolder)
        let token = registry.register(snapshot)

        let resolved = registry.snapshot(for: token)
        XCTAssertEqual(resolved, snapshot)
    }

    func testLookupForUnknownTokenReturnsNil() {
        let registry = FinderMenuActionRegistry()
        XCTAssertNil(registry.snapshot(for: 999))
    }

    func testLookupForNonPositiveTokenReturnsNil() {
        let registry = FinderMenuActionRegistry()
        XCTAssertNil(registry.snapshot(for: 0))
        XCTAssertNil(registry.snapshot(for: -1))
    }

    // MARK: - Snapshot isolation across menus

    func testFirstMenuSnapshotSurvivesSecondMenuBuildWithDifferentContext() {
        let registry = FinderMenuActionRegistry()

        // 构建第一个菜单：容器上下文，copyPath 命令
        let firstContext = makeContext(kind: .container)
        let firstSnapshot = FinderMenuActionSnapshot(context: firstContext, command: .copyPath)
        let firstToken = registry.register(firstSnapshot)

        // 构建第二个菜单：items 上下文，cut 命令
        let secondContext = FinderMenuContext(
            kind: .items,
            selectedURLs: [URL(fileURLWithPath: "/tmp/A.txt")],
            targetURL: URL(fileURLWithPath: "/tmp", isDirectory: true),
            isTargetWritable: true,
            hasCutTransaction: false
        )
        let secondSnapshot = FinderMenuActionSnapshot(context: secondContext, command: .cut)
        let secondToken = registry.register(secondSnapshot)

        // 第一个菜单的 token 仍解析到第一个快照，不受第二个菜单影响
        let resolvedFirst = registry.snapshot(for: firstToken)
        XCTAssertEqual(resolvedFirst?.context.kind, .container)
        XCTAssertEqual(resolvedFirst?.command, .copyPath)

        let resolvedSecond = registry.snapshot(for: secondToken)
        XCTAssertEqual(resolvedSecond?.context.kind, .items)
        XCTAssertEqual(resolvedSecond?.command, .cut)
    }

    // MARK: - Reclamation

    func testReclamationEvictsOldestSnapshotsBeyondRetentionCount() {
        let registry = FinderMenuActionRegistry(retentionCount: 3)

        // 注册 3 个快照，正好满
        var tokens: [Int] = []
        for i in 0..<3 {
            let token = registry.register(
                FinderMenuActionSnapshot(context: makeContext(), command: .copyPath)
            )
            tokens.append(token)
        }
        XCTAssertEqual(registry.liveCount, 3)

        // 注册第 4 个，最旧的（tokens[0]）应被淘汰
        let fourthToken = registry.register(
            FinderMenuActionSnapshot(context: makeContext(), command: .cut)
        )
        XCTAssertEqual(registry.liveCount, 3)
        XCTAssertNil(registry.snapshot(for: tokens[0]), "oldest token should be evicted")
        XCTAssertNotNil(registry.snapshot(for: tokens[1]))
        XCTAssertNotNil(registry.snapshot(for: tokens[2]))
        XCTAssertNotNil(registry.snapshot(for: fourthToken))
    }

    func testRegistryDoesNotGrowUnbounded() {
        let registry = FinderMenuActionRegistry(retentionCount: 10)

        for _ in 0..<1000 {
            _ = registry.register(
                FinderMenuActionSnapshot(context: makeContext(), command: .copyPath)
            )
        }
        XCTAssertEqual(registry.liveCount, 10)
    }

    func testEvictedTokensAreNeverReused() {
        let registry = FinderMenuActionRegistry(retentionCount: 2)
        var allTokens: [Int] = []

        for _ in 0..<10 {
            let token = registry.register(
                FinderMenuActionSnapshot(context: makeContext(), command: .copyPath)
            )
            allTokens.append(token)
        }

        // 所有 token 互不相同（单调递增计数器，被淘汰的 token 不会重新分配）
        XCTAssertEqual(Set(allTokens).count, 10)
        // 最新两个 token 仍有效
        XCTAssertNotNil(registry.snapshot(for: allTokens.last!))
        XCTAssertNotNil(registry.snapshot(for: allTokens[allTokens.count - 2]))
        // 最早的 token 已被淘汰
        XCTAssertNil(registry.snapshot(for: allTokens[0]))
    }

    // MARK: - Still-valid token after second menu build

    func testStillValidTokenFromFirstMenuIsNotInvalidatedBySecondMenu() {
        let registry = FinderMenuActionRegistry(retentionCount: 128)

        // 模拟第一个菜单的多个叶子项
        let firstContext = makeContext(kind: .container)
        var firstTokens: [Int] = []
        for _ in 0..<5 {
            firstTokens.append(
                registry.register(
                    FinderMenuActionSnapshot(context: firstContext, command: .copyPath)
                )
            )
        }

        // 模拟第二个菜单的叶子项
        let secondContext = makeContext(kind: .items)
        var secondTokens: [Int] = []
        for _ in 0..<5 {
            secondTokens.append(
                registry.register(
                    FinderMenuActionSnapshot(context: secondContext, command: .cut)
                )
            )
        }

        // 第一个菜单的所有 token 仍有效（未超过 retentionCount）
        for token in firstTokens {
            let resolved = registry.snapshot(for: token)
            XCTAssertEqual(resolved?.context.kind, .container)
            XCTAssertEqual(resolved?.command, .copyPath)
        }
        // 第二个菜单的 token 也有效
        for token in secondTokens {
            let resolved = registry.snapshot(for: token)
            XCTAssertEqual(resolved?.context.kind, .items)
            XCTAssertEqual(resolved?.command, .cut)
        }
    }

    // MARK: - Equatable conformance

    func testSnapshotsWithSameContextAndCommandAreEqual() {
        let context = makeContext()
        let a = FinderMenuActionSnapshot(context: context, command: .copyPath)
        let b = FinderMenuActionSnapshot(context: context, command: .copyPath)
        XCTAssertEqual(a, b)
    }

    func testSnapshotsWithDifferentCommandsAreNotEqual() {
        let context = makeContext()
        let a = FinderMenuActionSnapshot(context: context, command: .copyPath)
        let b = FinderMenuActionSnapshot(context: context, command: .cut)
        XCTAssertNotEqual(a, b)
    }
}
