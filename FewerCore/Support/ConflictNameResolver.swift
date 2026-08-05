import Foundation

public enum ConflictNameResolver {
    private static let compoundExtensions = ["tar.gz", "tar.bz2", "tar.xz"]

    public static func numberedName(for name: String, number: Int) -> String {
        let lowercaseName = name.lowercased()
        if let compoundExtension = compoundExtensions.first(where: {
            lowercaseName.hasSuffix(".\($0)")
        }) {
            let suffixLength = compoundExtension.count + 1
            let stem = String(name.dropLast(suffixLength))
            let suffix = String(name.suffix(suffixLength))
            return "\(stem) \(number)\(suffix)"
        }

        if name.hasPrefix(".") && !name.dropFirst().contains(".") {
            return "\(name) \(number)"
        }

        let pathExtension = (name as NSString).pathExtension
        guard !pathExtension.isEmpty else {
            return "\(name) \(number)"
        }

        let stem = (name as NSString).deletingPathExtension
        return "\(stem) \(number).\(pathExtension)"
    }

    public static func availableURL(
        named name: String,
        in directory: URL,
        exists: (URL) -> Bool
    ) -> URL {
        let proposedURL = directory.appendingPathComponent(name)
        guard exists(proposedURL) else { return proposedURL }

        var number = 2
        while true {
            let candidate = directory.appendingPathComponent(numberedName(for: name, number: number))
            if !exists(candidate) {
                return candidate
            }
            number += 1
        }
    }
}
