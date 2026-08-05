import Foundation

enum ExtensionStatus: Equatable {
    case enabled
    case notEnabled
    case unknown

    var title: String {
        switch self {
        case .enabled: "已启用"
        case .notEnabled: "未启用"
        case .unknown: "需要确认"
        }
    }
}

enum ExtensionStatusService {
    static func finderExtensionStatus() -> ExtensionStatus {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        process.arguments = ["-m", "-i", "com.number47.fewer.finder-extension"]
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let output = String(
                data: pipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            if output.contains("+    com.number47.fewer.finder-extension") { return .enabled }
            if output.contains("com.number47.fewer.finder-extension") { return .notEnabled }
            return .unknown
        } catch {
            return .unknown
        }
    }
}
