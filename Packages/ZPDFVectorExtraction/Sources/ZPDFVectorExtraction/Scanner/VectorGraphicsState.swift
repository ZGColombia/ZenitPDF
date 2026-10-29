import CoreGraphics
import Foundation

/// The part of the PDF graphics state that affects extracted geometry.
///
/// `CGPDFScanner` reports operators and operands and **does not** maintain any of this:
/// the CTM, the `q`/`Q` stack, the clip and the alpha constants are all the extractor's
/// job (`QUALITY_BAR` 3.6).
struct VectorGraphicsState {
    /// The composed current transformation matrix, page content downwards.
    var ctm: CGAffineTransform
    /// `w`, in the space the CTM maps *from*.
    var lineWidth: Double
    /// `d` with a non-empty array.
    var isDashed: Bool
    /// `CA` from an `/ExtGState`.
    var strokeAlpha: Double
    /// `ca` from an `/ExtGState`.
    var fillAlpha: Double
    /// The bounding box of the intersected clip, or `nil` when the only clip is the page
    /// box. A bounding box is a conservative over-approximation of the true clip, which
    /// is why it is only ever used to *exclude* geometry that lies wholly outside it.
    var clip: VectorBounds?
    /// `true` once the clip has been intersected with a box disjoint from it: nothing
    /// paints until the next `Q`.
    ///
    /// `VectorBounds?` has no empty value — `nil` means *no* clip, the opposite — and the
    /// old `intersection(...) ?? newBox` fell back to the new box alone, so two disjoint
    /// `W n` rectangles, or a form `/BBox` outside the clip in force, *widened* the clip
    /// to the new box and every stroke inside it was emitted `.insideClip` at full
    /// confidence, invisible on the page (BH-329, BH-331). While this is set ``clip``
    /// keeps the box that was in force before the emptying intersection, so a primitive
    /// recorded against it is correctly outside it.
    var clipIsEmpty: Bool = false
    /// A soft mask is in force, so visibility depends on compositing not performed here.
    var hasSoftMask: Bool
    /// The non-stroking colour space (`cs`, `g`, `rg`, `k`). Initially `DeviceGray`.
    var fillColorSpace: VectorColorSpace = .deviceGray
    /// The stroking colour space (`CS`, `G`, `RG`, `K`). Initially `DeviceGray`.
    var strokeColorSpace: VectorColorSpace = .deviceGray
    /// The non-stroking colour, opaque, or `nil` when it cannot be stated. Initially
    /// black (PDF 32000-1 Table 52: the initial colour is black in `DeviceGray`).
    var fillColor: VectorColor? = .black
    /// The stroking colour, opaque, or `nil` when it cannot be stated. Initially black.
    var strokeColor: VectorColor? = .black

    /// Intersects the clip with `box` (PDF 32000-1 8.5.4: "the new clipping path shall be
    /// the intersection of the current clipping path and the path"). A disjoint box
    /// empties the clip rather than replacing it.
    mutating func intersectClip(with box: VectorBounds) {
        guard !clipIsEmpty else { return }
        guard let current = clip else {
            clip = box
            return
        }
        if let intersection = current.intersection(box) {
            clip = intersection
        } else {
            clipIsEmpty = true
        }
    }

    /// The fill colour to stamp on a primitive painted now, with `ca` applied.
    var paintedFillColor: VectorColor? { fillColor?.withAlpha(fillAlpha) }
    /// The stroke colour to stamp on a primitive painted now, with `CA` applied.
    var paintedStrokeColor: VectorColor? { strokeColor?.withAlpha(strokeAlpha) }

    // Marked content (`BDC … EMC`) is deliberately *not* part of this struct. `q`/`Q` save
    // and restore the graphics state; marked-content sections are lexical and nest
    // independently of it (PDF 32000-1 8.11.3.2), so `BDC q … EMC … Q` must not restore a
    // hidden section that has already ended, and `q BDC … Q` must not end one that has not.
    // The hidden-content depth and the layer name live on ``VectorScanState`` (CR-39).

    static let initial = VectorGraphicsState(
        ctm: .identity,
        lineWidth: 1.0,
        isDashed: false,
        strokeAlpha: 1.0,
        fillAlpha: 1.0,
        clip: nil,
        hasSoftMask: false
    )

    /// The stroke width in page space.
    ///
    /// A CTM can scale anisotropically; the width of a stroked ribbon then depends on
    /// direction and no single number is correct. `sqrt(|det|)` is the standard scalar
    /// summary and is exact for every similarity transform, which is what real drawings
    /// use. Line width `0` means "thinnest renderable line" in PDF and stays `0`.
    func pageSpaceLineWidth() -> Double {
        guard lineWidth != 0 else { return 0 }
        let determinant = abs(ctm.a * ctm.d - ctm.b * ctm.c)
        return lineWidth * determinant.squareRoot()
    }
}

