import AppKit
import CoreImage
import FewerCore
import SwiftUI
import Vision

/// 贴图进入编辑时仍复用同一个标注工作区；截图结果本身也直接嵌入该工作区。
@MainActor
final class MarkupEditorWindowController: NSObject, NSWindowDelegate {
    static let shared = MarkupEditorWindowController()

    private var window: NSWindow?
    private var completion: ((Data) -> Void)?
    private var cancellation: (() -> Void)?

    private override init() {}

    func edit(
        pngData: Data,
        onComplete: @escaping (Data) -> Void,
        onCancel: @escaping () -> Void = {}
    ) {
        close()
        guard let source = MarkupImageSource(pngData: pngData) else { return }

        completion = onComplete
        cancellation = onCancel
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let contentSize = NSSize(
            width: min(max(source.displaySize.width + 32, 760), visibleFrame.width * 0.92),
            height: min(max(source.displaySize.height + 150, 560), visibleFrame.height * 0.92)
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("screenshot-markup-editor")
        window.title = "编辑贴图"
        window.minSize = NSSize(width: 720, height: 520)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: MarkupEditorView(
            source: source,
            onComplete: { [weak self] data in self?.finish(with: data) },
            onCancel: { [weak self] in self?.cancelEditing() }
        ))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func close() {
        completion = nil
        cancellation = nil
        window?.delegate = nil
        window?.contentViewController = nil
        window?.close()
        window = nil
    }

    private func finish(with data: Data) {
        let completion = completion
        self.completion = nil
        cancellation = nil
        window?.delegate = nil
        window?.contentViewController = nil
        window?.close()
        window = nil
        completion?(data)
    }

    private func cancelEditing() {
        let cancellation = cancellation
        completion = nil
        self.cancellation = nil
        window?.delegate = nil
        window?.contentViewController = nil
        window?.close()
        window = nil
        cancellation?()
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow, closingWindow === window else { return }
        closingWindow.contentViewController = nil
        window = nil
        let cancellation = cancellation
        completion = nil
        self.cancellation = nil
        cancellation?()
    }
}

struct MarkupImageSource {
    let id = UUID()
    let pngData: Data
    let cgImage: CGImage
    let image: NSImage
    /// 原始物理像素尺寸，标注模型与导出始终使用该坐标系。
    let size: CGSize
    /// PNG 记录的逻辑点尺寸，仅用于窗口和画布预览。
    let displaySize: CGSize

    init?(pngData: Data) {
        guard let rep = NSBitmapImageRep(data: pngData), let cgImage = rep.cgImage else { return nil }
        let size = CGSize(width: cgImage.width, height: cgImage.height)
        let encodedSize = CGSize(width: rep.size.width, height: rep.size.height)
        let displaySize = encodedSize.width > 0 && encodedSize.height > 0 ? encodedSize : size
        self.pngData = pngData
        self.cgImage = cgImage
        self.image = NSImage(cgImage: cgImage, size: size)
        self.size = size
        self.displaySize = displaySize
    }
}

private struct ScreenshotContentAnalysis: Sendable {
    let blockBounds: [CGRect]
    let fallbackBounds: [CGRect]

    static let empty = ScreenshotContentAnalysis(blockBounds: [], fallbackBounds: [])
}

private enum ScreenshotContentAnalyzer {
    /// Vision 分析输入的最长边（像素）。Retina 全屏截图常达 4000-5000px，
    /// 直接送入 Vision 会显著变慢甚至失败；降采样后速度提升数倍且结果稳定。
    private static let analysisMaxDimension = 2048

    static func analyze(_ image: CGImage) -> ScreenshotContentAnalysis {
        let originalWidth = image.width
        let originalHeight = image.height
        let longestSide = max(originalWidth, originalHeight)
        let scale = min(1, CGFloat(analysisMaxDimension) / CGFloat(longestSide))
        guard let analysisImage = scale < 1 ? downscaled(image, scale: scale) : image else {
            return .empty
        }

        let textRequest = VNRecognizeTextRequest()
        // .accurate + 语言纠正对中文小字识别率明显高于 .fast，配合降采样保证速度。
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = true
        textRequest.recognitionLanguages = ["zh-Hans", "en-US"]

        let rectangleRequest = VNDetectRectanglesRequest()
        rectangleRequest.maximumObservations = 200
        rectangleRequest.minimumSize = 0.005
        rectangleRequest.minimumAspectRatio = 0.05
        rectangleRequest.quadratureTolerance = 20

        let contourRequest = VNDetectContoursRequest()
        contourRequest.maximumImageDimension = 1536
        contourRequest.contrastAdjustment = 1.5
        let saliencyRequest = VNGenerateObjectnessBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cgImage: analysisImage, options: [:])
        try? handler.perform([textRequest, rectangleRequest, saliencyRequest, contourRequest])

        let imageBounds = CGRect(x: 0, y: 0, width: originalWidth, height: originalHeight)
        let textObservations = textRequest.results ?? []
        let textLineBounds = textObservations.map {
            pixelRect($0.boundingBox, image: analysisImage).insetBy(dx: -4, dy: -3)
        }
        let topLevelContours = contourRequest.results?.first?.topLevelContours ?? []
        let iconContours = topLevelContours.flatMap { [$0] + $0.childContours }
        let allIconRects = iconContours.compactMap { contour -> CGRect? in
            guard let rect = pixelRect(contour: contour, image: analysisImage) else { return nil }
            return rect.insetBy(dx: -2, dy: -2)
        }
        // 轮廓检测会产出整页/整卡片的巨大外框，它们不会是右键想选中的独立元素。
        // 只保留尺寸明显小于画面主体的轮廓。
        let pageArea = CGFloat(analysisImage.width) * CGFloat(analysisImage.height)
        let iconRects = allIconRects.filter { rect in
            rect.width < CGFloat(analysisImage.width) * 0.9
                && rect.height < CGFloat(analysisImage.height) * 0.9
                && rect.width * rect.height < pageArea * 0.25
        }
        // 文字笔画也会形成轮廓；被文字行覆盖的轮廓不能作为页面块，否则仍会退化为单字框选。
        let independentContours = iconRects.filter { candidate in
            let candidateArea = candidate.width * candidate.height
            return !textLineBounds.contains { line in
                let intersection = line.intersection(candidate)
                return !intersection.isNull && candidateArea > 0
                    && intersection.width * intersection.height / candidateArea > 0.6
            }
        }

        var blockCandidates = (rectangleRequest.results ?? []).map {
            pixelRect($0.boundingBox, image: analysisImage)
        }
        blockCandidates.append(contentsOf: (saliencyRequest.results ?? []).flatMap { observation in
            (observation.salientObjects ?? []).map {
                pixelRect($0.boundingBox, image: analysisImage)
            }
        })
        let fallbackCandidates = independentContours + textLineBounds
        // 降采样坐标系下的候选映射回原图像素坐标。
        let mappedBlocks = blockCandidates.map { rect in
            CGRect(
                x: rect.minX / scale,
                y: rect.minY / scale,
                width: rect.width / scale,
                height: rect.height / scale
            )
        }
        let mappedFallback = fallbackCandidates.map { rect in
            CGRect(
                x: rect.minX / scale,
                y: rect.minY / scale,
                width: rect.width / scale,
                height: rect.height / scale
            )
        }
        let mappedText = textLineBounds.map { rect in
            CGRect(
                x: rect.minX / scale,
                y: rect.minY / scale,
                width: rect.width / scale,
                height: rect.height / scale
            )
        }
        return ScreenshotContentAnalysis(
            blockBounds: ScreenshotContentPicker.filteredBlockBounds(
                mappedBlocks,
                textBounds: mappedText,
                imageSize: imageBounds.size
            ),
            fallbackBounds: ScreenshotContentPicker.filteredElementBounds(
                mappedFallback,
                imageSize: imageBounds.size
            )
        )
    }

