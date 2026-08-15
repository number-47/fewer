public enum RollingScrollDirection: String, Codable, Equatable, Sendable {
    case up
    case down

    public var title: String { self == .up ? "向上" : "向下" }
}
