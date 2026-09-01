import Darwin
import FewerCore
import Foundation
import IOKit

/// 后台采样结果。跨越 actor 边界传递给 MainActor facade。
struct SystemMetricsSampleResult: Sendable {
    let snapshot: SystemMetricsSnapshot
    let networkInterfaceName: String?
    let networkIPv4: String?
    let networkIPv6: String?
}

/// 非 MainActor 的采样 actor。持有所有阻塞采样状态和 IOKit/Mach/sysctl 调用。
/// MainActor 通过 `sample()` 获取 Sendable 结果；`isSampling` 防止并发采样。
actor SystemMetricsSampler {

    private var lastCPU: CPUTicks?
    private var lastCoreCPU: [Int: CPUTicks] = [:]
    private var lastNetwork: (interfaceName: String, inBytes: UInt64, outBytes: UInt64, date: Date)?
    private var lastDiskIO: (identifier: String, counters: DiskIOCounters, date: Date)?
    private let cpuFrequencyReader = CPUFrequencyReader()
    private let cpuTemperatureReader = CPUTemperatureReader()
    private let gpuReportReader = GPUReportReader()

    private var isSampling = false

    private var cachedGPU: GPUSnapshot?
    private var cachedDisk: DiskSnapshot?
    private var lastSnapshot: SystemMetricsSnapshot?

    func resetBaselines(for modules: Set<SystemMonitorModuleID>) {
        if modules.contains(.cpu) {
            lastCPU = nil
            lastCoreCPU.removeAll()
        }
        if modules.contains(.disk) {
            lastDiskIO = nil
            cachedDisk = nil
        }
        if modules.contains(.network) {
            lastNetwork = nil
        }
        if modules.contains(.gpu) {
            cachedGPU = nil
        }
    }

    /// 执行一轮采样。如果上一轮未完成则返回 nil（调用方合并 tick）。
    func sample(
        activeModules: Set<SystemMonitorModuleID>,
        gpuSelectionID: String?,
        plan: MetricsSamplingPlan
    ) -> SystemMetricsSampleResult? {
        guard !isSampling else { return nil }
        isSampling = true
        defer { isSampling = false }

        let now = Date()
        let isCPUActive = activeModules.contains(.cpu)
        let isGPUActive = activeModules.contains(.gpu)
        let isMemoryActive = activeModules.contains(.memory)
        let isDiskActive = activeModules.contains(.disk)
        let isNetworkActive = activeModules.contains(.network)

        let shouldSampleCPU = plan.modulesToSample.contains(.cpu)
        let shouldSampleGPU = plan.modulesToSample.contains(.gpu)
        let shouldSampleMemory = plan.modulesToSample.contains(.memory)
        let shouldSampleDisk = plan.modulesToSample.contains(.disk)
        let shouldSampleNetwork = plan.modulesToSample.contains(.network)

        let network = shouldSampleNetwork ? Self.defaultNetworkInterfaceSnapshot() : nil
        let rates = shouldSampleNetwork ? networkRates(network, at: now) : nil
        let cpu = shouldSampleCPU ? cpuSnapshot(at: now) : nil
        let gpu = shouldSampleGPU ? gpuSnapshot(at: now, selectionID: gpuSelectionID) : nil
        let memory = shouldSampleMemory ? memorySnapshot(at: now) : nil
        let disk = shouldSampleDisk ? diskSnapshot(at: now) : nil

        if shouldSampleGPU { cachedGPU = gpu }
        if shouldSampleDisk { cachedDisk = disk }

        let prev = lastSnapshot

        let gpuValue: GPUSnapshot? = shouldSampleGPU ? (gpu ?? cachedGPU) : (isGPUActive ? cachedGPU : prev?.gpu)
        let diskValue: DiskSnapshot? = shouldSampleDisk ? (disk ?? cachedDisk) : (isDiskActive ? cachedDisk : prev?.disk)

        let snapshot = SystemMetricsSnapshot(
            date: now,
            cpuUsage: isCPUActive ? (cpu?.total ?? prev?.cpuUsage ?? 0) : (prev?.cpuUsage ?? 0),
            cpu: isCPUActive ? (shouldSampleCPU ? cpu : prev?.cpu) : prev?.cpu,
            gpu: isGPUActive ? gpuValue : prev?.gpu,
            memory: isMemoryActive ? (shouldSampleMemory ? memory : prev?.memory) : prev?.memory,
            memoryUsage: isMemoryActive ? (memory?.usageRatio ?? prev?.memoryUsage ?? 0) : (prev?.memoryUsage ?? 0),
            diskUsage: isDiskActive ? (diskValue?.usageRatio ?? prev?.diskUsage ?? 0) : (prev?.diskUsage ?? 0),
            disk: isDiskActive ? diskValue : prev?.disk,
            networkInBytesPerSecond: isNetworkActive ? (rates?.in ?? prev?.networkInBytesPerSecond ?? 0) : (prev?.networkInBytesPerSecond ?? 0),
            networkOutBytesPerSecond: isNetworkActive ? (rates?.out ?? prev?.networkOutBytesPerSecond ?? 0) : (prev?.networkOutBytesPerSecond ?? 0),
            networkInBytes: isNetworkActive ? (network?.receivedBytes ?? prev?.networkInBytes ?? 0) : (prev?.networkInBytes ?? 0),
            networkOutBytes: isNetworkActive ? (network?.sentBytes ?? prev?.networkOutBytes ?? 0) : (prev?.networkOutBytes ?? 0)
        )

        lastSnapshot = snapshot

        let networkInfo: SystemMetricsSampleResult? = isNetworkActive ? .init(
            snapshot: snapshot,
            networkInterfaceName: network?.name,
            networkIPv4: network?.ipv4Address,
            networkIPv6: network?.ipv6Address
        ) : nil

        return networkInfo ?? .init(
            snapshot: snapshot,
            networkInterfaceName: nil,
            networkIPv4: nil,
            networkIPv6: nil
        )
    }

    // MARK: - CPU

    private func cpuSnapshot(at date: Date) -> CPUSnapshot? {
        let frequencyHz = cpuFrequencyReader.sample() ?? sysctlUInt64(named: "hw.cpufrequency")
        let temperatureCelsius = cpuTemperatureReader.sample()
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
            temperatureCelsius: temperatureCelsius,
            frequencyHz: frequencyHz
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

    // MARK: - GPU

    private func gpuSnapshot(at date: Date, selectionID: String?) -> GPUSnapshot? {
        let devices = Self.gpuDevices(report: gpuReportReader.sample())
        guard !devices.isEmpty else { return nil }
        let selectedDeviceID = selectionID.flatMap { requested in
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
            let gpuConfiguration = properties["GPUConfigurationVariable"] as? [String: Any]
            let powerManagement = properties["IOPowerManagement"] as? [String: Any]
            let model = modelName(properties: properties, statistics: statistics, ioClass: ioClass)
            let vendor = gpuVendor(properties: properties, model: model, ioClass: ioClass)
            let deviceType = gpuDeviceType(model: model, ioClass: ioClass)
            let utilization = doubleValue(statistics["Device Utilization %"] ?? statistics["utilization %"])
            let renderUtilization = doubleValue(statistics["Renderer Utilization %"] ?? statistics["renderUtilization %"])
            let tilerUtilization = doubleValue(statistics["Tiler Utilization %"] ?? statistics["tilerUtilization %"])
            let coreCount = integerValue(
                statistics["core count"]
                    ?? statistics["Core Count"]
                    ?? properties["gpu-core-count"]
                    ?? gpuConfiguration?["num_cores"]
            )
            let isActive = boolValue(statistics["Device Active"] ?? properties["Device Active"])
                ?? boolValue(properties["CommandSubmissionEnabled"])
                ?? integerValue(powerManagement?["CurrentPowerState"]).map { $0 > 0 }
                ?? (!statistics.isEmpty)

            let baseID = (model.isEmpty ? (vendor ?? ioClass) : model) + "-" + deviceType.rawValue
            var deviceID = baseID
            var suffix = 2
            while usedIDs.contains(deviceID) {
                deviceID = "\(baseID)-\(suffix)"
                suffix += 1
            }
            usedIDs.insert(deviceID)

            devices.append(GPUDeviceSnapshot(
                id: deviceID,
                model: model,
                vendor: vendor,
                type: deviceType,
                coreCount: coreCount,
                isActive: isActive,
                utilization: utilization,
                renderUtilization: renderUtilization,
                tilerUtilization: tilerUtilization,
                framesPerSecond: report.framesPerSecond,
                aneUtilization: report.anePowerWatts
            ))
        }
        return devices
    }

    private static func gpuDeviceType(model: String, ioClass: String) -> GPUDeviceType {
        let lower = (model + " " + ioClass).lowercased()
        if lower.contains("external") || lower.contains("egpu") {
            return .external
        }
        if lower.contains("apple") || lower.contains("agx") || lower.contains("integrated") || lower.contains("gmux") || lower.contains("intel") {
            return .integrated
        }
        if lower.contains("discrete") || lower.contains("radeon") || lower.contains("nvidia") || lower.contains("amd") {
            return .discrete
        }
        return .unknown
    }

    private static func modelName(properties: [String: Any], statistics: [String: Any], ioClass: String) -> String {
        if let model = stringValue(properties["Model"] ?? properties["model"] ?? statistics["Model"] ?? properties["IOName"]) {
            return model
        }
        let reportClass = stringValue(statistics["classCode"] ?? properties["classCode"])
        if let reportClass, !reportClass.isEmpty {
            return reportClass
        }
        return stringValue(properties["IOClass"]) ?? ioClass
    }

    private static func gpuVendor(properties: [String: Any], model: String, ioClass: String) -> String? {
        if let vendor = stringValue(properties["Vendor Name"] ?? properties["vendor"] ?? properties["Vendor"]) {
            return vendor
        }
        let vendorID = stringValue(properties["vendor-id"] ?? properties["VendorID"])
        if let vendorID {
            switch vendorID.lowercased() {
            case "0x106b": return "Apple"
            case "0x1002": return "AMD"
            case "0x10de": return "NVIDIA"
            case "0x8086", "0x80867": return "Intel"
            default: break
            }
        }
        let lower = (model + " " + ioClass).lowercased()
        if lower.contains("radeon") || lower.contains("amd") { return "AMD" }
        if lower.contains("nvidia") || lower.contains("geforce") { return "NVIDIA" }
        if lower.contains("intel") { return "Intel" }
        if lower.contains("apple") { return "Apple" }
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

    // MARK: - Memory

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

    // MARK: - Disk

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
        let registrySMART = device.flatMap(Self.diskSMARTSnapshot)
        let diskutilSMART = Self.diskutilSMARTSnapshot(for: rootURL.path)
        let smart = registrySMART.map { registry in
            DiskSMARTSnapshot(
                temperatureCelsius: registry.temperatureCelsius,
                health: registry.health ?? diskutilSMART?.health,
                lifeRemainingPercent: registry.lifeRemainingPercent,
                warning: registry.warning,
                powerOnHours: registry.powerOnHours
            )
        } ?? diskutilSMART
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
            smart: smart
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

    // MARK: - Network

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

    // MARK: - Static helpers

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
        var entry: io_registry_entry_t = device
        var ownsEntry = false
        defer { if ownsEntry { IOObjectRelease(entry) } }

        while entry != 0 {
            if let statistics = registryProperties(for: entry)?["Statistics"] as? [String: Any],
               let read = uint64Value(statistics["Bytes read from block device"] ?? statistics["Bytes (Read)"] ?? statistics["Bytes read by user"]),
               let write = uint64Value(statistics["Bytes written to block device"] ?? statistics["Bytes (Write)"] ?? statistics["Bytes written by user"]) {
                return DiskIOCounters(readBytes: read, writeBytes: write)
            }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS, parent != 0 else { return nil }
            if ownsEntry { IOObjectRelease(entry) }
            entry = parent
            ownsEntry = true
        }
        return nil
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

    private static func diskutilSMARTSnapshot(for path: String) -> DiskSMARTSnapshot? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["info", "-plist", path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let propertyList = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let properties = propertyList as? [String: Any],
              let health = stringValue(properties["SMARTStatus"]),
              !health.isEmpty
        else { return nil }

        return DiskSMARTSnapshot(
            temperatureCelsius: nil,
            health: health,
            lifeRemainingPercent: nil,
            warning: nil,
            powerOnHours: nil
        )
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

    private static func registryProperties(for service: io_registry_entry_t) -> [String: Any]? {
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = properties?.takeRetainedValue() as? [String: Any]
        else { return nil }
        return dictionary
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? Data, let value = String(data: value, encoding: .utf8) {
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

    private static func uint64Value(_ value: Any?) -> UInt64? {
        if let value = value as? NSNumber { return value.uint64Value }
        if let value = value as? UInt64 { return value }
        if let value = value as? Int, value >= 0 { return UInt64(value) }
        return nil
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
}

// MARK: - Supporting Types

struct CPUTicks {
    let user: UInt64
    let system: UInt64
    let idle: UInt64
    let nice: UInt64
    var total: UInt64 { user + system + idle + nice }
}

struct DiskIOCounters {
    let readBytes: UInt64
    let writeBytes: UInt64
}

struct GPUReportSample {
    let framesPerSecond: Double?
    let anePowerWatts: Double?
    static let unavailable = Self(framesPerSecond: nil, anePowerWatts: nil)
}

final class GPUReportReader {
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