    /// 按比例降采样图像（保持宽高比），用于 Vision 分析。
    private static func downscaled(_ image: CGImage, scale: CGFloat) -> CGImage? {
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// 小图标通常不是文字或规则矩形，用轮廓的外接框补充候选。
    private static func pixelRect(contour: VNContour, image: CGImage) -> CGRect? {
        let points = contour.normalizedPoints
        guard let first = points.first else { return nil }
        var minX = CGFloat(first.x)
        var maxX = minX
        var minY = CGFloat(first.y)
        var maxY = minY
        for point in points.dropFirst() {
            minX = min(minX, CGFloat(point.x))
            maxX = max(maxX, CGFloat(point.x))
            minY = min(minY, CGFloat(point.y))
            maxY = max(maxY, CGFloat(point.y))
        }
        return CGRect(
            x: minX * CGFloat(image.width),
            y: minY * CGFloat(image.height),
            width: (maxX - minX) * CGFloat(image.width),
            height: (maxY - minY) * CGFloat(image.height)
        )
    }

    private static func pixelRect(_ normalizedRect: CGRect, image: CGImage) -> CGRect {
        VNImageRectForNormalizedRect(normalizedRect, image.width, image.height)
    }
}

private enum MarkupTool: String, CaseIterable, Identifiable {
    case rectangle
    case roundedRectangle
    case ellipse
    case line
    case polyline
    case arrow
    case brush
    case highlight
    case mosaic
    case blur
    case text
    case eraser
    case counter
    case magnifier

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rectangle: "矩形"
        case .roundedRectangle: "圆角矩形"
        case .ellipse: "椭圆/圆形"
        case .line: "直线"
        case .polyline: "折线"
        case .arrow: "箭头"
        case .brush: "画笔"
        case .highlight: "记号笔"
        case .mosaic: "马赛克"
        case .blur: "高斯模糊"
        case .text: "文本标注（Enter 换行，⌘Enter 完成）"
        case .eraser: "橡皮擦"
        case .counter: "序号标注"
        case .magnifier: "放大镜标注"
        }
    }

    var symbol: String {
        switch self {
        case .rectangle: "rectangle"
        case .roundedRectangle: "rectangle.fill"
        case .ellipse: "circle"
        case .line: "line.diagonal"
        case .polyline: "point.3.connected.trianglepath.dotted"
        case .arrow: "arrow.up.right"
        case .brush: "pencil.line"
        case .highlight: "highlighter"
        case .mosaic: "squareshape.split.3x3"
        case .blur: "drop"
        case .text: "textformat"
        case .eraser: "eraser"
        case .counter: "1.circle"
        case .magnifier: "magnifyingglass.circle"
        }
    }

    var supportsStrokeStyle: Bool {
        switch self {
        case .rectangle, .roundedRectangle, .ellipse, .line, .polyline, .arrow, .brush: true
        default: false
        }
    }

    var supportsAreaShape: Bool {
        switch self {
        case .highlight, .mosaic, .blur, .eraser: true
        default: false
        }
    }

    var usesFreehandDrag: Bool {
        self == .brush
    }

    func shape(
        from start: CGPoint,
        to end: CGPoint,
        points: [CGPoint],
        areaShape: MarkupAreaShape,
        counterNumber: Int
    ) -> MarkupShape? {
        let rect = CaptureRegion.normalized(from: start, to: end)
        switch self {
        case .rectangle: return MarkupShape.rect(rect)
        case .roundedRectangle: return MarkupShape.roundedRect(rect)
        case .ellipse: return MarkupShape.ellipse(rect)
        case .line: return MarkupShape.line(start: start, end: end)
        case .polyline: return points.count > 1 ? MarkupShape.polyline(points) : nil
        case .arrow: return MarkupShape.arrow(start: start, end: end)
        case .brush: return points.count > 1 ? MarkupShape.freehand(points) : nil
        case .highlight:
            return MarkupShape.highlight(
                points: effectPoints(start: start, end: end, points: points, areaShape: areaShape),
                areaShape: areaShape
            )
        case .mosaic:
            return MarkupShape.mosaic(
                points: effectPoints(start: start, end: end, points: points, areaShape: areaShape),
                areaShape: areaShape
            )
        case .blur:
            return MarkupShape.blur(
                points: effectPoints(start: start, end: end, points: points, areaShape: areaShape),
                areaShape: areaShape
            )
        case .eraser:
            return MarkupShape.eraser(
                points: effectPoints(start: start, end: end, points: points, areaShape: areaShape),
                areaShape: areaShape
            )
        case .magnifier:
            return MarkupShape.magnifier(
                center: start,
                radius: max(24, hypot(end.x - start.x, end.y - start.y)),
                scale: 2
            )
        case .counter: return MarkupShape.counter(counterNumber, center: start)
        case .text: return nil
        }
    }

    private func effectPoints(
        start: CGPoint,
        end: CGPoint,
        points: [CGPoint],
        areaShape: MarkupAreaShape
    ) -> [CGPoint] {
        areaShape == .freehand ? points : [start, end]
    }
}

enum MarkupEditorLayout {
    case window
    case inline(
        canvasRect: CGRect,
        containerSize: CGSize,
        toolbarWidth: CGFloat
    )
}

struct MarkupEditorView: View {
    let source: MarkupImageSource
    let onComplete: (Data) -> Void
    let onCancel: () -> Void
    var layout: MarkupEditorLayout = .window
    var closeAfterExport = false
    var onExported: () -> Void = {}
    var onMarkupStateChange: (Bool) -> Void = { _ in }
    var isCanvasEnabled = true
    var isCanvasVisible = true
    var onToolSelected: () -> Void = {}
    var toolbarAccessory: AnyView?

    @State private var elements: [MarkupElement] = []
    @State private var tool: MarkupTool = .arrow
    @State private var color: MarkupColor = .red
    @State private var strokeWidth: Double = 4
    @State private var strokeStyle: MarkupStrokeStyle = .solid
    @State private var areaShape: MarkupAreaShape = .freehand
    @State private var selectedElementID: UUID?
    @State private var history = MarkupSnapshotHistory()
    @State private var toast: String?
    @State private var contentBlockBounds: [CGRect] = []
    @State private var contentFallbackBounds: [CGRect] = []
    @State private var isRecognizingContent = false
    @State private var isShowingInlineStyle = false
    @StateObject private var zoom = MarkupZoomModel()

    private let settingsStore = ScreenshotSettingsStore()

    var body: some View {
        Group {
            switch layout {
            case .window:
                windowWorkspace
            case .inline(let canvasRect, let containerSize, let toolbarWidth):
                inlineWorkspace(
                    canvasRect: canvasRect,
                    containerSize: containerSize,
                    toolbarWidth: toolbarWidth
                )
            }
        }
        .onAppear { onMarkupStateChange(!elements.isEmpty) }
        .onChange(of: elements.isEmpty) { _, isEmpty in
            onMarkupStateChange(!isEmpty)
        }
        .task(id: source.id) {
            contentBlockBounds = []
            contentFallbackBounds = []
            isRecognizingContent = true
            let image = source.cgImage
            let analysis = await Task.detached(priority: .utility) {
                ScreenshotContentAnalyzer.analyze(image)
            }.value
            guard !Task.isCancelled else { return }
            contentBlockBounds = analysis.blockBounds
            contentFallbackBounds = analysis.fallbackBounds
            isRecognizingContent = false
        }
    }

