import Foundation

public actor FileOperationCoordinator {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func move(
        _ sourceURLs: [URL],
        to targetDirectory: URL,
        policy: ConflictPolicy,
        replaceFailureInjector: ReplaceFailureInjector = .none
    ) -> FileOperationBatchResult {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: targetDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return FileOperationBatchResult(items: sourceURLs.map {
                FileOperationItemResult(sourceURL: $0, destinationURL: nil, status: .failed, error: .targetNotDirectory)
            })
        }

        return FileOperationBatchResult(items: sourceURLs.map { sourceURL in
            moveOne(sourceURL, to: targetDirectory, policy: policy, failureInjector: replaceFailureInjector)
        })
    }

    private func moveOne(
        _ sourceURL: URL,
        to targetDirectory: URL,
        policy: ConflictPolicy,
        failureInjector: ReplaceFailureInjector
    ) -> FileOperationItemResult {
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            return FileOperationItemResult(sourceURL: sourceURL, destinationURL: nil, status: .failed, error: .sourceMissing)
        }

        let source = sourceURL.standardizedFileURL
        let target = targetDirectory.standardizedFileURL
        let directDestination = target.appendingPathComponent(source.lastPathComponent)

        if source == directDestination.standardizedFileURL {
            return FileOperationItemResult(sourceURL: sourceURL, destinationURL: directDestination, status: .skipped, error: .sameLocation)
        }

        var sourceIsDirectory: ObjCBool = false
        _ = fileManager.fileExists(atPath: source.path, isDirectory: &sourceIsDirectory)
        if sourceIsDirectory.boolValue {
            let sourcePrefix = source.path.hasSuffix("/") ? source.path : source.path + "/"
            if target.path.hasPrefix(sourcePrefix) {
                return FileOperationItemResult(sourceURL: sourceURL, destinationURL: nil, status: .failed, error: .destinationInsideSource)
            }
        }

        var destination = directDestination
        if fileManager.fileExists(atPath: destination.path) {
            switch policy {
            case .keepBoth:
                destination = ConflictNameResolver.availableURL(
                    named: source.lastPathComponent,
                    in: target,
                    exists: { self.fileManager.fileExists(atPath: $0.path) }
                )
            case .skip:
                return FileOperationItemResult(sourceURL: sourceURL, destinationURL: destination, status: .skipped)
            case .replace:
                let outcome = RecoverableReplace.perform(
                    source: source,
                    destination: destination,
                    fileManager: fileManager,
                    sourceCoordination: .moving,
                    install: { fm, resolvedSource, resolvedDestination in
                        try fm.moveItem(at: resolvedSource, to: resolvedDestination)
                    },
                    failureInjector: failureInjector
                )
                switch outcome {
                case .success:
                    return FileOperationItemResult(sourceURL: sourceURL, destinationURL: destination, status: .moved)
                case .installFailed:
                    return FileOperationItemResult(sourceURL: sourceURL, destinationURL: destination, status: .failed, error: .systemError)
                case .notRecoverable:
                    return FileOperationItemResult(sourceURL: sourceURL, destinationURL: destination, status: .failed, error: .replacementNotRecoverable)
                }
            }
        }

        do {
            try fileManager.moveItem(at: source, to: destination)
            return FileOperationItemResult(sourceURL: sourceURL, destinationURL: destination, status: .moved)
        } catch {
            return FileOperationItemResult(sourceURL: sourceURL, destinationURL: destination, status: .failed, error: .systemError)
        }
    }
}
