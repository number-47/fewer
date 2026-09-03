import Foundation

public struct ProcessIdentity: Hashable, Sendable {
    public let pid: Int32
    public let startTime: UInt64

    public init(pid: Int32, startTime: UInt64) {
        self.pid = pid
        self.startTime = startTime
    }
}

public struct ProcessMetric: Identifiable, Equatable, Sendable {
    public let id: ProcessIdentity
    public let name: String
    public let executablePath: String?
    public let userID: UInt32
    public let cpuUsage: Double?
    public let memoryBytes: UInt64
    public let gpuUsage: Double?

    public var pid: Int32 { id.pid }

    public init(
        id: ProcessIdentity,
        name: String,
        executablePath: String?,
        userID: UInt32,
        cpuUsage: Double?,
        memoryBytes: UInt64,
        gpuUsage: Double?
    ) {
        self.id = id
        self.name = name
        self.executablePath = executablePath
        self.userID = userID
        self.cpuUsage = cpuUsage
        self.memoryBytes = memoryBytes
        self.gpuUsage = gpuUsage
    }
}

public struct GPUProcessCounter: Equatable, Sendable {
    public let creator: String
    public let accumulatedTime: UInt64

    public init(creator: String, accumulatedTime: UInt64) {
        self.creator = creator
        self.accumulatedTime = accumulatedTime
    }
}

public struct GPUProcessCreator: Equatable, Sendable {
    public let pid: Int32
    public let name: String

    public init(pid: Int32, name: String) {
        self.pid = pid
        self.name = name
    }
}

public enum ProcessMetricLogic {
    public static func absoluteTimeToNanoseconds(_ value: UInt64, numerator: UInt64, denominator: UInt64) -> UInt64 {
        guard denominator > 0 else { return 0 }
        let (whole, wholeOverflow) = (value / denominator).multipliedReportingOverflow(by: numerator)
        let (fractionProduct, fractionOverflow) = (value % denominator).multipliedReportingOverflow(by: numerator)
        guard !wholeOverflow, !fractionOverflow else { return .max }
        let fraction = fractionProduct / denominator
        let (result, overflow) = whole.addingReportingOverflow(fraction)
        return overflow ? .max : result
    }

    public static func intervalRatio(current: UInt64, previous: UInt64?, elapsed: TimeInterval) -> Double? {
        guard let previous, current >= previous, elapsed > 0 else { return nil }
        return Double(current - previous) / 1_000_000_000 / elapsed
    }

    public static func gpuCreator(from value: String) -> GPUProcessCreator? {
        guard value.hasPrefix("pid "),
              let comma = value.firstIndex(of: ","),
              let pid = Int32(value[value.index(value.startIndex, offsetBy: 4)..<comma])
        else { return nil }
        let name = value[value.index(after: comma)...].trimmingCharacters(in: .whitespaces)
        guard pid > 0, !name.isEmpty else { return nil }
        return GPUProcessCreator(pid: pid, name: name)
    }

    public static func aggregateGPU(_ counters: [GPUProcessCounter]) -> [Int32: UInt64] {
        var result: [Int32: UInt64] = [:]
        for counter in counters {
            guard let creator = gpuCreator(from: counter.creator) else { continue }
            let (sum, overflow) = result[creator.pid, default: 0].addingReportingOverflow(counter.accumulatedTime)
            result[creator.pid] = overflow ? .max : sum
        }
        return result
    }

    public static func topCPU(_ processes: [ProcessMetric], limit: Int = 5) -> [ProcessMetric] {
        top(processes, limit: limit, value: \.cpuUsage)
    }

    public static func topMemory(_ processes: [ProcessMetric], limit: Int = 5) -> [ProcessMetric] {
        Array(processes.sorted {
            if $0.memoryBytes != $1.memoryBytes { return $0.memoryBytes > $1.memoryBytes }
            return $0.pid < $1.pid
        }.prefix(max(0, limit)))
    }

    public static func topGPU(_ processes: [ProcessMetric], limit: Int = 5) -> [ProcessMetric] {
        top(processes, limit: limit, value: \.gpuUsage)
    }

    private static func top(
        _ processes: [ProcessMetric],
        limit: Int,
        value: KeyPath<ProcessMetric, Double?>
    ) -> [ProcessMetric] {
        Array(processes.compactMap { process -> (ProcessMetric, Double)? in
            guard let metric = process[keyPath: value] else { return nil }
            return (process, metric)
        }.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0.pid < $1.0.pid
        }.prefix(max(0, limit)).map(\.0))
    }
}

public enum ProcessTerminationPolicy {
    private static let systemNames: Set<String> = [
        "controlcenter", "dock", "finder", "kernel_task", "launchd", "loginwindow",
        "runningboardd", "systemuiserver", "windowserver",
    ]
    private static let systemPathPrefixes = [
        "/System/", "/bin/", "/sbin/", "/usr/bin/", "/usr/libexec/", "/usr/sbin/",
    ]

    public static func canTerminate(identity: ProcessIdentity, currentPID: Int32) -> Bool {
        identity.pid > 1 && identity.pid != currentPID && identity.startTime > 0
    }

    public static func requiresConfirmation(
        userID: UInt32,
        currentUserID: UInt32,
        executablePath: String?,
        name: String
    ) -> Bool {
        if userID != currentUserID { return true }
        if systemNames.contains(name.lowercased()) { return true }
        guard let executablePath else { return false }
        return systemPathPrefixes.contains { executablePath.hasPrefix($0) }
    }
}
