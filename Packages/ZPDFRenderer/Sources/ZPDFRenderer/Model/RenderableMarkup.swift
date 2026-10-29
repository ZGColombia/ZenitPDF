import Foundation
import ZPDFContracts

/// One markup, reduced to exactly what a renderer needs.
///
/// # Why `revision` exists
///
/// The Metal backend keeps every markup's instances in a persistent GPU buffer and rewrites only
/// the slots that changed. Deciding "changed" by deep-comparing geometry would cost more than
/// re-uploading it, so the producer stamps a monotonically increasing ``revision`` whenever it
/// mutates a markup. `(id, revision)` unchanged means the slot is untouched, and that single
/// integer is what makes dragging one markup in a 100 000-markup page cost one slot write instead
/// of a full rebuild. A producer that never bumps the revision gets a stale picture; a producer
/// that always bumps it gets a correct picture and no incremental win. Both fail loudly in the
/// incremental-update test rather than quietly on screen.
public struct RenderableMarkup: Sendable, Hashable, Identifiable, Codable {
    public let id: MarkupID
    /// Bumped by the producer on every geometry or style change. See the type's discussion.
    public var revision: UInt64
    /// Painter's-algorithm order. Ties are broken by ``id`` so ordering is total and stable.
    public var zIndex: Int
    public var shape: RenderShape
    public var style: RenderStyle
    /// Hidden markups occupy no instance slots at all; they are not drawn transparently.
    public var isHidden: Bool

    public init(
        id: MarkupID,
        revision: UInt64 = 0,
        zIndex: Int = 0,
        shape: RenderShape,
        style: RenderStyle = .default,
        isHidden: Bool = false
    ) {
        self.id = id
        self.revision = revision
        self.zIndex = zIndex
        self.shape = shape
        self.style = style
        self.isHidden = isHidden
    }

    /// The markup's page-space bounding box **without** the stroke, or `nil` when it has no
    /// drawable geometry. Text labels report a zero-size box at their anchor: their extent is a
    /// pixel-space quantity that only ``GlyphAtlas`` can answer.
    public var geometryBounds: PDFRect? {
        switch shape {
        case let .polyline(line):
            return Self.bounds(of: line.points)
        case let .filledPolygon(polygon):
            var box = Self.bounds(of: polygon.outer)
            for hole in polygon.holes {
                guard let holeBox = Self.bounds(of: hole) else { continue }
                box = box.map { $0.union(holeBox) } ?? holeBox
            }
            return box
        case let .countSymbol(symbol):
            guard symbol.center.isFinite, symbol.size.isFinite, symbol.size > 0 else { return nil }
            let half = symbol.size / 2
            return PDFRect(
                x: symbol.center.x - half,
                y: symbol.center.y - half,
                width: symbol.size,
                height: symbol.size
            )
        case let .textLabel(label):
            guard label.anchorPoint.isFinite else { return nil }
            return PDFRect(x: label.anchorPoint.x, y: label.anchorPoint.y, width: 0, height: 0)
        case let .dimensionLine(dimension):
            // The measured span only. Arrowheads, ticks and the pill are view-sized decoration;
            // the compiler reports their reach through the compiled bounds and ink padding.
            return Self.bounds(of: [dimension.start, dimension.end])
        case let .labelPill(pill):
            guard pill.anchorPoint.isFinite else { return nil }
            return PDFRect(x: pill.anchorPoint.x, y: pill.anchorPoint.y, width: 0, height: 0)
        case let .image(image):
            return Self.bounds(of: image.corners)
        }
    }

    private static func bounds(of points: [PDFPoint]) -> PDFRect? {
        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity
        var seen = false
        for point in points where point.isFinite {
            seen = true
            minX = Swift.min(minX, point.x); maxX = Swift.max(maxX, point.x)
            minY = Swift.min(minY, point.y); maxY = Swift.max(maxY, point.y)
        }
        guard seen else { return nil }
        return PDFRect(corner: PDFPoint(x: minX, y: minY), opposite: PDFPoint(x: maxX, y: maxY))
    }
}

/// Which markups are selected, and which one owns the handles.
///
/// This lives outside ``RenderableMarkup`` on purpose. Selection changes on every click and hover;
/// geometry does not. Keeping them apart is what lets the Metal backend repaint the overlay pass
/// without touching the geometry buffers — see `MetalMarkupRenderer`'s two-pass structure.
public struct SelectionSnapshot: Sendable, Hashable, Codable {
    /// Every selected markup, in no particular order.
    public var selectedIDs: Set<MarkupID>
    /// The markup whose resize handles are drawn, when exactly one is primary.
    public var primaryID: MarkupID?
    /// The markup under the pointer, drawn with a hover outline.
    public var hoveredID: MarkupID?
    /// Handle side length in **view points**, so a handle is the same physical size at any zoom.
    public var handleSizeViewPoints: Double

    public init(
        selectedIDs: Set<MarkupID> = [],
        primaryID: MarkupID? = nil,
        hoveredID: MarkupID? = nil,
        handleSizeViewPoints: Double = 7
    ) {
        self.selectedIDs = selectedIDs
        self.primaryID = primaryID
        self.hoveredID = hoveredID
        self.handleSizeViewPoints = handleSizeViewPoints
    }

    public static let empty = SelectionSnapshot()

    public var isEmpty: Bool {
        selectedIDs.isEmpty && primaryID == nil && hoveredID == nil
    }
}

/// The snap glyph and construction geometry, in the shape the renderer consumes.
///
/// This is the view-layer projection of `ZPDFSnapEngine.SnapFeedback`. The renderer takes its own
/// type so that it does not drag the snap engine, the vector extractor and their dependencies
/// into every process that wants to draw a page; the app owns the two-field adapter.
public struct RenderSnapFeedback: Sendable, Hashable, Codable {
    /// A construction line or circle drawn alongside the glyph.
    public enum Guide: Sendable, Hashable, Codable {
        case none
        case segment(from: PDFPoint, to: PDFPoint)
        case circle(center: PDFPoint, radius: Double)
    }

    /// The point the cursor has snapped to.
    public var point: PDFPoint
    /// Which glyph to draw. Mirrors `SnapKind` without depending on it.
    public var glyph: CountSymbol
    public var guide: Guide
    /// True when hysteresis is holding the candidate, drawn distinctly so the UI does not look
    /// like it is lagging.
    public var isHeldByHysteresis: Bool
    /// Glyph side length in **view points**.
    public var glyphSizeViewPoints: Double

    public init(
        point: PDFPoint,
        glyph: CountSymbol = .cross,
        guide: Guide = .none,
        isHeldByHysteresis: Bool = false,
        glyphSizeViewPoints: Double = 11
    ) {
        self.point = point
        self.glyph = glyph
        self.guide = guide
        self.isHeldByHysteresis = isHeldByHysteresis
        self.glyphSizeViewPoints = glyphSizeViewPoints
    }
}
