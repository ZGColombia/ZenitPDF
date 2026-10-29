import Foundation
import ZPDFContracts

/// How a stroke terminates. Purely geometric: the arrow decorations of
/// ``ZPDFContracts/LineCapStyle`` are *shapes*, not caps, and reach the renderer as their own
/// ``RenderShape/filledPolygon(_:)``. Keeping the two apart is what lets one line instance in a
/// GPU buffer describe a cap with three bits instead of a branch.
public enum RenderCap: UInt8, Sendable, Hashable, Codable, CaseIterable {
    /// The stroke stops exactly at the endpoint.
    case butt = 0
    /// A half-disc of radius `lineWidth / 2` is added past the endpoint.
    case round = 1
    /// A half-square of side `lineWidth` is added past the endpoint.
    case square = 2
}

/// A dash pattern in **page points**, with its phase.
///
/// The pattern is stored in page points because that is the space the document is authored in.
/// Both backends convert it to device pixels once per frame through ``RenderTransform`` and floor
/// each run at ``DashPattern/minimumRunPixels`` so a dashed line does not silently become solid
/// or invisible at 5 % zoom. That floor is a decoration decision, not a geometry decision: the
/// centreline, the endpoints and every measured length are untouched by it.
public enum RenderDash: Sendable, Hashable, Codable {
    case solid
    /// `runs` alternate on, off, on, off ... and must be non-empty, finite and positive.
    case pattern(runs: [Double], phase: Double)

    /// The pattern with every non-finite or negative run removed; `solid` when no positive run
    /// remains. Untrusted style data cannot make the renderer loop forever.
    ///
    /// A **zero** run is kept: `[0 2] 0 d` is PDF's round-capped dotted line, a dot every two
    /// points drawn entirely by its caps. Dropping the zero turned it into a 2/2 dash (BH-624).
    /// The period stays positive because at least one run must be.
    public var sanitized: RenderDash {
        switch self {
        case .solid:
            return .solid
        case let .pattern(runs, phase):
            let kept = runs.filter { $0.isFinite && $0 >= 0 }
            guard kept.contains(where: { $0 > 0 }) else { return .solid }
            // An odd-length pattern repeats doubled, exactly as CoreGraphics and PDF define it.
            let normalized = kept.count % 2 == 0 ? kept : kept + kept
            return .pattern(runs: normalized, phase: phase.isFinite ? phase : 0)
        }
    }
}

/// How a markup's ink combines with what is under it (r2-layers follow-up, ADR-0029's blend).
public enum RenderBlendMode: String, Sendable, Hashable, Codable {
    /// Ordinary source-over painting.
    case normal
    /// Multiply: a highlighter, whose ink darkens the linework under it instead of covering it.
    /// A PDF context writes it as `/BM /Multiply` in the graphics state.
    case multiply
}

/// The complete appearance of one renderable markup.
///
/// Every length here is in page points. Nothing in this type knows about zoom, the backing scale
/// or the minimum legible width — that is ``RenderTransform``'s job, and it is deliberately the
/// only place in the package that knows it.
public struct RenderStyle: Sendable, Hashable, Codable {
    /// Stroke colour, or `nil` for an unstroked shape.
    public var stroke: RGBAColor?
    /// Fill colour, or `nil` for an unfilled shape. Ignored by ``RenderShape/polyline(_:)``.
    public var fill: RGBAColor?
    /// Multiplied into both colours' alpha. Clamped to `0...1`.
    public var opacity: Double
    /// Stroke width in page points. Clamped to `0...` and floored on screen, never below zero.
    public var lineWidth: Double
    public var dash: RenderDash
    public var startCap: RenderCap
    public var endCap: RenderCap
    /// How the ink combines with the page, `nil` for normal painting. Optional so a style that
    /// does not use it encodes exactly as before (the synthesized coder omits a `nil`).
    public var blendMode: RenderBlendMode?

    public init(
        stroke: RGBAColor? = .opaqueBlack,
        fill: RGBAColor? = nil,
        opacity: Double = 1.0,
        lineWidth: Double = 1.0,
        dash: RenderDash = .solid,
        startCap: RenderCap = .butt,
        endCap: RenderCap = .butt
    ) {
        self.stroke = stroke
        self.fill = fill
        self.opacity = opacity
        self.lineWidth = lineWidth
        self.dash = dash
        self.startCap = startCap
        self.endCap = endCap
    }

    /// The stroke colour with ``opacity`` folded in, or `nil` when nothing would be drawn.
    public var effectiveStroke: RGBAColor? { Self.fold(stroke, opacity) }
    /// The fill colour with ``opacity`` folded in, or `nil` when nothing would be drawn.
    public var effectiveFill: RGBAColor? { Self.fold(fill, opacity) }

    /// Line width with non-finite and negative values coerced to zero.
    public var sanitizedLineWidth: Double {
        guard lineWidth.isFinite, lineWidth > 0 else { return 0 }
        return Swift.min(lineWidth, RenderLimits.maximumLineWidthPagePoints)
    }

    private static func fold(_ color: RGBAColor?, _ opacity: Double) -> RGBAColor? {
        guard var color else { return nil }
        let clamped = opacity.isFinite ? Swift.min(1, Swift.max(0, opacity)) : 0
        color = color.clampedToUnitRange()
        color.alpha *= clamped
        return color.alpha > 0 ? color : nil
    }

    public static let `default` = RenderStyle()
}

/// Hard bounds the renderer applies to untrusted geometry and style values.
///
/// A markup arrives from a project database that may have been edited by hand or corrupted, so
/// every bound here exists to keep a bad number from turning into an unbounded allocation, an
/// infinite loop or a `NaN` in a vertex buffer.
public enum RenderLimits {
    /// `QUALITY_BAR` 2.5: a PDF user-space page cannot legitimately exceed 14 400 units, so a
    /// coordinate beyond 1e7 is a corrupt file. Geometry outside this box is dropped, not drawn.
    public static let coordinateMagnitudeBound: Double = 1e7
    /// Widest stroke accepted, in page points. Above this the quad expansion overflows anything
    /// useful and the shape is a filled region, not a line.
    public static let maximumLineWidthPagePoints: Double = 1e4
    /// Most vertices accepted in one contour. Beyond this the markup is rejected as malformed.
    public static let maximumContourVertices = 100_000
    /// Most hole contours accepted on one polygon.
    public static let maximumHoles = 4_096
    /// Most characters rendered from one text label.
    public static let maximumLabelCharacters = 512
    /// Widest and tallest offscreen target the package will allocate, in device pixels.
    public static let maximumTargetPixels = 16_384
}
