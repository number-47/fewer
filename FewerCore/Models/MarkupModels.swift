import CoreGraphics
import Foundation

/// 标注预置颜色（编辑工具栏色板）。
public enum MarkupColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case red
    case orange
    case yellow
    case green
    case blue
    case black
    case white

    public var id: String { rawValue }
}

/// 轮廓线型；适用于几何形状、直线、折线、箭头与画笔。
public enum MarkupStrokeStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case solid
    case dashed
    case dotted

    public var id: String { rawValue }
}

/// 区域类工具的作用范围。自由绘制用于涂抹，矩形/椭圆用于精确框选。
public enum MarkupAreaShape: String, Codable, CaseIterable, Identifiable, Sendable {
    case freehand
    case rectangle
    case ellipse

    public var id: String { rawValue }
}

public enum MarkupPrimaryPointerRoute: Equatable, Sendable {
    case activeTool
    case moveExistingElement(UUID)
    case resizeExistingElement(UUID, CaptureResizeHandle)
}

/// 普通拖动始终交给当前绘图工具；控制点直接缩放，按住 Command 时临时移动已有标注。
public enum MarkupInteractionPolicy {
    public static func primaryPointerRoute(
        moveModifierPressed: Bool,
        selectedElementID: UUID?,
        selectedResizeHandle: CaptureResizeHandle?,
        hitElementID: UUID?
    ) -> MarkupPrimaryPointerRoute {
        if let selectedElementID, let selectedResizeHandle {
            return .resizeExistingElement(selectedElementID, selectedResizeHandle)
        }
        guard moveModifierPressed, let hitElementID else { return .activeTool }
        return .moveExistingElement(hitElementID)
    }
}

public enum MarkupTextReturnAction: Equatable, Sendable {
    case insertNewline
    case finishEditing
}

public enum MarkupTextEditingPolicy {
    public static func returnAction(commandModifierPressed: Bool) -> MarkupTextReturnAction {
        commandModifierPressed ? .finishEditing : .insertNewline
    }
}

/// 标注形状（纯数据，绘制与导出由 AppKit 层完成）。
public enum MarkupShape: Equatable, Sendable {
    case arrow(start: CGPoint, end: CGPoint)
    case rect(CGRect)
    case roundedRect(CGRect)
    case ellipse(CGRect)
    case line(start: CGPoint, end: CGPoint)
    case polyline([CGPoint])
    case freehand([CGPoint])
    case highlight(points: [CGPoint], areaShape: MarkupAreaShape)
    case mosaic(points: [CGPoint], areaShape: MarkupAreaShape)
    case blur(points: [CGPoint], areaShape: MarkupAreaShape)
    case text(String, origin: CGPoint)
    case eraser(points: [CGPoint], areaShape: MarkupAreaShape)
    case counter(Int, center: CGPoint)
    case magnifier(center: CGPoint, radius: CGFloat, scale: CGFloat)

    /// 平移任意标注形状；选择工具拖动时使用，保持形状自身参数不变。
    public func translated(by delta: CGSize) -> MarkupShape {
        func point(_ value: CGPoint) -> CGPoint {
            CGPoint(x: value.x + delta.width, y: value.y + delta.height)
        }
        func rect(_ value: CGRect) -> CGRect {
            value.offsetBy(dx: delta.width, dy: delta.height)
        }

        switch self {
        case .arrow(let start, let end):
            return .arrow(start: point(start), end: point(end))
        case .rect(let value):
            return .rect(rect(value))
        case .roundedRect(let value):
            return .roundedRect(rect(value))
        case .ellipse(let value):
            return .ellipse(rect(value))
        case .line(let start, let end):
            return .line(start: point(start), end: point(end))
        case .polyline(let points):
            return .polyline(points.map(point))
        case .freehand(let points):
            return .freehand(points.map(point))
        case .highlight(let points, let areaShape):
            return .highlight(points: points.map(point), areaShape: areaShape)
        case .mosaic(let points, let areaShape):
            return .mosaic(points: points.map(point), areaShape: areaShape)
        case .blur(let points, let areaShape):
            return .blur(points: points.map(point), areaShape: areaShape)
        case .text(let text, let origin):
            return .text(text, origin: point(origin))
        case .eraser(let points, let areaShape):
            return .eraser(points: points.map(point), areaShape: areaShape)
        case .counter(let number, let center):
            return .counter(number, center: point(center))
        case .magnifier(let center, let radius, let scale):
            return .magnifier(center: point(center), radius: radius, scale: scale)
        }
    }

