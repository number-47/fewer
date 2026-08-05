import Foundation

public enum TemplateSource: String, Codable, Sendable {
    case builtIn
    case user
}

public struct TemplateDescriptor: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var displayName: String
    public var fileExtension: String
    public var resourceName: String
    public var source: TemplateSource
    public var isEnabled: Bool
    public var order: Int

    public init(
        id: UUID,
        displayName: String,
        fileExtension: String,
        resourceName: String,
        source: TemplateSource,
        isEnabled: Bool = true,
        order: Int = 0
    ) {
        self.id = id
        self.displayName = displayName
        self.fileExtension = fileExtension
        self.resourceName = resourceName
        self.source = source
        self.isEnabled = isEnabled
        self.order = order
    }

    public static let builtInPlainText = TemplateDescriptor(
        id: UUID(uuidString: "A31B9B91-9713-4C36-89DE-AB2B121CE001")!,
        displayName: "文本文档",
        fileExtension: "txt",
        resourceName: "PlainText",
        source: .builtIn
    )

    public static let builtInMarkdown = TemplateDescriptor(
        id: UUID(uuidString: "A31B9B91-9713-4C36-89DE-AB2B121CE002")!,
        displayName: "Markdown 文档",
        fileExtension: "md",
        resourceName: "Markdown",
        source: .builtIn,
        order: 1
    )

    public static let builtInWord = TemplateDescriptor(
        id: UUID(uuidString: "A31B9B91-9713-4C36-89DE-AB2B121CE003")!,
        displayName: "Word 文档",
        fileExtension: "docx",
        resourceName: "WordDocument",
        source: .builtIn,
        order: 2
    )

    public static let builtInExcel = TemplateDescriptor(
        id: UUID(uuidString: "A31B9B91-9713-4C36-89DE-AB2B121CE004")!,
        displayName: "Excel 工作簿",
        fileExtension: "xlsx",
        resourceName: "ExcelWorkbook",
        source: .builtIn,
        order: 3
    )

    public static let builtInPowerPoint = TemplateDescriptor(
        id: UUID(uuidString: "A31B9B91-9713-4C36-89DE-AB2B121CE005")!,
        displayName: "PowerPoint 演示文稿",
        fileExtension: "pptx",
        resourceName: "PowerPointPresentation",
        source: .builtIn,
        order: 4
    )

    public static let builtInJSON = TemplateDescriptor(
        id: UUID(uuidString: "A31B9B91-9713-4C36-89DE-AB2B121CE006")!,
        displayName: "JSON 文件",
        fileExtension: "json",
        resourceName: "JSON",
        source: .builtIn,
        order: 5
    )

    public static let builtInCSV = TemplateDescriptor(
        id: UUID(uuidString: "A31B9B91-9713-4C36-89DE-AB2B121CE007")!,
        displayName: "CSV 文件",
        fileExtension: "csv",
        resourceName: "CSV",
        source: .builtIn,
        order: 6
    )

    public static let builtIns: [TemplateDescriptor] = [
        .builtInPlainText,
        .builtInMarkdown,
        .builtInWord,
        .builtInExcel,
        .builtInPowerPoint,
        .builtInJSON,
        .builtInCSV,
    ]
}
