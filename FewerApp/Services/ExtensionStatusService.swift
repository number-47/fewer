import Foundation
import FewerCore

enum ExtensionStatus: Equatable, Sendable {
    case enabled
    case notEnabled
    case unknown

    var title: String {
        switch self {
        case .enabled: "已启用"
        case .notEnabled: "未启用"
        case .unknown: "需要确认"
        }
    }
}

/// `finderExtensionStatus()` 启动 `/usr/bin/pluginkit` 并 `waitUntilExit()`，是同步阻塞调用，
/// 绝不能在 MainActor 上执行。`cachedStatus()` 提供带超时、缓存和单飞的 async 入口。
enum ExtensionStatusService {
    private static let cache = ExtensionStatusCache()

    static func cachedStatus() async -> ExtensionStatus {
        await cache.status(forceRefresh: false)
    }

    static func refreshStatus() async -> ExtensionStatus {
        await cache.status(forceRefresh: true)
    }

    /// 同步版本，仅用于后台 Task.detached 内部调用；不在 MainActor 使用。
    static func finderExtensionStatus() -> ExtensionStatus {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        process.arguments = ["-m", "-i", "com.number47.fewer.finder-extension"]
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            guard !process.isRunning else {
                process.terminate()
                return .unknown
            }
            let output = String(
                data: pipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            if output.contains("+    com.number47.fewer.finder-extension") { return .enabled }
            if output.contains("com.number47.fewer.finder-extension") { return .notEnabled }
            return .unknown
        } catch {
            return .unknown
        }
    }

    static func finderMenuDiagnostic() -> FinderMenuDiagnostic? {
        FinderMenuDiagnosticStore().load()
    }

}

private actor ExtensionStatusCache {
    private let cacheTTL: TimeInterval = 5
    private var cached: (status: ExtensionStatus, timestamp: Date)?
    private var inFlight: Task<ExtensionStatus, Never>?

    func status(forceRefresh: Bool) async -> ExtensionStatus {
        if !forceRefresh,
           let cached,
           Date().timeIntervalSince(cached.timestamp) < cacheTTL {
            return cached.status
        }
        if let inFlight {
            return await inFlight.value
        }
        let task = Task.detached(priority: .utility) {
            ExtensionStatusService.finderExtensionStatus()
        }
        inFlight = task
        let result = await task.value
        cached = (result, Date())
        inFlight = nil
        return result
    }
}
