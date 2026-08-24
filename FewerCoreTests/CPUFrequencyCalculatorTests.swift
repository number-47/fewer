import XCTest
@testable import FewerCore

final class CPUFrequencyCalculatorTests: XCTestCase {
    func testFrequencyTableConvertsM4KilohertzValues() {
        let data = voltageStates([1_020_000, 2_592_000])

        XCTAssertEqual(
            CPUFrequencyCalculator.frequenciesHz(fromVoltageStateData: data),
            [1_020_000_000, 2_592_000_000]
        )
    }

    func testFrequencyTablePreservesOlderHertzValues() {
        let data = voltageStates([600_000_000, 3_200_000_000])

        XCTAssertEqual(
            CPUFrequencyCalculator.frequenciesHz(fromVoltageStateData: data),
            [600_000_000, 3_200_000_000]
        )
    }

    func testFrequencyTableRejectsIncompleteEntries() {
        XCTAssertTrue(CPUFrequencyCalculator.frequenciesHz(fromVoltageStateData: Data([1, 2, 3])).isEmpty)
    }

    func testAverageFrequencyUsesStateResidencyWeights() {
        XCTAssertEqual(
            CPUFrequencyCalculator.averageFrequencyHz(
                frequenciesHz: [1_000_000_000, 3_000_000_000],
                residencies: [3, 1]
            ),
            1_500_000_000
        )
    }

    func testAverageFrequencyRejectsMissingOrIdleSamples() {
        XCTAssertNil(CPUFrequencyCalculator.averageFrequencyHz(frequenciesHz: [], residencies: []))
        XCTAssertNil(CPUFrequencyCalculator.averageFrequencyHz(
            frequenciesHz: [1_000_000_000],
            residencies: [0]
        ))
        XCTAssertNil(CPUFrequencyCalculator.averageFrequencyHz(
            frequenciesHz: [1_000_000_000],
            residencies: [1, 2]
        ))
    }

    private func voltageStates(_ frequencies: [UInt32]) -> Data {
        Data(frequencies.flatMap { frequency in
            withUnsafeBytes(of: frequency.littleEndian, Array.init) + [0, 0, 0, 0]
        })
    }
}
