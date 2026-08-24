import Foundation

public struct ScrollEventSnapshot: Equatable, Sendable {
    public var isContinuous: Bool
    public var scrollPhase: Int64
    public var momentumPhase: Int64
    public var verticalDelta: Double
    public var horizontalDelta: Double

    public init(
        isContinuous: Bool,
        scrollPhase: Int64,
        momentumPhase: Int64,
        verticalDelta: Double,
        horizontalDelta: Double
    ) {
        self.isContinuous = isContinuous
        self.scrollPhase = scrollPhase
        self.momentumPhase = momentumPhase
        self.verticalDelta = verticalDelta
        self.horizontalDelta = horizontalDelta
    }
}

public struct ScrollProcessingResult: Equatable, Sendable {
    public let device: ScrollInputDevice
    public let verticalDelta: Double
    public let horizontalDelta: Double
    public let shouldConsumeOriginal: Bool

    public init(
        device: ScrollInputDevice,
        verticalDelta: Double,
        horizontalDelta: Double,
        shouldConsumeOriginal: Bool
    ) {
        self.device = device
        self.verticalDelta = verticalDelta
        self.horizontalDelta = horizontalDelta
        self.shouldConsumeOriginal = shouldConsumeOriginal
    }
}

public enum ScrollEventProcessor {
    public static func classify(_ event: ScrollEventSnapshot) -> ScrollInputDevice {
        if event.scrollPhase != 0 || event.momentumPhase != 0 {
            return .trackpad
        }
        return .mouse
    }

    public static func process(
        _ event: ScrollEventSnapshot,
        settings: ScrollEnhancementSettings?
    ) -> ScrollProcessingResult {
        let device = classify(event)
        guard device == .mouse, let settings, settings.isEnabled else {
            return ScrollProcessingResult(
                device: device,
                verticalDelta: event.verticalDelta,
                horizontalDelta: event.horizontalDelta,
                shouldConsumeOriginal: false
            )
        }
        let vertical = normalized(event.verticalDelta, minimum: settings.vertical.minimumStep)
            * settings.vertical.speedGain * (settings.vertical.reversed ? -1 : 1)
        let horizontal = normalized(event.horizontalDelta, minimum: settings.horizontal.minimumStep)
            * settings.horizontal.speedGain * (settings.horizontal.reversed ? -1 : 1)
        return ScrollProcessingResult(
            device: device,
            verticalDelta: vertical,
            horizontalDelta: horizontal,
            shouldConsumeOriginal: (vertical != 0 && settings.vertical.smoothEnabled)
                || (horizontal != 0 && settings.horizontal.smoothEnabled)
                || vertical != event.verticalDelta
                || horizontal != event.horizontalDelta
        )
    }

    private static func normalized(_ value: Double, minimum: Double) -> Double {
        guard value != 0 else { return 0 }
        return value.sign == .minus ? -max(abs(value), minimum) : max(abs(value), minimum)
    }
}

public enum ScrollDeltaReader {
    /// Returns a scroll delta in pixels from the three Quartz scroll fields.
    ///
    /// `scrollWheelEventPointDeltaAxis*` is unambiguously pixel-based, so it is
    /// preferred. The fixed-point field (`scrollWheelEventFixedPtDeltaAxis*`) is
    /// documented as either line-based or pixel-based depending on the device; for
    /// single-wheel mice it can carry the line count (e.g. `1.0` per notch) even
    /// when a pixel point-delta is also present. Reading the fixed-point value
    /// first therefore yields a magnitude far too small for such devices. The
    /// line field is only a last resort.
    public static func pixelDelta(fixedPtDelta: Double, pointDelta: Int, lineDelta: Int) -> Double {
        if pointDelta != 0 { return Double(pointDelta) }
        if fixedPtDelta != 0 { return fixedPtDelta }
        return Double(lineDelta)
    }
}

