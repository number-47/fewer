import Foundation

public struct TemplateFileCreator {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func create(
        from templateURL: URL,
        descriptor: TemplateDescriptor,
        in directory: URL,
        policy: ConflictPolicy
    ) throws -> URL? {
        let defaultName = "新建 \(descriptor.displayName).\(descriptor.fileExtension)"
        var destination = directory.appendingPathComponent(defaultName)

        if fileManager.fileExists(atPath: destination.path) {
            switch policy {
            case .keepBoth:
                destination = ConflictNameResolver.availableURL(
                    named: defaultName,
                    in: directory,
                    exists: { fileManager.fileExists(atPath: $0.path) }
                )
            case .skip:
                return nil
            case .replace:
                var trashedURL: NSURL?
                try fileManager.trashItem(at: destination, resultingItemURL: &trashedURL)
            }
        }

        try fileManager.copyItem(at: templateURL, to: destination)
        return destination
    }
}
