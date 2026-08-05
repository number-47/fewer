import Foundation

public struct TemplateManifest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var templates: [TemplateDescriptor]

    public init(schemaVersion: Int = 1, templates: [TemplateDescriptor] = []) {
        self.schemaVersion = schemaVersion
        self.templates = templates
    }
}
