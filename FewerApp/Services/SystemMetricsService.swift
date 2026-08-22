import Darwin
import FewerCore
import Foundation
import IOKit

struct SystemMetricsSnapshot: Identifiable {
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

struct DiskSMARTSnapshot {
    let temperatureCelsius: Double?
    let health: String?
    let lifeRemainingPercent: Double?
    let warning: String?
    let powerOnHours: UInt64?
}

struct DiskSnapshot: Identifiable {
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

enum MemoryPressureLevel: String {
    case normal = "正常"
    case warning = "警告"
    case critical = "严重"
}

struct MemoryPressureSnapshot {
    let rawLevel: Int
    let level: MemoryPressureLevel
}

struct MemorySwapSnapshot {
    let totalBytes: UInt64
    let usedBytes: UInt64
    let freeBytes: UInt64
}

struct MemorySnapshot: Identifiable {
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

enum GPUDeviceType: String {
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

struct GPUDeviceSnapshot: Identifiable {
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

struct GPUSnapshot {
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

struct CPUSnapshot: Identifiable {
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

struct CPUCoreSnapshot: Identifiable {
    let id: Int
    let total: Double
    let user: Double
    let system: Double
    let idle: Double
}

struct CPUClusterSnapshot: Identifiable {
    let id: Int
    let name: String
    let logicalCoreCount: Int
    let physicalCoreCount: Int
}

private struct CPUTicks {
    let user: UInt64
    let system: UInt64
    let idle: UInt64
    let nice: UInt64

    var total: UInt64 { user + system + idle + nice }
}

private struct DiskIOCounters {
    let readBytes: UInt64
    let writeBytes: UInt64
}

struct DefaultNetworkInterfaceSnapshot: Equatable {
    let name: String
    let ipv4Address: String?
    let ipv6Address: String?
    let receivedBytes: UInt64
    let sentBytes: UInt64
}

/// 菜单栏当前真正需要的采样集合。保持为纯值类型，便于在不读取系统指标的情况下验证调度规则。
struct MonitorSamplingConfiguration: Equatable {
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

    private var timer: Timer?
    private var lastCPU: CPUTicks?
    private var lastCoreCPU: [Int: CPUTicks] = [:]
    private var lastNetwork: (interfaceName: String, inBytes: UInt64, outBytes: UInt64, date: Date)?
    private var lastDiskIO: (identifier: String, counters: DiskIOCounters, date: Date)?
    private let gpuReportReader = GPUReportReader()
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
        resetCounterBaselines(for: newlyActiveModules)
        stopTimer()

        guard configuration.refreshInterval != nil else { return }
        sample()
        startTimerIfNeeded()
    }

