import CoreGraphics
import Foundation

/// An axis-aligned box with **inclusive** edges.
///
/// `CGRect` is deliberately not used for extraction bookkeeping. A horizontal line has
/// zero height, and `CGRect.isEmpty` is `true` for a zero-height rectangle while
/// `CGRect.intersects(_:)` returns `false` for it — so a clip test written on `CGRect`
/// silently discards every axis-aligned line on the page. Inclusive bounds have no such
/// trap: a degenerate box is still a box, and touching boxes intersect.
public struct VectorBounds: Sendable, Hashable, Codable {
    public var minX: Double
    public var minY: Double
    public var maxX: Double
    public var maxY: Double

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = Swift.min(minX, maxX)
        self.minY = Swift.min(minY, maxY)
        self.maxX = Swift.max(minX, maxX)
        self.maxY = Swift.max(minY, maxY)
    }

    /// The degenerate box containing exactly one point.
    public init(point: CGPoint) {
        self.init(minX: point.x, minY: point.y, maxX: point.x, maxY: point.y)
    }

    public init(_ rect: CGRect) {
        self.init(minX: rect.minX, minY: rect.minY, maxX: rect.maxX, maxY: rect.maxY)
    }

    public var width: Double { maxX - minX }
    public var height: Double { maxY - minY }
    public var area: Double { width * height }
    public var center: CGPoint { CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2) }
    public var cgRect: CGRect { CGRect(x: minX, y: minY, width: width, height: height) }

    public var corners: [CGPoint] {
        [
            CGPoint(x: minX, y: minY),
            CGPoint(x: maxX, y: minY),
            CGPoint(x: maxX, y: maxY),
            CGPoint(x: minX, y: maxY)
        ]
    }

    public func union(_ other: VectorBounds) -> VectorBounds {
        VectorBounds(
            minX: Swift.min(minX, other.minX),
            minY: Swift.min(minY, other.minY),
            maxX: Swift.max(maxX, other.maxX),
            maxY: Swift.max(maxY, other.maxY)
        )
    }

    public func union(_ point: CGPoint) -> VectorBounds {
        union(VectorBounds(point: point))
    }

    /// Inclusive overlap: two boxes that share only an edge do intersect.
    public func intersects(_ other: VectorBounds) -> Bool {
        minX <= other.maxX && other.minX <= maxX && minY <= other.maxY && other.minY <= maxY
    }

    /// `true` when every point of `other` lies inside or on the boundary of `self`.
    public func contains(_ other: VectorBounds) -> Bool {
        minX <= other.minX && minY <= other.minY && maxX >= other.maxX && maxY >= other.maxY
    }

    public func contains(_ point: CGPoint) -> Bool {
        point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
    }

    public func intersection(_ other: VectorBounds) -> VectorBounds? {
        guard intersects(other) else { return nil }
        return VectorBounds(
            minX: Swift.max(minX, other.minX),
            minY: Swift.max(minY, other.minY),
            maxX: Swift.min(maxX, other.maxX),
            maxY: Swift.min(maxY, other.maxY)
        )
    }

    /// Grown by `margin` on every side. A negative margin shrinks, and never inverts:
    /// the result is clamped to the centre point.
    public func inset(by margin: Double) -> VectorBounds {
        let nx0 = minX + margin
        let nx1 = maxX - margin
        let ny0 = minY + margin
        let ny1 = maxY - margin
        let cx = (minX + maxX) / 2
        let cy = (minY + maxY) / 2
        return VectorBounds(
            minX: nx0 <= nx1 ? nx0 : cx,
            minY: ny0 <= ny1 ? ny0 : cy,
            maxX: nx0 <= nx1 ? nx1 : cx,
            maxY: ny0 <= ny1 ? ny1 : cy
        )
    }

    /// The bounds of `points`, or `nil` for an empty input.
    public static func containing(_ points: [CGPoint]) -> VectorBounds? {
        guard let first = points.first else { return nil }
        var result = VectorBounds(point: first)
        for point in points.dropFirst() { result = result.union(point) }
        return result
    }

    /// The image of the box's four corners under `transform`, re-bounded.
    public func applying(_ transform: CGAffineTransform) -> VectorBounds {
        var result = VectorBounds(point: corners[0].applying(transform))
        for corner in corners.dropFirst() {
            result = result.union(corner.applying(transform))
        }
        return result
    }
}