/// A colour space as far as the extractor can convert colours in it to ``VectorColor``.
///
/// `CalGray`, `CalRGB` and `ICCBased` with `/N` 1, 3 or 4 are folded into the device space
/// with the same component count — their calibration is ignored, as documented on
/// ``VectorColor``. Everything else is ``unsupported``: a colour set in it is `nil`.
enum VectorColorSpace: Equatable {
    case deviceGray
    case deviceRGB
    case deviceCMYK
    /// `Pattern`, `Indexed`, `Separation`, `DeviceN`, `Lab`, or a space that could not be
    /// resolved. Colours in it are never guessed.
    case unsupported

    /// The operand count of `sc`/`scn` in this space, or `nil` when unsupported.
    var componentCount: Int? {
        switch self {
        case .deviceGray: return 1
        case .deviceRGB: return 3
        case .deviceCMYK: return 4
        case .unsupported: return nil
        }
    }

    /// The initial colour when the space is selected by `cs`/`CS` (PDF 32000-1 8.6.8:
    /// black for every device space; the initial `Pattern` colour is "no pattern").
    var initialColor: VectorColor? {
        self == .unsupported ? nil : .black
    }

    /// Converts `components`, in operand order, to a colour. `nil` when the count is
    /// wrong or the space is unsupported.
    func color(_ components: [Double]) -> VectorColor? {
        guard components.count == componentCount else { return nil }
        switch self {
        case .deviceGray:
            return VectorColor(deviceGray: components[0])
        case .deviceRGB:
            return VectorColor(red: components[0], green: components[1], blue: components[2])
        case .deviceCMYK:
            return VectorColor(
                deviceCyan: components[0], magenta: components[1],
                yellow: components[2], black: components[3]
            )
        case .unsupported:
            return nil
        }
    }

    /// The space a name selects directly, without a resource lookup, or `nil` when the
    /// name must be looked up in `/ColorSpace`.
    static func named(_ name: String) -> VectorColorSpace? {
        switch name {
        case "DeviceGray", "CalGray": return .deviceGray
        case "DeviceRGB", "CalRGB": return .deviceRGB
        case "DeviceCMYK": return .deviceCMYK
        case "Pattern", "Lab", "Indexed", "Separation", "DeviceN", "ICCBased": return .unsupported
        default: return nil
        }
    }

    /// The space a component count selects for `ICCBased` (`/N`).
    static func withComponentCount(_ count: Int) -> VectorColorSpace {
        switch count {
        case 1: return .deviceGray
        case 3: return .deviceRGB
        case 4: return .deviceCMYK
        default: return .unsupported
        }
    }
}

/// One segment of a subpath under construction, already in page space.
enum VectorPathSegment {
    case line(VectorLine)
    case cubic(VectorCubic)

    var startPoint: CGPoint {
        switch self {
        case .line(let line): return line.start
        case .cubic(let cubic): return cubic.p0
        }
    }

    var endPoint: CGPoint {
        switch self {
        case .line(let line): return line.end
        case .cubic(let cubic): return cubic.p3
        }
    }

    var bounds: VectorBounds {
        switch self {
        case .line(let line): return line.bounds
        case .cubic(let cubic): return cubic.bounds
        }
    }
}

/// One subpath under construction.
///
/// Bounds are tracked as segments are appended (IM-236): a subpath's bounds are read four
/// or five times on the way to emission — the painted path's union, the degeneracy test,
/// the filter record, the emitted shape — and each read used to walk every segment and
/// re-solve every cubic's derivative roots. The per-segment bounds are kept alongside the
/// segments so the emitted primitives reuse them too.
struct VectorSubpathBuilder {
    var startPoint: CGPoint
    var currentPoint: CGPoint
    private(set) var segments: [VectorPathSegment] = []
    /// `segmentBounds[i]` is `segments[i].bounds`, computed once at append.
    private(set) var segmentBounds: [VectorBounds] = []
    /// On-curve vertices in drawing order, first vertex not repeated at the end.
    var vertices: [CGPoint]
    var isClosed = false
    var containsCurves = false
    /// Set when the subpath came from a single `re` operator.
    var rectangleQuad: VectorQuad?
    /// The union of the start point and every appended segment's bounds.
    private(set) var bounds: VectorBounds

    init(startPoint: CGPoint) {
        self.startPoint = startPoint
        self.currentPoint = startPoint
        self.vertices = [startPoint]
        self.bounds = VectorBounds(point: startPoint)
    }

    mutating func append(_ segment: VectorPathSegment) {
        let box = segment.bounds
        segments.append(segment)
        segmentBounds.append(box)
        bounds = bounds.union(box)
    }

    /// Replaces the segment list wholesale (the `re` operator builds all four at once).
    mutating func setSegments(_ newSegments: [VectorPathSegment]) {
        segments = newSegments
        segmentBounds = newSegments.map(\.bounds)
        var result = VectorBounds(point: startPoint)
        for box in segmentBounds { result = result.union(box) }
        bounds = result
    }

    /// A subpath with no extent at all is not geometry a person can snap to.
    var isDegenerate: Bool {
        if segments.isEmpty { return true }
        let box = bounds
        return box.width == 0 && box.height == 0
    }
}