    private func startTimerIfNeeded() {
        guard timer == nil, let interval = samplingConfiguration.refreshInterval else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func resetCounterBaselines(for modules: Set<SystemMonitorModuleID>) {
        if modules.contains(.cpu) {
            lastCPU = nil
            lastCoreCPU.removeAll()
        }
        if modules.contains(.disk) {
            lastDiskIO = nil
        }
        if modules.contains(.network) {
            lastNetwork = nil
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

    private func sample() {
        let activeModules = samplingConfiguration.activeModules
        guard !activeModules.isEmpty else { return }

        let now = Date()
        let isCPUActive = activeModules.contains(.cpu)
        let isGPUActive = activeModules.contains(.gpu)
        let isMemoryActive = activeModules.contains(.memory)
        let isDiskActive = activeModules.contains(.disk)
        let isNetworkActive = activeModules.contains(.network)
        let network = isNetworkActive ? Self.defaultNetworkInterfaceSnapshot() : nil
        let rates = isNetworkActive ? networkRates(network, at: now) : nil
        let cpu = isCPUActive ? cpuSnapshot(at: now) : nil
        let gpu = isGPUActive ? gpuSnapshot(at: now) : nil
        let memory = isMemoryActive ? memorySnapshot(at: now) : nil
        let disk = isDiskActive ? diskSnapshot(at: now) : nil
        let snapshot = SystemMetricsSnapshot(
            date: now,
            cpuUsage: isCPUActive ? (cpu?.total ?? current.cpuUsage) : current.cpuUsage,
            cpu: isCPUActive ? cpu : current.cpu,
            gpu: isGPUActive ? gpu : current.gpu,
            memory: isMemoryActive ? memory : current.memory,
            memoryUsage: isMemoryActive ? (memory?.usageRatio ?? current.memoryUsage) : current.memoryUsage,
            diskUsage: isDiskActive ? (disk?.usageRatio ?? current.diskUsage) : current.diskUsage,
            disk: isDiskActive ? disk : current.disk,
            networkInBytesPerSecond: isNetworkActive ? (rates?.in ?? 0) : current.networkInBytesPerSecond,
            networkOutBytesPerSecond: isNetworkActive ? (rates?.out ?? 0) : current.networkOutBytesPerSecond,
            networkInBytes: isNetworkActive ? (network?.receivedBytes ?? 0) : current.networkInBytes,
            networkOutBytes: isNetworkActive ? (network?.sentBytes ?? 0) : current.networkOutBytes
        )
        current = snapshot
        history.append(snapshot)
        history.removeAll { now.timeIntervalSince($0.date) > 3_600 }
        if isNetworkActive {
            defaultNetworkInterface = network?.name
            localIPv4Address = network?.ipv4Address
            localIPv6Address = network?.ipv6Address
            localIPAddress = network?.ipv4Address ?? network?.ipv6Address ?? "未连接"
        }
    }

    private func cpuSnapshot(at date: Date) -> CPUSnapshot? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let ticks = CPUTicks(
            user: UInt64(info.cpu_ticks.0),
            system: UInt64(info.cpu_ticks.1),
            idle: UInt64(info.cpu_ticks.2),
            nice: UInt64(info.cpu_ticks.3)
        )
        defer { lastCPU = ticks }
        guard let total = usage(from: ticks, previous: lastCPU) else { return nil }

        return CPUSnapshot(
            date: date,
            total: total.total,
            user: total.user,
            system: total.system,
            idle: total.idle,
            cores: coreSnapshots(),
            clusters: cpuClusters(),
            loadAverage: loadAverage(),
            uptime: systemUptime(at: date),
            temperatureCelsius: nil,
            frequencyHz: sysctlUInt64(named: "hw.cpufrequency")
        )
    }

    private func coreSnapshots() -> [CPUCoreSnapshot] {
        var processorCount: natural_t = 0
        var processorInfo: processor_info_array_t?
        var processorInfoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &processorCount,
            &processorInfo,
            &processorInfoCount
        )
        guard result == KERN_SUCCESS, let processorInfo else { return [] }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: processorInfo)),
                vm_size_t(processorInfoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            )
        }

        var snapshots: [CPUCoreSnapshot] = []
        var nextTicks: [Int: CPUTicks] = [:]
        for index in 0..<Int(processorCount) {
            let offset = index * Int(CPU_STATE_MAX)
            let ticks = CPUTicks(
                user: UInt64(processorInfo[offset + Int(CPU_STATE_USER)]),
                system: UInt64(processorInfo[offset + Int(CPU_STATE_SYSTEM)]),
                idle: UInt64(processorInfo[offset + Int(CPU_STATE_IDLE)]),
                nice: UInt64(processorInfo[offset + Int(CPU_STATE_NICE)])
            )
            defer { nextTicks[index] = ticks }
            guard let usage = usage(from: ticks, previous: lastCoreCPU[index]) else { continue }
            snapshots.append(CPUCoreSnapshot(
                id: index,
                total: usage.total,
                user: usage.user,
                system: usage.system,
                idle: usage.idle
            ))
        }
        lastCoreCPU = nextTicks
        return snapshots
    }

    private func usage(from current: CPUTicks, previous: CPUTicks?) -> (total: Double, user: Double, system: Double, idle: Double)? {
        guard let previous,
              current.total > previous.total,
              current.user >= previous.user,
              current.system >= previous.system,
              current.idle >= previous.idle,
              current.nice >= previous.nice
        else { return nil }
        let total = Double(current.total - previous.total)
        guard total > 0 else { return nil }
        let user = Double((current.user - previous.user) + (current.nice - previous.nice)) / total
        let system = Double(current.system - previous.system) / total
        let idle = Double(current.idle - previous.idle) / total
        return (
            total: min(max(user + system, 0), 1),
            user: min(max(user, 0), 1),
            system: min(max(system, 0), 1),
            idle: min(max(idle, 0), 1)
        )
    }

    private func loadAverage() -> [Double] {
        var values = [Double](repeating: 0, count: 3)
        return Int(getloadavg(&values, Int32(values.count))) == values.count ? values : []
    }