public enum ScrollDecayModel {
    public static func displacement(
        remaining: Double,
        deltaTime: Double,
        response: Double
    ) -> Double {
        guard remaining != 0, deltaTime > 0 else { return 0 }
        let clampedResponse = min(max(response, 0.05), 0.8)
        return remaining * (1 - exp(-deltaTime / clampedResponse))
    }
}

public enum SyntheticScrollUnits: Equatable, Sendable {
    case line
    case pixel
}

public struct SyntheticScrollEventSpec: Equatable, Sendable {
    public let units: SyntheticScrollUnits
    public let isContinuous: Bool
    public let scrollPhase: Int?
    public let momentumPhase: Int?
    public let verticalDelta: Int32
    public let horizontalDelta: Int32

    public init(
        units: SyntheticScrollUnits,
        isContinuous: Bool,
        scrollPhase: Int?,
        momentumPhase: Int?,
        verticalDelta: Int32,
        horizontalDelta: Int32
    ) {
        self.units = units
        self.isContinuous = isContinuous
        self.scrollPhase = scrollPhase
        self.momentumPhase = momentumPhase
        self.verticalDelta = verticalDelta
        self.horizontalDelta = horizontalDelta
    }
}

public enum SyntheticScrollEventSpecFactory {
    public static func make(
        vertical: Double,
        horizontal: Double,
        simulatesTrackpad: Bool,
        scrollPhase: Int?,
        momentumPhase: Int?
    ) -> SyntheticScrollEventSpec {
        let verticalDelta = Int32(clamping: Int(vertical.rounded()))
        let horizontalDelta = Int32(clamping: Int(horizontal.rounded()))
        if simulatesTrackpad {
            return SyntheticScrollEventSpec(
                units: .pixel,
                isContinuous: true,
                scrollPhase: scrollPhase,
                momentumPhase: momentumPhase,
                verticalDelta: verticalDelta,
                horizontalDelta: horizontalDelta
            )
        }
        return SyntheticScrollEventSpec(
            units: .line,
            isContinuous: false,
            scrollPhase: nil,
            momentumPhase: nil,
            verticalDelta: verticalDelta,
            horizontalDelta: horizontalDelta
        )
    }
}

public struct EventTapCircuitBreaker: Sendable {
    public let maximumFailures: Int
    public let window: TimeInterval
    private var failures: [Date] = []

    public init(maximumFailures: Int = 3, window: TimeInterval = 10) {
        self.maximumFailures = maximumFailures
        self.window = window
    }

    public mutating func recordFailure(at date: Date = Date()) -> Bool {
        failures.removeAll { date.timeIntervalSince($0) >= window }
        failures.append(date)
        return failures.count >= maximumFailures
    }

    public mutating func reset() {
        failures = []
    }
}

public enum SyntheticInputEventFilter {
    public static func shouldIgnore(userData: Int64, marker: Int64) -> Bool {
        userData == marker
    }
}

public enum InputShortcutSafety {
    public static func isAllowedGlobalToggle(
        _ shortcut: InputShortcut,
        additionalReserved: [InputShortcut] = []
    ) -> Bool {
        guard shortcut.modifiers.rawValue.nonzeroBitCount >= 2 else { return false }
        if shortcut.modifiers.contains(.command), [7, 8, 9].contains(shortcut.keyCode) {
            return false
        }
        if shortcut.keyCode == 53,
           shortcut.modifiers.contains([.control, .option, .command]) {
            return false
        }
        let defaultScreenshotShortcuts = [
            HotKeySpec.regionDefault,
            HotKeySpec.windowDefault,
            HotKeySpec.fullscreenDefault,
        ].map(InputShortcut.init)
        if (defaultScreenshotShortcuts + additionalReserved).contains(shortcut) { return false }
        return true
    }
}

public extension InputShortcut {
    init(_ hotKey: HotKeySpec) {
        var modifiers: ShortcutModifiers = []
        if hotKey.modifiers & HotKeySpec.command != 0 { modifiers.insert(.command) }
        if hotKey.modifiers & HotKeySpec.option != 0 { modifiers.insert(.option) }
        if hotKey.modifiers & HotKeySpec.shift != 0 { modifiers.insert(.shift) }
        if hotKey.modifiers & HotKeySpec.control != 0 { modifiers.insert(.control) }
        self.init(keyCode: UInt16(hotKey.keyCode), modifiers: modifiers)
    }
}

