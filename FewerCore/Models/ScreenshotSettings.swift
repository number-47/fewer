import Carbon.HIToolbox
import Foundation

/// 全局快捷键描述：按键码 + 修饰键（Carbon 常量，见 <Carbon/Events.h>）。
public struct HotKeySpec: Codable, Equatable, Sendable {
    public static let command = UInt32(cmdKey)      // 0x0100
    public static let shift = UInt32(shiftKey)      // 0x0200
    public static let option = UInt32(optionKey)    // 0x0800
    public static let control = UInt32(controlKey)  // 0x1000

    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// 区域截屏：⌘⌥A（避开 Snapzy/Snipaste 等已占用的 ⌘⇧数字键）
    public static let regionDefault = HotKeySpec(keyCode: UInt32(kVK_ANSI_A), modifiers: command | option)
    /// 窗口截屏：⌘⌥W
    public static let windowDefault = HotKeySpec(keyCode: UInt32(kVK_ANSI_W), modifiers: command | option)
    /// 全屏截屏：⌘⌥F
    public static let fullscreenDefault = HotKeySpec(keyCode: UInt32(kVK_ANSI_F), modifiers: command | option)
    /// 截图翻译：⌘⌥T
    public static let ocrTranslateDefault = HotKeySpec(keyCode: UInt32(kVK_ANSI_T), modifiers: command | option)

    /// 修饰键是否为空（无效快捷键）。
    public var isEmpty: Bool { modifiers == 0 }

    /// 人类可读的快捷键描述，如 "⌘⌥A"。
    public var displayString: String {
        var s = ""
        if modifiers & Self.command != 0 { s += "⌘" }
        if modifiers & Self.control != 0 { s += "⌃" }
        if modifiers & Self.option != 0 { s += "⌥" }
        if modifiers & Self.shift != 0 { s += "⇧" }
        s += Self.keyName(for: keyCode)
        return s
    }

    /// 按键码 → 键名（ANSI 键盘布局映射，来自 Carbon kVK_* 常量，特殊键兜底）。
    private static func keyName(for keyCode: UInt32) -> String {
        let names: [UInt32: String] = [
            0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G",
            0x06: "Z", 0x07: "X", 0x08: "C", 0x09: "V", 0x0B: "B", 0x0C: "Q",
            0x0D: "W", 0x0E: "E", 0x0F: "R", 0x10: "Y", 0x11: "T",
            0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x16: "6", 0x17: "5",
            0x18: "=", 0x19: "9", 0x1A: "7", 0x1B: "-", 0x1C: "8", 0x1D: "0",
            0x1E: "]", 0x1F: "O", 0x20: "U", 0x21: "[", 0x22: "I", 0x23: "P",
            0x25: "L", 0x26: "J", 0x27: "'", 0x28: "K", 0x29: ";",
            0x2A: "\\", 0x2B: ",", 0x2C: "/", 0x2D: "N", 0x2E: "M", 0x2F: ".",
            0x32: "`",
            0x24: "回车", 0x30: "Tab", 0x31: "空格", 0x33: "删除", 0x35: "Esc",
            0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5",
            0x61: "F6", 0x62: "F7", 0x64: "F8", 0x65: "F9", 0x6D: "F10",
            0x67: "F11", 0x6F: "F12",
            0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑",
            0x73: "Home", 0x77: "End", 0x74: "PageUp", 0x79: "PageDown",
        ]
        return names[keyCode] ?? "键\(keyCode)"
    }
}

/// 旧版本“截图后自动动作”字段，仅为解码已有设置保留。
/// 当前版本统一在截图结果窗口中由用户选择复制、编辑、贴图或保存。
public enum ScreenshotAfterAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case pin
    case editThenPin

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .pin: "贴图"
        case .editThenPin: "编辑并贴图"
        }
    }
}

/// 保存位置。
public enum ScreenshotSaveLocation: String, Codable, CaseIterable, Identifiable, Sendable {
    case desktop
    case downloads
    case custom

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .desktop: "桌面"
        case .downloads: "下载"
        case .custom: "自定义"
        }
    }
}

/// 截屏功能设置（独立于右键菜单设置）。
public struct ScreenshotSettings: Codable, Equatable, Sendable {
    public static let storageKey = "fewer.screenshotSettings"

    public var shortcutsEnabled: Bool
    public var regionHotKey: HotKeySpec
    public var windowHotKey: HotKeySpec
    public var fullscreenHotKey: HotKeySpec
    public var ocrTranslateHotKey: HotKeySpec
    /// 兼容旧设置；截图流程不再读取此值。
    public var afterAction: ScreenshotAfterAction
    public var rollingCaptureEnabled: Bool
    public var pinDefaultOpacity: Double
    public var saveLocation: ScreenshotSaveLocation
    /// 自定义保存目录的绝对路径；仅在 saveLocation == .custom 时使用。
    public var customSaveDirectory: String?

