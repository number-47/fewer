import AppKit
import AudioToolbox
import IOKit.pwr_mgt

@MainActor
final class SystemActionsService: ObservableObject {
    static let shared = SystemActionsService()

    @Published private(set) var preventsSleep = false
    @Published private(set) var isMuted = false
    @Published private(set) var removableVolumes: [URL] = []
    @Published var lastError: String?
    private var assertionID = IOPMAssertionID(0)

    private init() {
        isMuted = Self.readMuteState() ?? false
        refreshRemovableVolumes()
    }

    func setPreventsSleep(_ enabled: Bool) {
        if enabled {
            let reason = "Fewer 用户启用防休眠" as CFString
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason,
                &assertionID
            )
            preventsSleep = result == kIOReturnSuccess
            if !preventsSleep { lastError = "无法创建防休眠断言。" }
        } else {
            if assertionID != 0 { IOPMAssertionRelease(assertionID) }
            assertionID = 0
            preventsSleep = false
        }
    }

    func toggleMute() {
        guard let device = Self.defaultOutputDevice() else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = isMuted ? 0 : 1
        let result = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout.size(ofValue: value)), &value)
        if result == noErr { isMuted = value != 0 } else { lastError = "当前输出设备不支持静音控制。" }
    }

    func toggleDarkMode() {
        let script = NSAppleScript(source: "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode")
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        if let error { lastError = error[NSAppleScript.errorMessage] as? String ?? "无法切换深色模式。" }
    }

    func sleepDisplays() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]
        do { try process.run() } catch { lastError = error.localizedDescription }
    }

    func clearPasteboard() {
        NSPasteboard.general.clearContents()
    }

    func refreshRemovableVolumes() {
        Task { [weak self] in
            let volumes = await Task.detached(priority: .utility) {
                Self.removableVolumeURLs()
            }.value
            guard !Task.isCancelled else { return }
            self?.removableVolumes = volumes
        }
    }

    nonisolated private static func removableVolumeURLs() -> [URL] {
        let keys: Set<URLResourceKey> = [.volumeIsRemovableKey, .volumeIsInternalKey]
        return (FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys)
        ) ?? []).filter { volume in
            guard let values = try? volume.resourceValues(forKeys: keys) else { return false }
            return values.volumeIsRemovable == true && values.volumeIsInternal != true
        }
    }

    func eject(_ volume: URL) {
        guard removableVolumes.contains(volume) else { return }
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: volume)
            refreshRemovableVolumes()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return nil }
        return device
    }

    private static func readMuteState() -> Bool? {
        guard let device = defaultOutputDevice() else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout.size(ofValue: value))
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }
}
