import FewerCore
import Foundation
import IOKit

final class CPUFrequencyReader {
    #if arch(arm64)
    private let efficiencyFrequenciesHz: [UInt64]
    private let middleFrequenciesHz: [UInt64]
    private let performanceFrequenciesHz: [UInt64]
    private var channels: CFMutableDictionary?
    private var subscription: IOReportSubscriptionRef?
    private var previousSample: CFDictionary?
    #endif

    init() {
        #if arch(arm64)
        let tables = Self.frequencyTables()
        efficiencyFrequenciesHz = tables.efficiency
        middleFrequenciesHz = tables.middle
        performanceFrequenciesHz = tables.performance
        setupSubscription()
        #endif
    }

    func sample() -> UInt64? {
        #if arch(arm64)
        guard let channels,
              let subscription,
              let current = IOReportCreateSamples(subscription, channels, nil)?.takeRetainedValue()
        else { return nil }
        defer { previousSample = current }
        guard let previousSample,
              let delta = IOReportCreateSamplesDelta(previousSample, current, nil)?.takeRetainedValue(),
              let dictionary = delta as? [String: Any],
              let channelList = dictionary["IOReportChannels"] as? NSArray
        else { return nil }

        let items = channelList as CFArray
        var coreFrequencies: [UInt64] = []
        for index in 0..<CFArrayGetCount(items) {
            let channel = unsafeBitCast(CFArrayGetValueAtIndex(items, index), to: CFDictionary.self)
            guard let name = IOReportChannelGetChannelName(channel)?.takeUnretainedValue() as? String,
                  let frequencies = frequencies(for: name),
                  let frequency = CPUFrequencyCalculator.averageFrequencyHz(
                    frequenciesHz: frequencies,
                    residencies: activeResidencies(in: channel)
                  )
            else { continue }
            coreFrequencies.append(frequency)
        }

        guard !coreFrequencies.isEmpty else { return nil }
        return coreFrequencies.reduce(0, +) / UInt64(coreFrequencies.count)
        #else
        return nil
        #endif
    }

    #if arch(arm64)
    private func setupSubscription() {
        guard let copied = IOReportCopyChannelsInGroup(
            "CPU Stats" as CFString,
            "CPU Core Performance States" as CFString,
            0,
            0,
            0
        )?.takeRetainedValue(),
              let mutable = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, copied),
              let dictionary = mutable as? [String: Any],
              dictionary["IOReportChannels"] != nil
        else { return }

        channels = mutable
        var subscriptionChannels: Unmanaged<CFMutableDictionary>?
        subscription = IOReportCreateSubscription(nil, mutable, &subscriptionChannels, 0, nil)
        subscriptionChannels?.release()
    }

    private func frequencies(for channelName: String) -> [UInt64]? {
        if channelName.contains("ECPU") {
            return efficiencyFrequenciesHz.isEmpty ? nil : efficiencyFrequenciesHz
        }
        if channelName.contains("MCPU") {
            let values = middleFrequenciesHz.isEmpty ? performanceFrequenciesHz : middleFrequenciesHz
            return values.isEmpty ? nil : values
        }
        if channelName.contains("PCPU") {
            let values = performanceFrequenciesHz.isEmpty ? middleFrequenciesHz : performanceFrequenciesHz
            return values.isEmpty ? nil : values
        }
        return nil
    }

    private func activeResidencies(in channel: CFDictionary) -> [Int64] {
        let inactiveStates = Set(["DOWN", "IDLE", "OFF"])
        return (0..<IOReportStateGetCount(channel)).compactMap { index in
            let state = IOReportStateGetNameForIndex(channel, index)?.takeUnretainedValue() as String? ?? ""
            return inactiveStates.contains(state) ? nil : IOReportStateGetResidency(channel, index)
        }
    }

    private static func frequencyTables() -> (
        efficiency: [UInt64],
        middle: [UInt64],
        performance: [UInt64]
    ) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("AppleARMIODevice"),
            &iterator
        ) == kIOReturnSuccess else { return ([], [], []) }
        defer { IOObjectRelease(iterator) }

        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }

            guard let efficiencyData = propertyData("voltage-states1-sram", service: service),
                  let performanceData = propertyData("voltage-states5-sram", service: service)
            else { continue }

            return (
                CPUFrequencyCalculator.frequenciesHz(fromVoltageStateData: efficiencyData),
                propertyData("voltage-states22-sram", service: service).map {
                    CPUFrequencyCalculator.frequenciesHz(fromVoltageStateData: $0)
                } ?? [],
                CPUFrequencyCalculator.frequenciesHz(fromVoltageStateData: performanceData)
            )
        }
        return ([], [], [])
    }

    private static func propertyData(_ key: String, service: io_registry_entry_t) -> Data? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Data
    }
    #endif
}
