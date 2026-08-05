import Foundation

public enum PathFormatter {
    public static func string(for urls: [URL], format: PathOutputFormat) -> String {
        urls.map { url in
            switch format {
            case .posix:
                url.path
            case .quoted:
                "'\(url.path.replacingOccurrences(of: "'", with: "'\\''"))'"
            case .fileURL:
                url.absoluteString
            }
        }
        .joined(separator: "\n")
    }
}
