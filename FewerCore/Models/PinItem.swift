import CoreGraphics
import Foundation

/// 贴图项：截图 PNG 数据 + 屏幕位置 + 缩放 + 透明度。
public struct PinItem: Equatable, Sendable {
    /// 缩放范围（滚轮调整）。
    public static let scaleRange: ClosedRange<CGFloat> = 0.1...4.0
    /// 透明度范围（控制条调整）。
    public static let opacityRange: ClosedRange<CGFloat> = 0.1...1.0

    public let imageData: Data
    public var origin: CGPoint
    public var scale: CGFloat
    public var opacity: CGFloat

    public init(
        imageData: Data,
        origin: CGPoint = .zero,
        scale: CGFloat = 1.0,
        opacity: CGFloat = 1.0
    ) {
        self.imageData = imageData
        self.origin = origin
        self.scale = Self.clampedScale(scale)
        self.opacity = Self.clampedOpacity(opacity)
    }

    /// 约束缩放值到有效范围。
    public static func clampedScale(_ value: CGFloat) -> CGFloat {
        min(max(value, scaleRange.lowerBound), scaleRange.upperBound)
    }

    /// 约束透明度值到有效范围。
    public static func clampedOpacity(_ value: CGFloat) -> CGFloat {
        min(max(value, opacityRange.lowerBound), opacityRange.upperBound)
    }

    /// 缩放后的展示尺寸（基于 PNG 原始尺寸）。
    public func displaySize(originalSize: CGSize) -> CGSize {
        CGSize(width: originalSize.width * scale, height: originalSize.height * scale)
    }
}
