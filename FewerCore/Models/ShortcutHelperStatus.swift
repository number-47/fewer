import Foundation

public struct ShortcutHelperStatus: Codable, Equatable, Sendable {
    public static let unavailable = ShortcutHelperStatus(
        isAccessibilityTrusted: false,
        isInputMonitoringTrusted: false,
        processIdentifier: 0,
        updatedAt: .distantPast
    )

    public let isAccessibilityTrusted: Bool
    public let isInputMonitoringTrusted: Bool
    public let isEventTapActive: Bool
    public let isScrollEngineActive: Bool
    public let isGestureEngineActive: Bool
    public let isKeycastActive: Bool
    public let detectedScrollDevice: ScrollInputDevice?
    public let emergencyDisabled: Bool
    public let lastError: String?
    public let processIdentifier: Int32
    public let updatedAt: Date

    public init(
        isAccessibilityTrusted: Bool,
        isInputMonitoringTrusted: Bool = false,
        isEventTapActive: Bool = false,
        isScrollEngineActive: Bool = false,
        isGestureEngineActive: Bool = false,
        isKeycastActive: Bool = false,
        detectedScrollDevice: ScrollInputDevice? = nil,
        emergencyDisabled: Bool = false,
        lastError: String? = nil,
        processIdentifier: Int32,
        updatedAt: Date
    ) {
        self.isAccessibilityTrusted = isAccessibilityTrusted
        self.isInputMonitoringTrusted = isInputMonitoringTrusted
        self.isEventTapActive = isEventTapActive
        self.isScrollEngineActive = isScrollEngineActive
        self.isGestureEngineActive = isGestureEngineActive
        self.isKeycastActive = isKeycastActive
        self.detectedScrollDevice = detectedScrollDevice
        self.emergencyDisabled = emergencyDisabled
        self.lastError = lastError
        self.processIdentifier = processIdentifier
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case isAccessibilityTrusted
        case isInputMonitoringTrusted
        case isEventTapActive
        case isScrollEngineActive
        case isGestureEngineActive
        case isKeycastActive
        case detectedScrollDevice
        case emergencyDisabled
        case lastError
        case processIdentifier
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isAccessibilityTrusted = try container.decode(Bool.self, forKey: .isAccessibilityTrusted)
        isInputMonitoringTrusted = try container.decodeIfPresent(Bool.self, forKey: .isInputMonitoringTrusted) ?? false
        isEventTapActive = try container.decodeIfPresent(Bool.self, forKey: .isEventTapActive) ?? false
        isScrollEngineActive = try container.decodeIfPresent(Bool.self, forKey: .isScrollEngineActive) ?? false
        isGestureEngineActive = try container.decodeIfPresent(Bool.self, forKey: .isGestureEngineActive) ?? false
        isKeycastActive = try container.decodeIfPresent(Bool.self, forKey: .isKeycastActive) ?? false
        detectedScrollDevice = try container.decodeIfPresent(ScrollInputDevice.self, forKey: .detectedScrollDevice)
        emergencyDisabled = try container.decodeIfPresent(Bool.self, forKey: .emergencyDisabled) ?? false
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        processIdentifier = try container.decode(Int32.self, forKey: .processIdentifier)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    public func isFresh(at date: Date = Date(), timeout: TimeInterval = 5) -> Bool {
        processIdentifier > 0 && date.timeIntervalSince(updatedAt) <= timeout
    }

    /// Compare all meaningful fields except `updatedAt`.
    public func hasSameContent(as other: ShortcutHelperStatus) -> Bool {
        isAccessibilityTrusted == other.isAccessibilityTrusted &&
        isInputMonitoringTrusted == other.isInputMonitoringTrusted &&
        isEventTapActive == other.isEventTapActive &&
        isScrollEngineActive == other.isScrollEngineActive &&
        isGestureEngineActive == other.isGestureEngineActive &&
        isKeycastActive == other.isKeycastActive &&
        detectedScrollDevice == other.detectedScrollDevice &&
        emergencyDisabled == other.emergencyDisabled &&
        lastError == other.lastError &&
        processIdentifier == other.processIdentifier
    }
}
