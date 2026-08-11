import Foundation

public enum RollingScrollDirection: String, Codable, Equatable, Sendable {
    case up
    case down

    public var title: String { self == .up ? "向上" : "向下" }
    public var signedDistanceMultiplier: Int { self == .up ? 1 : -1 }
}

/// 主应用发送给 Shortcut Helper 的一次受控滚动请求。
public struct RollingScrollCommand: Equatable, Sendable {
    public static let maximumDistance = 4_000

    public let sessionID: UUID
    public let requestID: UUID
    public let screenX: Double
    public let screenY: Double
    public let direction: RollingScrollDirection
    /// 始终为正数；实际滚轮符号由 direction 决定。
    public let distance: Int

    public init?(
        sessionID: UUID,
        requestID: UUID,
        screenX: Double,
        screenY: Double,
        direction: RollingScrollDirection = .down,
        distance: Int
    ) {
        guard screenX.isFinite, screenY.isFinite,
              (1...Self.maximumDistance).contains(distance)
        else { return nil }
        self.sessionID = sessionID
        self.requestID = requestID
        self.screenX = screenX
        self.screenY = screenY
        self.direction = direction
        self.distance = distance
    }

    public init?(userInfo: [AnyHashable: Any]?) {
        guard let userInfo,
              let session = userInfo[PayloadKey.sessionID] as? String,
              let sessionID = UUID(uuidString: session),
              let request = userInfo[PayloadKey.requestID] as? String,
              let requestID = UUID(uuidString: request),
              let screenX = userInfo[PayloadKey.screenX] as? Double,
              let screenY = userInfo[PayloadKey.screenY] as? Double,
              let distance = userInfo[PayloadKey.distance] as? Int
        else { return nil }
        let direction = (userInfo[PayloadKey.direction] as? String)
            .flatMap(RollingScrollDirection.init(rawValue:)) ?? .down
        self.init(
            sessionID: sessionID,
            requestID: requestID,
            screenX: screenX,
            screenY: screenY,
            direction: direction,
            distance: distance
        )
    }

    public var userInfo: [String: Any] {
        [
            PayloadKey.sessionID: sessionID.uuidString,
            PayloadKey.requestID: requestID.uuidString,
            PayloadKey.screenX: screenX,
            PayloadKey.screenY: screenY,
            PayloadKey.direction: direction.rawValue,
            PayloadKey.distance: distance,
        ]
    }

    /// 将一次大幅滚动拆成较小的像素增量，避免部分应用把单个大 delta
    /// 当作高速触控板甩动并产生远超预期的位移。
    public func eventDeltas(maximumMagnitude: Int = 10) -> [Int] {
        guard maximumMagnitude > 0 else { return [] }
        let sign = direction.signedDistanceMultiplier
        var remaining = distance
        var deltas: [Int] = []
        while remaining > 0 {
            let magnitude = min(remaining, maximumMagnitude)
            deltas.append(magnitude * sign)
            remaining -= magnitude
        }
        return deltas
    }
}

public enum RollingScrollResponseReason: String, Equatable, Sendable {
    case completed
    case accessibilityDenied
    case invalidCommand
    case eventCreationFailed
}

public struct RollingScrollResponse: Equatable, Sendable {
    public let sessionID: UUID
    public let requestID: UUID
    public let reason: RollingScrollResponseReason

    public init(sessionID: UUID, requestID: UUID, reason: RollingScrollResponseReason) {
        self.sessionID = sessionID
        self.requestID = requestID
        self.reason = reason
    }

    public init?(userInfo: [AnyHashable: Any]?) {
        guard let userInfo,
              let session = userInfo[PayloadKey.sessionID] as? String,
              let sessionID = UUID(uuidString: session),
              let request = userInfo[PayloadKey.requestID] as? String,
              let requestID = UUID(uuidString: request),
              let rawReason = userInfo[PayloadKey.reason] as? String,
              let reason = RollingScrollResponseReason(rawValue: rawReason)
        else { return nil }
        self.init(sessionID: sessionID, requestID: requestID, reason: reason)
    }

    public var userInfo: [String: Any] {
        [
            PayloadKey.sessionID: sessionID.uuidString,
            PayloadKey.requestID: requestID.uuidString,
            PayloadKey.reason: reason.rawValue,
        ]
    }
}

private enum PayloadKey {
    static let sessionID = "sessionID"
    static let requestID = "requestID"
    static let screenX = "screenX"
    static let screenY = "screenY"
    static let direction = "direction"
    static let distance = "distance"
    static let reason = "reason"
}
