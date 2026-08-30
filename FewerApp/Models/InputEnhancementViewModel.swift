import AppKit
import FewerCore

private struct InputEnhancementSaveError: Error, Sendable {
    let message: String
}

private struct InputEnhancementLoadState: Sendable {
    let store: InputEnhancementStore
    let statusStore: ShortcutHelperStatusStore
    let settings: InputEnhancementSettings
}

@MainActor
final class InputEnhancementViewModel: NSObject, ObservableObject {
    static let shared = InputEnhancementViewModel()
    private static let settingsNotificationSource = UUID().uuidString
    @Published var settings: InputEnhancementSettings = .default
    @Published var helperStatus: ShortcutHelperStatus = .unavailable
    @Published var errorMessage: String?
    @Published private(set) var isLoading = true

    private var store: InputEnhancementStore?
    private var statusStore: ShortcutHelperStatusStore?
    private var loadTask: Task<InputEnhancementLoadState, Never>?
    private var refreshTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var refreshGeneration = 0
    private var saveGeneration = 0
    private var isRefreshing = false
    private var hasPendingSave = false

    override init() {
        super.init()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(settingsDidChange(_:)),
            name: AppGroupConstants.inputEnhancementSettingsDidChangeNotification,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        Task { [weak self] in
            await self?.loadSettings()
            await self?.refreshStatus()
        }
    }

    deinit {
        refreshTask?.cancel()
        saveTask?.cancel()
        DistributedNotificationCenter.default().removeObserver(self)
    }

    func save(allowEmergencyReset: Bool = false) {
        enqueueSave(after: nil, allowEmergencyReset: allowEmergencyReset)
    }

    func scheduleSave() {
        enqueueSave(after: .milliseconds(180), allowEmergencyReset: false)
    }

    func flushPendingSave() {
        guard hasPendingSave else { return }
        enqueueSave(after: nil, allowEmergencyReset: false)
    }

    func startRefreshing() async {
        isRefreshing = true
        refreshGeneration += 1
        let generation = refreshGeneration
        await loadSettings()
        guard isRefreshing, generation == refreshGeneration, !Task.isCancelled else { return }
        PermissionService.ensureShortcutHelperRunning()
        await refreshStatus()
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                await self?.refreshStatus()
            }
        }
    }

    func stopRefreshing() {
        isRefreshing = false
        refreshGeneration += 1
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func loadSettings() async {
        guard store == nil || statusStore == nil else { return }
        let task: Task<InputEnhancementLoadState, Never>
        if let loadTask {
            task = loadTask
        } else {
            task = Task.detached(priority: .utility) {
                let store = InputEnhancementStore(access: .mainAppWriter)
                return InputEnhancementLoadState(
                    store: store,
                    statusStore: ShortcutHelperStatusStore(),
                    settings: store.load()
                )
            }
            loadTask = task
        }
        let loaded = await task.value
        guard !Task.isCancelled else { return }
        store = loaded.store
        statusStore = loaded.statusStore
        settings = loaded.settings
        isLoading = false
        loadTask = nil
    }

    private func enqueueSave(after delay: Duration?, allowEmergencyReset: Bool) {
        guard let store else { return }
        let enabledRules = settings.gestureRules.filter(\.isEnabled)
        let signatures = enabledRules.map {
            "\($0.bundleIdentifier ?? "*")|\($0.triggerButton)|\($0.directions.map(\.rawValue).joined(separator: ","))"
        }
        guard Set(signatures).count == signatures.count else {
            errorMessage = "存在重复的鼠标手势规则，请先修改或停用冲突项。"
            return
        }
        hasPendingSave = true
        saveGeneration += 1
        let generation = saveGeneration
        let previousTask = saveTask
        previousTask?.cancel()
        let settings = settings
        saveTask = Task { [weak self] in
            if let delay {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            await previousTask?.value
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .utility) { () -> Result<Bool, InputEnhancementSaveError> in
                do {
                    var savedSettings = settings
                    let emergencyDisabled = !allowEmergencyReset && store.load().emergencyDisabled
                    if emergencyDisabled { savedSettings.emergencyDisabled = true }
                    try store.save(savedSettings)
                    return .success(emergencyDisabled)
                } catch {
                    return .failure(InputEnhancementSaveError(message: error.localizedDescription))
                }
            }.value
            guard !Task.isCancelled, let self, generation == self.saveGeneration else { return }
            self.hasPendingSave = false
            switch result {
            case let .success(emergencyDisabled):
                if emergencyDisabled { self.settings.emergencyDisabled = true }
                DistributedNotificationCenter.default().postNotificationName(
                    AppGroupConstants.inputEnhancementSettingsDidChangeNotification,
                    object: nil,
                    userInfo: ["source": Self.settingsNotificationSource],
                    deliverImmediately: true
                )
            case let .failure(error):
                self.errorMessage = "无法保存输入增强设置：\(error.message)"
            }
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

    private func refreshStatus() async {
        guard let statusStore else {
            helperStatus = .unavailable
            return
        }
        let status = await Task.detached(priority: .utility) { statusStore.load() }.value
        guard !Task.isCancelled,
              let status,
              let application = NSRunningApplication(processIdentifier: status.processIdentifier),
              !application.isTerminated,
              application.bundleURL?.standardizedFileURL == currentHelperURL
        else {
            helperStatus = .unavailable
            return
        }
        helperStatus = status
    }

    private var currentHelperURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LoginItems/FewerShortcutHelper.app")
            .standardizedFileURL
    }

    @objc private func settingsDidChange(_ notification: Notification) {
        guard notification.userInfo?["source"] as? String != Self.settingsNotificationSource else { return }
        guard isRefreshing else { return }
        let generation = refreshGeneration
        guard let store else { return }
        DispatchQueue.main.async { [weak self] in
            Task { [weak self] in
                let loadedSettings = await Task.detached(priority: .utility) { store.load() }.value
                guard let self,
                      self.isRefreshing,
                      self.refreshGeneration == generation,
                      !Task.isCancelled
                else { return }
                self.settings = loadedSettings
            }
        }
    }
}
