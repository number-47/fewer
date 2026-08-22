import AppKit
import FewerCore

let syntheticInputEventMarker: Int64 = 0x4645574552

enum InputActionExecutor {
    static func execute(_ action: InputAction) {
        switch action {
        case let .shortcut(shortcut):
            postShortcut(keyCode: CGKeyCode(shortcut.keyCode), modifiers: shortcut.modifiers)
        case .mouseBack:
            postMouseButton(3)
        case .mouseForward:
            postMouseButton(4)
        case .missionControl:
            postShortcut(keyCode: 126, flags: .maskControl)
        case .showDesktop:
            postShortcut(keyCode: 103, flags: [])
        case .spaceLeft:
            postShortcut(keyCode: 123, flags: .maskControl)
        case .spaceRight:
            postShortcut(keyCode: 124, flags: .maskControl)
        case .closeTab:
            postShortcut(keyCode: 13, flags: .maskCommand)
        case .newTab:
            postShortcut(keyCode: 17, flags: .maskCommand)
        case .reload:
            postShortcut(keyCode: 15, flags: .maskCommand)
        case .scrollToTop:
            postShortcut(keyCode: 126, flags: .maskCommand)
        case .scrollToBottom:
            postShortcut(keyCode: 125, flags: .maskCommand)
        case .minimizeWindow:
            postShortcut(keyCode: 46, flags: .maskCommand)
        case .zoomWindow:
            postShortcut(keyCode: 3, flags: [.maskControl, .maskCommand])
        case let .moduleCommand(moduleID, commandID):
            ModuleCommandIPC.post(moduleID: moduleID, commandID: commandID)
        }
    }

    static func postShortcut(keyCode: CGKeyCode, modifiers: ShortcutModifiers) {
        var flags: CGEventFlags = []
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        postShortcut(keyCode: keyCode, flags: flags)
    }

    static func postShortcut(keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        for isKeyDown in [true, false] {
            guard let event = CGEvent(
                keyboardEventSource: source,
                virtualKey: keyCode,
                keyDown: isKeyDown
            ) else { continue }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: syntheticInputEventMarker)
            event.post(tap: .cghidEventTap)
        }
    }

    static func postMouseClick(button: CGMouseButton, at location: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        let types: (CGEventType, CGEventType) = switch button {
        case .left: (.leftMouseDown, .leftMouseUp)
        case .right: (.rightMouseDown, .rightMouseUp)
        default: (.otherMouseDown, .otherMouseUp)
        }
        guard let downEvent = CGEvent(
            mouseEventSource: source,
            mouseType: types.0,
            mouseCursorPosition: location,
            mouseButton: button
        ) else { return }
        downEvent.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button.rawValue))
        downEvent.setIntegerValueField(.eventSourceUserData, value: syntheticInputEventMarker)
        downEvent.post(tap: .cghidEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard let upEvent = CGEvent(
                mouseEventSource: source,
                mouseType: types.1,
                mouseCursorPosition: location,
                mouseButton: button
            ) else { return }
            upEvent.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button.rawValue))
            upEvent.setIntegerValueField(.eventSourceUserData, value: syntheticInputEventMarker)
            upEvent.post(tap: .cghidEventTap)
        }
    }

    private static func postMouseButton(_ rawValue: UInt32) {
        guard let button = CGMouseButton(rawValue: rawValue) else { return }
        let location = CGEvent(source: nil)?.location ?? .zero
        postMouseClick(button: button, at: location)
    }
}