    private var windowWorkspace: some View {
        VStack(spacing: 0) {
            ZoomableCanvasScrollView(model: zoom) {
                editorCanvas(displaySize: source.displaySize)
                    .frame(width: source.displaySize.width, height: source.displaySize.height)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .shadow(color: .black.opacity(0.16), radius: 8)
                    .padding(24)
                    .opacity(isCanvasVisible ? 1 : 0)
                    .allowsHitTesting(isCanvasEnabled)
            }

            Divider()
            bottomToolbar
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.black.opacity(0.78), in: Capsule())
                    .padding(.bottom, 136)
            }
        }
    }

    private func inlineWorkspace(
        canvasRect: CGRect,
        containerSize: CGSize,
        toolbarWidth: CGFloat
    ) -> some View {
        ZStack(alignment: .topLeading) {
            editorCanvas(displaySize: canvasRect.size)
                .frame(width: canvasRect.width, height: canvasRect.height)
                .background(Color(nsColor: .windowBackgroundColor))
                .overlay(Rectangle().stroke(.white, lineWidth: 1))
                .shadow(color: .black.opacity(0.2), radius: 5)
                .position(x: canvasRect.midX, y: canvasRect.midY)
                .opacity(isCanvasVisible ? 1 : 0)
                .allowsHitTesting(isCanvasEnabled)

            inlineToolbar
                .frame(width: toolbarWidth, height: ScreenshotToolbarLayout.compactHeight)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .shadow(color: .black.opacity(0.28), radius: 8)
                .position(ScreenshotToolbarLayout.position(
                    selection: canvasRect,
                    containerSize: containerSize,
                    toolbarSize: CGSize(
                        width: toolbarWidth,
                        height: ScreenshotToolbarLayout.compactHeight
                    )
                ))
        }
        .frame(width: containerSize.width, height: containerSize.height)
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.black.opacity(0.78), in: Capsule())
                    .padding(.bottom, 16)
            }
        }
    }

    /// 缩放容器的文档尺寸 = 画布逻辑尺寸 + 24 内边距。
    private var zoomDocumentSize: CGSize {
        CGSize(
            width: source.displaySize.width + 48,
            height: source.displaySize.height + 48
        )
    }

    private func editorCanvas(displaySize: CGSize) -> some View {
        MarkupCanvas(
            source: source,
            displaySize: displaySize,
            contentBlockBounds: contentBlockBounds,
            contentFallbackBounds: contentFallbackBounds,
            elements: elements,
            tool: tool,
            color: color,
            strokeWidth: strokeWidth,
            strokeStyle: strokeStyle,
            areaShape: areaShape,
            nextCounterNumber: nextCounterNumber,
            selectedElementID: selectedElementID,
            onCommit: commit,
            onSelect: { selectedElementID = $0 },
            onBeginMutation: recordUndo,
            onUpdateElement: updateElement,
            onDeleteSelection: deleteSelectedElement,
            onPickMiss: handlePickMiss
        )
        .help("普通拖动新建标注，拖动控制点缩放；按住 ⌘ 拖动已有标注可移动")
    }

    private var nextCounterNumber: Int {
        elements.reduce(into: 0) { count, element in
            if case .counter = element.shape { count += 1 }
        } + 1
    }

    /// 当前工具支持右键自动框选界面元素时的提示文案。
    private var elementPickHint: String? {
        if isRecognizingContent { return "正在识别界面元素…" }
        switch tool {
        case .rectangle, .roundedRectangle, .ellipse: return "右键选择鼠标下最小页面元素；可在外层框内继续叠加"
        case .highlight, .mosaic, .blur, .eraser:
            return "右键选择内部元素并叠加标记"
        default: return nil
        }
    }

    private var bottomToolbar: some View {
        VStack(spacing: 7) {
            ScrollView(.horizontal, showsIndicators: false) {
                toolStrip
                    .padding(.horizontal, 14)
            }

            if let elementPickHint {
                Text(elementPickHint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    Text("颜色")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                HStack(spacing: 5) {
                    ForEach(MarkupColor.allCases) { value in
                        Button {
                            setColor(value)
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(Color(nsColor: value.nsColor))
                                    .frame(width: 15, height: 15)
                                Circle()
                                    .stroke(
                                        activeColor == value ? Color.accentColor : Color.secondary.opacity(0.35),
                                        lineWidth: activeColor == value ? 2.5 : 0.8
                                    )
                                    .frame(width: 21, height: 21)
                            }
                            .frame(width: 22, height: 22)
                            .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help(value.title)
                        .accessibilityLabel(value.title)
                        .accessibilityAddTraits(activeColor == value ? .isSelected : [])
                    }
                }

                Text(widthLabel)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .trailing)

                Slider(
                    value: activeStrokeWidth,
                    in: activeStrokeWidthRange,
                    step: 1,
                    onEditingChanged: { editing in
                        if editing, selectedElementID != nil { recordUndo() }
                    }
                )
                .frame(width: 104)
                .help("线条粗细；马赛克、高斯模糊、记号笔和橡皮擦可调笔触大小")

                if showsStrokeStyle {
                    Menu {
                        ForEach(MarkupStrokeStyle.allCases) { value in
                            Button(value.title) {
                                setStrokeStyle(value)
                            }
                        }
                    } label: {
                        Label(activeStrokeStyle.title, systemImage: activeStrokeStyle.symbol)
                            .frame(minWidth: 64)
                    }
                    .help("实线 / 虚线 / 点线")
                }

                if tool.supportsAreaShape {
                    Menu {
                        ForEach(MarkupAreaShape.allCases) { value in
                            Button(value.title) {
                                areaShape = value
                            }
                        }
                    } label: {
                        Label(areaShape.title, systemImage: areaShape.symbol)
                            .frame(minWidth: 82)
                    }
                    .help("记号笔、马赛克、高斯模糊、橡皮擦的范围形状；按住 Shift 绘制圆形")
                }

                Button {
                    undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .disabled(!history.canUndo)
                .keyboardShortcut("z", modifiers: .command)
                .help("撤销（⌘Z）")
                .accessibilityLabel("撤销")

                Button {
                    redo()
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                }
                .disabled(!history.canRedo)
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .help("重做（⇧⌘Z）")
                .accessibilityLabel("重做")

                    Button(role: .destructive) {
                        deleteSelectedElement()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(selectedElementID == nil)
                    .help("删除所选标注（Delete）")
                }
                .padding(.horizontal, 14)
            }

            HStack(spacing: 10) {
                if let toolbarAccessory { toolbarAccessory }
                Spacer()

                Divider().frame(height: 16)

                Button {
                    zoom.zoomOut()
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .keyboardShortcut("-", modifiers: .command)
                .help("缩小（⌘−）")
                .accessibilityLabel("缩小")

                Text(zoom.percentageLabel)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .center)

                Button {
                    zoom.zoomIn()
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .keyboardShortcut("+", modifiers: .command)
                .help("放大（⌘+）")
                .accessibilityLabel("放大")

                Button {
                    zoom.zoomToActual()
                } label: {
                    Text("100%")
                }
                .keyboardShortcut("1", modifiers: .command)
                .help("实际大小（⌘1）")

                Button {
                    zoom.zoomToFit(documentSize: zoomDocumentSize)
                } label: {
                    Text("适应窗口")
                }
                .keyboardShortcut("0", modifiers: .command)
                .help("适应窗口（⌘0）")

                Divider().frame(height: 16)

                Button {
                    copyImage()
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }
                .keyboardShortcut("c", modifiers: .command)

                Button {
                    saveImage()
                } label: {
                    Label("保存", systemImage: "square.and.arrow.down")
                }
                .keyboardShortcut("s", modifiers: .command)

                Button("关闭", role: .cancel) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button {
                    pinImage()
                } label: {
                    Label("贴图", systemImage: "pin.fill")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [])
            }
            .padding(.horizontal, 14)
        }
        .padding(.vertical, 9)
        .background(.bar)
    }

    private var inlineToolbar: some View {
        HStack(spacing: 5) {
            if let toolbarAccessory {
                toolbarAccessory
                    .labelStyle(.iconOnly)
            }

            Divider().frame(height: 24)

            ScrollView(.horizontal, showsIndicators: false) {
                toolStrip
            }
            .frame(maxWidth: .infinity)

            Divider().frame(height: 24)

            Button {
                isShowingInlineStyle.toggle()
            } label: {
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: "slider.horizontal.3")
                        .frame(width: 26, height: 24)
                    Circle()
                        .fill(Color(nsColor: activeColor.nsColor))
                        .frame(width: 8, height: 8)
                }
            }
            .buttonStyle(.plain)
            .help("颜色与线条样式")
            .accessibilityLabel("颜色与线条样式")
            .popover(isPresented: $isShowingInlineStyle, arrowEdge: .bottom) {
                inlineStylePanel
            }

            Button { undo() } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(!history.canUndo)
            .keyboardShortcut("z", modifiers: .command)
            .help("撤销（⌘Z）")
            .accessibilityLabel("撤销")

            Button { redo() } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .disabled(!history.canRedo)
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .help("重做（⇧⌘Z）")
            .accessibilityLabel("重做")

            Button(role: .destructive) { deleteSelectedElement() } label: {
                Image(systemName: "trash")
            }
            .disabled(selectedElementID == nil)
            .help("删除所选标注（Delete）")
            .accessibilityLabel("删除所选标注")

            Divider().frame(height: 24)

            Button { copyImage() } label: {
                Image(systemName: "doc.on.doc")
            }
            .keyboardShortcut("c", modifiers: .command)
            .help("复制（⌘C）")
            .accessibilityLabel("复制")

            Button { saveImage() } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .keyboardShortcut("s", modifiers: .command)
            .help("保存（⌘S）")
            .accessibilityLabel("保存")

            Button(role: .cancel) { onCancel() } label: {
                Image(systemName: "xmark")
            }
            .keyboardShortcut(.cancelAction)
            .help("关闭（Esc）")
            .accessibilityLabel("关闭")

            Button { pinImage() } label: {
                Image(systemName: "pin.fill")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: [])
            .help("贴图（Return）")
            .accessibilityLabel("贴图")
        }
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var toolStrip: some View {
        HStack(spacing: 4) {
            ForEach(MarkupTool.allCases) { candidate in
                Button {
                    selectTool(candidate)
                } label: {
                    Image(systemName: candidate.symbol)
                        .frame(width: 28, height: 24)
                        .contentShape(Rectangle())
                        .background(
                            tool == candidate ? Color.accentColor.opacity(0.2) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                }
                .buttonStyle(.plain)
                .help(candidate.title)
                .accessibilityLabel(candidate.title)
            }
        }
    }

    private var inlineStylePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(MarkupColor.allCases) { value in
                    Button {
                        setColor(value)
                    } label: {
                        Circle()
                            .fill(Color(nsColor: value.nsColor))
                            .overlay(
                                Circle().stroke(
                                    activeColor == value ? Color.accentColor : Color.secondary.opacity(0.35),
                                    lineWidth: activeColor == value ? 3 : 1
                                )
                            )
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help(value.title)
                    .accessibilityLabel(value.title)
                }
            }

            HStack(spacing: 10) {
                Text(widthLabel)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 72, alignment: .leading)
                Slider(
                    value: activeStrokeWidth,
                    in: activeStrokeWidthRange,
                    step: 1,
                    onEditingChanged: { editing in
                        if editing, selectedElementID != nil { recordUndo() }
                    }
                )
            }

            if showsStrokeStyle {
                Menu {
                    ForEach(MarkupStrokeStyle.allCases) { value in
                        Button(value.title) { setStrokeStyle(value) }
                    }
                } label: {
                    Label(activeStrokeStyle.title, systemImage: activeStrokeStyle.symbol)
                }
            }

            if tool.supportsAreaShape {
                Menu {
                    ForEach(MarkupAreaShape.allCases) { value in
                        Button(value.title) { areaShape = value }
                    }
                } label: {
                    Label(areaShape.title, systemImage: areaShape.symbol)
                }
            }

            if let elementPickHint {
                Text(elementPickHint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 280)
    }

    private func copyImage() {
        guard let data = renderedData() else { return showToast("导出失败") }
        let succeeded = ScreenshotClipboard.copy(pngData: data)
        showToast(succeeded ? "已复制" : "复制失败")
        if succeeded, closeAfterExport { onExported() }
    }

    private func saveImage() {
        guard let data = renderedData() else { return showToast("导出失败") }
        do {
            let url = try PinSaver.save(pngData: data, settings: settingsStore.load())
            showToast("已保存到 \(url.deletingLastPathComponent().lastPathComponent)")
            if closeAfterExport { onExported() }
        } catch {
            showToast(error.localizedDescription)
        }
    }

    private func pinImage() {
        guard let data = renderedData() else { return showToast("导出失败") }
        onComplete(data)
    }

    private func renderedData() -> Data? {
        MarkupRenderer.pngData(source: source, elements: elements)
    }

    private var selectedElementIndex: Int? {
        guard let selectedElementID else { return nil }
        return elements.firstIndex(where: { $0.id == selectedElementID })
    }

    private var selectedElement: MarkupElement? {
        selectedElementIndex.map { elements[$0] }
    }

    private var activeColor: MarkupColor {
        selectedElement?.color ?? color
    }

    private var activeStrokeStyle: MarkupStrokeStyle {
        selectedElement?.strokeStyle ?? strokeStyle
    }

    private var activeStrokeWidth: Binding<Double> {
        Binding(
            get: { Double(selectedElement?.strokeWidth ?? CGFloat(strokeWidth)) },
            set: { newValue in
                if let index = selectedElementIndex {
                    elements[index].strokeWidth = newValue
                } else {
                    strokeWidth = newValue
                }
            }
        )
    }

    private var activeStrokeWidthRange: ClosedRange<Double> {
        if selectedElement.map(isAreaEffect) == true || tool.supportsAreaShape {
            return 4...80
        }
        return 1...24
    }

    private var widthLabel: String {
        let value = Int(activeStrokeWidth.wrappedValue.rounded())
        return (selectedElement.map(isAreaEffect) == true || tool.supportsAreaShape)
            ? "笔触 \(value) px"
            : "线宽 \(value) px"
    }

    private var showsStrokeStyle: Bool {
        tool.supportsStrokeStyle || selectedElement.map(supportsStrokeStyle) == true
    }

    private func selectTool(_ candidate: MarkupTool) {
        tool = candidate
        onToolSelected()
        if candidate.supportsAreaShape, strokeWidth < 12 {
            strokeWidth = 24
        }
    }

    private func commit(_ element: MarkupElement) {
        recordUndo()
        elements.append(element)
        selectedElementID = element.id
    }

    private func recordUndo() {
        history.record(elements)
    }

    private func undo() {
        guard let previous = history.undo(current: elements) else { return }
        elements = previous
        selectedElementID = nil
    }

    private func redo() {
        guard let next = history.redo(current: elements) else { return }
        elements = next
        selectedElementID = nil
    }

    private func deleteSelectedElement() {
        guard let index = selectedElementIndex else { return }
        recordUndo()
        elements.remove(at: index)
        selectedElementID = nil
    }

    private func updateElement(_ element: MarkupElement) {
        guard let index = elements.firstIndex(where: { $0.id == element.id }) else { return }
        elements[index] = element
    }

    private func handlePickMiss() {
        showToast(isRecognizingContent ? "正在识别界面元素，请稍候再试" : "未识别到该位置的界面元素")
    }

    private func setColor(_ value: MarkupColor) {
        color = value
        guard let index = selectedElementIndex else { return }
        recordUndo()
        elements[index].color = value
    }

    private func setStrokeStyle(_ value: MarkupStrokeStyle) {
        strokeStyle = value
        guard let index = selectedElementIndex else { return }
        recordUndo()
        elements[index].strokeStyle = value
    }

    private func isAreaEffect(_ element: MarkupElement) -> Bool {
        switch element.shape {
        case .highlight, .mosaic, .blur, .eraser: true
        default: false
        }
    }

    private func supportsStrokeStyle(_ element: MarkupElement) -> Bool {
        switch element.shape {
        case .rect, .roundedRect, .ellipse, .line, .polyline, .arrow, .freehand: true
        default: false
        }
    }

    private func showToast(_ message: String) {
        withAnimation(.easeOut(duration: 0.15)) { toast = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeIn(duration: 0.2)) { toast = nil }
        }
    }
}

