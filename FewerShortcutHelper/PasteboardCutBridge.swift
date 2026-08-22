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

    func validTransactionPasteboardChangeCount() -> Int? {
        guard let store else { return nil }
        return ((try? store.load(currentPasteboardChangeCount: NSPasteboard.general.changeCount)) ?? nil)?
            .pasteboardChangeCount
    }
}