public struct GesturePoint: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public enum MouseGestureClickTolerance {
    public static let maximumMovement: Double = 4

    public static func isExceeded(from initialPoint: GesturePoint, to currentPoint: GesturePoint) -> Bool {
        hypot(currentPoint.x - initialPoint.x, currentPoint.y - initialPoint.y) > maximumMovement
    }
}

/// 保留手势轨迹的整体形状，同时限制实时渲染的工作量。
public struct MouseGestureTrail: Sendable {
    public static let maximumPointCount = 128

    public private(set) var points: [GesturePoint] = []

    public init() {}

    public mutating func begin(at point: GesturePoint) {
        points = [point]
    }

    public mutating func append(_ point: GesturePoint) {
        if points.count == Self.maximumPointCount {
            points = points.enumerated().compactMap { index, point in
                index.isMultiple(of: 2) ? point : nil
            }
        }
        points.append(point)
    }

    public mutating func reset() {
        points = []
    }
}

public enum MouseGestureCancellationReason: Equatable, Sendable {
    case applicationChanged
    case timedOut
}

public enum MouseGestureSessionPolicy {
    public static func cancellationReason(
        startedAt: Date,
        now: Date,
        startedBundleIdentifier: String?,
        currentBundleIdentifier: String?,
        timeout: TimeInterval = 3
    ) -> MouseGestureCancellationReason? {
        if startedBundleIdentifier != currentBundleIdentifier { return .applicationChanged }
        if now.timeIntervalSince(startedAt) > timeout { return .timedOut }
        return nil
    }
}

/// 手势结束（松开按键或被取消）时的处置结果。
public enum MouseGestureCompletion: Equatable, Sendable {
    /// 命中规则，执行对应动作。
    case executeAction(InputAction)
    /// 未超过点击容差且未命中规则，重放原始右键点击以还原系统行为。
    case replayClick
    /// 已超过点击容差但未命中任何规则，静默结束，不重放点击。
    case none
}

public enum MouseGestureCompletionPolicy {
    public static func completion(
        rule: MouseGestureRule?,
        hasExceededClickTolerance: Bool
    ) -> MouseGestureCompletion {
        if let rule { return .executeAction(rule.action) }
        if !hasExceededClickTolerance { return .replayClick }
        return .none
    }
}

public struct MouseGestureRecognizer: Sendable {
    public let minimumSegmentLength: Double
    public let maximumDirections: Int
    private var anchor: GesturePoint?
    public private(set) var directions: [MouseGestureDirection] = []

    public init(minimumSegmentLength: Double = 16, maximumDirections: Int = 8) {
        self.minimumSegmentLength = minimumSegmentLength
        self.maximumDirections = maximumDirections
    }

    public mutating func begin(at point: GesturePoint) {
        anchor = point
        directions = []
    }

    @discardableResult
    public mutating func append(_ point: GesturePoint) -> MouseGestureDirection? {
        guard directions.count < maximumDirections, let anchor else { return nil }
        let deltaX = point.x - anchor.x
        let deltaY = point.y - anchor.y
        let distance = hypot(deltaX, deltaY)
        guard distance >= minimumSegmentLength else { return nil }
        let direction: MouseGestureDirection
        let angle = atan2(deltaY, deltaX) * 180 / Double.pi
        if let last = directions.last {
            let band: Double = 30
            switch last {
            case .up:
                if abs(angle - 90) <= band { self.anchor = point; return nil }
            case .down:
                if abs(angle + 90) <= band { self.anchor = point; return nil }
            case .left:
                if abs(angle) >= 180 - band { self.anchor = point; return nil }
            case .right:
                if abs(angle) <= band { self.anchor = point; return nil }
            default:
                break
            }
        }
        switch angle {
        case 22.5..<67.5: direction = .upRight
        case 67.5..<112.5: direction = .up
        case 112.5..<157.5: direction = .upLeft
        case -67.5..<(-22.5): direction = .downRight
        case -112.5..<(-67.5): direction = .down
        case -157.5..<(-112.5): direction = .downLeft
        case let a where a >= 157.5 || a < -157.5: direction = .left
        default: direction = .right
        }
        self.anchor = point
        guard directions.last != direction else { return nil }
        directions.append(direction)
        return direction
    }

