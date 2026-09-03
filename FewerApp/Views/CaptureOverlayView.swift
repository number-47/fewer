import AppKit
import FewerCore
import SwiftUI

/// 遮罩交互回调（主线程）。
@MainActor
protocol CaptureOverlayDelegate: AnyObject {
    func overlayDidStartRollingCapture(_ cgRect: CGRect)
    func overlayDidSelectOCRRegion(_ cgRect: CGRect)
    func overlayDidFinishEditing()
    func overlayDidPin(_ pngData: Data)
    func overlayDidCancel()
}

/// 全屏截屏遮罩：区域拖拽 / 窗口高亮点击 + 工具条。
struct CaptureOverlayView: View {
    let intent: ScreenshotCaptureIntent
    let rollingCaptureEnabled: Bool
    /// 所在屏幕的 AppKit frame。
    let screenFrame: NSRect
    weak var delegate: CaptureOverlayDelegate?

    /// 用户完成的选区（当前遮罩窗口的局部坐标，原点左上）。
    @State private var selection: CGRect?
    /// 实际捕获使用的全局屏幕坐标（原点左上）。
    @State private var captureRect: CGRect?
    @State private var editorSource: MarkupImageSource?
    @State private var isPreparing = false
    @State private var captureError: String?
    @State private var hasMarkup = false
    @State private var isAdjustingSelection = false
    @State private var isDraggingSelection = false
    @State private var captureWindowID: CGWindowID?

    private var mode: ScreenshotMode { intent.mode }
    private var isOCRSelection: Bool { intent.purpose == .ocrTranslation }

