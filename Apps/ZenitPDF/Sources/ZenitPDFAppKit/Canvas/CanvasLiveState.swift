import AppKit
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation

/// Everything the canvas's live overlay draws, as one value (IM-163).
///
/// Before this, `CanvasPageView` carried about fifteen independent live properties, each with
/// its own `didSet`, and the controller assigned them one by one on every refresh. The state is
/// now three small groups, each compared once. A change repaints the union of the old and the
/// new group's ink bounds on the overlay only, never the page view with its raster and
/// committed markups.
///
/// The groups follow what changes together:
/// - ``Drawing``: the measurement or markup being placed. Changes when a point is placed or
///   the pointer moves while placing.
/// - ``Pointer``: the snap ring and the Select tool's rubber band. Changes at pointer rate.
/// - ``Calibration``: the two reference points and the live segment of a calibration.
struct CanvasLiveState: Equatable {

    /// The measurement or markup in progress.
    struct Drawing: Equatable {
        /// Vertices placed so far by the armed tool.
        var points: [PDFPointValue] = []
        /// Arc segments while drawing (NL-MEASURE-05, ADR-0030 §5.6): the bulge of the edge from
        /// point `i` to point `i + 1`; empty, or `0`, is straight.
        var bulges: [Double] = []
        /// The point the arc segment in progress passes through; the rubber band to the pointer
        /// is drawn as that arc.
        var arcThroughPoint: PDFPointValue?
        /// Whether the armed tool closes its outline.
        var closesOutline = false
        /// The live readout drawn beside the measurement in progress.
        var caption: String?
        /// The pointer in page space while a measurement is in progress; the rubber band runs
        /// from the last placed vertex to it.
        var cursorPoint: PDFPointValue?
        /// The first vertex, when the next click would close the polygon on it.
        var firstVertexCloseTarget: PDFPointValue?
        /// The anchor corner of a one-gesture drag tool in progress.
        var dragAnchor: PDFPointValue?
        /// The inferred quadrilateral of a three-point rectangle following the cursor.
        var inferredQuad: [PDFPointValue]?
        /// Whether the placed points are points (Count), never a path.
        var isPointPlacement = false
        /// The markup kind being drawn, so the preview is the shape that will be committed.
        var markupKind: ZPDFUIPresentation.MarkupKind?
        /// The keyboard cursor while it leads a measurement (R-137), drawn as a crosshair;
        /// `nil` while the pointer leads.
        var keyboardCursor: PDFPointValue?

        /// The caption the overlay actually draws: a Count's running total joined to the
        /// readout, otherwise the readout. One function for the drawing and the dirty rect.
        var displayedCaption: String? {
            guard isPointPlacement, !points.isEmpty else { return caption }
            let runningTotal = String(
                format: NSLocalizedString(
                    "%d placed",
                    comment: "Live count readout: how many count points are in the group so far"
                ),
                points.count
            )
            return caption.map { "\($0)  \(runningTotal)" } ?? runningTotal
        }

        /// Where the caption pill hangs, in page space.
        var captionAnchor: PDFPointValue? {
            if dragAnchor != nil { return cursorPoint }
            if let quad = inferredQuad, quad.count >= 3 { return cursorPoint ?? quad.last }
            return cursorPoint ?? points.last
        }

        /// The placed path with its arcs flattened for drawing (the screen's 0.01 pt), or the
        /// placed points themselves when every edge is straight.
        var drawnPath: [PDFPointValue] {
            guard bulges.contains(where: { $0 != 0 }), points.count >= 2 else { return points }
            var path: [PDFPointValue] = [points[0]]
            for index in 0..<(points.count - 1) {
                let bulge = index < bulges.count ? bulges[index] : 0
                let start = points[index], end = points[index + 1]
                guard bulge != 0 else { path.append(end); continue }
                path.append(contentsOf: BulgeArc.flattened(
                    from: PDFPoint(x: start.x, y: start.y), to: PDFPoint(x: end.x, y: end.y),
                    bulge: bulge, tolerance: CanvasSceneBuilder.arcDrawingTolerance
                ).map { PDFPointValue(x: $0.x, y: $0.y) })
            }
            return path
        }

        /// The rubber band from the last vertex to the pointer: the arc through
        /// ``arcThroughPoint`` while an arc is being drawn, otherwise the straight segment.
        var rubberBand: [PDFPointValue]? {
            guard let cursorPoint, let last = points.last else { return nil }
            guard let through = arcThroughPoint,
                  let bulge = MarkupTopologyEditing.bulge(
                    from: PDFPoint(x: last.x, y: last.y),
                    to: PDFPoint(x: cursorPoint.x, y: cursorPoint.y),
                    through: PDFPoint(x: through.x, y: through.y)
                  ), bulge != 0 else { return [last, cursorPoint] }
            return [last] + BulgeArc.flattened(
                from: PDFPoint(x: last.x, y: last.y), to: PDFPoint(x: cursorPoint.x, y: cursorPoint.y),
                bulge: bulge, tolerance: CanvasSceneBuilder.arcDrawingTolerance
            ).map { PDFPointValue(x: $0.x, y: $0.y) }
        }

