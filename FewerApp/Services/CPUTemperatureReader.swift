import Darwin
import Foundation
import IOKit

final class CPUTemperatureReader {
    private let connection = SMCReadConnection()
    private let sensorKeys: [String]

    init() {
        sensorKeys = Self.sensorKeys(for: Self.cpuBrand())
    }

    func sample() -> Double? {
        guard let connection else { return nil }

        for key in ["TC0D", "TC0E", "TC0F", "TC0P", "TC0H"] {
            if let value = validTemperature(connection.value(for: key)) {
                return value
            }
        }

        let values = sensorKeys.compactMap { validTemperature(connection.value(for: $0)) }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private func validTemperature(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0, value < 110 else { return nil }
        return value
    }

    private static func cpuBrand() -> String {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else { return "" }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self).lowercased()
    }

    private static func sensorKeys(for cpuBrand: String) -> [String] {
        if cpuBrand.contains("m1") {
            return ["Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"]
        }
        if cpuBrand.contains("m2") {
            return ["Tp1h", "Tp1t", "Tp1p", "Tp1l", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j"]
        }
        if cpuBrand.contains("m3") {
            return ["Te05", "Te0L", "Te0P", "Te0S", "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E", "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"]
        }
        if cpuBrand.contains("m4") {
            return ["Te05", "Te09", "Te0H", "Te0S", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"]
        }
        if cpuBrand.contains("m5") {
            return ["Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K", "Tp0O", "Tp0R", "Tp0U", "Tp0X", "Tp0a", "Tp0d", "Tp0g", "Tp0j", "Tp0m", "Tp0p", "Tp0u", "Tp0y"]
        }
        return []
    }
}

private final class SMCReadConnection {
    private var connection: io_connect_t = 0

    init?() {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("AppleSMC"),
            &iterator
        ) == kIOReturnSuccess else { return nil }
        defer { IOObjectRelease(iterator) }

        let service = IOIteratorNext(iterator)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else { return nil }
    }

    deinit {
        if connection != 0 {
            IOServiceClose(connection)
        }
    }

    func value(for key: String) -> Double? {
        guard let keyCode = fourCharacterCode(key) else { return nil }

        var input = SMCKeyData()
        var output = SMCKeyData()
        input.key = keyCode
        input.data8 = 9
        guard call(input: &input, output: &output) == kIOReturnSuccess else { return nil }

        let dataSize = Int(output.keyInfo.dataSize)
        let dataType = output.keyInfo.dataType
        guard dataSize > 0, dataSize <= 32 else { return nil }
        input.keyInfo.dataSize = output.keyInfo.dataSize
        input.data8 = 5
        guard call(input: &input, output: &output) == kIOReturnSuccess else { return nil }

        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(dataSize)) }
        switch fourCharacterString(dataType) {
        case "sp78":
            guard bytes.count >= 2 else { return nil }
            let bits = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            return Double(Int16(bitPattern: bits)) / 256
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let bits = UInt32(bytes[0])
                | UInt32(bytes[1]) << 8
                | UInt32(bytes[2]) << 16
                | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: bits))
        default:
            return nil
        }
    }

    private func call(input: inout SMCKeyData, output: inout SMCKeyData) -> kern_return_t {
        let inputSize = MemoryLayout<SMCKeyData>.stride
        var outputSize = MemoryLayout<SMCKeyData>.stride
        return IOConnectCallStructMethod(connection, 2, &input, inputSize, &output, &outputSize)
    }

    private func fourCharacterCode(_ value: String) -> UInt32? {
        let bytes = Array(value.utf8)
        guard bytes.count == 4 else { return nil }
        return bytes.reduce(UInt32(0)) { result, byte in result << 8 | UInt32(byte) }
    }

    private func fourCharacterString(_ value: UInt32) -> String {
        String(bytes: [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ], encoding: .ascii) ?? ""
    }
}

private struct SMCKeyData {
    struct Version {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    struct PowerLimit {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpu: UInt32 = 0
        var gpu: UInt32 = 0
        var memory: UInt32 = 0
    }

    struct KeyInfo {
        var dataSize: IOByteCount32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    typealias Bytes = (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    )

    var key: UInt32 = 0
    var version = Version()
    var powerLimit = PowerLimit()
    var keyInfo = KeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: Bytes = (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0
    )
}
