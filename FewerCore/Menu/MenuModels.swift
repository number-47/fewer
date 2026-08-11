import Foundation

public enum MenuCommand: Equatable, Sendable {
    case newFile
    case createFromTemplate(UUID)
    case copyPath
    case cut
    case pasteHere
    case pasteIntoFolder
    case openInTerminal
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
