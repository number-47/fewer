import AppKit
import FewerCore

final class PasteboardCutBridge: @unchecked Sendable {
    private let store: CutTransactionStore?

    init() {
        store = try? CutTransactionStore()
    }

    func captureFinderCopy() {
        let pasteboard = NSPasteboard.general
        let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]
        guard let urls = objects, !urls.isEmpty else { return }
        _ = try? store?.start(urls: urls, pasteboardChangeCount: pasteboard.changeCount)
    }

    func hasValidTransaction() -> Bool {
        guard let store else { return false }
        return ((try? store.load(currentPasteboardChangeCount: NSPasteboard.general.changeCount)) ?? nil) != nil
    }
}
