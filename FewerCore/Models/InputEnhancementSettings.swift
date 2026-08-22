import Foundation

public enum ScrollInputDevice: String, Codable, Sendable {
    case mouse
    case trackpad
}

public struct ScrollAxisSettings: Codable, Equatable, Sendable {
    public var smoothEnabled: Bool
    public var reversed: Bool
    public var minimumStep: Double
    public var speedGain: Double
    public var response: Double

    public init(
        smoothEnabled: Bool = true,
        reversed: Bool = false,
        minimumStep: Double = 3,
        speedGain: Double = 1,
        response: Double = 0.18
    ) {
        self.smoothEnabled = smoothEnabled
        self.reversed = reversed
        self.minimumStep = minimumStep
        self.speedGain = speedGain
        self.response = response
        normalize()
    }

    public mutating func normalize() {
        minimumStep = min(max(minimumStep, 0), 24)
        speedGain = min(max(speedGain, 0.25), 8)
        response = min(max(response, 0.05), 0.8)
    }

    private enum CodingKeys: String, CodingKey {
        case smoothEnabled, reversed, minimumStep, speedGain, response
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            smoothEnabled: try container.decodeIfPresent(Bool.self, forKey: .smoothEnabled) ?? true,
            reversed: try container.decodeIfPresent(Bool.self, forKey: .reversed) ?? false,
            minimumStep: try container.decodeIfPresent(Double.self, forKey: .minimumStep) ?? 3,
            speedGain: try container.decodeIfPresent(Double.self, forKey: .speedGain) ?? 1,
            response: try container.decodeIfPresent(Double.self, forKey: .response) ?? 0.18
        )
    }
}

public struct ScrollEnhancementSettings: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var vertical: ScrollAxisSettings
    public var horizontal: ScrollAxisSettings
    public var simulatesTrackpad: Bool

    public init(
        isEnabled: Bool = false,
        vertical: ScrollAxisSettings = ScrollAxisSettings(),
        horizontal: ScrollAxisSettings = ScrollAxisSettings(),
        minimumStep: Double? = nil,
        speedGain: Double? = nil,
        response: Double? = nil,
        simulatesTrackpad: Bool = false
    ) {
        self.isEnabled = isEnabled
        self.vertical = vertical
        self.horizontal = horizontal
        if let minimumStep {
            self.vertical.minimumStep = minimumStep
            self.horizontal.minimumStep = minimumStep
        }
        if let speedGain {
            self.vertical.speedGain = speedGain
            self.horizontal.speedGain = speedGain
        }
        if let response {
            self.vertical.response = response
            self.horizontal.response = response
        }
        self.simulatesTrackpad = simulatesTrackpad
        normalize()
    }

    public mutating func normalize() {
        vertical.normalize()
        horizontal.normalize()
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, vertical, horizontal, simulatesTrackpad
        case minimumStep, speedGain, response
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            isEnabled: try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false,
            vertical: try container.decodeIfPresent(ScrollAxisSettings.self, forKey: .vertical) ?? .init(),
            horizontal: try container.decodeIfPresent(ScrollAxisSettings.self, forKey: .horizontal) ?? .init(),
            minimumStep: try container.decodeIfPresent(Double.self, forKey: .minimumStep),
            speedGain: try container.decodeIfPresent(Double.self, forKey: .speedGain),
            response: try container.decodeIfPresent(Double.self, forKey: .response),
            simulatesTrackpad: try container.decodeIfPresent(Bool.self, forKey: .simulatesTrackpad) ?? false
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(vertical, forKey: .vertical)
        try container.encode(horizontal, forKey: .horizontal)
        try container.encode(simulatesTrackpad, forKey: .simulatesTrackpad)
    }
}

public enum ApplicationScrollMode: String, Codable, Hashable, Sendable {
    case inherit
    case override
    case bypass
}

public struct ApplicationScrollOverride: Codable, Equatable, Identifiable, Sendable {
    public let bundleIdentifier: String
    public var displayName: String
    public var mode: ApplicationScrollMode
    public var settings: ScrollEnhancementSettings

    public var id: String { bundleIdentifier }

    public init(
        bundleIdentifier: String,
        displayName: String,
        mode: ApplicationScrollMode,
        settings: ScrollEnhancementSettings = ScrollEnhancementSettings()
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.mode = mode
        self.settings = settings
    }
}

public enum MouseGestureDirection: String, Codable, CaseIterable, Sendable {
    case up
    case down
    case left
    case right
    case upRight
    case downRight
    case upLeft
    case downLeft
}

