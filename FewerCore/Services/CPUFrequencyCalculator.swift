import Foundation

public enum CPUFrequencyCalculator {
    public static func frequenciesHz(fromVoltageStateData data: Data) -> [UInt64] {
        guard data.count.isMultiple(of: 8) else { return [] }

        return stride(from: 0, to: data.count, by: 8).compactMap { offset in
            let rawValue = data[offset..<(offset + 4)].enumerated().reduce(UInt32(0)) { value, element in
                value | UInt32(element.element) << UInt32(element.offset * 8)
            }
            guard rawValue > 0 else { return nil }
            return rawValue >= 100_000_000 ? UInt64(rawValue) : UInt64(rawValue) * 1_000
        }
    }

    public static func averageFrequencyHz(
        frequenciesHz: [UInt64],
        residencies: [Int64]
    ) -> UInt64? {
        guard !frequenciesHz.isEmpty, frequenciesHz.count == residencies.count else { return nil }

        var totalResidency = 0.0
        var weightedFrequency = 0.0
        for (frequency, residency) in zip(frequenciesHz, residencies) where residency > 0 {
            let weight = Double(residency)
            totalResidency += weight
            weightedFrequency += Double(frequency) * weight
        }
        guard totalResidency > 0 else { return nil }
        return UInt64((weightedFrequency / totalResidency).rounded())
    }
}
