import AppKit
import FewerCore

@MainActor
final class InputEnhancementViewModel: NSObject, ObservableObject {
    static let shared = InputEnhancementViewModel()
    @Published var settings: InputEnhancementSettings
    @Published var helperStatus: ShortcutHelperStatus = .unavailable
    @Published var errorMessage: String?

    private let store = InputEnhancementStore()
    nonisolated(unsafe) private var timer: Timer?

    override init() {
        settings = store.load()
        super.init()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(settingsDidChange),
            name: AppGroupConstants.inputEnhancementSettingsDidChangeNotification,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        refreshStatus()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStatus() }
        }
        PermissionService.ensureShortcutHelperRunning()
    }

    deinit {
        timer?.invalidate()
        DistributedNotificationCenter.default().removeObserver(self)
    }

    func save(allowEmergencyReset: Bool = false) {
        let enabledRules = settings.gestureRules.filter(\.isEnabled)
        let signatures = enabledRules.map {
            "\($0.bundleIdentifier ?? "*")|\($0.triggerButton)|\($0.directions.map(\.rawValue).joined(separator: ","))"
        }
        guard Set(signatures).count == signatures.count else {
            errorMessage = "存在重复的鼠标手势规则，请先修改或停用冲突项。"
            return
        }
        do {
            if !allowEmergencyReset, store.load().emergencyDisabled {
                settings.emergencyDisabled = true
            }
            try store.save(settings)
            DistributedNotificationCenter.default().postNotificationName(
                AppGroupConstants.inputEnhancementSettingsDidChangeNotification,
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
        } catch {
            errorMessage = "无法保存输入增强设置：\(error.localizedDescription)"
        }
    }

    func clearEmergencyStop() {
        settings.emergencyDisabled = false
        save(allowEmergencyReset: true)
    }

    func addApplication(at url: URL) {
        guard let bundle = Bundle(url: url),
              let bundleIdentifier = bundle.bundleIdentifier,
              !settings.applicationOverrides.contains(where: { $0.bundleIdentifier == bundleIdentifier })
        else { return }
        settings.applicationOverrides.append(ApplicationScrollOverride(
            bundleIdentifier: bundleIdentifier,
            displayName: bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? url.deletingPathExtension().lastPathComponent,
            mode: .bypass
        ))
        save()
    }

    func addGestureRule() {
        settings.gestureRules.append(MouseGestureRule(
            isEnabled: false,
            triggerButton: 2,
            directions: [.left],
            action: .mouseBack
        ))
        save()
    }

    func setTemporaryAllKeys(_ enabled: Bool) {
        DistributedNotificationCenter.default().postNotificationName(
            AppGroupConstants.inputEnhancementControlNotification,
            object: nil,
            userInfo: ["command": "temporary-all-keys", "enabled": enabled],
            deliverImmediately: true
        )
    }

    func setKeycastPositioning(_ enabled: Bool) {
        DistributedNotificationCenter.default().postNotificationName(
            AppGroupConstants.inputEnhancementControlNotification,
            object: nil,
            userInfo: ["command": "keycast-positioning", "enabled": enabled],
            deliverImmediately: true
        )
    }

    private func refreshStatus() {
        helperStatus = PermissionService.shortcutHelperStatus
    }

    @objc private func settingsDidChange() {
        DispatchQueue.main.async { [weak self] in
            self?.settings = self?.store.load() ?? .default
        }
    }
}