    private func systemUptime(at date: Date) -> TimeInterval? {
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &bootTime, &size, nil, 0) == 0,
              bootTime.tv_sec > 0
        else { return nil }
        return max(0, date.timeIntervalSince1970 - TimeInterval(bootTime.tv_sec))
    }

    private func cpuClusters() -> [CPUClusterSnapshot] {
        guard let count = sysctlInt(named: "hw.nperflevels"), count > 0 else { return [] }
        return (0..<count).compactMap { index in
            guard let logical = sysctlInt(named: "hw.perflevel\(index).logicalcpu"), logical > 0 else { return nil }
            return CPUClusterSnapshot(
                id: index,
                name: "性能集群 \(index + 1)",
                logicalCoreCount: logical,
                physicalCoreCount: sysctlInt(named: "hw.perflevel\(index).physicalcpu") ?? logical
            )
        }
    }

    private func sysctlInt(named name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    private func sysctlUInt64(named name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0, value > 0 else { return nil }
        return value
    }

    private func gpuSnapshot(at date: Date) -> GPUSnapshot? {
        let requestedDeviceID = ModuleHost.shared.preferences.monitorPreferences(for: .gpu).selectedItemID
        let devices = Self.gpuDevices(report: gpuReportReader.sample())
        guard !devices.isEmpty else { return nil }
        let selectedDeviceID = requestedDeviceID.flatMap { requested in
            devices.contains(where: { $0.id == requested }) ? requested : nil
        }
        return GPUSnapshot(
            date: date,
            devices: devices,
            selectedDeviceID: selectedDeviceID,
            selectedAutomatically: selectedDeviceID == nil
        )
    }

    private static func gpuDevices(report: GPUReportSample) -> [GPUDeviceSnapshot] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOAccelerator"),
            &iterator
        ) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var devices: [GPUDeviceSnapshot] = []
        var usedIDs = Set<String>()
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            guard let properties = registryProperties(for: service) else { continue }
            let ioClass = stringValue(properties["IOClass"]) ?? ""
            let statistics = properties["PerformanceStatistics"] as? [String: Any] ?? [:]
            let model = modelName(properties: properties, statistics: statistics, ioClass: ioClass)
            let vendor = gpuVendor(properties: properties, model: model, ioClass: ioClass)
            let type = gpuType(properties: properties, vendor: vendor, ioClass: ioClass)
            let baseID = gpuIdentifier(properties: properties, ioClass: ioClass, model: model, service: service)
            let id = uniqueIdentifier(baseID, used: &usedIDs)
            let isActive = isGPUActive(properties)
            let isAppleGPU = vendor == "Apple" || ioClass.localizedCaseInsensitiveContains("agx")

            devices.append(GPUDeviceSnapshot(
                id: id,
                model: model,
                vendor: vendor,
                type: type,
                coreCount: integerValue(properties["gpu-core-count"])
                    ?? integerValue(properties["Core Count"])
                    ?? integerValue(properties["cores"]),
                isActive: isActive,
                utilization: percentageValue(statistics, keys: ["Device Utilization %", "GPU Activity(%)"]),
                renderUtilization: percentageValue(statistics, keys: ["Renderer Utilization %"]),
                tilerUtilization: percentageValue(statistics, keys: ["Tiler Utilization %"]),
                framesPerSecond: isAppleGPU ? report.framesPerSecond : nil,
                aneUtilization: isAppleGPU ? report.anePowerWatts.map {
                    min(max($0 / aneMaximumPower(for: model), 0), 1)
                } : nil
            ))
        }
        return devices.sorted { $0.id < $1.id }
    }

    private static func registryProperties(for service: io_registry_entry_t) -> [String: Any]? {
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let properties = unmanaged?.takeRetainedValue() as? [String: Any]
        else { return nil }
        return properties
    }

    private static func modelName(properties: [String: Any], statistics: [String: Any], ioClass: String) -> String {
        if let model = stringValue(properties["model"]), !model.isEmpty { return model }
        if let model = stringValue(statistics["model"]), !model.isEmpty { return model }
        if ioClass.localizedCaseInsensitiveContains("agx") { return "Apple Graphics" }
        if ioClass.localizedCaseInsensitiveContains("intel") { return "Intel Graphics" }
        if ioClass.localizedCaseInsensitiveContains("amd") { return "AMD Graphics" }
        if ioClass.localizedCaseInsensitiveContains("nvidia") { return "NVIDIA Graphics" }
        return "未知 GPU"
    }

