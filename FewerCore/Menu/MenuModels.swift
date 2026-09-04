import Foundation

public enum MenuCommand: Equatable, Sendable {
    case newFile
    case newFolder
    case createFromTemplate(UUID)
    case copyPath
    case copyAs(FinderCopyFormat)
    case batchRename
    case cut
    case pasteHere
    case pasteIntoFolder
    case openInTerminal
    case openWith(bundleIdentifier: String)
    case refresh
}

public enum FinderCopyFormat: String, Codable, CaseIterable, Sendable {
    case name
    case absolutePath
    case relativePath
    case shellEscapedPath
    case fileURL

    /// 菜单显示标题。MenuBuilder 构建菜单、FinderSync 解析 action 共用此属性,
    /// 避免标题在两处硬编码导致漂移。
    public var menuTitle: String {
        switch self {
        case .name: "文件名"
        case .absolutePath: "绝对路径"
        case .relativePath: "相对路径"
        case .shellEscapedPath: "Shell 转义路径"
        case .fileURL: "file:// URL"
        }
    }

    /// 从菜单标题反解格式。Finder Sync 的 NSMenuItem 跨 XPC 传递时,
    /// representedObject 不会被序列化,只能依赖 title 做映射。
    public init?(menuTitle: String) {
        guard let match = FinderCopyFormat.allCases.first(where: { $0.menuTitle == menuTitle }) else {
            return nil
        }
        self = match
    }
}

public struct MenuEntry: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let command: MenuCommand
    public let title: String
    public let isEnabled: Bool
    public let children: [MenuEntry]

    public init(
        id: UUID = UUID(),
        command: MenuCommand,
        title: String,
        isEnabled: Bool = true,
        children: [MenuEntry] = []
    ) {
        self.id = id
        self.command = command
        self.title = title
        self.isEnabled = isEnabled
        self.children = children
    }
}
