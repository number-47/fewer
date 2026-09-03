import XCTest
@testable import FewerCore

final class ProcessMetricsTests: XCTestCase {
    func testAbsoluteTimeConversionUsesMachTimebaseRatio() {
        XCTAssertEqual(
            ProcessMetricLogic.absoluteTimeToNanoseconds(24_000_000, numerator: 125, denominator: 3),
            1_000_000_000
        )
        XCTAssertEqual(ProcessMetricLogic.absoluteTimeToNanoseconds(10, numerator: 1, denominator: 0), 0)
    }

    func testIntervalRatioRequiresBaselineAndRejectsCounterRegression() {
        XCTAssertNil(ProcessMetricLogic.intervalRatio(current: 2_000_000_000, previous: nil, elapsed: 1))
        XCTAssertNil(ProcessMetricLogic.intervalRatio(current: 1, previous: 2, elapsed: 1))
        XCTAssertNil(ProcessMetricLogic.intervalRatio(current: 2, previous: 1, elapsed: 0))
    }

    func testIntervalRatioAllowsMulticoreCPUAboveOne() {
        XCTAssertEqual(
            ProcessMetricLogic.intervalRatio(current: 3_500_000_000, previous: 1_000_000_000, elapsed: 1),
            2.5
        )
    }

    func testTopMetricsFilterUnavailableValuesUseStablePIDTieBreakAndLimit() {
        let processes = [
            process(pid: 4, cpu: 0.5, memory: 40, gpu: 0.2),
            process(pid: 2, cpu: 0.5, memory: 20, gpu: nil),
            process(pid: 3, cpu: nil, memory: 50, gpu: 0.8),
            process(pid: 1, cpu: 0.9, memory: 10, gpu: 0.8),
        ]

        XCTAssertEqual(ProcessMetricLogic.topCPU(processes, limit: 2).map(\.pid), [1, 2])
        XCTAssertEqual(ProcessMetricLogic.topMemory(processes, limit: 3).map(\.pid), [3, 4, 2])
        XCTAssertEqual(ProcessMetricLogic.topGPU(processes, limit: 2).map(\.pid), [1, 3])
    }

    func testGPUCreatorParsingAndAggregation() {
        XCTAssertEqual(
            ProcessMetricLogic.gpuCreator(from: "pid 1351, Finder"),
            GPUProcessCreator(pid: 1351, name: "Finder")
        )
        XCTAssertNil(ProcessMetricLogic.gpuCreator(from: "Finder"))
        XCTAssertNil(ProcessMetricLogic.gpuCreator(from: "pid 0, kernel"))

        let result = ProcessMetricLogic.aggregateGPU([
            GPUProcessCounter(creator: "pid 20, App", accumulatedTime: 7),
            GPUProcessCounter(creator: "pid 20, App", accumulatedTime: 5),
            GPUProcessCounter(creator: "pid 21, Other", accumulatedTime: 3),
            GPUProcessCounter(creator: "invalid", accumulatedTime: 99),
        ])
        XCTAssertEqual(result, [20: 12, 21: 3])
    }

    func testTerminationPolicyProtectsOwnAndCriticalPIDs() {
        XCTAssertFalse(ProcessTerminationPolicy.canTerminate(identity: .init(pid: 0, startTime: 1), currentPID: 47))
        XCTAssertFalse(ProcessTerminationPolicy.canTerminate(identity: .init(pid: 1, startTime: 1), currentPID: 47))
        XCTAssertFalse(ProcessTerminationPolicy.canTerminate(identity: .init(pid: 47, startTime: 1), currentPID: 47))
        XCTAssertFalse(ProcessTerminationPolicy.canTerminate(identity: .init(pid: 48, startTime: 0), currentPID: 47))
        XCTAssertTrue(ProcessTerminationPolicy.canTerminate(identity: .init(pid: 48, startTime: 1), currentPID: 47))
    }

    func testTerminationPolicyConfirmsSystemProcesses() {
        XCTAssertTrue(ProcessTerminationPolicy.requiresConfirmation(
            userID: 0,
            currentUserID: 501,
            executablePath: "/usr/sbin/systemstats",
            name: "systemstats"
        ))
        XCTAssertTrue(ProcessTerminationPolicy.requiresConfirmation(
            userID: 501,
            currentUserID: 501,
            executablePath: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder",
            name: "Finder"
        ))
        XCTAssertTrue(ProcessTerminationPolicy.requiresConfirmation(
            userID: 501,
            currentUserID: 501,
            executablePath: nil,
            name: "WindowServer"
        ))
        XCTAssertFalse(ProcessTerminationPolicy.requiresConfirmation(
            userID: 501,
            currentUserID: 501,
            executablePath: "/Applications/Test.app/Contents/MacOS/Test",
            name: "Test"
        ))
    }

    private func process(
        pid: Int32,
        cpu: Double?,
        memory: UInt64,
        gpu: Double?
    ) -> ProcessMetric {
        ProcessMetric(
            id: ProcessIdentity(pid: pid, startTime: UInt64(pid)),
            name: "P\(pid)",
            executablePath: nil,
            userID: 501,
            cpuUsage: cpu,
            memoryBytes: memory,
            gpuUsage: gpu
        )
    }
}