private struct MarkupCanvas: NSViewRepresentable {
    let source: MarkupImageSource
    let displaySize: CGSize
    let contentBlockBounds: [CGRect]
    let contentFallbackBounds: [CGRect]
    let elements: [MarkupElement]
    let tool: MarkupTool
    let color: MarkupColor
    let strokeWidth: Double
    let strokeStyle: MarkupStrokeStyle
    let areaShape: MarkupAreaShape
    let nextCounterNumber: Int
    let selectedElementID: UUID?
    let onCommit: (MarkupElement) -> Void
    let onSelect: (UUID?) -> Void
    let onBeginMutation: () -> Void
    let onUpdateElement: (MarkupElement) -> Void
    let onDeleteSelection: () -> Void
    let onPickMiss: () -> Void

    func makeNSView(context: Context) -> MarkupCanvasView {
        let view = MarkupCanvasView(frame: CGRect(origin: .zero, size: displaySize))
        update(view)
        return view
    }

    func updateNSView(_ nsView: MarkupCanvasView, context: Context) {
        update(nsView)
    }

    private func update(_ view: MarkupCanvasView) {
        let sourceBounds = CGRect(origin: .zero, size: source.size)
        let displayBounds = CGRect(origin: .zero, size: displaySize)
        let displayScale = min(
            displaySize.width / max(source.size.width, 1),
            displaySize.height / max(source.size.height, 1)
        )
        if view.tool != tool { view.cancelPendingInteraction() }
        view.source = source
        view.displayImage = NSImage(cgImage: source.cgImage, size: displaySize)
        view.displayBlockBounds = contentBlockBounds.map {
            scaledRect($0, to: displayBounds, from: sourceBounds)
        }
        view.displayFallbackBounds = contentFallbackBounds.map {
            scaledRect($0, to: displayBounds, from: sourceBounds)
        }
        view.elements = elements.map { $0.scaled(to: displayBounds, from: sourceBounds) }
        view.tool = tool
        view.color = color
        view.strokeWidth = max(0.5, strokeWidth * displayScale)
        view.strokeStyle = strokeStyle
        view.areaShape = areaShape
        view.nextCounterNumber = nextCounterNumber
        view.selectedElementID = selectedElementID
        view.onCommit = { onCommit($0.scaled(to: sourceBounds, from: displayBounds)) }
        view.onSelect = onSelect
        view.onBeginMutation = onBeginMutation
        view.onUpdateElement = { onUpdateElement($0.scaled(to: sourceBounds, from: displayBounds)) }
        view.onDeleteSelection = onDeleteSelection
        view.onPickMiss = onPickMiss
        view.needsDisplay = true
    }

    private func scaledRect(_ rect: CGRect, to target: CGRect, from original: CGRect) -> CGRect {
        guard original.width > 0, original.height > 0 else { return rect }
        let scaleX = target.width / original.width
        let scaleY = target.height / original.height
        return CGRect(
            x: target.minX + (rect.minX - original.minX) * scaleX,
            y: target.minY + (rect.minY - original.minY) * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        )
    }
}

private enum ElementEditMode: Equatable {
    case none
    case move
    case resize(CaptureResizeHandle)
}

private final class MarkupCanvasView: NSView, NSTextViewDelegate {
    var source: MarkupImageSource?
    var displayImage: NSImage?
    var displayBlockBounds: [CGRect] = []
    var displayFallbackBounds: [CGRect] = []
    var elements: [MarkupElement] = []
    var tool: MarkupTool = .arrow
    var color: MarkupColor = .red
    var strokeWidth: Double = 4
    var strokeStyle: MarkupStrokeStyle = .solid
    var areaShape: MarkupAreaShape = .freehand
    var nextCounterNumber = 1
    var selectedElementID: UUID?
    var onCommit: ((MarkupElement) -> Void)?
    var onSelect: ((UUID?) -> Void)?
    var onBeginMutation: (() -> Void)?
    var onUpdateElement: ((MarkupElement) -> Void)?
    var onDeleteSelection: (() -> Void)?
    var onPickMiss: (() -> Void)?