        /// Every page point the drawing puts ink near.
        var inkPoints: [PDFPointValue] {
            var all = drawnPath
            if let band = rubberBand { all.append(contentsOf: band) }
            if let arcThroughPoint { all.append(arcThroughPoint) }
            if let cursorPoint { all.append(cursorPoint) }
            if let firstVertexCloseTarget { all.append(firstVertexCloseTarget) }
            if let dragAnchor { all.append(dragAnchor) }
            if let inferredQuad { all.append(contentsOf: inferredQuad) }
            if let keyboardCursor { all.append(keyboardCursor) }
            return all
        }
    }

    /// Pointer-rate feedback that is not part of a placement.
    struct Pointer: Equatable {
        /// Where the snap engine says the pointer will land.
        var snapPoint: PDFPointValue?
        /// The Select tool's rubber band, in page space.
        var selectionMarquee: PDFRectValue?
    }

    /// A calibration in progress.
    struct Calibration: Equatable {
        /// The reference points placed so far.
        var points: [PDFPointValue] = []
        /// The pointer, so a live segment can follow it.
        var cursor: PDFPointValue?
    }

    var drawing = Drawing()
    var pointer = Pointer()
    var calibration = Calibration()

    // MARK: - Dirty rectangles

    /// View points around every live point that handles, rings, arrowheads and dashes can
    /// reach: the close ring is 7 pt in radius plus its stroke, an arrowhead 9 pt long.
    static let inkPadding: CGFloat = 14

    /// The view rectangle that must repaint when the live state goes from `old` to `new`:
    /// the old and new ink of every group that changed, and nothing for a group that did not.
    /// `nil` means "the whole overlay" (no transform to map through).
    static func dirtyRect(
        from old: CanvasLiveState,
        to new: CanvasLiveState,
        transform: PageDisplayTransform?,
        captionSize: (String) -> CGSize
    ) -> CGRect? {
        guard let transform else { return nil }
        var rect = CGRect.null
        if old.drawing != new.drawing {
            rect = rect.union(inkBounds(of: old.drawing, transform: transform, captionSize: captionSize))
            rect = rect.union(inkBounds(of: new.drawing, transform: transform, captionSize: captionSize))
        }
        if old.pointer != new.pointer {
            rect = rect.union(inkBounds(of: old.pointer, transform: transform))
            rect = rect.union(inkBounds(of: new.pointer, transform: transform))
        }
        if old.calibration != new.calibration {
            rect = rect.union(inkBounds(of: old.calibration, transform: transform))
            rect = rect.union(inkBounds(of: new.calibration, transform: transform))
        }
        return rect
    }

    /// Where a drawing in progress puts ink, in view space, including its caption pill on
    /// whichever side of the anchor ``CanvasPageView/anchoredPillBox(size:anchor:visible:)``
    /// flips it to.
    static func inkBounds(
        of drawing: Drawing,
        transform: PageDisplayTransform,
        captionSize: (String) -> CGSize
    ) -> CGRect {
        var rect = bounds(of: drawing.inkPoints, transform: transform)
        guard !rect.isNull else { return rect }
        rect = rect.insetBy(dx: -inkPadding, dy: -inkPadding)
        if let caption = drawing.displayedCaption, let anchor = drawing.captionAnchor {
            let size = captionSize(caption)
            let box = CanvasMarkupStyle.pillBoxSize(forText: size)
            let view = transform.viewPoint(from: anchor)
            let reach = CGRect(
                x: view.x - box.width - CanvasMarkupStyle.pillAnchorGap - 2,
                y: view.y - box.height - 2,
                width: (box.width + CanvasMarkupStyle.pillAnchorGap + 2) * 2,
                height: box.height * 2 + CanvasMarkupStyle.pillAnchorGap + 4
            )
            rect = rect.union(reach)
        }
        return rect
    }

    static func inkBounds(of pointer: Pointer, transform: PageDisplayTransform) -> CGRect {
        var rect = CGRect.null
        if let snap = pointer.snapPoint {
            rect = rect.union(bounds(of: [snap], transform: transform).insetBy(dx: -inkPadding, dy: -inkPadding))
        }
        if let marquee = pointer.selectionMarquee {
            rect = rect.union(transform.viewRect(from: marquee).standardized.insetBy(dx: -4, dy: -4))
        }
        return rect
    }

    static func inkBounds(of calibration: Calibration, transform: PageDisplayTransform) -> CGRect {
        var points = calibration.points
        guard !points.isEmpty else { return .null }
        if let cursor = calibration.cursor { points.append(cursor) }
        return bounds(of: points, transform: transform).insetBy(dx: -inkPadding, dy: -inkPadding)
    }

    private static func bounds(of points: [PDFPointValue], transform: PageDisplayTransform) -> CGRect {
        var rect = CGRect.null
        for point in points {
            rect = rect.union(CGRect(origin: transform.viewPoint(from: point), size: .zero))
        }
        return rect
    }
}