    public func matchingRule(
        in rules: [MouseGestureRule],
        triggerButton: Int64,
        bundleIdentifier: String?
    ) -> MouseGestureRule? {
        rules.enumerated()
            .filter { _, rule in
                rule.isEnabled
                    && rule.triggerButton == triggerButton
                    && rule.directions == directions
                    && (rule.bundleIdentifier == nil || rule.bundleIdentifier == bundleIdentifier)
            }
            .sorted { lhs, rhs in
                let lhsSpecific = lhs.element.bundleIdentifier == nil ? 0 : 1
                let rhsSpecific = rhs.element.bundleIdentifier == nil ? 0 : 1
                if lhsSpecific != rhsSpecific { return lhsSpecific > rhsSpecific }
                return lhs.offset < rhs.offset
            }
            .first?.element
    }
}

public enum KeycastEventFilter {
    private static let modifierMask = ShortcutModifiers.command.rawValue
        | ShortcutModifiers.option.rawValue
        | ShortcutModifiers.control.rawValue

    public static func shouldDisplay(
        keyCode: UInt16,
        modifiers: ShortcutModifiers,
        mode: KeycastMode,
        temporaryAllKeys: Bool,
        secureInputEnabled: Bool,
        isExcludedApplication: Bool
    ) -> Bool {
        guard !secureInputEnabled, !isExcludedApplication else { return false }
        if temporaryAllKeys { return true }
        if isSpecialKey(keyCode) { return true }
        switch mode {
        case .shortcutsOnly:
            return modifiers.rawValue & modifierMask != 0
        case .specialKeysOnly:
            return false
        }
    }

    public static func displayString(
        keyCode: UInt16,
        modifiers: ShortcutModifiers,
        keyLabel: String? = nil
    ) -> String {
        var value = ""
        if modifiers.contains(.control) { value += "⌃" }
        if modifiers.contains(.option) { value += "⌥" }
        if modifiers.contains(.shift) { value += "⇧" }
        if modifiers.contains(.command) { value += "⌘" }
        value += specialKeyName(keyCode) ?? keyLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? keyName(keyCode)
        return value
    }

    private static func isSpecialKey(_ keyCode: UInt16) -> Bool {
        specialKeyName(keyCode) != nil
    }

    private static func specialKeyName(_ keyCode: UInt16) -> String? {
        switch keyCode {
        case 36, 76: "↩"
        case 48: "⇥"
        case 49: "Space"
        case 51: "⌫"
        case 53: "Esc"
        case 115: "↖"
        case 116: "⇞"
        case 117: "⌦"
        case 119: "↘"
        case 121: "⇟"
        case 122: "F1"
        case 120: "F2"
        case 99: "F3"
        case 118: "F4"
        case 96: "F5"
        case 97: "F6"
        case 98: "F7"
        case 100: "F8"
        case 101: "F9"
        case 109: "F10"
        case 103: "F11"
        case 111: "F12"
        case 105: "F13"
        case 107: "F14"
        case 113: "F15"
        case 106: "F16"
        case 64: "F17"
        case 79: "F18"
        case 80: "F19"
        case 90: "F20"
        case 123: "←"
        case 124: "→"
        case 125: "↓"
        case 126: "↑"
        default: nil
        }
    }

    private static func keyName(_ keyCode: UInt16) -> String {
        let common: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 31: "O", 32: "U", 34: "I", 35: "P", 37: "L",
            38: "J", 40: "K", 45: "N", 46: "M",
        ]
        return common[keyCode] ?? "Key \(keyCode)"
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
