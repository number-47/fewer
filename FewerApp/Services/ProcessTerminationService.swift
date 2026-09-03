import AppKit
import Darwin
import FewerCore
import Foundation

@MainActor
enum ProcessTerminationService {
    enum TerminationError: LocalizedError {
        case processUnavailable
        case processIdentityChanged
        case applicationRefused
        case signalFailed(String)

        var errorDescription: String? {
            switch self {
            case .processUnavailable:
                "进程已经退出或当前无法读取。"
            case .processIdentityChanged:
                "PID 已被其他进程复用，已取消退出操作。"
            case .applicationRefused:
                "应用拒绝了正常退出请求。"
            case let .signalFailed(message):
                "无法退出进程：\(message)"
            }
        }
    }

    static func terminate(_ process: ProcessMetric) throws {
        guard let current = currentIdentity(for: process.pid) else {
            throw TerminationError.processUnavailable
        }
        guard current == process.id else {
            throw TerminationError.processIdentityChanged
        }

        if let application = NSRunningApplication(processIdentifier: process.pid), !application.isTerminated {
            guard application.terminate() else { throw TerminationError.applicationRefused }
            return
        }

        guard kill(process.pid, SIGTERM) == 0 else {
            throw TerminationError.signalFailed(String(cString: strerror(errno)))
        }
    }

    private static func currentIdentity(for pid: pid_t) -> ProcessIdentity? {
        var usage = rusage_info_v4()
        let usageResult = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard usageResult == 0, usage.ri_proc_start_abstime > 0 else { return nil }

        return ProcessIdentity(pid: pid, startTime: usage.ri_proc_start_abstime)
    }
}