    private var hint: String {
        if isOCRSelection { return "拖拽选择文字区域，Esc 取消" }
        return switch mode {
        case .region: "拖拽选择截屏区域，Esc 取消"
        case .smart: "单击窗口或拖拽选择区域，Esc 取消"
        case .window: "移动鼠标选择窗口，点击截取，Esc 取消"
        case .fullscreen: ""
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            MouseCaptureLayer(
                mode: mode,
                screenFrame: screenFrame,
                selection: captureRect,
                allowsSelectionAdjustment: !isOCRSelection && isAdjustingSelection && !hasMarkup,
                isEnabled: (editorSource == nil || isAdjustingSelection) && !isPreparing && captureError == nil,
                onSelectionUpdate: { cgRect in
                    captureRect = cgRect
                    selection = cgRect.map(localRect(fromCG:))
                },
                onSelectionEnd: { cgRect in
                    captureRect = cgRect
                    selection = localRect(fromCG: cgRect)
                    if isOCRSelection {
                        delegate?.overlayDidSelectOCRRegion(cgRect)
                        return
                    }
                    isAdjustingSelection = true
                    prepareRegion(cgRect)
                },
                onSelectionAdjustmentChange: { isDraggingSelection = $0 },
                onWindowClick: { prepareWindow($0) },
                onCancel: { delegate?.overlayDidCancel() }
            )

            SelectionMask(cutout: selection)
                .fill(.black.opacity(0.28), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)

            if let selection, editorSource == nil {
                Rectangle()
                    .stroke(.white, lineWidth: 1)
                    .frame(width: selection.width, height: selection.height)
                    .position(x: selection.midX, y: selection.midY)
                    .allowsHitTesting(false)
            }

            if !hint.isEmpty, selection == nil {
                Text(hint)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(.top, 24)
                    .allowsHitTesting(false)
            }

            if isPreparing {
                ProgressView("正在准备截图…")
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
                    .position(toolbarPosition)
            } else if let captureError {
                HStack(spacing: 10) {
                    Text(captureError).foregroundStyle(.red)
                    Button("重试") { retryCapture() }
                    Button("取消", role: .cancel) { delegate?.overlayDidCancel() }
                }
                .font(.caption)
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
                .position(toolbarPosition)
            } else if let editorSource, let selection {
                MarkupEditorView(
                    source: editorSource,
                    onComplete: { delegate?.overlayDidPin($0) },
                    onCancel: { delegate?.overlayDidCancel() },
                    layout: .inline(
                        canvasRect: selection,
                        containerSize: screenFrame.size,
                        toolbarWidth: toolbarWidth
                    ),
                    closeAfterExport: true,
                    onExported: { delegate?.overlayDidFinishEditing() },
                    onMarkupStateChange: {
                        hasMarkup = $0
                        if $0 { isAdjustingSelection = false }
                    },
                    isCanvasEnabled: !isAdjustingSelection,
                    isCanvasVisible: !isDraggingSelection,
                    onToolSelected: { isAdjustingSelection = false },
                    toolbarAccessory: AnyView(editorToolbarAccessory)
                )
            }

            if let selection, isAdjustingSelection {
                Rectangle()
                    .stroke(.white, lineWidth: 1)
                    .frame(width: selection.width, height: selection.height)
                    .position(x: selection.midX, y: selection.midY)
                    .allowsHitTesting(false)
                ForEach(Array(CaptureResizeHandle.allCases.enumerated()), id: \.offset) { _, handle in
                    let point = handle.anchorPoint(in: selection)
                    Rectangle()
                        .fill(.white)
                        .overlay(Rectangle().stroke(.black.opacity(0.45), lineWidth: 1))
                        .frame(width: 7, height: 7)
                        .position(point)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(width: screenFrame.width, height: screenFrame.height)
    }

    private var editorToolbarAccessory: some View {
        HStack(spacing: 8) {
            Button {
                isAdjustingSelection.toggle()
            } label: {
                Label(
                    isAdjustingSelection ? "完成调整" : "调整选区",
                    systemImage: isAdjustingSelection ? "checkmark" : "crop"
                )
            }
            .disabled(hasMarkup)
            .help(hasMarkup ? "已有标注，无法再调整选区" : "拖动选区内部移动，拖动边缘或角落调整大小")

            if rollingCaptureEnabled {
                Button {
                    startRolling()
                } label: {
                    Label("滚动截图", systemImage: "rectangle.stack")
                }
                .disabled(hasMarkup)
                .help(hasMarkup ? "已有标注，无法切换为滚动截图" : "从当前选区开始手动滚动截图")
            }
        }
    }

    private var toolbarPosition: CGPoint {
        guard let selection else { return CGPoint(x: screenFrame.width / 2, y: screenFrame.height / 2) }
        let halfWidth = toolbarWidth / 2
        let halfHeight: CGFloat = 72
        let x = min(max(selection.midX, halfWidth + 8), screenFrame.width - halfWidth - 8)
        let below = selection.maxY + halfHeight + 10
        let preferredY = below <= screenFrame.height - 8
            ? below
            : selection.minY - halfHeight - 10
        let y = min(max(preferredY, halfHeight + 8), screenFrame.height - halfHeight - 8)
        return CGPoint(x: x, y: y)
    }

    private var toolbarWidth: CGFloat {
        ScreenshotToolbarLayout.compactWidth(containerWidth: screenFrame.width)
    }

    private func prepareRegion(_ cgRect: CGRect) {
        captureWindowID = nil
        editorSource = nil
        isPreparing = true
        captureError = nil
        Task { @MainActor in
            do {
                let image = try await ScreenshotCapture.rollingRegionImage(cgRect)
                installEditorSource(image)
            } catch {
                if let image = debugPlaceholderImage(size: cgRect.size) {
                    installEditorSource(image)
                    return
                }
                isPreparing = false
                captureError = error.localizedDescription
            }
        }
    }

    private func prepareWindow(_ info: ScreenshotCapture.WindowInfo) {
        captureWindowID = info.id
        captureRect = info.bounds
        selection = localRect(fromCG: info.bounds)
        isAdjustingSelection = true
        isPreparing = true
        captureError = nil
        Task { @MainActor in
            do {
                let image = try await ScreenshotCapture.windowImage(windowID: info.id)
                installEditorSource(image)
            } catch {
                if let image = debugPlaceholderImage(size: info.bounds.size) {
                    installEditorSource(image)
                    return
                }
                isPreparing = false
                captureError = "无法读取所选窗口，请重试。"
            }
        }
    }

    private func installEditorSource(_ image: CGImage) {
        guard let data = ScreenshotService.pngData(from: image, pointSize: captureRect?.size),
              let source = MarkupImageSource(pngData: data)
        else {
            isPreparing = false
            captureError = "截图编码失败，请重试。"
            return
        }
        editorSource = source
        isPreparing = false
    }

    private func retryCapture() {
        guard let captureRect else { return }
        if let captureWindowID {
            prepareWindow(.init(
                id: captureWindowID,
                ownerPID: 0,
                bounds: captureRect,
                title: "",
                ownerName: ""
            ))
        } else {
            prepareRegion(captureRect)
        }
    }

    private func startRolling() {
        guard !hasMarkup, let captureRect else { return }
        delegate?.overlayDidStartRollingCapture(captureRect)
    }

    private func debugPlaceholderImage(size: CGSize) -> CGImage? {
        guard UserDefaults.standard.bool(forKey: "fewer.debug.ignoreScreenPermission") else { return nil }
        return ScreenshotService.debugPlaceholderImage(size: size)
    }

    private func localRect(fromCG rect: CGRect) -> CGRect {
        let top = NSScreen.screens.map(\.frame.maxY).max() ?? 0
        return CGRect(
            x: rect.minX - screenFrame.origin.x,
            y: rect.minY - (top - screenFrame.origin.y - screenFrame.height),
            width: rect.width,
            height: rect.height
        )
    }
}

private struct SelectionMask: Shape {
    let cutout: CGRect?

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        if let cutout {
            path.addRect(cutout)
        }
        return path
    }
}

// MARK: - 鼠标事件层

/// 事件层：区域拖拽选择、窗口模式悬停高亮/点击、Esc 取消。
/// 视图为 flipped（原点左上），与全局屏幕坐标（原点左上）仅差常量偏移。
struct MouseCaptureLayer: NSViewRepresentable {
    let mode: ScreenshotMode
    let screenFrame: NSRect
    let selection: CGRect?
    let allowsSelectionAdjustment: Bool
    let isEnabled: Bool
    let onSelectionUpdate: (CGRect?) -> Void
    let onSelectionEnd: (CGRect) -> Void
    let onSelectionAdjustmentChange: (Bool) -> Void
    let onWindowClick: (ScreenshotCapture.WindowInfo) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> MouseCaptureNSView {
        let view = MouseCaptureNSView()
        view.mode = mode
        view.screenFrame = screenFrame
        view.setSelection(selection)
        view.allowsSelectionAdjustment = allowsSelectionAdjustment
        view.isCaptureEnabled = isEnabled
        view.onSelectionUpdate = onSelectionUpdate
        view.onSelectionEnd = onSelectionEnd
        view.onSelectionAdjustmentChange = onSelectionAdjustmentChange
        view.onWindowClick = onWindowClick
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_ nsView: MouseCaptureNSView, context: Context) {
        nsView.mode = mode
        nsView.setSelection(selection)
        nsView.allowsSelectionAdjustment = allowsSelectionAdjustment
        nsView.isCaptureEnabled = isEnabled
    }
}

/// 选区调整交互模式：调整大小（固定对边/对角，选区随之移动）或整体移动。
private enum CaptureAdjustMode: Equatable {
    case none
    case move
    case resize(CaptureResizeHandle)
}

final class MouseCaptureNSView: NSView {
    override var isFlipped: Bool { true }

    var mode: ScreenshotMode = .region
    var screenFrame = NSRect.zero
    var allowsSelectionAdjustment = false
    var isCaptureEnabled = true
    var onSelectionUpdate: ((CGRect?) -> Void)?
    var onSelectionEnd: ((CGRect) -> Void)?
    var onSelectionAdjustmentChange: ((Bool) -> Void)?
    var onWindowClick: ((ScreenshotCapture.WindowInfo) -> Void)?
    var onCancel: (() -> Void)?

    private var dragStart: NSPoint?
    private var dragCurrent: NSPoint?
    private var selectionRect: CGRect?
    private var hoveredWindowID: CGWindowID?
    private var hoveredBounds: CGRect?
    private var windowList: [ScreenshotCapture.WindowInfo] = []

    /// 当前选区调整模式（调整大小 / 整体移动），none 表示未在调整。
    private var adjustMode: CaptureAdjustMode = .none
    /// 移动模式：拖拽起点与选区原始位置。
    private var moveStartPoint: NSPoint?
    private var moveOriginalRect: CGRect?
    /// 调整大小模式：选区原始位置（每次拖拽基于原始值重算，避免累积误差）。
    private var resizeOriginalRect: CGRect?

    // 所有屏幕顶部（AppKit 坐标）。
    private var top: CGFloat {
        NSScreen.screens.map(\.frame.maxY).max() ?? 0
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        // 窗口 key 后再设置 firstResponder（viewDidMoveToWindow 时窗口可能未 key，makeFirstResponder 会失败）
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
            self.window?.makeKey()
        }
        refreshWindowList()
    }

    private func refreshWindowList() {
        guard mode == .window || mode == .smart else { return }
        windowList = ScreenshotCapture.onScreenWindows()
    }

    // MARK: - 坐标换算

    /// 局部 flipped 坐标 → 全局屏幕坐标（原点左上）。
    private func cgPoint(fromLocal point: NSPoint) -> CGPoint {
        CGPoint(
            x: screenFrame.origin.x + point.x,
            y: top - screenFrame.origin.y - screenFrame.height + point.y
        )
    }

    private func cgRect(fromLocal rect: CGRect) -> CGRect {
        CGRect(x: rect.minX + screenFrame.origin.x,
               y: rect.minY + top - screenFrame.origin.y - screenFrame.height,
               width: rect.width,
               height: rect.height)
    }

    /// 全局屏幕坐标（原点左上）→ 局部 flipped 坐标。
    private func localRect(fromCG rect: CGRect) -> CGRect {
        CGRect(x: rect.minX - screenFrame.origin.x,
               y: rect.minY - (top - screenFrame.origin.y - screenFrame.height),
               width: rect.width,
               height: rect.height)
    }

    // MARK: - 鼠标事件

    override func mouseDown(with event: NSEvent) {
        guard isCaptureEnabled else { return }
        let point = convert(event.locationInWindow, from: nil)
        if allowsSelectionAdjustment,
           let rect = selectionRect, rect.width > 4, rect.height > 4 {
            if let handle = CaptureResizeHandle.edgeHitTest(point: point, in: rect) {
                adjustMode = .resize(handle)
                resizeOriginalRect = rect
                onSelectionAdjustmentChange?(true)
                onSelectionUpdate?(cgRect(fromLocal: rect))
                needsDisplay = true
                return
            }
            if rect.contains(point) {
                adjustMode = .move
                moveOriginalRect = rect
                moveStartPoint = point
                onSelectionAdjustmentChange?(true)
                onSelectionUpdate?(cgRect(fromLocal: rect))
                needsDisplay = true
                return
            }
        }
        if mode == .smart {
            dragStart = point
            dragCurrent = point
            onSelectionUpdate?(nil)
            needsDisplay = true
            return
        }
        guard mode == .window else {
            dragStart = point
            dragCurrent = dragStart
            onSelectionUpdate?(nil)
            needsDisplay = true
            return
        }
        let local = convert(event.locationInWindow, from: nil)
        let globalPoint = cgPoint(fromLocal: local)
        if let index = WindowHitTester.hitTest(
            point: globalPoint,
            windowBounds: windowList.map(\.bounds)
        ) {
            onWindowClick?(windowList[index])
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isCaptureEnabled else { return }
        guard mode == .region || mode == .smart || adjustMode != .none else { return }
        let point = convert(event.locationInWindow, from: nil)

        switch adjustMode {
        case .move:
            guard let start = moveStartPoint, let original = moveOriginalRect else { return }
            let delta = CGSize(width: point.x - start.x, height: point.y - start.y)
            guard delta.width != 0 || delta.height != 0 else { return }
            updateSelection(CaptureResizeHandle.clamped(original.offsetBy(dx: delta.width, dy: delta.height), within: bounds))
            needsDisplay = true
            return
        case .resize(let handle):
            guard let original = resizeOriginalRect else { return }
            let resized = CaptureResizeHandle.resizedRect(original: original, handle: handle, current: point)
            updateSelection(CaptureResizeHandle.clamped(resized, within: bounds))
            needsDisplay = true
            return
        case .none:
            guard dragStart != nil else { return }
            dragCurrent = point
            if let start = dragStart {
                onSelectionUpdate?(cgRect(fromLocal: CaptureRegion.normalized(from: start, to: point)))
            }
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard isCaptureEnabled else { return }
        guard mode == .region || mode == .smart || adjustMode != .none else { return }
        if adjustMode != .none {
            onSelectionAdjustmentChange?(false)
            adjustMode = .none
            moveOriginalRect = nil
            moveStartPoint = nil
            resizeOriginalRect = nil
            if let rect = selectionRect {
                onSelectionEnd?(cgRect(fromLocal: rect))
            }
            needsDisplay = true
            return
        }
        guard let start = dragStart else { return }
        let end = convert(event.locationInWindow, from: nil)
        dragStart = nil
        dragCurrent = nil
        needsDisplay = true

        let rect = CaptureRegion.normalized(from: start, to: end)
        if mode == .smart {
            let point = cgPoint(fromLocal: end)
            let index = WindowHitTester.hitTest(point: point, windowBounds: windowList.map(\.bounds))
            switch SmartCaptureGesture.resolve(start: start, end: end, windowIndex: index) {
            case .region(let rect):
                selectionRect = rect
                onSelectionEnd?(cgRect(fromLocal: rect))
            case .window(let index):
                onWindowClick?(windowList[index])
            case .none:
                break
            }
            return
        }
        // 过小选区视为误触，忽略
        guard rect.width > 4, rect.height > 4 else { return }
        selectionRect = rect
        onSelectionEnd?(cgRect(fromLocal: rect))
    }

    override func mouseMoved(with event: NSEvent) {
        guard isCaptureEnabled else { return }
        guard mode == .window || mode == .smart else { return }
        let local = convert(event.locationInWindow, from: nil)
        let point = cgPoint(fromLocal: local)
        if let index = WindowHitTester.hitTest(
            point: point,
            windowBounds: windowList.map(\.bounds)
        ) {
            let info = windowList[index]
            if hoveredWindowID != info.id {
                hoveredWindowID = info.id
                hoveredBounds = info.bounds
                needsDisplay = true
            }
        } else if hoveredWindowID != nil {
            hoveredWindowID = nil
            hoveredBounds = nil
            needsDisplay = true
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }

    override var acceptsFirstResponder: Bool { true }

    // MARK: - 选区调整

    private func updateSelection(_ rect: CGRect) {
        selectionRect = rect
        onSelectionUpdate?(cgRect(fromLocal: rect))
    }

    func setSelection(_ cgRect: CGRect?) {
        let updated = cgRect.map(localRect(fromCG:))
        guard updated != selectionRect else { return }
        selectionRect = updated
        needsDisplay = true
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if (mode == .window || mode == .smart), dragStart == nil, let hoveredBounds {
            let rect = localRect(fromCG: hoveredBounds).insetBy(dx: -2, dy: -2)
            NSColor.systemYellow.setStroke()
            let path = NSBezierPath(rect: rect)
            path.lineWidth = 3
            path.stroke()
        }

        if (mode == .region || mode == .smart), let start = dragStart, let current = dragCurrent {
            let rect = CaptureRegion.normalized(from: start, to: current)
            NSColor.white.setStroke()
            let path = NSBezierPath(rect: rect)
            path.lineWidth = 1
            path.stroke()
        }

        // 已有选区且未开始新拖拽：绘制四角调整手柄
        if allowsSelectionAdjustment, dragStart == nil,
           let rect = selectionRect, rect.width > 4, rect.height > 4 {
            drawResizeHandles(for: rect)
        }
    }

    private func drawResizeHandles(for rect: CGRect) {
        let size: CGFloat = 7
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.maxY),
        ]
        for corner in corners {
            let handle = CGRect(x: corner.x - size / 2, y: corner.y - size / 2, width: size, height: size)
            NSColor.white.setFill()
            NSBezierPath(rect: handle).fill()
            NSColor.black.withAlphaComponent(0.45).setStroke()
            let border = NSBezierPath(rect: handle)
            border.lineWidth = 1
            border.stroke()
        }
    }
}
