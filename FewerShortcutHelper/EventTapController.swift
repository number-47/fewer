import AppKit
import ApplicationServices
import FewerCore

private let syntheticEventMarker: Int64 = 0x4645574552

final class EventTapController: @unchecked Sendable {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let bridge = PasteboardCutBridge()
    private let settingsStore = try? SharedSettingsStore()

    func start() {
        guard AXIsProcessTrusted() else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: eventTapCallback,
            userInfo: pointer
        )
        guard let eventTap else { return }
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    fileprivate func process(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        if event.getIntegerValueField(.eventSourceUserData) == syntheticEventMarker {
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let key: ShortcutKey = switch keyCode {
        case 7: .x
        case 9: .v
        default: .other
        }
        let flags = event.flags
        var modifiers: ShortcutModifiers = []
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        if flags.contains(.maskControl) { modifiers.insert(.control) }

        let decision = FinderShortcutRouter.decision(
            frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            isEnabled: settingsStore?.load().settings.shortcutHelperEnabled ?? false,
            isAccessibilityTrusted: AXIsProcessTrusted(),
            key: key,
            modifiers: modifiers,
            hasValidCutTransaction: bridge.hasValidTransaction()
        )

        switch decision {
        case .passThrough:
            return Unmanaged.passUnretained(event)
        case .captureCut:
            postShortcut(keyCode: 8, flags: .maskCommand)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [bridge] in
                bridge.captureFinderCopy()
            }
            return nil
        case .performFinderMovePaste:
            postShortcut(keyCode: 9, flags: [.maskCommand, .maskAlternate])
            return nil
        }
    }

    private func postShortcut(keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        for isKeyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: isKeyDown) else { continue }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
            event.post(tap: .cghidEventTap)
        }
    }
}

private let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard type == .keyDown, let userInfo else {
        return Unmanaged.passUnretained(event)
    }
    return Unmanaged<EventTapController>.fromOpaque(userInfo).takeUnretainedValue().process(event)
}
