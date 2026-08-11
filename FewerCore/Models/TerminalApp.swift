import Foundation

/// 内置支持"在终端打开"的常见终端应用。
/// 仅收录确认支持 `open -a <App> <目录>` 语义（在目标目录打开新窗口/标签）的应用；
/// 其他终端可在设置中选择"自定义…"并填写 Bundle Identifier。
public struct CommonTerminal: Identifiable, Equatable, Sendable {
    public let name: String
    public let bundleIdentifier: String

    public var id: String { bundleIdentifier }

    public init(name: String, bundleIdentifier: String) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
    }

    /// 内置终端目录。
    public static let all: [CommonTerminal] = [
        CommonTerminal(name: "Terminal", bundleIdentifier: "com.apple.Terminal"),
        CommonTerminal(name: "iTerm2", bundleIdentifier: "com.googlecode.iterm2"),
    ]

    /// 按 Bundle Identifier 查找内置终端；非内置（自定义）返回 nil。
    public static func commonTerminal(matchingBundleID bundleIdentifier: String) -> CommonTerminal? {
        all.first { $0.bundleIdentifier == bundleIdentifier }
    }
}
