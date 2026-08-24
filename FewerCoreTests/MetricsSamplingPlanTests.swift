import XCTest
@testable import FewerCore

final class MetricsSamplingPlanTests: XCTestCase {

    // MARK: - Frequency tiering

    func testPlanSamplesAllModulesOnSlowTick() {
        let active: Set<SystemMonitorModuleID> = [.cpu, .gpu, .memory, .disk, .network]
        let plan = MetricsSamplingPlan.plan(tick: 0, activeModules: active)
        XCTAssertEqual(plan.modulesToSample, active)
        XCTAssertTrue(plan.modulesToReuse.isEmpty)
    }

    func testPlanSamplesOnlyHighFrequencyOnFastTick() {
        let active: Set<SystemMonitorModuleID> = [.cpu, .gpu, .memory, .disk, .network]
        let plan = MetricsSamplingPlan.plan(tick: 1, activeModules: active)
        XCTAssertEqual(plan.modulesToSample, [.cpu, .memory, .network])
        XCTAssertEqual(plan.modulesToReuse, [.gpu, .disk])
    }

    func testPlanSamplesSlowModulesEvery5Ticks() {
        let active: Set<SystemMonitorModuleID> = [.gpu, .disk]
        for tick in 0...20 {
            let plan = MetricsSamplingPlan.plan(tick: tick, activeModules: active)
            if tick % 5 == 0 {
                XCTAssertEqual(plan.modulesToSample, [.gpu, .disk], "tick \(tick) should sample slow modules")
            } else {
                XCTAssertTrue(plan.modulesToSample.isEmpty, "tick \(tick) should not sample slow modules")
                XCTAssertEqual(plan.modulesToReuse, [.gpu, .disk])
            }
        }
    }

    func testCustomSlowInterval() {
        let active: Set<SystemMonitorModuleID> = [.gpu]
        let plan = MetricsSamplingPlan.plan(tick: 2, activeModules: active, slowSamplingEveryNTicks: 2)
        XCTAssertEqual(plan.modulesToSample, [.gpu])

        let planOff = MetricsSamplingPlan.plan(tick: 1, activeModules: active, slowSamplingEveryNTicks: 2)
        XCTAssertTrue(planOff.modulesToSample.isEmpty)
    }

    // MARK: - Disabled modules

    func testEmptyActiveModulesProducesEmptyPlan() {
        let plan = MetricsSamplingPlan.plan(tick: 0, activeModules: [])
        XCTAssertTrue(plan.modulesToSample.isEmpty)
        XCTAssertTrue(plan.modulesToReuse.isEmpty)
    }

    func testOnlyCpuActiveAlwaysSamples() {
        let active: Set<SystemMonitorModuleID> = [.cpu]
        for tick in 0...10 {
            let plan = MetricsSamplingPlan.plan(tick: tick, activeModules: active)
            XCTAssertEqual(plan.modulesToSample, [.cpu], "CPU should always be sampled at tick \(tick)")
        }
    }

    // MARK: - Coordinator: coalescing

    func testBeginSamplingReturnsTrueOnce() {
        var coordinator = SamplingCoordinator()
        XCTAssertTrue(coordinator.beginSampling())
        XCTAssertFalse(coordinator.beginSampling(), "second begin should be coalesced")
    }

    func testCompleteSamplingAllowsNextBegin() {
        var coordinator = SamplingCoordinator()
        XCTAssertTrue(coordinator.beginSampling())
        coordinator.completeSampling()
        XCTAssertTrue(coordinator.beginSampling(), "should allow begin after complete")
    }

    func testTickAdvancesOnComplete() {
        var coordinator = SamplingCoordinator()
        XCTAssertEqual(coordinator.tick, 0)
        coordinator.beginSampling()
        coordinator.completeSampling()
        XCTAssertEqual(coordinator.tick, 1)
        coordinator.beginSampling()
        coordinator.completeSampling()
        XCTAssertEqual(coordinator.tick, 2)
    }

    // MARK: - Coordinator: generation / stale discarding

    func testInvalidateDiscardsStaleResult() {
        var coordinator = SamplingCoordinator()
        XCTAssertTrue(coordinator.beginSampling())
        let gen = coordinator.generation
        coordinator.invalidate()
        XCTAssertFalse(coordinator.isCurrent(gen), "stale generation should be rejected")
    }

    func testInvalidateIncrementsGeneration() {
        var coordinator = SamplingCoordinator()
        let gen0 = coordinator.generation
        coordinator.invalidate()
        XCTAssertEqual(coordinator.generation, gen0 + 1)
    }

    func testBeginSamplingIncrementsGeneration() {
        var coordinator = SamplingCoordinator()
        let gen0 = coordinator.generation
        XCTAssertTrue(coordinator.beginSampling())
        XCTAssertEqual(coordinator.generation, gen0 + 1)
    }

    func testIsCurrentAcceptsMatchingGeneration() {
        var coordinator = SamplingCoordinator()
        coordinator.beginSampling()
        XCTAssertTrue(coordinator.isCurrent(coordinator.generation))
    }

    func testInvalidateResetsSamplingFlag() {
        var coordinator = SamplingCoordinator()
        coordinator.beginSampling()
        XCTAssertTrue(coordinator.isSampling)
        coordinator.invalidate()
        XCTAssertFalse(coordinator.isSampling)
    }

    // MARK: - Combined behavior

    func testCoalesceThenInvalidateThenBegin() {
        var coordinator = SamplingCoordinator()
        XCTAssertTrue(coordinator.beginSampling())
        XCTAssertFalse(coordinator.beginSampling(), "coalesce")
        coordinator.invalidate()
        XCTAssertFalse(coordinator.isSampling)
        XCTAssertTrue(coordinator.beginSampling(), "should allow new begin after invalidate")
    }

    func testTickCounterDrivesPlanTiering() {
        var coordinator = SamplingCoordinator()
        let active: Set<SystemMonitorModuleID> = [.cpu, .gpu]

        // tick 0: slow tick → sample all
        coordinator.beginSampling()
        let plan0 = MetricsSamplingPlan.plan(tick: coordinator.tick, activeModules: active)
        XCTAssertEqual(plan0.modulesToSample, [.cpu, .gpu])
        coordinator.completeSampling()

        // tick 1: fast tick → only CPU
        coordinator.beginSampling()
        let plan1 = MetricsSamplingPlan.plan(tick: coordinator.tick, activeModules: active)
        XCTAssertEqual(plan1.modulesToSample, [.cpu])
        XCTAssertEqual(plan1.modulesToReuse, [.gpu])
        coordinator.completeSampling()

        // Advance to tick 5 (slow tick): complete 3 more times (tick 2→3, 3→4, 4→5)
        for _ in 2...4 {
            coordinator.beginSampling()
            coordinator.completeSampling()
        }
        XCTAssertEqual(coordinator.tick, 5)
        let plan5 = MetricsSamplingPlan.plan(tick: coordinator.tick, activeModules: active)
        XCTAssertEqual(plan5.modulesToSample, [.cpu, .gpu])
    }
}
