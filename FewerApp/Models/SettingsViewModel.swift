import AppKit
import Combine
import FewerCore
import ServiceManagement

private struct SettingsLoadState: Sendable {
    let settingsStore: SharedSettingsStore
    let templateStore: TemplateStore
    let result: SettingsLoadResult
    let templates: [TemplateDescriptor]
}

private struct SettingsViewModelError: Error, Sendable {
    let message: String
}

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var settings: FeatureSettings = .default
    @Published var templates: [TemplateDescriptor] = []
    @Published var errorMessage: String?
    @Published private(set) var isLoading = true

    private var settingsStore: SharedSettingsStore?
    private var templateStore: TemplateStore?
    private let helperService = SMAppService.loginItem(identifier: "com.number47.fewer.shortcut-helper")

    init() {}

    func load() async {
        guard settingsStore == nil else { return }
        let resourceDirectory = Bundle.main.resourceURL ?? Bundle.main.bundleURL
        let loaded = await Task.detached(priority: .utility) { () -> Result<SettingsLoadState, SettingsViewModelError> in
            do {
                let settingsStore = try SharedSettingsStore(access: .mainAppWriter)
                let templateStore = try TemplateStore(builtInDirectory: resourceDirectory)
                return .success(SettingsLoadState(
                    settingsStore: settingsStore,
                    templateStore: templateStore,
                    result: settingsStore.load(),
                    templates: (try? templateStore.templates()) ?? []
                ))
            } catch {
                return .failure(SettingsViewModelError(message: error.localizedDescription))
            }
        }.value
        guard !Task.isCancelled else { return }
        switch loaded {
        case let .success(state):
            settingsStore = state.settingsStore
            templateStore = state.templateStore
            settings = state.result.settings
            templates = state.templates
            errorMessage = state.result.recoveryReason
        case let .failure(error):
            errorMessage = "共享容器不可用：\(error.message)"
        }
        isLoading = false
    }

    func setFeature(_ feature: FewerFeature, enabled: Bool) {
        if enabled {
            settings.enabledFeatures.insert(feature)
        } else {
            settings.enabledFeatures.remove(feature)
        }
        saveSettings()
    }

    func moveFeatures(from offsets: IndexSet, to destination: Int) {
        settings.menuOrder.move(fromOffsets: offsets, toOffset: destination)
        saveSettings()
    }

    func setPathFormat(_ format: PathOutputFormat) {
        settings.pathFormat = format
        saveSettings()
    }

    func setTerminalBundleID(_ bundleIdentifier: String) {
        settings.terminalBundleID = bundleIdentifier
        saveSettings()
    }

    func setOpenWithApplications(_ applications: [OpenWithApplication]) {
        settings.openWithApplications = applications
        saveSettings()
    }

    func setConflictPolicy(_ policy: ConflictPolicy) {
        settings.conflictPolicy = policy
        saveSettings()
    }

    func setNotificationsEnabled(_ enabled: Bool) {
        settings.notificationsEnabled = enabled
        saveSettings()
    }

    func setShortcutHelperEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try helperService.register()
            } else {
                try helperService.unregister()
            }
            settings.shortcutHelperEnabled = enabled
            settings.launchHelperAtLogin = enabled
            saveSettings()
            if enabled {
                PermissionService.launchShortcutHelper()
            }
        } catch {
            errorMessage = "无法更新快捷键助手：\(error.localizedDescription)"
        }
    }

    func setLaunchHelperAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try helperService.register()
            } else {
                try helperService.unregister()
            }
            settings.launchHelperAtLogin = enabled
            saveSettings()
            if enabled {
                PermissionService.launchShortcutHelper()
            }
        } catch {
            errorMessage = "无法更新登录项：\(error.localizedDescription)"
        }
    }

    func updateTemplate(_ descriptor: TemplateDescriptor) {
        guard let templateStore else { return }
        Task { [weak self] in
            let result = await Self.updateTemplates(using: templateStore) {
                try templateStore.update(descriptor)
            }
            self?.applyTemplateUpdate(result, action: "更新")
        }
    }

    func importTemplate(from url: URL) {
        guard let templateStore else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        Task { [weak self] in
            let result = await Self.updateTemplates(using: templateStore) {
                _ = try templateStore.importTemplate(
                    from: url,
                    displayName: url.deletingPathExtension().lastPathComponent
                )
            }
            if accessing { url.stopAccessingSecurityScopedResource() }
            self?.applyTemplateUpdate(result, action: "导入")
        }
    }

    func deleteTemplate(_ descriptor: TemplateDescriptor) {
        guard let templateStore else { return }
        Task { [weak self] in
            let result = await Self.updateTemplates(using: templateStore) {
                try templateStore.delete(descriptor)
            }
            self?.applyTemplateUpdate(result, action: "删除")
        }
    }

    func revealTemplate(_ descriptor: TemplateDescriptor) {
        guard let templateStore else { return }
        Task {
            let url = await Task.detached(priority: .utility) {
                try? templateStore.fileURL(for: descriptor)
            }.value
            if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }

    private static func updateTemplates(
        using templateStore: TemplateStore,
        operation: @escaping @Sendable () throws -> Void
    ) async -> Result<[TemplateDescriptor], SettingsViewModelError> {
        await Task.detached(priority: .utility) {
            do {
                try operation()
                return .success(try templateStore.templates())
            } catch {
                return .failure(SettingsViewModelError(message: error.localizedDescription))
            }
        }.value
    }

    private func applyTemplateUpdate(
        _ result: Result<[TemplateDescriptor], SettingsViewModelError>,
        action: String
    ) {
        switch result {
        case let .success(templates):
            self.templates = templates
        case let .failure(error):
            errorMessage = "无法\(action)模板：\(error.message)"
        }
    }

    private func saveSettings() {
        guard let settingsStore else { return }
        let settings = settings
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) { () -> Result<Void, SettingsViewModelError> in
                do {
                    try settingsStore.save(settings)
                    return .success(())
                } catch {
                    return .failure(SettingsViewModelError(message: error.localizedDescription))
                }
            }.value
            guard !Task.isCancelled, let self else { return }
            switch result {
            case .success:
                DistributedNotificationCenter.default().postNotificationName(
                    AppGroupConstants.featureSettingsDidChangeNotification,
                    object: nil,
                    userInfo: nil,
                    deliverImmediately: true
                )
            case let .failure(error):
                self.errorMessage = "无法保存设置：\(error.message)"
            }
        }
    }
}