    private var dragStart: CGPoint?
    private var dragEnd: CGPoint?
    private var dragPoints: [CGPoint] = []
    private var polylinePoints: [CGPoint] = []
    private var didBeginSelectionMutation = false
    private var pendingSelectionElementID: UUID?
    private weak var inlineTextScrollView: NSScrollView?
    private weak var inlineTextView: NSTextView?
    private var inlineTextOrigin: CGPoint?
    /// 正在二次编辑的原有文字元素（nil 表示新建文字）。
    private var inlineEditOriginal: MarkupElement?
    /// 悬停高亮的元素（仅绘制提示，不改变选中态）。
    private var hoveredElementID: UUID?
    /// 已选中元素的编辑模式：移动或按手柄调整大小。
    private var elementEditMode: ElementEditMode = .none
    /// 元素编辑起点与原始元素（拖拽基于原始值计算，避免累积误差）。
    private var editDragStart: CGPoint?
    private var elementEditOriginal: MarkupElement?
    private var pointerTrackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        pointerTrackingArea = area
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard source != nil, let baseImage = displayImage else { return }
        baseImage.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
        MarkupRenderer.draw(elements: elements, on: baseImage)
        if let element = previewElement {
            MarkupRenderer.draw(elements: [element], on: baseImage)
        }
        if let selectedElementID,
           let element = elements.first(where: { $0.id == selectedElementID }) {
            MarkupGeometry.drawSelection(for: element)
        }
        if let hoveredElementID,
           hoveredElementID != selectedElementID,
           let element = elements.first(where: { $0.id == hoveredElementID }) {
            MarkupGeometry.drawHover(for: element)
        }
    }

    /// 矩形/椭圆类工具与矩形填充画笔支持：右键自动框选鼠标下的界面元素。
    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard isElementPickingTool else { return }
        let point = clamped(convert(event.locationInWindow, from: nil))
        guard let rect = pickedElementRect(at: point) else {
            onPickMiss?()
            return
        }
        commit(shape: elementShape(for: rect))
    }

    /// 当前工具是否支持右键自动框选界面元素。
    private var isElementPickingTool: Bool {
        switch tool {
        case .rectangle, .roundedRectangle, .ellipse: true
        case .highlight, .mosaic, .blur, .eraser: true
        default: false
        }
    }

    /// 拾取鼠标位置下的界面元素边界（视图坐标）；找不到或过小返回 nil。
    /// Vision 候选与未翻转的 AppKit 画布均使用左下原点，无需转换 y。
    private func pickedElementRect(at localPoint: CGPoint) -> CGRect? {
        guard source != nil else { return nil }
        guard let rect = ScreenshotContentPicker.pageElementRect(
            at: localPoint,
            imageSize: bounds.size,
            blockBounds: displayBlockBounds,
            fallbackBounds: displayFallbackBounds
        ) else { return nil }
        guard rect.width > 4, rect.height > 4 else { return nil }
        return rect
    }

    /// 由元素边界生成当前工具对应的标注形状。
    private func elementShape(for rect: CGRect) -> MarkupShape {
        let start = rect.origin
        let end = CGPoint(x: rect.maxX, y: rect.maxY)
        switch tool {
        case .rectangle: return .rect(rect)
        case .roundedRectangle: return .roundedRect(rect)
        case .ellipse: return .ellipse(rect)
        case .highlight: return .highlight(points: [start, end], areaShape: .rectangle)
        case .mosaic: return .mosaic(points: [start, end], areaShape: .rectangle)
        case .blur: return .blur(points: [start, end], areaShape: .rectangle)
        case .eraser: return .eraser(points: [start, end], areaShape: .rectangle)
        default: return .rect(rect)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = clamped(convert(event.locationInWindow, from: nil))

        // 普通拖动始终新建标注；控制点直接缩放，Command 拖动临时移动已有标注。
        let selectedElement = selectedElementID.flatMap(element(withID:))
        let selectedResizeHandle = selectedElement.flatMap { resizeHandle(at: point, for: $0) }
        let hitElement = hitElement(at: point)
        if event.clickCount == 2, let hitElement, case .text = hitElement.shape {
            onSelect?(hitElement.id)
            selectedElementID = hitElement.id
            beginInlineText(at: point, editing: hitElement)
            return
        }
        let pointerRoute = MarkupInteractionPolicy.primaryPointerRoute(
            moveModifierPressed: event.modifierFlags.contains(.command),
            selectedElementID: selectedElement?.id,
            selectedResizeHandle: selectedResizeHandle,
            hitElementID: hitElement?.id
        )
        switch pointerRoute {
        case .resizeExistingElement(let id, let handle):
            guard let element = element(withID: id) else { break }
            beginElementEdit(element, mode: .resize(handle), at: point)
            return
        case .moveExistingElement(let id):
            guard let element = element(withID: id) else { break }
            beginElementEdit(element, mode: .move, at: point)
            return
        case .activeTool:
            break
        }

        onSelect?(nil)
        selectedElementID = nil
        pendingSelectionElementID = nil

        switch tool {
        case .text:
            beginInlineText(at: point)
        case .counter:
            commit(shape: .counter(nextCounterNumber, center: point))
        case .polyline:
            addPolylinePoint(point, clickCount: event.clickCount)
        default:
            pendingSelectionElementID = hitElement?.id
            dragStart = point
            dragEnd = point
            dragPoints = [point]
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        // 已选中元素的移动 / 调整大小
        if elementEditMode != .none,
           let original = elementEditOriginal,
           let start = editDragStart {
            let point = clamped(convert(event.locationInWindow, from: nil))
            let delta = CGSize(width: point.x - start.x, height: point.y - start.y)
            guard hypot(delta.width, delta.height) > 0 else { return }
            if !didBeginSelectionMutation {
                onBeginMutation?()
                didBeginSelectionMutation = true
            }
            switch elementEditMode {
            case .move:
                // 基于原始元素计算绝对位置（幂等），避免增量累加漂移
                var updated = original
                updated.shape = original.shape.translated(by: delta)
                onUpdateElement?(updated)
            case .resize(let handle):
                let originalBounds = MarkupGeometry.bounds(for: original)
                let newBounds = CaptureResizeHandle.resizedRect(original: originalBounds, handle: handle, current: point)
                if let updated = resizedElement(original, to: newBounds) {
                    onUpdateElement?(updated)
                }
            case .none:
                break
            }
            needsDisplay = true
            return
        }
        guard let start = dragStart else { return }
        let rawPoint = clamped(convert(event.locationInWindow, from: nil))
        let point = constrainedEnd(rawPoint, from: start, modifiers: event.modifierFlags)
        if hypot(point.x - start.x, point.y - start.y) > 3 {
            pendingSelectionElementID = nil
        }
        dragEnd = point
        if tool.usesFreehandDrag || (tool.supportsAreaShape && areaShape == .freehand) {
            if dragPoints.last.map({ hypot($0.x - point.x, $0.y - point.y) > 1.5 }) ?? true {
                dragPoints.append(point)
            }
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if elementEditMode != .none {
            elementEditMode = .none
            elementEditOriginal = nil
            editDragStart = nil
            didBeginSelectionMutation = false
            let point = clamped(convert(event.locationInWindow, from: nil))
            updateCursor(at: point, modifiers: event.modifierFlags)
            needsDisplay = true
            return
        }
        guard let start = dragStart else { return }
        let rawPoint = clamped(convert(event.locationInWindow, from: nil))
        let end = constrainedEnd(rawPoint, from: start, modifiers: event.modifierFlags)
        if dragPoints.last != end { dragPoints.append(end) }

        let points = dragPoints
        let pendingSelectionElementID = pendingSelectionElementID
        self.pendingSelectionElementID = nil
        clearDrag()
        guard hypot(end.x - start.x, end.y - start.y) > 3 else {
            if let pendingSelectionElementID {
                onSelect?(pendingSelectionElementID)
                selectedElementID = pendingSelectionElementID
            }
            updateCursor(at: end, modifiers: event.modifierFlags)
            needsDisplay = true
            return
        }
        guard let shape = tool.shape(
                from: start,
                to: end,
                points: points,
                areaShape: areaShape,
                counterNumber: nextCounterNumber
              )
        else {
            needsDisplay = true
            return
        }
        commit(shape: shape)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = clamped(convert(event.locationInWindow, from: nil))
        let hovered = hitElement(at: point)?.id
        if hovered != hoveredElementID {
            hoveredElementID = hovered
            needsDisplay = true
        }
        updateCursor(at: point, modifiers: event.modifierFlags)
    }

    override func mouseExited(with event: NSEvent) {
        hoveredElementID = nil
        NSCursor.arrow.set()
        needsDisplay = true
    }

    override func cursorUpdate(with event: NSEvent) {
        let point = clamped(convert(event.locationInWindow, from: nil))
        updateCursor(at: point, modifiers: event.modifierFlags)
    }

    override func flagsChanged(with event: NSEvent) {
        if let window {
            let point = clamped(convert(window.mouseLocationOutsideOfEventStream, from: nil))
            updateCursor(at: point, modifiers: event.modifierFlags)
        }
        super.flagsChanged(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if tool == .polyline, event.keyCode == 36 || event.keyCode == 76 {
            finishPolyline()
            return
        }
        if event.keyCode == 53 {
            cancelPendingInteraction()
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 {
            onDeleteSelection?()
            return
        }
        super.keyDown(with: event)
    }

    func cancelPendingInteraction() {
        finishInlineText(commit: true)
        clearDrag()
        polylinePoints.removeAll()
        pendingSelectionElementID = nil
        elementEditMode = .none
        elementEditOriginal = nil
        editDragStart = nil
        didBeginSelectionMutation = false
        activeToolCursor.set()
        needsDisplay = true
    }

    private func addPolylinePoint(_ point: CGPoint, clickCount: Int) {
        if polylinePoints.last.map({ hypot($0.x - point.x, $0.y - point.y) > 2 }) ?? true {
            polylinePoints.append(point)
        }
        needsDisplay = true
        if clickCount >= 2 { finishPolyline() }
    }

    private func finishPolyline() {
        guard polylinePoints.count > 1 else {
            polylinePoints.removeAll()
            needsDisplay = true
            return
        }
        let points = polylinePoints
        polylinePoints.removeAll()
        commit(shape: .polyline(points))
    }

    private func beginInlineText(at point: CGPoint, editing element: MarkupElement? = nil) {
        finishInlineText(commit: true)
        var origin = point
        var text = ""
        var textColor = color.nsColor
        var fontSize = max(14, strokeWidth * 4)
        if let element, case .text(let existing, let textOrigin) = element.shape {
            origin = textOrigin
            text = existing
            textColor = element.color.nsColor
            fontSize = max(14, element.strokeWidth * 4)
        }
        let editorWidth = min(MarkupTextLayout.maximumWidth, max(120, bounds.maxX - origin.x))
        let editorY = min(max(bounds.minY, origin.y - 3), max(bounds.minY, bounds.maxY - 44))
        let editorHeight = min(max(fontSize + 18, 44), max(24, bounds.maxY - editorY))
        let scrollView = NSScrollView(frame: NSRect(
            x: origin.x,
            y: editorY,
            width: editorWidth,
            height: editorHeight
        ))
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.82)
        scrollView.autohidesScrollers = true
        scrollView.toolTip = "Enter 换行，⌘Enter 完成，Esc 取消"

        let textView = NSTextView(frame: NSRect(origin: .zero, size: scrollView.contentSize))
        textView.delegate = self
        textView.font = .systemFont(ofSize: fontSize, weight: .semibold)
        textView.textColor = textColor
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: .greatestFiniteMagnitude
        )
        textView.string = text
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))

        scrollView.documentView = textView
        addSubview(scrollView)
        inlineTextScrollView = scrollView
        inlineTextView = textView
        inlineTextOrigin = origin
        inlineEditOriginal = element
        window?.makeFirstResponder(textView)
        resizeInlineTextEditor()
    }

    func textDidChange(_ notification: Notification) {
        resizeInlineTextEditor()
    }

    func textDidEndEditing(_ notification: Notification) {
        finishInlineText(commit: true)
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            let action = MarkupTextEditingPolicy.returnAction(
                commandModifierPressed: NSApp.currentEvent?.modifierFlags.contains(.command) == true
            )
            if action == .finishEditing {
                finishInlineText(commit: true)
            } else {
                textView.insertText("\n", replacementRange: textView.selectedRange())
                resizeInlineTextEditor()
            }
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            finishInlineText(commit: false)
            return true
        }
        return false
    }

    private func resizeInlineTextEditor() {
        guard let scrollView = inlineTextScrollView,
              let textView = inlineTextView,
              let textContainer = textView.textContainer,
              let layoutManager = textView.layoutManager
        else { return }

        layoutManager.ensureLayout(for: textContainer)
        let usedHeight = layoutManager.usedRect(for: textContainer).height
        let desiredHeight = max(44, ceil(usedHeight + textView.textContainerInset.height * 2 + 6))
        let maximumHeight = min(240, max(44, bounds.maxY - scrollView.frame.minY))
        var frame = scrollView.frame
        frame.size.height = min(desiredHeight, maximumHeight)
        scrollView.frame = frame

        let contentSize = scrollView.contentSize
        textContainer.containerSize = NSSize(width: contentSize.width, height: .greatestFiniteMagnitude)
        textView.frame.size = NSSize(width: contentSize.width, height: max(contentSize.height, desiredHeight))
        scrollView.hasVerticalScroller = desiredHeight > maximumHeight
        textView.scrollRangeToVisible(textView.selectedRange())
    }

    private func finishInlineText(commit shouldCommit: Bool) {
        guard let scrollView = inlineTextScrollView, let textView = inlineTextView else { return }
        let origin = inlineTextOrigin
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let editingElement = inlineEditOriginal
        textView.delegate = nil
        inlineTextScrollView = nil
        inlineTextView = nil
        inlineTextOrigin = nil
        inlineEditOriginal = nil
        scrollView.removeFromSuperview()
        window?.makeFirstResponder(self)
        if shouldCommit {
            if let editingElement, let origin {
                // 二次编辑：保留元素 id 与自身样式，仅更新文本内容
                if !text.isEmpty {
                    var updated = editingElement
                    updated.shape = .text(text, origin: origin)
                    onUpdateElement?(updated)
                }
            } else if !text.isEmpty, let origin {
                commit(shape: .text(text, origin: origin))
            }
        }
    }

    private func commit(shape: MarkupShape) {
        onCommit?(MarkupElement(
            shape: shape,
            color: color,
            strokeWidth: strokeWidth,
            strokeStyle: tool.supportsStrokeStyle ? strokeStyle : .solid
        ))
        needsDisplay = true
    }

    private var previewElement: MarkupElement? {
        if tool == .polyline, polylinePoints.count > 1 {
            return element(shape: .polyline(polylinePoints))
        }
        guard let start = dragStart, let end = dragEnd,
              let shape = tool.shape(
                from: start,
                to: end,
                points: dragPoints,
                areaShape: areaShape,
                counterNumber: nextCounterNumber
              )
        else { return nil }
        return element(shape: shape)
    }

    private func element(shape: MarkupShape) -> MarkupElement {
        MarkupElement(
            shape: shape,
            color: color,
            strokeWidth: strokeWidth,
            strokeStyle: tool.supportsStrokeStyle ? strokeStyle : .solid
        )
    }

    private func clearDrag() {
        dragStart = nil
        dragEnd = nil
        dragPoints.removeAll()
    }

    private func constrainedEnd(
        _ point: CGPoint,
        from start: CGPoint,
        modifiers: NSEvent.ModifierFlags
    ) -> CGPoint {
        let isEllipticalArea = tool.supportsAreaShape && areaShape == .ellipse
        let constrainsAspect = tool == .rectangle || tool == .roundedRectangle || tool == .ellipse || isEllipticalArea
        guard constrainsAspect, modifiers.contains(.shift) else { return point }
        let dx = point.x - start.x
        let dy = point.y - start.y
        let side = max(abs(dx), abs(dy))
        return clamped(CGPoint(
            x: start.x + (dx < 0 ? -side : side),
            y: start.y + (dy < 0 ? -side : side)
        ))
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }

    private func hitElement(at point: CGPoint) -> MarkupElement? {
        elements.reversed().first { MarkupGeometry.hitTest($0, at: point) }
    }

    private func element(withID id: UUID) -> MarkupElement? {
        elements.first { $0.id == id }
    }

    private func resizeHandle(at point: CGPoint, for element: MarkupElement) -> CaptureResizeHandle? {
        let selectionBounds = MarkupGeometry.bounds(for: element).insetBy(dx: -5, dy: -5)
        return CaptureResizeHandle.allCases.first {
            let anchor = $0.anchorPoint(in: selectionBounds)
            return hypot(anchor.x - point.x, anchor.y - point.y) <= 8
        }
    }

    private func beginElementEdit(_ element: MarkupElement, mode: ElementEditMode, at point: CGPoint) {
        onSelect?(element.id)
        selectedElementID = element.id
        elementEditMode = mode
        elementEditOriginal = element
        editDragStart = point
        didBeginSelectionMutation = false
        switch mode {
        case .move: NSCursor.closedHand.set()
        case .resize(let handle): resizeCursor(for: handle).set()
        case .none: break
        }
        needsDisplay = true
    }

    private func updateCursor(at point: CGPoint, modifiers: NSEvent.ModifierFlags) {
        if let selectedElementID,
           let selectedElement = element(withID: selectedElementID),
           let handle = resizeHandle(at: point, for: selectedElement) {
            resizeCursor(for: handle).set()
            return
        }
        if modifiers.contains(.command), hitElement(at: point) != nil {
            (elementEditMode == .move ? NSCursor.closedHand : NSCursor.openHand).set()
            return
        }
        activeToolCursor.set()
    }

    private var activeToolCursor: NSCursor {
        tool == .text ? .iBeam : .crosshair
    }

    private func resizeCursor(for handle: CaptureResizeHandle) -> NSCursor {
        if #available(macOS 15.0, *) {
            return .frameResize(position: frameResizePosition(for: handle), directions: .all)
        }
        switch handle {
        case .top, .bottom: return .resizeUpDown
        case .left, .right: return .resizeLeftRight
        case .topLeft, .bottomRight: return Self.diagonalDownCursor
        case .topRight, .bottomLeft: return Self.diagonalUpCursor
        }
    }

    private static let diagonalDownCursor = diagonalResizeCursor(
        symbolName: "arrow.up.left.and.arrow.down.right"
    )

    private static let diagonalUpCursor = diagonalResizeCursor(
        symbolName: "arrow.up.right.and.arrow.down.left"
    )

    private static func diagonalResizeCursor(symbolName: String) -> NSCursor {
        guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else {
            return .crosshair
        }
        let size = NSSize(width: 20, height: 20)
        let image = NSImage(size: size, flipped: false) { rect in
            symbol.draw(in: rect.insetBy(dx: 2, dy: 2))
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: size.width / 2, y: size.height / 2))
    }

    @available(macOS 15.0, *)
    private func frameResizePosition(for handle: CaptureResizeHandle) -> NSCursor.FrameResizePosition {
        switch handle {
        case .topLeft: .topLeft
        case .top: .top
        case .topRight: .topRight
        case .left: .left
        case .right: .right
        case .bottomLeft: .bottomLeft
        case .bottom: .bottom
        case .bottomRight: .bottomRight
        }
    }

    /// 依据新的包围盒缩放元素；文字/数字通过字号调整，其余几何形状直接缩放。
    private func resizedElement(_ element: MarkupElement, to newBounds: CGRect) -> MarkupElement? {
        var updated = element
        switch element.shape {
        case .text(let text, _):
            let scale = max(0.2, min(4, newBounds.width / max(1, MarkupGeometry.bounds(for: element).width)))
            updated.strokeWidth = max(3.5, (element.strokeWidth * scale).rounded())
            updated.shape = .text(text, origin: newBounds.origin)
        case .counter(let number, let center):
            let diameter = max(24, element.strokeWidth * 7)
            let scale = max(0.2, min(4, newBounds.width / max(1, diameter)))
            updated.strokeWidth = max(3.5, (element.strokeWidth * scale).rounded())
            updated.shape = .counter(number, center: center)
        default:
            updated.shape = element.shape.scaled(to: newBounds, from: MarkupGeometry.bounds(for: element))
        }
        return updated
    }
}