    public init(
        shortcutsEnabled: Bool = true,
        regionHotKey: HotKeySpec = .regionDefault,
        windowHotKey: HotKeySpec = .windowDefault,
        fullscreenHotKey: HotKeySpec = .fullscreenDefault,
        ocrTranslateHotKey: HotKeySpec = .ocrTranslateDefault,
        afterAction: ScreenshotAfterAction = .editThenPin,
        rollingCaptureEnabled: Bool = true,
        pinDefaultOpacity: Double = 1.0,
        saveLocation: ScreenshotSaveLocation = .desktop,
        customSaveDirectory: String? = nil
    ) {
        self.shortcutsEnabled = shortcutsEnabled
        self.regionHotKey = regionHotKey
        self.windowHotKey = windowHotKey
        self.fullscreenHotKey = fullscreenHotKey
        self.ocrTranslateHotKey = ocrTranslateHotKey
        self.afterAction = afterAction
        self.rollingCaptureEnabled = rollingCaptureEnabled
        self.pinDefaultOpacity = pinDefaultOpacity
        self.saveLocation = saveLocation
        self.customSaveDirectory = customSaveDirectory
    }

    public static let `default` = ScreenshotSettings()

    private enum CodingKeys: String, CodingKey {
        case shortcutsEnabled
        case regionHotKey
        case windowHotKey
        case fullscreenHotKey
        case ocrTranslateHotKey
        case afterAction
        case rollingCaptureEnabled
        case pinDefaultOpacity
        case saveLocation
        case customSaveDirectory
    }

    /// 解码旧数据：缺失字段回退默认，兼容后续新增字段。
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ScreenshotSettings.default
        shortcutsEnabled = try values.decodeIfPresent(Bool.self, forKey: .shortcutsEnabled)
            ?? defaults.shortcutsEnabled
        regionHotKey = try values.decodeIfPresent(HotKeySpec.self, forKey: .regionHotKey)
            ?? defaults.regionHotKey
        windowHotKey = try values.decodeIfPresent(HotKeySpec.self, forKey: .windowHotKey)
            ?? defaults.windowHotKey
        fullscreenHotKey = try values.decodeIfPresent(HotKeySpec.self, forKey: .fullscreenHotKey)
            ?? defaults.fullscreenHotKey
        ocrTranslateHotKey = try values.decodeIfPresent(HotKeySpec.self, forKey: .ocrTranslateHotKey)
            ?? defaults.ocrTranslateHotKey
        afterAction = try values.decodeIfPresent(ScreenshotAfterAction.self, forKey: .afterAction)
            ?? defaults.afterAction
        rollingCaptureEnabled = try values.decodeIfPresent(Bool.self, forKey: .rollingCaptureEnabled)
            ?? defaults.rollingCaptureEnabled
        pinDefaultOpacity = try values.decodeIfPresent(Double.self, forKey: .pinDefaultOpacity)
            ?? defaults.pinDefaultOpacity
        saveLocation = try values.decodeIfPresent(ScreenshotSaveLocation.self, forKey: .saveLocation)
            ?? defaults.saveLocation
        customSaveDirectory = try values.decodeIfPresent(String.self, forKey: .customSaveDirectory)
            ?? defaults.customSaveDirectory
    }

    /// 编码时显式写出全部字段，保证格式稳定。
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(shortcutsEnabled, forKey: .shortcutsEnabled)
        try container.encode(regionHotKey, forKey: .regionHotKey)
        try container.encode(windowHotKey, forKey: .windowHotKey)
        try container.encode(fullscreenHotKey, forKey: .fullscreenHotKey)
        try container.encode(ocrTranslateHotKey, forKey: .ocrTranslateHotKey)
        try container.encode(afterAction, forKey: .afterAction)
        try container.encode(rollingCaptureEnabled, forKey: .rollingCaptureEnabled)
        try container.encode(pinDefaultOpacity, forKey: .pinDefaultOpacity)
        try container.encode(saveLocation, forKey: .saveLocation)
        try container.encodeIfPresent(customSaveDirectory, forKey: .customSaveDirectory)
    }
}

/// 截屏设置的持久化存储（UserDefaults）。
public final class ScreenshotSettingsStore {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> ScreenshotSettings {
        guard let data = defaults.data(forKey: ScreenshotSettings.storageKey),
              let settings = try? JSONDecoder().decode(ScreenshotSettings.self, from: data)
        else { return .default }
        return settings
    }

    public func save(_ settings: ScreenshotSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: ScreenshotSettings.storageKey)
    }
}