public struct InputShortcut: Codable, Hashable, Sendable {
    public let keyCode: UInt16
    public let modifiers: ShortcutModifiers

    public init(keyCode: UInt16, modifiers: ShortcutModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

public enum InputAction: Codable, Hashable, Sendable {
    case shortcut(InputShortcut)
    case mouseBack
    case mouseForward
    case missionControl
    case showDesktop
    case spaceLeft
    case spaceRight
    case closeTab
    case newTab
    case reload
    case scrollToTop
    case scrollToBottom
    case minimizeWindow
    case zoomWindow
    case moduleCommand(moduleID: String, commandID: String)
}

public struct MouseGestureRule: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var isEnabled: Bool
    public var triggerButton: Int64
    public var directions: [MouseGestureDirection]
    public var action: InputAction
    public var bundleIdentifier: String?

    public init(
        id: UUID = UUID(),
        isEnabled: Bool = true,
        triggerButton: Int64,
        directions: [MouseGestureDirection],
        action: InputAction,
        bundleIdentifier: String? = nil
    ) {
        self.id = id
        self.isEnabled = isEnabled
        self.triggerButton = triggerButton
        self.directions = Array(directions.prefix(8))
        self.action = action
        self.bundleIdentifier = bundleIdentifier
    }
}

public enum MouseGesturePresets {
    public static let defaultRules: [MouseGestureRule] = [
        MouseGestureRule(triggerButton: 1, directions: [.left], action: .mouseBack),
        MouseGestureRule(triggerButton: 1, directions: [.right], action: .mouseForward),
        MouseGestureRule(triggerButton: 1, directions: [.up], action: .scrollToTop),
        MouseGestureRule(triggerButton: 1, directions: [.down], action: .scrollToBottom),
        MouseGestureRule(triggerButton: 1, directions: [.downRight], action: .closeTab),
        MouseGestureRule(triggerButton: 1, directions: [.upRight], action: .reload),
        MouseGestureRule(triggerButton: 1, directions: [.downLeft], action: .newTab),
        MouseGestureRule(triggerButton: 1, directions: [.upLeft], action: .showDesktop),
    ]
}

public enum KeycastMode: String, Codable, Sendable {
    case shortcutsOnly
    case specialKeysOnly
}

public enum KeycastOverlayPosition: String, Codable, CaseIterable, Sendable {
    case topLeft
    case top
    case topRight
    case left
    case center
    case right
    case bottomLeft
    case bottom
    case bottomRight
    case custom

    public var title: String {
        switch self {
        case .topLeft: "左上"
        case .top: "上"
        case .topRight: "右上"
        case .left: "左"
        case .center: "居中"
        case .right: "右"
        case .bottomLeft: "左下"
        case .bottom: "下"
        case .bottomRight: "右下"
        case .custom: "自定义"
        }
    }

    public var normalizedPoint: KeycastNormalizedPosition? {
        switch self {
        case .topLeft: .init(x: 0, y: 1)
        case .top: .init(x: 0.5, y: 1)
        case .topRight: .init(x: 1, y: 1)
        case .left: .init(x: 0, y: 0.5)
        case .center: .init(x: 0.5, y: 0.5)
        case .right: .init(x: 1, y: 0.5)
        case .bottomLeft: .init(x: 0, y: 0)
        case .bottom: .init(x: 0.5, y: 0)
        case .bottomRight: .init(x: 1, y: 0)
        case .custom: nil
        }
    }
}

public struct KeycastNormalizedPosition: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = min(max(x, 0), 1)
        self.y = min(max(y, 0), 1)
    }
}

