import AppKit
import FewerCore

@MainActor
final class GestureHUDController {
    private let panel: NSPanel
    private let pathView = GesturePathView(frame: .zero)
    private var hideGeneration = 0

    init() {
        let frame = NSScreen.screens.first?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = pathView
        pathView.frame = NSRect(origin: .zero, size: frame.size)
        pathView.autoresizingMask = [.width, .height]
    }

    func begin(at point: CGPoint) {
        hideGeneration += 1
        panel.alphaValue = 1
        pathView.points = [point]
        pathView.directions = []
        pathView.needsDisplay = true
        panel.orderFrontRegardless()
    }

    func append(point: CGPoint, directions: [MouseGestureDirection]) {
        pathView.points.append(point)
        pathView.directions = directions
        pathView.needsDisplay = true
    }

    func hide() {
        hideGeneration += 1
        let generation = hideGeneration
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.hideGeneration == generation else { return }
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
                self.pathView.points = []
                self.pathView.directions = []
                self.pathView.needsDisplay = true
            }
        })
    }
}

private final class GesturePathView: NSView {
    override var isFlipped: Bool { true }

    var points: [CGPoint] = []
    var directions: [MouseGestureDirection] = []

    override func draw(_ dirtyRect: NSRect) {
        guard !points.isEmpty else { return }

        if points.count > 1 {
            let path = NSBezierPath()
            path.lineWidth = 6
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            for (index, point) in points.enumerated() {
                index == 0 ? path.move(to: point) : path.line(to: point)
            }
            NSColor.systemBlue.withAlphaComponent(0.9).setStroke()
            path.stroke()
        }

        let symbols = directions.map(\.symbol).joined(separator: " ")
        guard !symbols.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 28, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let size = symbols.size(withAttributes: attributes)
        let backgroundRect = NSRect(
            x: bounds.midX - size.width / 2 - 14,
            y: 20,
            width: size.width + 28,
            height: size.height + 18
        )
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: backgroundRect, xRadius: 10, yRadius: 10).fill()
        symbols.draw(
            at: NSPoint(x: bounds.midX - size.width / 2, y: 29),
            withAttributes: attributes
        )
    }
}

private extension MouseGestureDirection {
    var symbol: String {
        switch self {
        case .up: "↑"
        case .down: "↓"
        case .left: "←"
        case .right: "→"
        case .upRight: "↗"
        case .downRight: "↘"
        case .upLeft: "↖"
        case .downLeft: "↙"
        }
    }
}
