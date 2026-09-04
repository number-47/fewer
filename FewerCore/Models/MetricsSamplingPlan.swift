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

/// 系统监控图表的一次轻量历史采样，不持有进程列表或当前详情快照。
public struct MonitorHistoryPoint: Equatable, Sendable {
    public let date: Date
    public let cpuUsage: Double?
    public let gpuUtilizationByDeviceID: [String: Double]
    public let memoryUsage: Double?
    public let disk: MonitorDiskHistoryPoint?
    public let networkInBytesPerSecond: Double
    public let networkOutBytesPerSecond: Double

    public init(
        date: Date,
        cpuUsage: Double?,
        gpuUtilizationByDeviceID: [String: Double],
        memoryUsage: Double?,
        disk: MonitorDiskHistoryPoint?,
        networkInBytesPerSecond: Double,
        networkOutBytesPerSecond: Double
    ) {
        self.date = date
        self.cpuUsage = cpuUsage
        self.gpuUtilizationByDeviceID = gpuUtilizationByDeviceID
        self.memoryUsage = memoryUsage
        self.disk = disk
        self.networkInBytesPerSecond = networkInBytesPerSecond
        self.networkOutBytesPerSecond = networkOutBytesPerSecond
    }

    public func gpuUtilization(for deviceID: String) -> Double? {
        gpuUtilizationByDeviceID[deviceID]
    }
}

public struct MonitorDiskHistoryPoint: Equatable, Sendable {
    public let usageRatio: Double
    public let readBytesPerSecond: Double?
    public let writeBytesPerSecond: Double?

    public init(
        usageRatio: Double,
        readBytesPerSecond: Double?,
        writeBytesPerSecond: Double?
    ) {
        self.usageRatio = usageRatio
        self.readBytesPerSecond = readBytesPerSecond
        self.writeBytesPerSecond = writeBytesPerSecond
    }
}

public enum MonitorHistoryRetention {
    public static func append(
        _ point: MonitorHistoryPoint,
        to history: inout [MonitorHistoryPoint],
        now: Date = .now,
        maximumAge: TimeInterval = 3_600
    ) {
        history.append(point)
        let expiredCount = history.prefix {
            now.timeIntervalSince($0.date) > maximumAge
        }.count
        if expiredCount > 0 {
            history.removeFirst(expiredCount)
        }
    }
}
