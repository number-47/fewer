import Foundation

/// 决定一次 tick 中哪些模块需要新鲜采样、哪些可以复用上次结果。
/// CPU 和网络保持高频；GPU 和磁盘（含 SMART）按 N tick 低频采样。
public struct MetricsSamplingPlan: Equatable, Sendable {
    public let modulesToSample: Set<SystemMonitorModuleID>
    public let modulesToReuse: Set<SystemMonitorModuleID>

    public init(modulesToSample: Set<SystemMonitorModuleID>, modulesToReuse: Set<SystemMonitorModuleID>) {
        self.modulesToSample = modulesToSample
        self.modulesToReuse = modulesToReuse
    }

    public static func plan(
        tick: Int,
        activeModules: Set<SystemMonitorModuleID>,
        slowSamplingEveryNTicks: Int = 5
    ) -> MetricsSamplingPlan {
        guard !activeModules.isEmpty else {
            return .init(modulesToSample: [], modulesToReuse: [])
        }
        let slowModules: Set<SystemMonitorModuleID> = [.gpu, .disk]
        let shouldSampleSlow = tick % slowSamplingEveryNTicks == 0
        let modulesToSample = shouldSampleSlow
            ? activeModules
            : activeModules.subtracting(slowModules)
        let modulesToReuse = activeModules.subtracting(modulesToSample)
        return .init(modulesToSample: modulesToSample, modulesToReuse: modulesToReuse)
    }
}

/// 纯值类型，跟踪采样代际、合并状态和 tick 计数。
/// 在 MainActor 上维护，用于决定是否发起异步采样以及是否接受结果。
public struct SamplingCoordinator: Sendable {
    public private(set) var generation: Int = 0
    public private(set) var isSampling: Bool = false
    public private(set) var tick: Int = 0

    public init() {}

    /// 尝试开始一轮采样。如果上一轮未完成则返回 false（合并 tick）。
    public mutating func beginSampling() -> Bool {
        guard !isSampling else { return false }
        isSampling = true
        generation += 1
        return true
    }

    /// 标记当前采样完成并推进 tick。
    public mutating func completeSampling() {
        isSampling = false
        tick += 1
    }

    /// 配置变化时使当前代际失效，丢弃未来结果。
    public mutating func invalidate() {
        generation += 1
        isSampling = false
    }

    /// 判断结果是否来自当前代际。
    public func isCurrent(_ resultGeneration: Int) -> Bool {
        resultGeneration == generation
    }
}
