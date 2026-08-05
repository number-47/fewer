import AppKit
import Combine
import FewerCore
import ServiceManagement

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var settings: FeatureSettings = .default
    @Published var templates: [TemplateDescriptor] = []
    @Published var errorMessage: String?

    private let settingsStore: SharedSettingsStore?
    private let templateStore: TemplateStore?
    private let helperService = SMAppService.loginItem(identifier: "com.number47.fewer.shortcut-helper")

    init() {
        do {
            let settingsStore = try SharedSettingsStore()
            let resourceDirectory = Bundle.main.resourceURL ?? Bundle.main.bundleURL
            let templateStore = try TemplateStore(builtInDirectory: resourceDirectory)
            self.settingsStore = settingsStore
            self.templateStore = templateStore
            let result = settingsStore.load()
            settings = result.settings
            templates = (try? templateStore.templates()) ?? []
            errorMessage = result.recoveryReason
        } catch {
            settingsStore = nil
            templateStore = nil
            errorMessage = "共享容器不可用：\(error.localizedDescription)"
        }
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
        } catch {
            errorMessage = "无法更新登录项：\(error.localizedDescription)"
        }
    }

    func updateTemplate(_ descriptor: TemplateDescriptor) {
        do {
            try templateStore?.update(descriptor)
            reloadTemplates()
        } catch {
            errorMessage = "无法更新模板：\(error.localizedDescription)"
        }
    }

    func importTemplate(from url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            _ = try templateStore?.importTemplate(
                from: url,
                displayName: url.deletingPathExtension().lastPathComponent
            )
            reloadTemplates()
        } catch {
            errorMessage = "无法导入模板：\(error.localizedDescription)"
        }
    }

    func deleteTemplate(_ descriptor: TemplateDescriptor) {
        do {
            try templateStore?.delete(descriptor)
            reloadTemplates()
        } catch {
            errorMessage = "无法删除模板：\(error.localizedDescription)"
        }
    }

    func revealTemplate(_ descriptor: TemplateDescriptor) {
        guard let url = try? templateStore?.fileURL(for: descriptor) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func reloadTemplates() {
        templates = (try? templateStore?.templates()) ?? []
    }

    private func saveSettings() {
        do {
            try settingsStore?.save(settings)
        } catch {
            errorMessage = "无法保存设置：\(error.localizedDescription)"
        }
    }
}
