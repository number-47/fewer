import FewerCore
import Foundation

struct SystemMetricsSnapshot: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let cpuUsage: Double
    let cpu: CPUSnapshot?
    let gpu: GPUSnapshot?
    let memory: MemorySnapshot?
    let memoryUsage: Double
    let diskUsage: Double
    let disk: DiskSnapshot?
    let networkInBytesPerSecond: Double
    let networkOutBytesPerSecond: Double
    let networkInBytes: UInt64
    let networkOutBytes: UInt64
}

struct DiskSMARTSnapshot: Sendable {
    let temperatureCelsius: Double?
    let health: String?
    let lifeRemainingPercent: Double?
    let warning: String?
    let powerOnHours: UInt64?
}

struct DiskSnapshot: Identifiable, Sendable {
    let id: String
    let date: Date
    let volumeName: String
    let totalBytes: UInt64
    let availableBytes: UInt64
    let usedBytes: UInt64
    let fileSystem: String?
    let connectionType: String?
    let deviceName: String?
    let readBytes: UInt64?
    let writeBytes: UInt64?
    let readBytesPerSecond: Double?
    let writeBytesPerSecond: Double?
    let smart: DiskSMARTSnapshot?

    var usageRatio: Double {
        guard totalBytes > 0 else { return 0 }
        return min(max(Double(usedBytes) / Double(totalBytes), 0), 1)
    }
}

enum MemoryPressureLevel: String, Sendable {
    case normal = "正常"
    case warning = "警告"
    case critical = "严重"
}

struct MemoryPressureSnapshot: Sendable {
    let rawLevel: Int
    let level: MemoryPressureLevel
}

struct MemorySwapSnapshot: Sendable {
    let totalBytes: UInt64
    let usedBytes: UInt64
    let freeBytes: UInt64
}

struct MemorySnapshot: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let totalBytes: UInt64
    let usedBytes: UInt64
    let freeBytes: UInt64
    let appBytes: UInt64
    let activeBytes: UInt64
    let inactiveBytes: UInt64
    let wiredBytes: UInt64
    let compressedBytes: UInt64
    let cacheBytes: UInt64
    let swap: MemorySwapSnapshot?
    let pressure: MemoryPressureSnapshot?

    var usageRatio: Double {
        guard totalBytes > 0 else { return 0 }
        return min(max(Double(usedBytes) / Double(totalBytes), 0), 1)
    }
}

enum GPUDeviceType: String, Sendable {
    case integrated = "集成"
    case discrete = "独立"
    case external = "外置"
    case unknown = "未知"

    var menuBarPrefix: String {
        switch self {
        case .integrated: "iGPU"
        case .discrete: "dGPU"
        case .external: "eGPU"
        case .unknown: "GPU"
        }
    }
}

struct GPUDeviceSnapshot: Identifiable, Sendable {
    let id: String
    let model: String
    let vendor: String?
    let type: GPUDeviceType
    let coreCount: Int?
    let isActive: Bool
    let utilization: Double?
    let renderUtilization: Double?
    let tilerUtilization: Double?
    let framesPerSecond: Double?
    let aneUtilization: Double?
}

struct GPUSnapshot: Sendable {
    let date: Date
    let devices: [GPUDeviceSnapshot]
    let selectedDeviceID: String?
    let selectedAutomatically: Bool

    var selectedDevice: GPUDeviceSnapshot? {
        guard !devices.isEmpty else { return nil }
        if let selectedDeviceID, let selected = devices.first(where: { $0.id == selectedDeviceID }) {
            return selected
        }
        return devices.first(where: { $0.isActive && $0.utilization != nil })
            ?? devices.first(where: \.isActive)
            ?? devices.first
    }

    func device(id: String) -> GPUDeviceSnapshot? {
        devices.first { $0.id == id }
    }
}

struct CPUSnapshot: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let total: Double
    let user: Double
    let system: Double
    let idle: Double
    let cores: [CPUCoreSnapshot]
    let clusters: [CPUClusterSnapshot]
    let loadAverage: [Double]
    let uptime: TimeInterval?
    let temperatureCelsius: Double?
    let frequencyHz: UInt64?
}

struct CPUCoreSnapshot: Identifiable, Sendable {
    let id: Int
    let total: Double
    let user: Double
    let system: Double
    let idle: Double
}

struct CPUClusterSnapshot: Identifiable, Sendable {
    let id: Int
    let name: String
    let logicalCoreCount: Int
    let physicalCoreCount: Int
}

struct DefaultNetworkInterfaceSnapshot: Equatable, Sendable {
    let name: String
    let ipv4Address: String?
    let ipv6Address: String?
    let receivedBytes: UInt64
    let sentBytes: UInt64
}

/// 菜单栏当前真正需要的采样集合。保持为纯值类型，便于在不读取系统指标的情况下验证调度规则。
struct MonitorSamplingConfiguration: Equatable, Sendable {
    let activeModules: Set<SystemMonitorModuleID>
    let refreshInterval: TimeInterval?
    private let preferences: [SystemMonitorModuleID: MonitorModulePreferences]