    /// 将形状从原始边界缩放到目标边界：所有锚点按相对位置映射，文字/序号等
    /// 尺寸由缩放比例调整，供选中元素拖拽手柄调整大小时使用。
    public func scaled(to rect: CGRect, from original: CGRect) -> MarkupShape {
        guard original.width > 0, original.height > 0 else { return self }
        let scaleX = rect.width / original.width
        let scaleY = rect.height / original.height

        func point(_ value: CGPoint) -> CGPoint {
            CGPoint(
                x: rect.minX + (value.x - original.minX) * scaleX,
                y: rect.minY + (value.y - original.minY) * scaleY
            )
        }
        func scaledRect(_ value: CGRect) -> CGRect {
            CGRect(
                x: rect.minX + (value.minX - original.minX) * scaleX,
                y: rect.minY + (value.minY - original.minY) * scaleY,
                width: value.width * scaleX,
                height: value.height * scaleY
            )
        }

        switch self {
        case .rect(let value):
            return .rect(scaledRect(value))
        case .roundedRect(let value):
            return .roundedRect(scaledRect(value))
        case .ellipse(let value):
            return .ellipse(scaledRect(value))
        case .line(let start, let end):
            return .line(start: point(start), end: point(end))
        case .arrow(let start, let end):
            return .arrow(start: point(start), end: point(end))
        case .polyline(let points):
            return .polyline(points.map(point))
        case .freehand(let points):
            return .freehand(points.map(point))
        case .highlight(let points, let areaShape):
            return .highlight(points: points.map(point), areaShape: areaShape)
        case .mosaic(let points, let areaShape):
            return .mosaic(points: points.map(point), areaShape: areaShape)
        case .blur(let points, let areaShape):
            return .blur(points: points.map(point), areaShape: areaShape)
        case .text(let text, let origin):
            return .text(text, origin: point(origin))
        case .eraser(let points, let areaShape):
            return .eraser(points: points.map(point), areaShape: areaShape)
        case .counter(let number, let center):
            return .counter(number, center: point(center))
        case .magnifier(let center, let radius, let scale):
            return .magnifier(
                center: point(center),
                radius: max(8, radius * min(scaleX, scaleY)),
                scale: scale
            )
        }
    }
}

/// 一条标注记录：形状 + 颜色 + 线宽，用于撤销栈与导出合成。
public struct MarkupElement: Equatable, Sendable {
    public let id: UUID
    public var shape: MarkupShape
    public var color: MarkupColor
    public var strokeWidth: CGFloat
    public var strokeStyle: MarkupStrokeStyle

    public init(
        id: UUID = UUID(),
        shape: MarkupShape,
        color: MarkupColor,
        strokeWidth: CGFloat = 3,
        strokeStyle: MarkupStrokeStyle = .solid
    ) {
        self.id = id
        self.shape = shape
        self.color = color
        self.strokeWidth = strokeWidth
        self.strokeStyle = strokeStyle
    }

    public func scaled(to target: CGRect, from original: CGRect) -> MarkupElement {
        guard original.width > 0, original.height > 0 else { return self }
        var copy = self
        copy.shape = shape.scaled(to: target, from: original)
        let scale = min(target.width / original.width, target.height / original.height)
        copy.strokeWidth = max(0.5, strokeWidth * scale)
        return copy
    }
}

/// 标注撤销历史：push 添加、undo 回退一步。
public struct MarkupHistory: Equatable, Sendable {
    public private(set) var elements: [MarkupElement]

    public init(elements: [MarkupElement] = []) {
        self.elements = elements
    }

    public var canUndo: Bool { !elements.isEmpty }

    public mutating func push(_ element: MarkupElement) {
        elements.append(element)
    }

    /// 回退一步并返回被移除的元素。
    @discardableResult
    public mutating func undo() -> MarkupElement? {
        elements.popLast()
    }
}

/// 标注编辑的快照历史。新增、移动、改色、改线宽和删除都可共用同一套撤销/重做。
public struct MarkupSnapshotHistory: Equatable, Sendable {
    public private(set) var undoSnapshots: [[MarkupElement]] = []
    public private(set) var redoSnapshots: [[MarkupElement]] = []

    public init() {}

    public var canUndo: Bool { !undoSnapshots.isEmpty }
    public var canRedo: Bool { !redoSnapshots.isEmpty }

    public mutating func record(_ elements: [MarkupElement]) {
        if undoSnapshots.last != elements {
            undoSnapshots.append(elements)
        }
        redoSnapshots.removeAll()
    }

    public mutating func undo(current: [MarkupElement]) -> [MarkupElement]? {
        guard let previous = undoSnapshots.popLast() else { return nil }
        redoSnapshots.append(current)
        return previous
    }

    public mutating func redo(current: [MarkupElement]) -> [MarkupElement]? {
        guard let next = redoSnapshots.popLast() else { return nil }
        undoSnapshots.append(current)
        return next
    }
}
