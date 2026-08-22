import AppKit
import FewerCore

@MainActor
final class KeycastPanelController {
    var visibilityChanged: ((Bool) -> Void)?
    var customPositionChanged: ((KeycastNormalizedPosition) -> Void)?
    private struct DisplayEntry {
        var text: String
        var count: Int
        var expiresAt: Date
    }

    private let panel: NSPanel
    private let stackView = DraggableStackView()
    private var entries: [DisplayEntry] = []
    private var expirationTimer: Timer?
    private var positioningTimer: Timer?
    private var isPositioning = false
    private(set) var temporaryAllKeys = false

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 80, y: 80, width: 360, height: 180),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        stackView.orientation = .vertical
        stackView.alignment = .centerX
        stackView.spacing = 5
        stackView.edgeInsets = NSEdgeInsets(top: 14, left: 18, bottom: 14, right: 18)
        stackView.wantsLayer = true
        stackView.layer?.cornerRadius = 16
        stackView.onMove = { [weak self] in self?.persistCustomPosition() }
        panel.contentView = stackView
    }

    func show(text: String, settings: KeycastSettings) {
        let expiration = Date().addingTimeInterval(settings.displayDuration)
        if entries.last?.text == text {
            entries[entries.count - 1].count += 1
            entries[entries.count - 1].expiresAt = expiration
        } else {
            entries.append(DisplayEntry(text: text, count: 1, expiresAt: expiration))
        }
        entries = Array(entries.suffix(settings.maximumVisibleEvents))
        render(settings: settings)
        scheduleExpiration(settings: settings)
    }

    func setTemporaryAllKeys(_ enabled: Bool) {
        temporaryAllKeys = enabled
    }

    func setPositioning(_ enabled: Bool, settings: KeycastSettings) {
        isPositioning = enabled
        panel.ignoresMouseEvents = !enabled
        if enabled {
            show(text: "拖动此浮层调整位置", settings: settings)
            positioningTimer?.invalidate()
            positioningTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.clear() }
            }
        } else {
            clear()
        }
    }

    func clear(resetTemporaryMode: Bool = false) {
        expirationTimer?.invalidate()
        expirationTimer = nil
        positioningTimer?.invalidate()
        positioningTimer = nil
        entries = []
        panel.orderOut(nil)
        visibilityChanged?(false)
        panel.ignoresMouseEvents = true
        isPositioning = false
        if resetTemporaryMode { temporaryAllKeys = false }
    }

    private func render(settings: KeycastSettings) {
        stackView.arrangedSubviews.forEach { view in
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        stackView.layer?.backgroundColor = NSColor.black
            .withAlphaComponent(settings.opacity)
            .cgColor
        for entry in entries {
            let label = NSTextField(labelWithString: entry.count > 1 ? "\(entry.text) ×\(entry.count)" : entry.text)
            label.textColor = .white
            label.font = .systemFont(ofSize: settings.fontSize, weight: .medium)
            label.alignment = .center
            stackView.addArrangedSubview(label)
        }
        stackView.layoutSubtreeIfNeeded()
        let fitting = stackView.fittingSize
        panel.setContentSize(NSSize(width: max(220, fitting.width), height: max(70, fitting.height)))
        place(on: screenUnderMouse(), settings: settings)
        panel.orderFrontRegardless()
        visibilityChanged?(true)
    }

    private func scheduleExpiration(settings: KeycastSettings) {
        guard !isPositioning else { return }
        expirationTimer?.invalidate()
        expirationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.entries.removeAll { $0.expiresAt <= Date() }
                if self.entries.isEmpty {
                    self.clear()
                } else {
                    self.render(settings: settings)
                }
            }
        }
    }

    private func screenUnderMouse() -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
    }

    private func place(on screen: NSScreen?, settings: KeycastSettings) {
        guard let screen else { return }
        let visible = screen.visibleFrame
        let normalized = settings.position.normalizedPoint
            ?? settings.customPosition
            ?? KeycastOverlayPosition.bottom.normalizedPoint!
        let width = min(panel.frame.width, visible.width)
        let height = min(panel.frame.height, visible.height)
        let origin = NSPoint(
            x: visible.minX + (visible.width - width) * normalized.x,
            y: visible.minY + (visible.height - height) * normalized.y
        )
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: false)
    }

    private func persistCustomPosition() {
        guard let screen = screenUnderMouse() else { return }
        let visible = screen.visibleFrame
        let width = min(panel.frame.width, visible.width)
        let height = min(panel.frame.height, visible.height)
        let maxX = max(visible.width - width, 0)
        let maxY = max(visible.height - height, 0)
        let origin = NSPoint(
            x: min(max(panel.frame.minX, visible.minX), visible.maxX - width),
            y: min(max(panel.frame.minY, visible.minY), visible.maxY - height)
        )
        panel.setFrameOrigin(origin)
        customPositionChanged?(KeycastNormalizedPosition(
            x: maxX > 0 ? (origin.x - visible.minX) / maxX : 0.5,
            y: maxY > 0 ? (origin.y - visible.minY) / maxY : 0.5
        ))
    }
}

private final class DraggableStackView: NSStackView {
    var onMove: (() -> Void)?
    private var dragStart: NSPoint?
    private var windowStart: NSPoint?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        dragStart = NSEvent.mouseLocation
        windowStart = window?.frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart, let windowStart else { return }
        let current = NSEvent.mouseLocation
        window?.setFrameOrigin(NSPoint(
            x: windowStart.x + current.x - dragStart.x,
            y: windowStart.y + current.y - dragStart.y
        ))
        onMove?()
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
        windowStart = nil
    }
}