private enum MarkupTextLayout {
    static let maximumWidth: CGFloat = 320

    static func size(for text: String, fontSize: CGFloat) -> CGSize {
        let rect = (text as NSString).boundingRect(
            with: CGSize(width: maximumWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: .semibold)]
        )
        return CGSize(width: max(1, ceil(rect.width)), height: max(fontSize, ceil(rect.height)))
    }
}

private enum MarkupGeometry {
    static func bounds(for element: MarkupElement) -> CGRect {
        switch element.shape {
        case .rect(let rect), .roundedRect(let rect), .ellipse(let rect):
            return rect
        case .arrow(let start, let end), .line(let start, let end):
            return pointsBounds([start, end]).insetBy(dx: -element.strokeWidth, dy: -element.strokeWidth)
        case .polyline(let points), .freehand(let points):
            return pointsBounds(points).insetBy(dx: -element.strokeWidth, dy: -element.strokeWidth)
        case .highlight(let points, let areaShape),
             .mosaic(let points, let areaShape),
             .blur(let points, let areaShape),
             .eraser(let points, let areaShape):
            if areaShape == .freehand {
                return pointsBounds(points).insetBy(dx: -element.strokeWidth / 2, dy: -element.strokeWidth / 2)
            }
            guard let first = points.first, let last = points.last else { return .zero }
            return CaptureRegion.normalized(from: first, to: last)
        case .text(let text, let origin):
            let fontSize = max(14, element.strokeWidth * 4)
            return CGRect(origin: origin, size: MarkupTextLayout.size(for: text, fontSize: fontSize))
        case .counter(_, let center):
            let diameter = max(24, element.strokeWidth * 7)
            return CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
        case .magnifier(let center, let radius, _):
            return CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        }
    }

