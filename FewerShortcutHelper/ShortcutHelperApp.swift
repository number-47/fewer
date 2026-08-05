import AppKit

@main
enum ShortcutHelperApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = ShortcutHelperDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.prohibited)
        application.run()
        _ = delegate
    }
}

final class ShortcutHelperDelegate: NSObject, NSApplicationDelegate {
    private var eventTapController: EventTapController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        eventTapController = EventTapController()
        eventTapController?.start()
    }
}