    private static func gpuVendor(properties: [String: Any], model: String, ioClass: String) -> String? {
        let source = "\(model) \(ioClass)".lowercased()
        if source.contains("agx") || source.contains("apple") { return "Apple" }
        if source.contains("intel") { return "Intel" }
        if source.contains("amd") || source.contains("ati") { return "AMD" }
        if source.contains("nvidia") || source.contains("nv") { return "NVIDIA" }
        guard let vendorID = dataValue(properties["vendor-id"]), vendorID.count >= 2 else { return nil }
        let id = UInt16(vendorID[0]) | UInt16(vendorID[1]) << 8
        switch id {
        case 0x106B: return "Apple"
        case 0x8086: return "Intel"
        case 0x1002: return "AMD"
        case 0x10DE: return "NVIDIA"
        default: return nil
        }
    }

    private static func gpuType(properties: [String: Any], vendor: String?, ioClass: String) -> GPUDeviceType {
        if boolValue(properties["IOPCITunnelCompatible"]) == true || boolValue(properties["external"]) == true {
            return .external
        }
        if vendor == "Apple" || vendor == "Intel" || ioClass.localizedCaseInsensitiveContains("agx") {
            return .integrated
        }
        if vendor == "AMD" || vendor == "NVIDIA" { return .discrete }
        return .unknown
    }

    private static func gpuIdentifier(
        properties: [String: Any],
        ioClass: String,
        model: String,
        service: io_registry_entry_t
    ) -> String {
        if let match = stringValue(properties["IOPCIMatch"] ?? properties["IOPCIPrimaryMatch"]), !match.isEmpty {
            return "pci:\(match.lowercased())|\(ioClass)"
        }
        var path = [CChar](repeating: 0, count: 1_024)
        if IORegistryEntryGetPath(service, kIOServicePlane, &path) == KERN_SUCCESS {
            return "registry:\(String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))"
        }
        return "model:\(model)|\(ioClass)"
    }

    private static func uniqueIdentifier(_ base: String, used: inout Set<String>) -> String {
        guard !used.contains(base) else {
            var suffix = 2
            while used.contains("\(base)#\(suffix)") { suffix += 1 }
            let value = "\(base)#\(suffix)"
            used.insert(value)
            return value
        }
        used.insert(base)
        return base
    }

    private static func isGPUActive(_ properties: [String: Any]) -> Bool {
        guard let info = properties["AGCInfo"] as? [String: Any],
              let poweredOff = integerValue(info["poweredOffByAGC"])
        else { return true }
        return poweredOff == 0
    }

    private static func percentageValue(_ values: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            guard let raw = doubleValue(values[key]) else { continue }
            return min(max(raw / 100, 0), 1)
        }
        return nil
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let value = value as? String { return value.trimmingCharacters(in: .controlCharacters) }
        if let data = dataValue(value), let value = String(data: data, encoding: .utf8) {
            return value.trimmingCharacters(in: .controlCharacters)
        }
        return nil
    }

    private static func dataValue(_ value: Any?) -> Data? {
        if let value = value as? Data { return value }
        if let value = value as? NSData { return value as Data }
        return nil
    }

    private static func integerValue(_ value: Any?) -> Int? {
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? Int { return value }
        return nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        return nil
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return nil
    }

    private static func aneMaximumPower(for model: String) -> Double {
        let model = model.lowercased()
        if model.contains("ultra") {
            if model.contains("m4") { return 12 }
            if model.contains("m3") { return 6 }
            if model.contains("m2") { return 5 }
            return 4
        }
        if model.contains("m4") { return 6 }
        if model.contains("m3") { return 3 }
        if model.contains("m2") { return 2.5 }
        if model.contains("m1") { return 2 }
        return 8
    }