    static func hitTest(_ element: MarkupElement, at point: CGPoint) -> Bool {
        switch element.shape {
        case .arrow(let start, let end), .line(let start, let end):
            return distance(from: point, toSegmentFrom: start, to: end) <= hitTolerance(for: element)
        case .polyline(let points), .freehand(let points):
            return zip(points, points.dropFirst()).contains {
                distance(from: point, toSegmentFrom: $0.0, to: $0.1) <= hitTolerance(for: element)
            }
        case .ellipse(let rect):
            let rx = max(1, rect.width / 2 + 6)
            let ry = max(1, rect.height / 2 + 6)
            let dx = (point.x - rect.midX) / rx
            let dy = (point.y - rect.midY) / ry
            return dx * dx + dy * dy <= 1
        case .counter(_, let center):
            let diameter = max(24, element.strokeWidth * 7)
            return hypot(point.x - center.x, point.y - center.y) <= diameter / 2 + 6
        case .magnifier(let center, let radius, _):
            return hypot(point.x - center.x, point.y - center.y) <= radius + 6
        default:
            return bounds(for: element).insetBy(dx: -10, dy: -10).contains(point)
        }
    }

    private static func hitTolerance(for element: MarkupElement) -> CGFloat {
        max(10, element.strokeWidth / 2 + 6)
    }

    static func drawSelection(for element: MarkupElement) {
        let rect = bounds(for: element).insetBy(dx: -5, dy: -5)
        guard !rect.isEmpty else { return }
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        path.lineWidth = 1.5
        let pattern: [CGFloat] = [5, 3]
        path.setLineDash(pattern, count: pattern.count, phase: 0)
        path.stroke()
        // 8 个调整大小手柄：四角 + 四边中点
        for handle in CaptureResizeHandle.allCases {
            let point = handle.anchorPoint(in: rect)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(ovalIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)).fill()
        }
    }

    /// 悬停提示：淡色虚线框，不改变选中态。
    static func drawHover(for element: MarkupElement) {
        let rect = bounds(for: element).insetBy(dx: -5, dy: -5)
        guard !rect.isEmpty else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.5).setStroke()
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        path.lineWidth = 1
        let pattern: [CGFloat] = [4, 3]
        path.setLineDash(pattern, count: pattern.count, phase: 0)
        path.stroke()
    }

    private static func pointsBounds(_ points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        let minX = xs.min() ?? first.x
        let maxX = xs.max() ?? first.x
        let minY = ys.min() ?? first.y
        let maxY = ys.max() ?? first.y
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func distance(
        from point: CGPoint,
        toSegmentFrom start: CGPoint,
        to end: CGPoint
    ) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - start.x, point.y - start.y) }
        let projection = min(1, max(0, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
        let closest = CGPoint(x: start.x + projection * dx, y: start.y + projection * dy)
        return hypot(point.x - closest.x, point.y - closest.y)
    }
}

@MainActor
private enum MarkupRenderer {
    private static let ciContext = CIContext(options: [.cacheIntermediates: true])