    init(
        activeModules: Set<SystemMonitorModuleID>,
        preferences: [SystemMonitorModuleID: MonitorModulePreferences]
    ) {
        self.activeModules = activeModules
        self.preferences = preferences
        let intervals = activeModules.map { moduleID -> TimeInterval in
            let value = preferences[moduleID]?.refreshInterval
                ?? MonitorModulePreferences.default(for: moduleID).refreshInterval
            return value.isFinite && value > 0 ? max(value, 1) : 1
        }
        refreshInterval = intervals.min()
    }

    func including(_ modules: Set<SystemMonitorModuleID>) -> MonitorSamplingConfiguration {
        MonitorSamplingConfiguration(activeModules: activeModules.union(modules), preferences: preferences)
    }

    static let inactive = MonitorSamplingConfiguration(activeModules: [], preferences: [:])
}

/// MainActor UI facade。Timer 只触发异步采样请求，阻塞调用在 `SystemMetricsSampler` actor 中执行。
@MainActor
final class SystemMetricsService: ObservableObject {
    static let shared = SystemMetricsService()

    @Published private(set) var current = SystemMetricsSnapshot(
        date: .now,
        cpuUsage: 0,
        cpu: nil,
        gpu: nil,
        memory: nil,
        memoryUsage: 0,
        diskUsage: 0,
        disk: nil,
        networkInBytesPerSecond: 0,
        networkOutBytesPerSecond: 0,
        networkInBytes: 0,
        networkOutBytes: 0
    )
    @Published private(set) var history: [SystemMetricsSnapshot] = []
    @Published private(set) var localIPAddress = "未连接"
    @Published private(set) var localIPv4Address: String?
    @Published private(set) var localIPv6Address: String?
    @Published private(set) var defaultNetworkInterface: String?
    @Published private(set) var publicIPAddress: String?
    @Published private(set) var publicIPError: String?

    private let sampler = SystemMetricsSampler()
    private var timer: Timer?
    private var coordinator = SamplingCoordinator()
    private(set) var samplingConfiguration = MonitorSamplingConfiguration.inactive
    private var configuredSampling = MonitorSamplingConfiguration.inactive
    private var visibleModules: Set<SystemMonitorModuleID> = []

    private init() {}

    func start() {
        startTimerIfNeeded()
    }

    func stop() {
        configuredSampling = .inactive
        samplingConfiguration = .inactive
        coordinator.invalidate()
        stopTimer()
    }

    func configureSampling(_ configuration: MonitorSamplingConfiguration) {
        configuredSampling = configuration
        applySamplingConfiguration()
    }

    func setModuleVisible(_ moduleID: SystemMonitorModuleID, isVisible: Bool) {
        if isVisible {
            visibleModules.insert(moduleID)
        } else {
            visibleModules.remove(moduleID)
        }
        applySamplingConfiguration()
    }

    private func applySamplingConfiguration() {
        let configuration = configuredSampling.including(visibleModules)
        guard configuration != samplingConfiguration else { return }

        let newlyActiveModules = configuration.activeModules.subtracting(samplingConfiguration.activeModules)
        samplingConfiguration = configuration
        coordinator.invalidate()
        stopTimer()

        let sampler = self.sampler
        Task { await sampler.resetBaselines(for: newlyActiveModules) }

        guard configuration.refreshInterval != nil else { return }
        tickAndSample()
        startTimerIfNeeded()
    }

    private func startTimerIfNeeded() {
        guard timer == nil, let interval = samplingConfiguration.refreshInterval else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickAndSample() }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tickAndSample() {
        guard coordinator.beginSampling() else { return }
        let capturedGeneration = coordinator.generation
        let plan = MetricsSamplingPlan.plan(tick: coordinator.tick, activeModules: samplingConfiguration.activeModules)
        let activeModules = samplingConfiguration.activeModules
        let gpuSelectionID = ModuleHost.shared.preferences.monitorPreferences(for: .gpu).selectedItemID
        let sampler = self.sampler

        Task { [weak self] in
            guard let result = await sampler.sample(
                activeModules: activeModules,
                gpuSelectionID: gpuSelectionID,
                plan: plan
            ) else {
                await MainActor.run { self?.coordinator.completeSampling() }
                return
            }
            await MainActor.run {
                guard let self, self.coordinator.isCurrent(capturedGeneration) else { return }
                self.publish(result)
                self.coordinator.completeSampling()
            }
        }
    }

    private func publish(_ result: SystemMetricsSampleResult) {
        current = result.snapshot
        history.append(result.snapshot)
        history.removeAll { Date().timeIntervalSince($0.date) > 3_600 }
        if let name = result.networkInterfaceName {
            defaultNetworkInterface = name
            localIPv4Address = result.networkIPv4
            localIPv6Address = result.networkIPv6
            localIPAddress = result.networkIPv4 ?? result.networkIPv6 ?? "未连接"
        }
    }

    func refreshPublicIP() async {
        publicIPError = nil
        let sources = [
            URL(string: "https://api.ipify.org")!,
            URL(string: "https://ifconfig.me/ip")!,
        ]
        for source in sources {
            do {
                var request = URLRequest(url: source)
                request.timeoutInterval = 5
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !value.isEmpty
                else { continue }
                publicIPAddress = value
                return
            } catch {
                continue
            }
        }
        publicIPError = "两个公网 IP 服务均不可用"
    }
}