    private func memorySnapshot(at date: Date) -> MemorySnapshot? {
        var basicInfo = host_basic_info()
        var basicInfoCount = mach_msg_type_number_t(MemoryLayout<host_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let basicInfoResult = withUnsafeMutablePointer(to: &basicInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(basicInfoCount)) {
                host_info(mach_host_self(), HOST_BASIC_INFO, $0, &basicInfoCount)
            }
        }
        guard basicInfoResult == KERN_SUCCESS, basicInfo.max_mem > 0 else { return nil }

        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &statistics) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let pageSize = UInt64(getpagesize())
        let active = UInt64(statistics.active_count) * pageSize
        let speculative = UInt64(statistics.speculative_count) * pageSize
        let inactive = UInt64(statistics.inactive_count) * pageSize
        let wired = UInt64(statistics.wire_count) * pageSize
        let compressed = UInt64(statistics.compressor_page_count) * pageSize
        let free = UInt64(statistics.free_count) * pageSize
        let app = UInt64(statistics.internal_page_count) * pageSize
        let purgeable = UInt64(statistics.purgeable_count) * pageSize
        let external = UInt64(statistics.external_page_count) * pageSize
        let total = UInt64(basicInfo.max_mem)
        let usedBeforeCache = active + inactive + speculative + wired + compressed
        let cache = purgeable + external
        let used = min(total, usedBeforeCache > cache ? usedBeforeCache - cache : 0)

