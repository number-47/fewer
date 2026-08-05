import Foundation

public final class TemplateStore: @unchecked Sendable {
    private let builtInDirectory: URL
    private let userDirectory: URL
    private let manifestURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        builtInDirectory: URL,
        userDirectory: URL,
        fileManager: FileManager = .default
    ) {
        self.builtInDirectory = builtInDirectory
        self.userDirectory = userDirectory
        self.manifestURL = userDirectory.appendingPathComponent("manifest.json")
        self.fileManager = fileManager
    }

    public convenience init(builtInDirectory: URL) throws {
        self.init(
            builtInDirectory: builtInDirectory,
            userDirectory: AppGroupConstants.sharedDataDirectory()
                .appendingPathComponent("Templates", isDirectory: true)
        )
    }

    public func templates() throws -> [TemplateDescriptor] {
        lock.lock()
        defer { lock.unlock() }

        let availableBuiltIns = TemplateDescriptor.builtIns.filter {
            fileManager.fileExists(atPath: builtInURL(for: $0).path)
        }
        return (availableBuiltIns + (try readManifest()).templates)
            .sorted { ($0.order, $0.displayName) < ($1.order, $1.displayName) }
    }

    @discardableResult
    public func importTemplate(from sourceURL: URL, displayName: String) throws -> TemplateDescriptor {
        lock.lock()
        defer { lock.unlock() }

        try fileManager.createDirectory(at: userDirectory, withIntermediateDirectories: true)
        var manifest = try readManifest()
        let fileExtension = sourceURL.pathExtension
        let descriptor = TemplateDescriptor(
            id: UUID(),
            displayName: displayName,
            fileExtension: fileExtension,
            resourceName: "",
            source: .user,
            order: manifest.templates.count
        )
        try fileManager.copyItem(at: sourceURL, to: userURL(for: descriptor))
        manifest.templates.append(descriptor)
        try writeManifest(manifest)
        return descriptor
    }

    public func update(_ descriptor: TemplateDescriptor) throws {
        lock.lock()
        defer { lock.unlock() }

        guard descriptor.source == .user else { throw TemplateStoreError.builtInIsReadOnly }
        var manifest = try readManifest()
        guard let index = manifest.templates.firstIndex(where: { $0.id == descriptor.id }) else {
            throw TemplateStoreError.templateNotFound
        }
        manifest.templates[index] = descriptor
        try writeManifest(manifest)
    }

    public func delete(_ descriptor: TemplateDescriptor) throws {
        lock.lock()
        defer { lock.unlock() }

        guard descriptor.source == .user else { throw TemplateStoreError.builtInIsReadOnly }
        var manifest = try readManifest()
        guard let index = manifest.templates.firstIndex(where: { $0.id == descriptor.id }) else {
            throw TemplateStoreError.templateNotFound
        }
        let fileURL = userURL(for: manifest.templates[index])
        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }
        manifest.templates.remove(at: index)
        try writeManifest(manifest)
    }

    public func fileURL(for descriptor: TemplateDescriptor) throws -> URL {
        switch descriptor.source {
        case .builtIn:
            let url = builtInURL(for: descriptor)
            guard fileManager.fileExists(atPath: url.path) else { throw TemplateStoreError.templateNotFound }
            return url
        case .user:
            let url = userURL(for: descriptor)
            guard fileManager.fileExists(atPath: url.path) else { throw TemplateStoreError.templateNotFound }
            return url
        }
    }

    private func readManifest() throws -> TemplateManifest {
        guard fileManager.fileExists(atPath: manifestURL.path) else { return TemplateManifest() }
        do {
            return try decoder.decode(TemplateManifest.self, from: Data(contentsOf: manifestURL))
        } catch {
            throw TemplateStoreError.manifestCorrupt
        }
    }

    private func writeManifest(_ manifest: TemplateManifest) throws {
        try fileManager.createDirectory(at: userDirectory, withIntermediateDirectories: true)
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
    }

    private func builtInURL(for descriptor: TemplateDescriptor) -> URL {
        builtInDirectory.appendingPathComponent(descriptor.resourceName)
            .appendingPathExtension(descriptor.fileExtension)
    }

    private func userURL(for descriptor: TemplateDescriptor) -> URL {
        userDirectory.appendingPathComponent(descriptor.id.uuidString)
            .appendingPathExtension(descriptor.fileExtension)
    }
}

public enum TemplateStoreError: Error, Equatable {
    case appGroupUnavailable
    case builtInIsReadOnly
    case templateNotFound
    case manifestCorrupt
}