public struct KeycastSettings: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var mode: KeycastMode
    public var showsMouseClicks: Bool
    public var opacity: Double
    public var fontSize: Double
    public var displayDuration: Double
    public var maximumVisibleEvents: Int
    public var excludedBundleIdentifiers: Set<String>
    public var toggleShortcut: InputShortcut?
    public var position: KeycastOverlayPosition
    public var customPosition: KeycastNormalizedPosition?

    public init(
        isEnabled: Bool = false,
        mode: KeycastMode = .shortcutsOnly,
        showsMouseClicks: Bool = false,
        opacity: Double = 0.88,
        fontSize: Double = 24,
        displayDuration: Double = 1.8,
        maximumVisibleEvents: Int = 5,
        excludedBundleIdentifiers: Set<String> = [],
        toggleShortcut: InputShortcut? = nil,
        position: KeycastOverlayPosition = .bottom,
        customPosition: KeycastNormalizedPosition? = nil
    ) {
        self.isEnabled = isEnabled
        self.mode = mode
        self.showsMouseClicks = showsMouseClicks
        self.opacity = min(max(opacity, 0.2), 1)
        self.fontSize = min(max(fontSize, 12), 64)
        self.displayDuration = min(max(displayDuration, 0.5), 8)
        self.maximumVisibleEvents = min(max(maximumVisibleEvents, 1), 10)
        self.excludedBundleIdentifiers = excludedBundleIdentifiers
        self.toggleShortcut = toggleShortcut
        self.position = position
        self.customPosition = customPosition
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, mode, showsMouseClicks, opacity, fontSize, displayDuration
        case maximumVisibleEvents, excludedBundleIdentifiers, toggleShortcut, position, customPosition
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            isEnabled: try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false,
            mode: try container.decodeIfPresent(KeycastMode.self, forKey: .mode) ?? .shortcutsOnly,
            showsMouseClicks: try container.decodeIfPresent(Bool.self, forKey: .showsMouseClicks) ?? false,
            opacity: try container.decodeIfPresent(Double.self, forKey: .opacity) ?? 0.88,
            fontSize: try container.decodeIfPresent(Double.self, forKey: .fontSize) ?? 24,
            displayDuration: try container.decodeIfPresent(Double.self, forKey: .displayDuration) ?? 1.8,
            maximumVisibleEvents: try container.decodeIfPresent(Int.self, forKey: .maximumVisibleEvents) ?? 5,
            excludedBundleIdentifiers: try container.decodeIfPresent(Set<String>.self, forKey: .excludedBundleIdentifiers) ?? [],
            toggleShortcut: try container.decodeIfPresent(InputShortcut.self, forKey: .toggleShortcut),
            position: try container.decodeIfPresent(KeycastOverlayPosition.self, forKey: .position) ?? .bottom,
            customPosition: try container.decodeIfPresent(KeycastNormalizedPosition.self, forKey: .customPosition)
        )
    }
}

public struct InputEnhancementSettings: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 3

    public var schemaVersion: Int
    public var scroll: ScrollEnhancementSettings
    public var applicationOverrides: [ApplicationScrollOverride]
    public var gestureRules: [MouseGestureRule]
    public var gestureExcludedBundleIdentifiers: Set<String>
    public var keycast: KeycastSettings
    public var emergencyDisabled: Bool

    public init(
        schemaVersion: Int = currentSchemaVersion,
        scroll: ScrollEnhancementSettings = ScrollEnhancementSettings(),
        applicationOverrides: [ApplicationScrollOverride] = [],
        gestureRules: [MouseGestureRule] = [],
        gestureExcludedBundleIdentifiers: Set<String> = [],
        keycast: KeycastSettings = KeycastSettings(),
        emergencyDisabled: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.scroll = scroll
        self.applicationOverrides = applicationOverrides
        self.gestureRules = gestureRules
        self.gestureExcludedBundleIdentifiers = gestureExcludedBundleIdentifiers
        self.keycast = keycast
        self.emergencyDisabled = emergencyDisabled
    }

    public static let `default` = InputEnhancementSettings(
        gestureRules: MouseGesturePresets.defaultRules
    )

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case scroll
        case applicationOverrides
        case gestureRules
        case gestureExcludedBundleIdentifiers
        case keycast
        case emergencyDisabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        scroll = try container.decodeIfPresent(ScrollEnhancementSettings.self, forKey: .scroll) ?? .init()
        applicationOverrides = try container.decodeIfPresent(
            [ApplicationScrollOverride].self,
            forKey: .applicationOverrides
        ) ?? []
        gestureRules = try container.decodeIfPresent([MouseGestureRule].self, forKey: .gestureRules) ?? []
        gestureExcludedBundleIdentifiers = try container.decodeIfPresent(
            Set<String>.self,
            forKey: .gestureExcludedBundleIdentifiers
        ) ?? []
        keycast = try container.decodeIfPresent(KeycastSettings.self, forKey: .keycast) ?? .init()
        emergencyDisabled = try container.decodeIfPresent(Bool.self, forKey: .emergencyDisabled) ?? false
    }

    public func resolvedScrollSettings(for bundleIdentifier: String?) -> ScrollEnhancementSettings? {
        guard !emergencyDisabled else { return nil }
        guard let bundleIdentifier,
              let rule = applicationOverrides.first(where: { $0.bundleIdentifier == bundleIdentifier })
        else {
            return scroll.isEnabled ? scroll : nil
        }
        switch rule.mode {
        case .inherit:
            return scroll.isEnabled ? scroll : nil
        case .override:
            return rule.settings.isEnabled ? rule.settings : nil
        case .bypass:
            return nil
        }
    }
}
