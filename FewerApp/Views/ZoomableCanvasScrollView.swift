import AppKit
import SwiftUI

/// 编辑画布的缩放状态。画布布局始终保持 1:1，缩放完全由 NSScrollView 的
/// clip transform 承担，因此标注坐标、命中测试、Vision 元素框与行内文字
/// 编辑都不受影响。
@MainActor
final class MarkupZoomModel: ObservableObject {
    static let minimumMagnification: CGFloat = 0.05
    static let maximumMagnification: CGFloat = 4.0

    @Published private(set) var magnification: CGFloat = 1.0
    @Published private(set) var viewportSize: CGSize = .zero

    /// 由缩放容器设置；按钮/快捷键修改 magnification 时回调，把变化应用到 NSScrollView。
    var onMagnificationChange: ((CGFloat) -> Void)?

    var percentageLabel: String {
        "\(Int((magnification * 100).rounded()))%"
    }

    /// 视图侧（捏合、⌘+滚轮、窗口尺寸变化）向模型同步，不触发回环。
    func setFromView(_ value: CGFloat, viewportSize: CGSize) {
        if viewportSize != self.viewportSize {
            self.viewportSize = viewportSize
        }
        setMagnification(value)
    }

    func zoomIn() {
        setMagnification(magnification * 1.25)
    }

    func zoomOut() {
        setMagnification(magnification / 1.25)
    }

    func zoomToActual() {
        setMagnification(1.0)
    }

    /// 适应窗口：整张画布装入视口；不放大超过 100%。
    func zoomToFit(documentSize: CGSize) {
        guard documentSize.width > 0, documentSize.height > 0,
              viewportSize.width > 0, viewportSize.height > 0
        else { return }
        let fit = min(
            viewportSize.width / documentSize.width,
            viewportSize.height / documentSize.height
        )
        setMagnification(min(fit, 1.0))
    }

    private func setMagnification(_ value: CGFloat) {
        let clamped = min(max(value, Self.minimumMagnification), Self.maximumMagnification)
        guard abs(clamped - magnification) > 0.0001 else { return }
        magnification = clamped
        onMagnificationChange?(clamped)
    }
}

/// 支持触控板捏合、⌘+滚轮与程序化缩放的画布容器。缩放以光标为锚点，
/// 缩放范围 5%–400%。
struct ZoomableCanvasScrollView<Content: View>: NSViewRepresentable {
    let model: MarkupZoomModel
    let content: () -> Content

    init(model: MarkupZoomModel, @ViewBuilder content: @escaping () -> Content) {
        self.model = model
        self.content = content
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> MagnifyingScrollView {
        let scrollView = MagnifyingScrollView()
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .underPageBackgroundColor
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = MarkupZoomModel.minimumMagnification
        scrollView.maxMagnification = MarkupZoomModel.maximumMagnification
        scrollView.zoomModel = model

        let hosting = NSHostingView(rootView: content())
        scrollView.documentView = hosting
        context.coordinator.attach(to: scrollView, hostingView: hosting)
        return scrollView
    }

    func updateNSView(_ scrollView: MagnifyingScrollView, context: Context) {
        context.coordinator.hostingView?.rootView = content()
        context.coordinator.layoutDocument(in: scrollView)
    }

    static func dismantleNSView(_ nsView: MagnifyingScrollView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject {
        let model: MarkupZoomModel
        weak var hostingView: NSHostingView<Content>?
        private weak var scrollView: MagnifyingScrollView?
        private var observers: [NSObjectProtocol] = []

        init(model: MarkupZoomModel) {
            self.model = model
        }

        func attach(to scrollView: MagnifyingScrollView, hostingView: NSHostingView<Content>) {
            self.scrollView = scrollView
            self.hostingView = hostingView

            let center = NotificationCenter.default
            let liveNames = [
                NSScrollView.didLiveScrollNotification,
                NSScrollView.didEndLiveMagnifyNotification,
            ]
            for name in liveNames {
                let observer = center.addObserver(
                    forName: name,
                    object: scrollView,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.syncFromView()
                    }
                }
                observers.append(observer)
            }
            let clipObserver = center.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.syncFromView()
                }
            }
            observers.append(clipObserver)

            model.onMagnificationChange = { [weak self] value in
                guard let scrollView = self?.scrollView else { return }
                let viewport = scrollView.contentView.bounds
                let center = CGPoint(x: viewport.midX, y: viewport.midY)
                scrollView.setMagnification(value, centeredAt: center)
            }

            layoutDocument(in: scrollView)
            syncFromView()
        }

        func layoutDocument(in scrollView: MagnifyingScrollView) {
            guard let hosting = hostingView else { return }
            hosting.layoutSubtreeIfNeeded()
            let size = hosting.fittingSize
            hosting.frame = NSRect(
                origin: .zero,
                size: NSSize(width: max(size.width, 1), height: max(size.height, 1))
            )
            syncFromView()
        }

        private func syncFromView() {
            guard let scrollView else { return }
            model.setFromView(
                scrollView.magnification,
                viewportSize: scrollView.contentView.bounds.size
            )
        }

        func detach() {
            model.onMagnificationChange = nil
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
            observers.removeAll()
        }
    }
}

/// ⌘+滚轮缩放：滚动方向与内容移动方向一致（手指/滚轮向上为放大）。
final class MagnifyingScrollView: NSScrollView {
    weak var zoomModel: MarkupZoomModel?

    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command), event.scrollingDeltaY != 0 else {
            super.scrollWheel(with: event)
            return
        }
        let location = contentView.convert(event.locationInWindow, from: nil)
        let factor = CGFloat(pow(1.1, -Double(event.scrollingDeltaY) / 10))
        let next = min(max(magnification * factor, minMagnification), maxMagnification)
        setMagnification(next, centeredAt: location)
        zoomModel?.setFromView(next, viewportSize: contentView.bounds.size)
    }
}
