import AppKit
import Combine
import Foundation

enum AppPresentationMode: String, CaseIterable, Identifiable {
    case menuBar
    case dock

    static let storageKey = "appPresentationMode"

    var id: Self { self }

    var title: String {
        switch self {
        case .menuBar:
            return "菜单栏"
        case .dock:
            return "Dock"
        }
    }

    var systemImage: String {
        switch self {
        case .menuBar:
            return "menubar.rectangle"
        case .dock:
            return "dock.rectangle"
        }
    }

    static var stored: Self {
        guard let value = UserDefaults.standard.string(forKey: storageKey) else {
            return .menuBar
        }
        return Self(rawValue: value) ?? .menuBar
    }
}

@MainActor
final class AppPresentationController: ObservableObject {
    static let shared = AppPresentationController()

    @Published private(set) var mode = AppPresentationMode.menuBar

    private init() {}

    func restoreStoredMode() {
        setMode(.stored, persist: false)
    }

    func setMode(_ mode: AppPresentationMode, persist: Bool = true) {
        self.mode = mode

        if persist {
            UserDefaults.standard.set(mode.rawValue, forKey: AppPresentationMode.storageKey)
        }

        switch mode {
        case .menuBar:
            // macOS 26.4+：若先设置 .accessory 再创建 status item，图标不会渲染
            // （WindowServer 注册问题）。需先以 .regular 激活注册，安装 status item
            // 后再切回 .accessory 隐藏 Dock 图标。
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            MenuBarController.shared.setVisible(true)
            NSApp.setActivationPolicy(.accessory)
        case .dock:
            MenuBarController.shared.setVisible(false)
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
