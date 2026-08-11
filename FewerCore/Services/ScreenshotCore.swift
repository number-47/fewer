import Accelerate
import CoreGraphics
import Foundation

public enum ScreenshotPixelGeometry {
    public static func outputSize(pointSize: CGSize, pointPixelScale: CGFloat) -> CGSize {
        let scale = max(pointPixelScale, 1)
        return CGSize(
            width: max(ceil(pointSize.width * scale), 1),
            height: max(ceil(pointSize.height * scale), 1)
        )
    }

    public static func cropRect(
        pointRect: CGRect,
        displayFrame: CGRect,
        pointPixelScale: CGFloat
    ) -> CGRect {
        let scale = max(pointPixelScale, 1)
        let minX = floor((pointRect.minX - displayFrame.minX) * scale)
        let minY = floor((pointRect.minY - displayFrame.minY) * scale)
        let maxX = ceil((pointRect.maxX - displayFrame.minX) * scale)
        let maxY = ceil((pointRect.maxY - displayFrame.minY) * scale)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// 将截图编辑栏优先放在选区下方；空间不足时移到上方，并按真实尺寸限制在屏幕内。
public enum ScreenshotToolbarLayout {
    public static let compactHeight: CGFloat = 40

    public static func compactWidth(
        containerWidth: CGFloat,
        maximum: CGFloat = 860,
        margin: CGFloat = 8
    ) -> CGFloat {
        min(maximum, max(containerWidth - margin * 2, 0))
    }

    public static func position(
        selection: CGRect,
        containerSize: CGSize,
        toolbarSize: CGSize,
        spacing: CGFloat = 10,
        margin: CGFloat = 8
    ) -> CGPoint {
        let halfWidth = toolbarSize.width / 2
        let halfHeight = toolbarSize.height / 2
        let x = min(
            max(selection.midX, halfWidth + margin),
            containerSize.width - halfWidth - margin
        )
        let belowY = selection.maxY + spacing + halfHeight
        let aboveY = selection.minY - spacing - halfHeight
        let fitsBelow = belowY + halfHeight <= containerSize.height - margin
        let fitsAbove = aboveY - halfHeight >= margin

        let preferredY: CGFloat
        if fitsBelow {
            preferredY = belowY
        } else if fitsAbove {
            preferredY = aboveY
        } else {
            let spaceBelow = containerSize.height - selection.maxY
            let spaceAbove = selection.minY
            preferredY = spaceBelow >= spaceAbove ? belowY : aboveY
        }

        let y = min(
            max(preferredY, halfHeight + margin),
            containerSize.height - halfHeight - margin
        )
        return CGPoint(x: x, y: y)
    }
}

/// 串行化截图流程，并阻止已取消或过期的异步回调覆盖最新结果。
public struct ScreenshotCaptureSessionGate: Sendable {
    private var nextID: UInt64 = 0
    public private(set) var activeID: UInt64?

    public init() {}

    public var hasActiveSession: Bool { activeID != nil }

    public mutating func begin() -> UInt64? {
        guard activeID == nil else { return nil }
        nextID &+= 1
        activeID = nextID
        return nextID
    }

    public func isActive(_ id: UInt64) -> Bool {
        activeID == id
    }

    public mutating func complete(_ id: UInt64) -> Bool {
        guard activeID == id else { return false }
        activeID = nil
        return true
    }

    public mutating func cancel() {
        activeID = nil
    }
}

/// 截屏区域工具：任意方向拖拽规范化、屏幕内裁剪。
public enum CaptureRegion {
    /// 由任意方向的拖拽起点/终点生成规范化矩形（宽高恒为正）。
    public static func normalized(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    /// 将矩形裁剪到屏幕边界内（宽高非负）。
    public static func clamped(_ rect: CGRect, within bounds: CGRect) -> CGRect {
        rect.intersection(bounds)
    }
}

/// 窗口命中测试：给定鼠标位置与窗口边界列表（按 z-order 从顶到底），
/// 返回第一个包含鼠标点的窗口下标。
public enum WindowHitTester {
    public static func hitTest(point: CGPoint, windowBounds: [CGRect]) -> Int? {
        windowBounds.firstIndex { $0.contains(point) }
    }
}

public enum SmartCaptureGestureResult: Equatable, Sendable {
    case window(index: Int)
    case region(CGRect)
    case none
}

public enum SmartCaptureGesture {
    public static func resolve(
        start: CGPoint,
        end: CGPoint,
        windowIndex: Int?,
        minimumRegionSize: CGFloat = 4
    ) -> SmartCaptureGestureResult {
        let rect = CaptureRegion.normalized(from: start, to: end)
        if rect.width > minimumRegionSize, rect.height > minimumRegionSize {
            return .region(rect)
        }
        if let windowIndex { return .window(index: windowIndex) }
        return .none
    }
}

/// 根据截图内容分析得到的候选边界，返回点击位置下最小的可见元素。
public enum ScreenshotContentPicker {
    public static func elementRect(
        at point: CGPoint,
        imageSize: CGSize,
        elementBounds: [CGRect]
    ) -> CGRect? {
        let imageBounds = CGRect(origin: .zero, size: imageSize)
        guard imageSize.width > 0, imageSize.height > 0, imageBounds.contains(point)
        else { return nil }

        return elementBounds
            .map { $0.standardized.intersection(imageBounds) }
            .filter { !$0.isNull && $0.width > 4 && $0.height > 4 && $0.contains(point) }
            .min { $0.width * $0.height < $1.width * $1.height }
    }

    public static func pageElementRect(
        at point: CGPoint,
        imageSize: CGSize,
        blockBounds: [CGRect],
        fallbackBounds: [CGRect]
    ) -> CGRect? {
        pageElementStack(
            at: point,
            imageSize: imageSize,
            blockBounds: blockBounds,
            fallbackBounds: fallbackBounds
        ).first
    }

    /// 鼠标下所有嵌套候选，按面积从小到大排列；父块与内部行可以同时保留。
    public static func pageElementStack(
        at point: CGPoint,
        imageSize: CGSize,
        blockBounds: [CGRect],
        fallbackBounds: [CGRect]
    ) -> [CGRect] {
        let imageBounds = CGRect(origin: .zero, size: imageSize)
        guard imageSize.width > 0, imageSize.height > 0, imageBounds.contains(point)
        else { return [] }

        let candidates = blockBounds + fallbackBounds
        let clipped = candidates.map { $0.standardized.intersection(imageBounds) }
        let containing = clipped.filter {
            !$0.isNull && $0.width > 4 && $0.height > 4 && $0.contains(point)
        }
        let sorted = containing.sorted {
            $0.width * $0.height < $1.width * $1.height
        }
        return sorted.reduce(into: []) { stack, rect in
            if !stack.contains(rect) { stack.append(rect) }
        }
    }

    public static func filteredBlockBounds(
        _ candidates: [CGRect],
        textBounds: [CGRect],
        imageSize: CGSize
    ) -> [CGRect] {
        let nonGlyphCandidates = candidates.filter { candidate in
            let rect = candidate.standardized
            let candidateArea = rect.width * rect.height
            guard candidateArea > 0 else { return false }
            let isGlyphRectangle = textBounds.contains { text in
                let line = text.standardized
                let intersection = line.intersection(rect)
                guard !intersection.isNull else { return false }
                let intersectionArea = intersection.width * intersection.height
                let textArea = line.width * line.height
                return textArea > 0
                    && intersectionArea / candidateArea > 0.6
                    && intersectionArea / textArea < 0.6
            }
            return !isGlyphRectangle
        }
        return filteredElementBounds(nonGlyphCandidates, imageSize: imageSize)
    }

    /// 清理越界、过大和近似重复候选，同时保留不同尺寸的嵌套页面层级。
    public static func filteredElementBounds(
        _ candidates: [CGRect],
        imageSize: CGSize
    ) -> [CGRect] {
        let imageBounds = CGRect(origin: .zero, size: imageSize)
        let maximumArea = imageBounds.width * imageBounds.height * 0.45
        let maximumWidth = imageBounds.width * 0.9
        let maximumHeight = imageBounds.height * 0.9
        var result: [CGRect] = []
        for candidate in candidates.sorted(by: { $0.width * $0.height < $1.width * $1.height }) {
            let rect = candidate.standardized.intersection(imageBounds)
            guard !rect.isNull, rect.width > 4, rect.height > 4,
                  rect.width * rect.height < maximumArea,
                  rect.width < maximumWidth,
                  rect.height < maximumHeight
            else { continue }
            let isDuplicate = result.contains { existing in
                let intersection = existing.intersection(rect)
                guard !intersection.isNull else { return false }
                let existingArea = existing.width * existing.height
                let rectArea = rect.width * rect.height
                let smallerArea = min(existingArea, rectArea)
                let largerArea = max(existingArea, rectArea)
                return smallerArea > 0
                    && smallerArea / largerArea > 0.8
                    && intersection.width * intersection.height / smallerArea > 0.9
            }
            if !isDuplicate { result.append(rect) }
        }
        return result
    }
}

/// 截屏选区调整手柄（8 方向）。调整大小时固定对侧边/角，拖拽边跟随鼠标，
/// 因此选区位置会随调整一起移动。
public enum CaptureResizeHandle: CaseIterable, Equatable, Sendable {
    case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight

    /// 命中选区调整手柄：边缘/角落条带命中对应 8 方向手柄；
    /// 选区内按下按象限固定对角（对边移动、选区随之移动）。
    public static func hitTest(point: CGPoint, in rect: CGRect, edge: CGFloat = 8) -> CaptureResizeHandle? {
        guard rect.insetBy(dx: -edge, dy: -edge).contains(point) else { return nil }
        guard !rect.insetBy(dx: edge, dy: edge).contains(point) else {
            switch (point.x < rect.midX, point.y < rect.midY) {
            case (true, true): return .topLeft
            case (false, true): return .topRight
            case (true, false): return .bottomLeft
            case (false, false): return .bottomRight
            }
        }
        let nearLeft = point.x < rect.minX + edge
        let nearRight = point.x > rect.maxX - edge
        let nearTop = point.y < rect.minY + edge
        let nearBottom = point.y > rect.maxY - edge
        switch (nearLeft, nearRight, nearTop, nearBottom) {
        case (true, false, true, false): return .topLeft
        case (true, false, false, false): return .left
        case (true, false, false, true): return .bottomLeft
        case (false, false, true, false): return .top
        case (false, true, true, false): return .topRight
        case (false, true, false, false): return .right
        case (false, true, false, true): return .bottomRight
        case (false, false, false, true): return .bottom
        default: return nil
        }
    }

    /// 只命中边缘与角落手柄；选区内部留给整体移动手势。
    public static func edgeHitTest(point: CGPoint, in rect: CGRect, edge: CGFloat = 8) -> CaptureResizeHandle? {
        guard rect.insetBy(dx: -edge, dy: -edge).contains(point),
              !rect.insetBy(dx: edge, dy: edge).contains(point)
        else { return nil }
        return hitTest(point: point, in: rect, edge: edge)
    }

    /// 按手柄方向调整大小：固定对侧边/角，拖拽边跟随鼠标，选区随之移动。
    public static func resizedRect(
        original: CGRect,
        handle: CaptureResizeHandle,
        current: CGPoint,
        minSize: CGFloat = 4
    ) -> CGRect {
        var rect = original
        switch handle {
        case .topLeft:
            rect.origin.x = min(current.x, original.maxX - minSize)
            rect.origin.y = min(current.y, original.maxY - minSize)
            rect.size.width = original.maxX - rect.minX
            rect.size.height = original.maxY - rect.minY
        case .top:
            rect.origin.y = min(current.y, original.maxY - minSize)
            rect.size.height = original.maxY - rect.minY
        case .topRight:
            rect.size.width = max(current.x - original.minX, minSize)
            rect.origin.y = min(current.y, original.maxY - minSize)
            rect.size.height = original.maxY - rect.minY
        case .left:
            rect.origin.x = min(current.x, original.maxX - minSize)
            rect.size.width = original.maxX - rect.minX
        case .right:
            rect.size.width = max(current.x - original.minX, minSize)
        case .bottomLeft:
            rect.origin.x = min(current.x, original.maxX - minSize)
            rect.size.width = original.maxX - rect.minX
            rect.size.height = max(current.y - original.minY, minSize)
        case .bottom:
            rect.size.height = max(current.y - original.minY, minSize)
        case .bottomRight:
            rect.size.width = max(current.x - original.minX, minSize)
            rect.size.height = max(current.y - original.minY, minSize)
        }
        return rect
    }

    /// 将选区整体平移到范围内（大小不变）。
    public static func clamped(_ rect: CGRect, within bounds: CGRect) -> CGRect {
        guard rect.width <= bounds.width, rect.height <= bounds.height else { return rect }
        var rect = rect
        rect.origin.x = min(max(rect.minX, bounds.minX), bounds.maxX - rect.width)
        rect.origin.y = min(max(rect.minY, bounds.minY), bounds.maxY - rect.height)
        return rect
    }

    /// 手柄锚点（矩形四角与四边中点），与 `hitTest` 的 8 方向一一对应，用于绘制调整手柄。
    public func anchorPoint(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
        case .top: CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
        case .left: CGPoint(x: rect.minX, y: rect.midY)
        case .right: CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
        case .bottom: CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }
}

/// 滚动截屏匹配与输出限制。
public struct StitchConfiguration: Equatable, Sendable {
    public var minimumShift: Int
    public var minimumOverlapRatio: Double
    public var maximumStationaryBandRatio: Double
    public var minimumConfidence: Double
    public var sampleColumns: Int
    public var rowStride: Int
    public var trimmedOutlierRatio: Double
    /// 最佳位移必须比同方向次佳位移的分数至少低该差值，否则视为不可靠匹配。
    public var minimumScoreMargin: Double
    public var maximumPixelCount: Int
    public var maximumHeight: Int
    public var maximumFrameCount: Int

    public init(
    minimumShift: Int = 4,
    minimumOverlapRatio: Double = 0.2,
    maximumStationaryBandRatio: Double = 0.3,
    minimumConfidence: Double = 0.9,
    sampleColumns: Int = 96,
    rowStride: Int = 3,
    trimmedOutlierRatio: Double = 0.3,
    minimumScoreMargin: Double = 0.02,
        maximumPixelCount: Int = 64_000_000,
        maximumHeight: Int = 32_000,
        maximumFrameCount: Int = 120
    ) {
        self.minimumShift = max(minimumShift, 1)
        self.minimumOverlapRatio = min(max(minimumOverlapRatio, 0.05), 0.95)
        self.maximumStationaryBandRatio = min(max(maximumStationaryBandRatio, 0), 0.45)
        self.minimumConfidence = min(max(minimumConfidence, 0), 1)
        self.sampleColumns = max(sampleColumns, 8)
        self.rowStride = max(rowStride, 1)
        self.trimmedOutlierRatio = min(max(trimmedOutlierRatio, 0), 0.45)
        self.minimumScoreMargin = max(minimumScoreMargin, 0)
        self.maximumPixelCount = max(maximumPixelCount, 1)
        self.maximumHeight = max(maximumHeight, 1)
        self.maximumFrameCount = max(maximumFrameCount, 1)
    }

    public static let `default` = StitchConfiguration()
}

/// 相邻滚动帧的可靠纵向匹配结果。
public struct StitchMatch: Equatable, Sendable {
    public let direction: RollingScrollDirection
    public let offsetY: Int
    public var signedOffsetY: Int { direction == .down ? offsetY : -offsetY }
    public let overlapHeight: Int
    public let confidence: Double
    /// 同位置保持不动的顶部/底部连续区域候选；调用方需连续两次确认后再用于去重。
    public let stationaryTopHeight: Int
    public let stationaryBottomHeight: Int

    public init(
        direction: RollingScrollDirection = .down,
        offsetY: Int,
        overlapHeight: Int,
        confidence: Double,
        stationaryTopHeight: Int,
        stationaryBottomHeight: Int
    ) {
        self.direction = direction
        self.offsetY = offsetY
        self.overlapHeight = overlapHeight
        self.confidence = confidence
        self.stationaryTopHeight = stationaryTopHeight
        self.stationaryBottomHeight = stationaryBottomHeight
    }
}

public struct StitchFramePlacement: Equatable, Sendable {
    public let originY: Int

    public init(originY: Int) {
        self.originY = originY
    }
}

public enum StitchCoverageContribution: Equatable, Sendable {
    case prepend
    case append
    case covered
}

/// 以首帧为原点追踪当前视口和已覆盖的文档范围。
public struct StitchCoverage: Equatable, Sendable {
    public private(set) var currentOriginY = 0
    public private(set) var minimumOriginY = 0
    public private(set) var maximumOriginY = 0

    public init() {}

    public mutating func advance(by match: StitchMatch) -> StitchCoverageContribution {
        currentOriginY += match.signedOffsetY
        if currentOriginY < minimumOriginY {
            minimumOriginY = currentOriginY
            return .prepend
        }
        if currentOriginY > maximumOriginY {
            maximumOriginY = currentOriginY
            return .append
        }
        return .covered
    }

    public func outputHeight(frameHeight: Int) -> Int {
        frameHeight + maximumOriginY - minimumOriginY
    }
}

public enum StitchFailure: Error, Equatable, Sendable {
    case dimensionChanged(expectedWidth: Int, expectedHeight: Int, actualWidth: Int, actualHeight: Int)
    case duplicateFrame
    case lowConfidence(Double)
    case invalidFrame
    case outputLimitExceeded
}

/// 滚动截屏拼接引擎：降采样灰度特征、异常行剔除、双向位移匹配和长图合成。
public enum StitchEngine {
    /// 单帧行哈希表示。
    public struct Frame: Equatable, Sendable {
        public let width: Int
        public let height: Int
        /// 每行一个哈希值（从顶到底）。
        public let rowHashes: [UInt64]

        public init(width: Int, height: Int, rowHashes: [UInt64]) {
            precondition(rowHashes.count == height, "rowHashes 数量必须等于 height")
            self.width = width
            self.height = height
            self.rowHashes = rowHashes
        }
    }

    /// 缓存后的灰度行特征；连续滚动时复用上一帧，避免每次匹配重复缩放和读取像素。
    public struct PreparedFrame: Sendable {
        public let width: Int
        public let height: Int
        fileprivate let rows: [[Float]]
    }

    /// 匹配时单帧最大重叠尝试行数（防止逐行全量比较开销过大）。
    public static let maxOverlapCandidates = 240

    /// 分析相邻帧并返回页面向上或向下滚动产生的纵向位移。
    public static func analyze(
        previous: CGImage,
        next: CGImage,
        configuration: StitchConfiguration = .default
    ) -> Result<StitchMatch, StitchFailure> {
        guard previous.width == next.width, previous.height == next.height else {
            return .failure(.dimensionChanged(
                expectedWidth: previous.width,
                expectedHeight: previous.height,
                actualWidth: next.width,
                actualHeight: next.height
            ))
        }
        guard let previousFrame = prepare(previous, configuration: configuration),
              let nextFrame = prepare(next, configuration: configuration)
        else {
            return .failure(.invalidFrame)
        }
        return analyze(previous: previousFrame, next: nextFrame, configuration: configuration)
    }

    public static func prepare(
        _ image: CGImage,
        configuration: StitchConfiguration = .default
    ) -> PreparedFrame? {
        guard image.width > 0, image.height > configuration.minimumShift * 2 else { return nil }
        return sampledFrame(of: image, columns: configuration.sampleColumns)
    }

    public static func analyze(
        previous: PreparedFrame,
        next: PreparedFrame,
        preferredDirection: RollingScrollDirection? = nil,
        maximumShiftRatio: Double? = nil,
        configuration: StitchConfiguration = .default
    ) -> Result<StitchMatch, StitchFailure> {
        guard previous.width == next.width, previous.height == next.height else {
            return .failure(.dimensionChanged(
                expectedWidth: previous.width,
                expectedHeight: previous.height,
                actualWidth: next.width,
                actualHeight: next.height
            ))
        }
        guard previous.rows.first?.count == next.rows.first?.count else {
            return .failure(.invalidFrame)
        }
        let duplicateScore = score(
            first: previous,
            second: next,
            shift: 0,
            reverse: false,
            configuration: configuration
        )
        if confidence(for: duplicateScore) >= 0.995 {
            return .failure(.duplicateFrame)
        }

        let maximumShift = maximumShiftRatio.map {
            max(configuration.minimumShift, Int(Double(previous.height) * min(max($0, 0.05), 0.95)))
        }
        if let preferredDirection {
            guard let selected = bestShifts(
                first: previous,
                second: next,
                reverse: preferredDirection == .up,
                maximumShift: maximumShift,
                configuration: configuration
            ) else {
                return .failure(.lowConfidence(0))
            }
            let selectedConfidence = confidence(for: selected.best.score)
            guard selectedConfidence >= configuration.minimumConfidence,
                  selected.secondBest.score - selected.best.score >= configuration.minimumScoreMargin
            else {
                return .failure(.lowConfidence(selectedConfidence))
            }
            let bands = stationaryBands(
                previous: preferredDirection == .down ? previous : next,
                next: preferredDirection == .down ? next : previous,
                shift: selected.best.shift,
                configuration: configuration
            )
            return .success(StitchMatch(
                direction: preferredDirection,
                offsetY: selected.best.shift,
                overlapHeight: previous.height - selected.best.shift,
                confidence: selectedConfidence,
                stationaryTopHeight: bands.top,
                stationaryBottomHeight: bands.bottom
            ))
        }

        let downward = bestShifts(
            first: previous,
            second: next,
            reverse: false,
            maximumShift: maximumShift,
            configuration: configuration
        )
        let upward = bestShifts(
            first: previous,
            second: next,
            reverse: true,
            maximumShift: maximumShift,
            configuration: configuration
        )
        let downwardConfidence = downward.map { confidence(for: $0.best.score) } ?? 0
        let upwardConfidence = upward.map { confidence(for: $0.best.score) } ?? 0
        let bestConfidence = max(downwardConfidence, upwardConfidence)
        guard bestConfidence >= configuration.minimumConfidence else {
            return .failure(.lowConfidence(bestConfidence))
        }
        guard abs(downwardConfidence - upwardConfidence) >= 0.015 else {
            return .failure(.lowConfidence(bestConfidence))
        }

        let direction: RollingScrollDirection = downwardConfidence > upwardConfidence ? .down : .up
        guard let selected = direction == .down ? downward : upward else {
            return .failure(.lowConfidence(bestConfidence))
        }
        // 峰值锐度：快速滚动或空白页面会在多个位移处得到相近的低分数，
        // 此时最佳位移并不比次佳更可信，直接接受会产生错误位移导致拼接内容重复。
        guard selected.secondBest.score - selected.best.score >= configuration.minimumScoreMargin else {
            return .failure(.lowConfidence(bestConfidence))
        }

        let bands = stationaryBands(
            previous: direction == .down ? previous : next,
            next: direction == .down ? next : previous,
            shift: selected.best.shift,
            configuration: configuration
        )
        return .success(StitchMatch(
            direction: direction,
            offsetY: selected.best.shift,
            overlapHeight: previous.height - selected.best.shift,
            confidence: bestConfidence,
            stationaryTopHeight: bands.top,
            stationaryBottomHeight: bands.bottom
        ))
    }

    /// 轻量判断两帧是否几乎相同（滚动停顿检测）：只评估零位移分数，不做方向搜索。
    /// 用于快速滚动失配后区分“画面仍在变化（继续跟踪）”与“画面已停顿（等待回滚恢复）”。
    public static func isDuplicate(
        first: PreparedFrame,
        second: PreparedFrame,
        configuration: StitchConfiguration = .default
    ) -> Bool {
        guard first.width == second.width, first.height == second.height else { return false }
        let duplicateScore = score(
            first: first,
            second: second,
            shift: 0,
            reverse: false,
            configuration: configuration
        )
        return confidence(for: duplicateScore) >= 0.995
    }

    /// 检查继续接收一帧是否会超过首版滚动截图限制。
    public static func validateOutput(
        width: Int,
        height: Int,
        frameCount: Int,
        configuration: StitchConfiguration = .default
    ) -> StitchFailure? {
        guard width > 0, height > 0, frameCount > 0 else { return .invalidFrame }
        guard height <= configuration.maximumHeight,
              width <= configuration.maximumPixelCount / height,
              frameCount <= configuration.maximumFrameCount
        else {
            return .outputLimitExceeded
        }
        return nil
    }

    /// 将按文档坐标放置的帧合成长图；固定顶栏和底栏各保留一份。
    public static func compose(
        frames: [CGImage],
        placements: [StitchFramePlacement],
        confirmedTopHeight: Int = 0,
        confirmedBottomHeight: Int = 0,
        configuration: StitchConfiguration = .default
    ) -> Result<CGImage, StitchFailure> {
        guard let first = frames.first, frames.count == placements.count else {
            return .failure(.invalidFrame)
        }
        guard frames.allSatisfy({ $0.width == first.width && $0.height == first.height }) else {
            let actual = frames.first(where: { $0.width != first.width || $0.height != first.height })!
            return .failure(.dimensionChanged(
                expectedWidth: first.width,
                expectedHeight: first.height,
                actualWidth: actual.width,
                actualHeight: actual.height
            ))
        }

        let bottom = min(max(confirmedBottomHeight, 0), first.height / 3)
        let top = min(max(confirmedTopHeight, 0), first.height / 3)
        let ordered = zip(frames, placements).sorted { $0.1.originY < $1.1.originY }
        guard let firstPlaced = ordered.first, let lastPlaced = ordered.last else {
            return .failure(.invalidFrame)
        }
        let bodyStart = firstPlaced.1.originY + top
        let bodyEnd = lastPlaced.1.originY + first.height - bottom
        let bodyHeight = bodyEnd - bodyStart
        let totalHeight = top + bodyHeight + bottom
        if let failure = validateOutput(
            width: first.width,
            height: totalHeight,
            frameCount: frames.count,
            configuration: configuration
        ) {
            return .failure(failure)
        }

        guard let context = CGContext(
            data: nil,
            width: first.width,
            height: totalHeight,
            bitsPerComponent: 8,
            bytesPerRow: first.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return .failure(.invalidFrame)
        }

        var destinationTop = 0
        if top > 0 {
            guard drawTopOriented(
                image: firstPlaced.0,
                source: CGRect(x: 0, y: 0, width: first.width, height: top),
                destinationTop: destinationTop,
                totalHeight: totalHeight,
                context: context
            ) else { return .failure(.invalidFrame) }
            destinationTop += top
        }

        var coveredUntil = bodyStart
        for (frame, placement) in ordered {
            let frameBodyStart = placement.originY + top
            let frameBodyEnd = placement.originY + frame.height - bottom
            let drawStart = max(frameBodyStart, coveredUntil)
            let drawHeight = frameBodyEnd - drawStart
            guard drawHeight <= 0 ||
                  drawTopOriented(
                    image: frame,
                    source: CGRect(
                        x: 0,
                        y: top + drawStart - frameBodyStart,
                        width: frame.width,
                        height: drawHeight
                    ),
                    destinationTop: top + drawStart - bodyStart,
                    totalHeight: totalHeight,
                    context: context
                  )
            else {
                return .failure(.invalidFrame)
            }
            if drawHeight > 0 { coveredUntil = frameBodyEnd }
        }
        destinationTop = top + bodyHeight

        if bottom > 0 {
            guard drawTopOriented(
                image: lastPlaced.0,
                source: CGRect(x: 0, y: lastPlaced.0.height - bottom, width: first.width, height: bottom),
                destinationTop: destinationTop,
                totalHeight: totalHeight,
                context: context
            ) else {
                return .failure(.invalidFrame)
            }
            destinationTop += bottom
        }

        // 固定栏去重会让实际内容比理论 height 少；裁掉尚未绘制的底部空白。
        guard let fullImage = context.makeImage() else { return .failure(.invalidFrame) }
        let usedHeight = min(destinationTop, totalHeight)
        guard let cropped = fullImage.cropping(to: CGRect(
            x: 0,
            y: totalHeight - usedHeight,
            width: first.width,
            height: usedHeight
        )) else {
            return .failure(.invalidFrame)
        }
        return .success(cropped)
    }

    /// 兼容顺序帧调用方：按相邻匹配累积文档坐标后交给坐标合成器。
    public static func compose(
        frames: [CGImage],
        matches: [StitchMatch],
        confirmedTopHeight: Int = 0,
        confirmedBottomHeight: Int = 0,
        configuration: StitchConfiguration = .default
    ) -> Result<CGImage, StitchFailure> {
        guard frames.count == matches.count + 1 else { return .failure(.invalidFrame) }
        var originY = 0
        var placements = [StitchFramePlacement(originY: originY)]
        for match in matches {
            originY += match.signedOffsetY
            placements.append(StitchFramePlacement(originY: originY))
        }
        return compose(
            frames: frames,
            placements: placements,
            confirmedTopHeight: confirmedTopHeight,
            confirmedBottomHeight: confirmedBottomHeight,
            configuration: configuration
        )
    }

    /// 将图像转为逐行哈希帧。使用 FNV-1a 64 位哈希；像素从图像顶部逐行读取。
    public static func frame(of image: CGImage) -> Frame? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        guard let data = pixelData(of: image) else { return nil }

        var hashes: [UInt64] = []
        hashes.reserveCapacity(height)
        let bytesPerRow = width * 4
        for y in 0..<height {
            let rowStart = y * bytesPerRow
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            for x in 0..<bytesPerRow {
                hash ^= UInt64(data[rowStart + x])
                hash &*= 0x0000_0100_0000_01B3
            }
            hashes.append(hash)
        }
        return Frame(width: width, height: height, rowHashes: hashes)
    }

    /// 计算 bottom 帧顶部与 top 帧底部重叠的行数（0 = 无重叠）。
    /// 要求两帧等宽；只接受正向滚动（bottom 是 top 之后的内容）。
    public static func verticalOverlap(top: Frame, bottom: Frame) -> Int {
        guard top.width == bottom.width else { return 0 }
        let maxOverlap = min(top.height, bottom.height, maxOverlapCandidates)
        guard maxOverlap > 0 else { return 0 }

        var best = 0
        // overlap 从 1 到 maxOverlap：检查 bottom 顶部 overlap 行 == top 底部 overlap 行
        for overlap in 1...maxOverlap {
            var matches = true
            for i in 0..<overlap {
                if bottom.rowHashes[i] != top.rowHashes[top.height - overlap + i] {
                    matches = false
                    break
                }
            }
            if matches { best = overlap }
        }
        return best
    }

    /// 拼接总高度：上下两帧高度之和减去重叠行数。
    public static func stitchedHeight(topHeight: Int, bottomHeight: Int, overlap: Int) -> Int {
        topHeight + bottomHeight - overlap
    }

    // MARK: - Private

    private struct ShiftScore {
        let shift: Int
        let score: Double
    }

    private static func sampledFrame(of image: CGImage, columns: Int) -> PreparedFrame? {
        let width = image.width
        let height = image.height
        let count = min(columns, width)
        var data = Data(count: count * height)
        let drawn = data.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: count,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: count,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: count, height: height))
            return true
        }
        guard drawn else { return nil }
        var rows: [[Float]] = []
        rows.reserveCapacity(height)
        for y in 0..<height {
            let start = y * count
            rows.append(data[start..<(start + count)].map(Float.init))
        }
        return PreparedFrame(width: width, height: height, rows: rows)
    }

    private static func bestShifts(
        first: PreparedFrame,
        second: PreparedFrame,
        reverse: Bool,
        maximumShift: Int? = nil,
        configuration: StitchConfiguration
    ) -> (best: ShiftScore, secondBest: ShiftScore)? {
        let minimumOverlap = max(
            configuration.minimumShift * 2,
            Int(Double(first.height) * configuration.minimumOverlapRatio)
        )
        let maximumShift = min(first.height - minimumOverlap, maximumShift ?? .max)
        guard maximumShift >= configuration.minimumShift else { return nil }

        let coarseStep = first.height > 800 ? 3 : 2
        var coarseCandidates: [ShiftScore] = []
        coarseCandidates.reserveCapacity((maximumShift - configuration.minimumShift) / coarseStep + 1)
        var shift = configuration.minimumShift
        while shift <= maximumShift {
            let value = score(
                first: first,
                second: second,
                shift: shift,
                reverse: reverse,
                rowStrideMultiplier: 8,
                columnStride: 8,
                configuration: configuration
            )
            coarseCandidates.append(ShiftScore(shift: shift, score: value))
            shift += coarseStep
        }

        // 稀疏扫描只负责召回候选；最终分数仍使用完整行列，置信度标准不变。
        let leadingCandidates = coarseCandidates.sorted { $0.score < $1.score }.prefix(12)
        var refinedShifts = Set<Int>()
        for coarse in leadingCandidates {
            let lower = max(configuration.minimumShift, coarse.shift - coarseStep)
            let upper = min(maximumShift, coarse.shift + coarseStep)
            refinedShifts.formUnion(lower...upper)
        }

        let scores = refinedShifts.map { candidate in
            ShiftScore(
                shift: candidate,
                score: score(
                first: first,
                second: second,
                shift: candidate,
                reverse: reverse,
                configuration: configuration
                )
            )
        }.sorted { $0.score < $1.score }
        guard let best = scores.first else { return nil }
        let minimumPeakDistance = max(
            configuration.minimumShift,
            configuration.rowStride * 2,
            Int(ceil(Double(first.height) * 0.02))
        )
        guard let secondBest = scores.first(where: {
            abs($0.shift - best.shift) >= minimumPeakDistance
        }) else { return nil }
        return (best, secondBest)
    }

    private static func score(
        first: PreparedFrame,
        second: PreparedFrame,
        shift: Int,
        reverse: Bool,
        rowStrideMultiplier: Int = 1,
        columnStride: Int = 1,
        configuration: StitchConfiguration
    ) -> Double {
        let overlap = first.height - shift
        guard overlap > 0 else { return 1 }
        var rowScores: [Double] = []
        let rowStride = configuration.rowStride * max(rowStrideMultiplier, 1)
        rowScores.reserveCapacity(overlap / rowStride + 1)
        var y = 0
        while y < overlap {
            let firstIndex = reverse ? y : y + shift
            let secondIndex = reverse ? y + shift : y
            rowScores.append(rowDifference(
                first.rows[firstIndex],
                second.rows[secondIndex],
                stride: columnStride
            ))
            y += rowStride
        }
        guard !rowScores.isEmpty else { return 1 }
        rowScores.sort()
        let keepCount = max(1, Int(Double(rowScores.count) * (1 - configuration.trimmedOutlierRatio)))
        return rowScores.prefix(keepCount).reduce(0, +) / Double(keepCount) / 255
    }

    private static func confidence(for score: Double) -> Double {
        min(max(1 - score, 0), 1)
    }

    private static func rowDifference(_ lhs: [Float], _ rhs: [Float], stride: Int = 1) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 255 }
        let stride = max(stride, 1)
        let count = (lhs.count + stride - 1) / stride
        var squaredDistance: Float = 0
        lhs.withUnsafeBufferPointer { lhsBuffer in
            rhs.withUnsafeBufferPointer { rhsBuffer in
                guard let lhsBase = lhsBuffer.baseAddress,
                      let rhsBase = rhsBuffer.baseAddress
                else { return }
                vDSP_distancesq(
                    lhsBase,
                    vDSP_Stride(stride),
                    rhsBase,
                    vDSP_Stride(stride),
                    &squaredDistance,
                    vDSP_Length(count)
                )
            }
        }
        return sqrt(Double(squaredDistance) / Double(count))
    }

    private static func stationaryBands(
        previous: PreparedFrame,
        next: PreparedFrame,
        shift: Int,
        configuration: StitchConfiguration
    ) -> (top: Int, bottom: Int) {
        let maximum = min(
            Int(Double(previous.height) * configuration.maximumStationaryBandRatio),
            previous.height - shift - 1
        )
        guard maximum >= 4 else { return (0, 0) }
        let sameThreshold = 4.0
        let translatedMargin = 5.0

        var top = 0
        for y in 0..<maximum {
            let same = rowDifference(previous.rows[y], next.rows[y])
            let translated = rowDifference(previous.rows[y + shift], next.rows[y])
            guard same <= sameThreshold, translated >= same + translatedMargin else { break }
            top += 1
        }

        var bottom = 0
        for offset in 0..<maximum {
            let y = previous.height - 1 - offset
            let same = rowDifference(previous.rows[y], next.rows[y])
            let translatedIndex = y - shift
            guard translatedIndex >= 0 else { break }
            let translated = rowDifference(previous.rows[translatedIndex], next.rows[y])
            guard same <= sameThreshold, translated >= same + translatedMargin else { break }
            bottom += 1
        }
        return (top >= 4 ? top : 0, bottom >= 4 ? bottom : 0)
    }

    private static func drawTopOriented(
        image: CGImage,
        source: CGRect,
        destinationTop: Int,
        totalHeight: Int,
        context: CGContext
    ) -> Bool {
        guard let piece = image.cropping(to: source), piece.height > 0 else { return false }
        let destination = CGRect(
            x: 0,
            y: totalHeight - destinationTop - piece.height,
            width: piece.width,
            height: piece.height
        )
        context.draw(piece, in: destination)
        return true
    }

    /// 读取图像 RGBA 像素字节（每像素 4 字节，行宽 width*4）。
    private static func pixelData(of image: CGImage) -> Data? {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var data = Data(count: bytesPerRow * height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        // 注意：必须用 withUnsafeMutableBytes 取 Data 内部缓冲区地址，
        // CGContext 会持有该指针并在 draw 时写入像素。
        let drawn: Bool = data.withUnsafeMutableBytes { raw in
            guard let baseAddress = raw.baseAddress else { return false }
            guard let context = CGContext(
                data: baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? data : nil
    }
}