    static func pngData(source: MarkupImageSource, elements: [MarkupElement]) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(source.size.width),
            pixelsHigh: Int(source.size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = source.displaySize

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        source.image.draw(
            in: CGRect(origin: .zero, size: source.size),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        draw(elements: elements, on: source.image)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    static func draw(elements: [MarkupElement], on baseImage: NSImage) {
        for element in elements {
            draw(element: element, on: baseImage)
        }
    }

    private static func draw(element: MarkupElement, on baseImage: NSImage) {
        let color = element.color.nsColor
        let width = element.strokeWidth

        switch element.shape {
        case .arrow(let start, let end):
            let path = linePath([start, end])
            stroke(path, color: color, element: element)
            color.setFill()
            arrowHead(start: start, end: end, width: width).fill()

        case .rect(let rect):
            stroke(NSBezierPath(rect: rect), color: color, element: element)

        case .roundedRect(let rect):
            let radius = min(16, min(rect.width, rect.height) / 4)
            stroke(NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius), color: color, element: element)

        case .ellipse(let rect):
            stroke(NSBezierPath(ovalIn: rect), color: color, element: element)

        case .line(let start, let end):
            stroke(linePath([start, end]), color: color, element: element)

        case .polyline(let points), .freehand(let points):
            stroke(linePath(points), color: color, element: element)

        case .highlight(let points, let areaShape):
            drawHighlight(points: points, areaShape: areaShape, color: color, width: width)

        case .mosaic(let points, let areaShape):
            clip(points: points, areaShape: areaShape, width: max(4, width)) {
                drawMosaic(in: effectBounds(points: points, areaShape: areaShape, width: width), from: baseImage)
            }

        case .blur(let points, let areaShape):
            clip(points: points, areaShape: areaShape, width: max(4, width)) {
                drawBlurred(baseImage)
            }

        case .text(let text, let origin):
            let fontSize = max(14, width * 4)
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
            shadow.shadowBlurRadius = 2
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            let attributedText = NSAttributedString(
                string: text,
                attributes: [
                    .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
                    .foregroundColor: color,
                    .shadow: shadow,
                ]
            )
            attributedText.draw(
                with: CGRect(origin: origin, size: MarkupTextLayout.size(for: text, fontSize: fontSize)),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )

        case .eraser(let points, let areaShape):
            clip(points: points, areaShape: areaShape, width: max(4, width)) {
                baseImage.draw(
                    in: CGRect(origin: .zero, size: baseImage.size),
                    from: .zero,
                    operation: .copy,
                    fraction: 1
                )
            }

        case .counter(let number, let center):
            drawCounter(number, center: center, color: color, diameter: max(24, width * 7))

        case .magnifier(let center, let radius, let scale):
            drawMagnifier(center: center, radius: radius, scale: scale, baseImage: baseImage)
        }
    }

    private static func stroke(_ path: NSBezierPath, color: NSColor, element: MarkupElement) {
        color.setStroke()
        path.lineWidth = element.strokeWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        switch element.strokeStyle {
        case .solid:
            break
        case .dashed:
            let pattern = [element.strokeWidth * 3, element.strokeWidth * 2]
            path.setLineDash(pattern, count: pattern.count, phase: 0)
        case .dotted:
            let pattern = [element.strokeWidth * 0.12, element.strokeWidth * 2]
            path.setLineDash(pattern, count: pattern.count, phase: 0)
        }
        path.stroke()
    }

    private static func linePath(_ points: [CGPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() { path.line(to: point) }
        return path
    }

    private static func arrowHead(start: CGPoint, end: CGPoint, width: CGFloat) -> NSBezierPath {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLength = max(12, width * 3.5)
        let spread = CGFloat.pi / 7
        let left = CGPoint(
            x: end.x - headLength * cos(angle - spread),
            y: end.y - headLength * sin(angle - spread)
        )
        let right = CGPoint(
            x: end.x - headLength * cos(angle + spread),
            y: end.y - headLength * sin(angle + spread)
        )
        let head = NSBezierPath()
        head.move(to: end)
        head.line(to: left)
        head.line(to: right)
        head.close()
        return head
    }

    private static func drawHighlight(
        points: [CGPoint],
        areaShape: MarkupAreaShape,
        color: NSColor,
        width: CGFloat
    ) {
        let highlightColor = color.withAlphaComponent(0.3)
        switch areaShape {
        case .freehand:
            highlightColor.setStroke()
            let path = linePath(points)
            path.lineWidth = max(4, width)
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
        case .rectangle, .ellipse:
            highlightColor.setFill()
            areaPath(points: points, areaShape: areaShape).fill()
        }
    }

    private static func clip(
        points: [CGPoint],
        areaShape: MarkupAreaShape,
        width: CGFloat,
        drawing: () -> Void
    ) {
        NSGraphicsContext.saveGraphicsState()
        if areaShape == .freehand,
           let context = NSGraphicsContext.current?.cgContext {
            let path = linePath(points)
            context.addPath(path.cgPath)
            context.setLineWidth(width)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.replacePathWithStrokedPath()
            context.clip()
        } else {
            areaPath(points: points, areaShape: areaShape).addClip()
        }
        drawing()
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func areaPath(points: [CGPoint], areaShape: MarkupAreaShape) -> NSBezierPath {
        guard let first = points.first, let last = points.last else { return NSBezierPath() }
        let rect = CaptureRegion.normalized(from: first, to: last)
        return areaShape == .ellipse ? NSBezierPath(ovalIn: rect) : NSBezierPath(rect: rect)
    }

    private static func effectBounds(
        points: [CGPoint],
        areaShape: MarkupAreaShape,
        width: CGFloat
    ) -> CGRect {
        guard let first = points.first else { return .zero }
        if areaShape != .freehand, let last = points.last {
            return CaptureRegion.normalized(from: first, to: last)
        }
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        let inset = max(4, width) / 2
        return CGRect(
            x: (xs.min() ?? first.x) - inset,
            y: (ys.min() ?? first.y) - inset,
            width: (xs.max() ?? first.x) - (xs.min() ?? first.x) + inset * 2,
            height: (ys.max() ?? first.y) - (ys.min() ?? first.y) + inset * 2
        )
    }

    private static func drawMosaic(in rect: CGRect, from baseImage: NSImage) {
        guard rect.width > 1, rect.height > 1 else { return }
        let blockSize: CGFloat = 12
        let smallSize = NSSize(
            width: max(1, ceil(rect.width / blockSize)),
            height: max(1, ceil(rect.height / blockSize))
        )
        let pixelated = NSImage(size: smallSize)
        pixelated.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .none
        baseImage.draw(in: CGRect(origin: .zero, size: smallSize), from: rect, operation: .copy, fraction: 1)
        pixelated.unlockFocus()

        NSGraphicsContext.current?.imageInterpolation = .none
        pixelated.draw(in: rect, from: .zero, operation: .copy, fraction: 1)
    }

    private static func drawBlurred(_ baseImage: NSImage) {
        guard let input = CIImage(data: baseImage.tiffRepresentation ?? Data()) else { return }
        let filter = CIFilter(name: "CIGaussianBlur")
        filter?.setValue(input, forKey: kCIInputImageKey)
        filter?.setValue(10, forKey: kCIInputRadiusKey)
        guard let output = filter?.outputImage?.cropped(to: input.extent),
              let cgImage = ciContext.createCGImage(output, from: input.extent)
        else { return }
        NSImage(cgImage: cgImage, size: baseImage.size).draw(
            in: CGRect(origin: .zero, size: baseImage.size),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
    }

    private static func drawCounter(_ number: Int, center: CGPoint, color: NSColor, diameter: CGFloat) {
        let rect = CGRect(
            x: center.x - diameter / 2,
            y: center.y - diameter / 2,
            width: diameter,
            height: diameter
        )
        color.setFill()
        NSBezierPath(ovalIn: rect).fill()
        let text = NSAttributedString(
            string: String(number),
            attributes: [
                .font: NSFont.systemFont(ofSize: diameter * 0.52, weight: .bold),
                .foregroundColor: NSColor.white,
            ]
        )
        let size = text.size()
        text.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }

    private static func drawMagnifier(
        center: CGPoint,
        radius: CGFloat,
        scale: CGFloat,
        baseImage: NSImage
    ) {
        let destination = CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        let sourceSize = radius * 2 / scale
        let sourceRect = CGRect(
            x: center.x - sourceSize / 2,
            y: center.y - sourceSize / 2,
            width: sourceSize,
            height: sourceSize
        )
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(ovalIn: destination).addClip()
        baseImage.draw(in: destination, from: sourceRect, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        NSColor.white.setStroke()
        let outer = NSBezierPath(ovalIn: destination)
        outer.lineWidth = 6
        outer.stroke()
        NSColor.black.withAlphaComponent(0.7).setStroke()
        let inner = NSBezierPath(ovalIn: destination.insetBy(dx: 3, dy: 3))
        inner.lineWidth = 2
        inner.stroke()
    }
}

extension MarkupColor {
    var title: String {
        switch self {
        case .red: "红色"
        case .orange: "橙色"
        case .yellow: "黄色"
        case .green: "绿色"
        case .blue: "蓝色"
        case .black: "黑色"
        case .white: "白色"
        }
    }

    var nsColor: NSColor {
        switch self {
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .blue: .systemBlue
        case .black: .black
        case .white: .white
        }
    }
}

private extension MarkupStrokeStyle {
    var title: String {
        switch self {
        case .solid: "实线"
        case .dashed: "虚线"
        case .dotted: "点线"
        }
    }

    var symbol: String {
        switch self {
        case .solid: "line.diagonal"
        case .dashed: "line.3.horizontal"
        case .dotted: "ellipsis"
        }
    }
}

private extension MarkupAreaShape {
    var title: String {
        switch self {
        case .freehand: "涂抹"
        case .rectangle: "矩形"
        case .ellipse: "椭圆/圆形"
        }
    }

    var symbol: String {
        switch self {
        case .freehand: "scribble"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        }
    }
}