        return MemorySnapshot(
            date: date,
            totalBytes: total,
            usedBytes: used,
            freeBytes: free,
            appBytes: app,
            activeBytes: active,
            inactiveBytes: inactive,
            wiredBytes: wired,
            compressedBytes: compressed,
            cacheBytes: cache,
            swap: swapSnapshot(),
            pressure: memoryPressure()
        )
    }

    private func memoryPressure() -> MemoryPressureSnapshot? {
        var rawLevel: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &rawLevel, &size, nil, 0) == 0 else { return nil }
        let level: MemoryPressureLevel = switch rawLevel {
        case 2: .warning
        case 4: .critical
        default: .normal
        }
        return MemoryPressureSnapshot(rawLevel: Int(rawLevel), level: level)
    }

    private func swapSnapshot() -> MemorySwapSnapshot? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return MemorySwapSnapshot(
            totalBytes: usage.xsu_total,
            usedBytes: usage.xsu_used,
            freeBytes: usage.xsu_avail
        )
    }

    private func diskSnapshot(at date: Date) -> DiskSnapshot? {
        let rootURL = URL(fileURLWithPath: "/")
        guard let values = try? rootURL.resourceValues(forKeys: [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeLocalizedFormatDescriptionKey,
        ]),
        let total = values.volumeTotalCapacity,
        let available = values.volumeAvailableCapacityForImportantUsage,
        total > 0, available >= 0
        else {
            lastDiskIO = nil
            return nil
        }

        var fileStatus = statfs()
        let hasFileStatus = statfs("/", &fileStatus) == 0
        let mountSource = hasFileStatus ? Self.string(from: fileStatus.f_mntfromname) : nil
        let fileSystem = hasFileStatus ? Self.string(from: fileStatus.f_fstypename) : values.volumeLocalizedFormatDescription
        let deviceName = mountSource.flatMap(Self.diskDeviceName(from:))
        let device = deviceName.flatMap(Self.diskDevice)
        defer {
            if let device { IOObjectRelease(device) }
        }
        let counters = device.flatMap(Self.diskIOCounters)
        let rates = diskRates(counters, identifier: mountSource ?? rootURL.path, at: date)
        let totalBytes = UInt64(total)
        let availableBytes = UInt64(available)
        let used = totalBytes >= availableBytes ? totalBytes - availableBytes : 0

        return DiskSnapshot(
            id: mountSource ?? rootURL.path,
            date: date,
            volumeName: values.volumeName ?? "/",
            totalBytes: totalBytes,
            availableBytes: availableBytes,
            usedBytes: used,
            fileSystem: fileSystem,
            connectionType: device.flatMap(Self.diskConnectionType),
            deviceName: deviceName,
            readBytes: counters?.readBytes,
            writeBytes: counters?.writeBytes,
            readBytesPerSecond: rates.read,
            writeBytesPerSecond: rates.write,
            smart: device.flatMap(Self.diskSMARTSnapshot)
        )
    }

    private func diskRates(
        _ counters: DiskIOCounters?,
        identifier: String,
        at date: Date
    ) -> (read: Double?, write: Double?) {
        defer {
            lastDiskIO = counters.map { (identifier: identifier, counters: $0, date: date) }
        }
        guard let counters,
              let previous = lastDiskIO,
              previous.identifier == identifier,
              counters.readBytes >= previous.counters.readBytes,
              counters.writeBytes >= previous.counters.writeBytes
        else { return (nil, nil) }
        let interval = date.timeIntervalSince(previous.date)
        guard interval > 0 else { return (nil, nil) }
        return (
            Double(counters.readBytes - previous.counters.readBytes) / interval,
            Double(counters.writeBytes - previous.counters.writeBytes) / interval
        )
    }

    private static func diskDeviceName(from mountSource: String) -> String? {
        guard mountSource.hasPrefix("/dev/") else { return nil }
        let name = String(mountSource.dropFirst("/dev/".count))
        return name.isEmpty ? nil : name
    }

    private static func diskDevice(named name: String) -> io_registry_entry_t? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOMedia"),
            &iterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { return nil }
            if let properties = registryProperties(for: service), stringValue(properties["BSD Name"]) == name {
                return service
            }
            IOObjectRelease(service)
        }
    }

    private static func diskIOCounters(for device: io_registry_entry_t) -> DiskIOCounters? {
        guard let statistics = registryProperties(for: device)?["Statistics"] as? [String: Any],
              let read = uint64Value(statistics["Bytes read from block device"] ?? statistics["Bytes (Read)"] ?? statistics["Bytes read by user"]),
              let write = uint64Value(statistics["Bytes written to block device"] ?? statistics["Bytes (Write)"] ?? statistics["Bytes written by user"])
        else { return nil }
        return DiskIOCounters(readBytes: read, writeBytes: write)
    }

    private static func diskConnectionType(for device: io_registry_entry_t) -> String? {
        var entry: io_registry_entry_t = device
        var ownsEntry = false
        defer { if ownsEntry { IOObjectRelease(entry) } }

        while entry != 0 {
            let properties = registryProperties(for: entry)
            if let type = stringValue(properties?["Physical Interconnect"]), !type.isEmpty { return type }
            if boolValue(properties?["Removable"]) == true { return "可移动" }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS, parent != 0 else { break }
            if ownsEntry { IOObjectRelease(entry) }
            entry = parent
            ownsEntry = true
        }
        return "内置"
    }

    private static func diskSMARTSnapshot(for device: io_registry_entry_t) -> DiskSMARTSnapshot? {
        var entry: io_registry_entry_t = device
        var ownsEntry = false
        defer { if ownsEntry { IOObjectRelease(entry) } }

        while entry != 0 {
            if let properties = registryProperties(for: entry),
               let smart = smartProperties(from: properties) {
                return smart
            }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS, parent != 0 else { break }
            if ownsEntry { IOObjectRelease(entry) }
            entry = parent
            ownsEntry = true
        }
        return nil
    }

    private static func smartProperties(from properties: [String: Any]) -> DiskSMARTSnapshot? {
        let status = stringValue(properties["SMART Status"] ?? properties["SMARTStatus"])
        let attributes = properties["SMART Attributes"] as? [String: Any]
            ?? properties["SMARTAttributes"] as? [String: Any]
        let temperature = doubleValue(attributes?["Temperature"] ?? properties["Temperature"])
        let health = status ?? stringValue(attributes?["Health"])
        let life = doubleValue(attributes?["Lifetime Remaining"] ?? attributes?["Life Remaining"])
        let warning = stringValue(attributes?["Critical Warning"] ?? properties["SMART Warning"])
        let powerOnHours = uint64Value(attributes?["Power-On Hours"] ?? attributes?["Power On Hours"])
        guard status != nil || attributes != nil || temperature != nil || health != nil || life != nil || warning != nil || powerOnHours != nil else {
            return nil
        }
        return DiskSMARTSnapshot(
            temperatureCelsius: temperature,
            health: health,
            lifeRemainingPercent: life.map { $0 > 1 ? min($0, 100) : $0 * 100 },
            warning: warning,
            powerOnHours: powerOnHours
        )
    }

    private static func string<T>(from tuple: T) -> String? {
        var tuple = tuple
        return withUnsafePointer(to: &tuple) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) {
                let value = String(cString: $0)
                return value.isEmpty ? nil : value
            }
        }
    }

    private static func uint64Value(_ value: Any?) -> UInt64? {
        if let value = value as? NSNumber { return value.uint64Value }
        if let value = value as? UInt64 { return value }
        if let value = value as? Int, value >= 0 { return UInt64(value) }
        return nil
    }

    private func networkRates(_ network: DefaultNetworkInterfaceSnapshot?, at date: Date) -> (in: Double, out: Double) {
        guard let network else {
            lastNetwork = nil
            return (0, 0)
        }
        defer {
            lastNetwork = (
                interfaceName: network.name,
                inBytes: network.receivedBytes,
                outBytes: network.sentBytes,
                date: date
            )
        }
        guard let previous = lastNetwork,
              previous.interfaceName == network.name
        else { return (0, 0) }
        let interval = date.timeIntervalSince(previous.date)
        guard interval > 0 else { return (0, 0) }
        guard network.receivedBytes >= previous.inBytes,
              network.sentBytes >= previous.outBytes
        else { return (0, 0) }
        let inRate = Double(network.receivedBytes - previous.inBytes) / interval
        let outRate = Double(network.sentBytes - previous.outBytes) / interval
        return (inRate, outRate)
    }

    static func defaultRouteInterface(from routeOutputs: [String]) -> String? {
        for output in routeOutputs {
            for line in output.split(whereSeparator: \.isNewline) {
                let pieces = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard pieces.count == 2,
                      pieces[0].trimmingCharacters(in: .whitespaces) == "interface"
                else { continue }
                let name = pieces[1].trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { return name }
            }
        }
        return nil
    }

    private static func defaultNetworkInterfaceSnapshot() -> DefaultNetworkInterfaceSnapshot? {
        guard let interfaceName = defaultRouteInterface(from: [
            routeOutput(arguments: ["-n", "get", "default"]),
            routeOutput(arguments: ["-n", "get", "-inet6", "default"]),
        ]) else { return nil }
        return interfaceSnapshot(named: interfaceName)
    }

    private static func routeOutput(arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/route")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ""
        }
        guard process.terminationStatus == 0 else { return "" }
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    private static func interfaceSnapshot(named interfaceName: String) -> DefaultNetworkInterfaceSnapshot? {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return nil }
        defer { freeifaddrs(addresses) }
        var receivedBytes: UInt64?
        var sentBytes: UInt64?
        var ipv4Address: String?
        var ipv6Address: String?
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let interfaceNamePointer = interface.ifa_name,
                  String(cString: interfaceNamePointer) == interfaceName,
                  let address = interface.ifa_addr
            else { continue }
            switch Int32(address.pointee.sa_family) {
            case AF_LINK:
                guard let data = interface.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
                receivedBytes = UInt64(data.pointee.ifi_ibytes)
                sentBytes = UInt64(data.pointee.ifi_obytes)
            case AF_INET where ipv4Address == nil:
                ipv4Address = numericAddress(address)
            case AF_INET6 where ipv6Address == nil:
                ipv6Address = numericAddress(address)
            default:
                continue
            }
        }
        guard let receivedBytes, let sentBytes else { return nil }
        return DefaultNetworkInterfaceSnapshot(
            name: interfaceName,
            ipv4Address: ipv4Address,
            ipv6Address: ipv6Address,
            receivedBytes: receivedBytes,
            sentBytes: sentBytes
        )
    }

    private static func numericAddress(_ address: UnsafeMutablePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(
            address,
            socklen_t(address.pointee.sa_len),
            &host,
            socklen_t(host.count),
            nil,
            0,
            NI_NUMERICHOST
        ) == 0 else { return nil }
        return String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

private struct GPUReportSample {
    let framesPerSecond: Double?
    let anePowerWatts: Double?

    static let unavailable = Self(framesPerSecond: nil, anePowerWatts: nil)
}

private final class GPUReportReader {
    #if arch(arm64)
    private var frameChannels: CFMutableDictionary?
    private var frameSubscription: IOReportSubscriptionRef?
    private var previousFrameCount: Int64?
    private var previousFrameDate: CFAbsoluteTime?

    private var aneChannels: CFMutableDictionary?
    private var aneSubscription: IOReportSubscriptionRef?
    private var previousANEEnergy: Double?
    private var previousANEDate: Date?
    #endif

    init() {
        #if arch(arm64)
        setupFrames()
        setupANE()
        #endif
    }

    func sample() -> GPUReportSample {
        #if arch(arm64)
        return GPUReportSample(framesPerSecond: readFrames(), anePowerWatts: readANEPower())
        #else
        return .unavailable
        #endif
    }

    #if arch(arm64)
    private func setupFrames() {
        let groups = ["DCP", "DCPEXT0", "DCPEXT1", "DCPEXT2", "DCPEXT3"]
        var merged: CFMutableDictionary?
        for group in groups {
            guard let channels = IOReportCopyChannelsInGroup(group as CFString, "swap" as CFString, 0, 0, 0)?.takeRetainedValue() else { continue }
            if let merged {
                IOReportMergeChannels(merged, channels, nil)
            } else {
                merged = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, channels)
            }
        }
        guard let merged,
              let dictionary = merged as? [String: Any],
              dictionary["IOReportChannels"] != nil
        else { return }

        frameChannels = merged
        var subscriptionChannels: Unmanaged<CFMutableDictionary>?
        frameSubscription = IOReportCreateSubscription(nil, merged, &subscriptionChannels, 0, nil)
        subscriptionChannels?.release()
    }

    private func setupANE() {
        guard let channels = IOReportCopyChannelsInGroup("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue(),
              let mutable = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, channels),
              let dictionary = mutable as? [String: Any],
              dictionary["IOReportChannels"] != nil
        else { return }

        aneChannels = mutable
        var subscriptionChannels: Unmanaged<CFMutableDictionary>?
        aneSubscription = IOReportCreateSubscription(nil, mutable, &subscriptionChannels, 0, nil)
        subscriptionChannels?.release()
    }

    private func readFrames() -> Double? {
        guard let frameSubscription,
              let frameChannels,
              let sample = IOReportCreateSamples(frameSubscription, frameChannels, nil)?.takeRetainedValue(),
              let dictionary = sample as? [String: Any],
              let channels = dictionary["IOReportChannels"] as? NSArray
        else { return nil }

        var count: Int64 = 0
        for index in 0..<channels.count {
            let channel = unsafeBitCast(channels.object(at: index), to: CFDictionary.self)
            guard let group = IOReportChannelGetGroup(channel)?.takeUnretainedValue() as? String,
                  group.hasPrefix("DCP"),
                  let subgroup = IOReportChannelGetSubGroup(channel)?.takeUnretainedValue() as? String,
                  subgroup == "swap"
            else { continue }
            count += IOReportSimpleGetIntegerValue(channel, 0)
        }

        let now = CFAbsoluteTimeGetCurrent()
        defer {
            previousFrameCount = count
            previousFrameDate = now
        }
        guard let previousFrameCount, let previousFrameDate else { return nil }
        let elapsed = now - previousFrameDate
        let delta = count - previousFrameCount
        guard elapsed > 0, delta >= 0 else { return nil }
        return Double(delta) / elapsed
    }

    private func readANEPower() -> Double? {
        guard let aneSubscription,
              let aneChannels,
              let sample = IOReportCreateSamples(aneSubscription, aneChannels, nil)?.takeRetainedValue(),
              let dictionary = sample as? [String: Any],
              let channels = dictionary["IOReportChannels"] as? NSArray
        else { return nil }

        var energyJoules: Double = 0
        var foundANEChannel = false
        for index in 0..<channels.count {
            let channel = unsafeBitCast(channels.object(at: index), to: CFDictionary.self)
            guard let group = IOReportChannelGetGroup(channel)?.takeUnretainedValue() as? String,
                  group == "Energy Model",
                  let name = IOReportChannelGetChannelName(channel)?.takeUnretainedValue() as? String,
                  name.hasPrefix("ANE")
            else { continue }
            let value = Double(IOReportSimpleGetIntegerValue(channel, 0))
            let unit = (IOReportChannelGetUnitLabel(channel)?.takeUnretainedValue() as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            switch unit {
            case "mj": energyJoules += value / 1_000
            case "uj", "µj": energyJoules += value / 1_000_000
            case "nj": energyJoules += value / 1_000_000_000
            case "pj": energyJoules += value / 1_000_000_000_000
            default: energyJoules += value / 1_000_000_000
            }
            foundANEChannel = true
        }
        guard foundANEChannel else { return nil }

        let now = Date()
        defer {
            previousANEEnergy = energyJoules
            previousANEDate = now
        }
        guard let previousANEEnergy, let previousANEDate else { return nil }
        let elapsed = now.timeIntervalSince(previousANEDate)
        let delta = energyJoules - previousANEEnergy
        guard elapsed > 0, delta >= 0 else { return nil }
        return delta / elapsed
    }

    #endif
}
