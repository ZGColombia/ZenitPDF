import Foundation

// MARK: - Seams the drawing input flow needs beyond `MeasurementToolPresenting`

/// The one thing counting needs from the measurement presenter that measuring does not:
/// removing a point that is *not* the last one.
///
/// ⌥-clicking the third mark of a group of nine removes the third mark. `removeLastPoint()`
/// cannot express that. The input flow (`ZPDFUIMeasurement.MeasurementInputController`) calls
/// this, and the application tier's measurement presenter adopts it. Presenters that do not
/// conform keep working: the controller then leaves the group untouched rather than removing
/// the wrong point.
///
/// Declared here, beside `MeasurementToolPresenting`, rather than in the input package, so the
/// application core can adopt it without depending on a UI package (IM-019).
@MainActor
public protocol CountPointEditing: AnyObject {

    /// Removes the point at `index` from the count group in progress.
    ///
    /// - Parameter index: a position in the presenter's `placedPoints`.
    func removePoint(at index: Int)
}

/// Commits a cutout against its parent instead of as a free markup.
///
/// This is the second half of the cutout fix: the geometry already exists,
/// `DocumentCommand.addCutout(parent:cutout:)` already recomputes the parent and already carries
/// its own undo inverse — what was missing was a caller. The input flow's controller becomes
/// that caller through this protocol.
///
/// Declared here for the same reason as ``CountPointEditing`` (IM-019).
@MainActor
public protocol CutoutCommitting: AnyObject {

    /// Commits the cutout in progress as a child of `parentMarkupID`.
    ///
    /// Implementations route to `DocumentCommand.addCutout`, never to `.addMarkup`: a cutout
    /// that lands as a free polygon subtracts nothing and is the defect this replaces.
    func commitActiveCutout(parentMarkupID: UUID)
}

/// Draws the next segment of a shape in progress as a circular arc (NL-MEASURE-05, ADR-0030 §5.6).
///
/// A while drawing arms it; the next click is a point the arc passes through, and the click after
/// that is the arc's end — a three-point arc. The presenter holds the through point and bends the
/// segment when the end lands, as a bulge on the committed geometry, so the quantity is the arc's
/// exact length and area and never its chords.
///
/// Declared here for the same reason as ``CountPointEditing`` (IM-019).
@MainActor
public protocol ArcSegmentDrawing: AnyObject {

    /// Whether the next segment is an arc.
    var isArcNextSegment: Bool { get }
    /// The through point of the arc in progress, once it has been placed.
    var arcThroughPoint: PDFPointValue? { get }
    /// Arms (or disarms) an arc for the next segment. Disarming forgets a placed through point.
    func setArcNextSegment(_ isArc: Bool)
    /// Places the through point of the arc in progress (snapped like a vertex).
    func placeArcThroughPoint(_ point: PDFPointValue)
    /// Removes the through point of the arc in progress; the arc stays armed.
    func removeArcThroughPoint()
    /// Whether the shape in progress can take an arc segment right now (ADR-0030 §5.7). `false`
    /// while the armed tool is drawing something other than a measurement — a Scale Region or
    /// Project Zone boundary, whose edges are straight — so the input machine never arms an arc
    /// the presenter would refuse and then takes the next click for a through point nobody hears.
    var drawsArcSegments: Bool { get }
}

extension ArcSegmentDrawing {
    /// A host that adopts ``ArcSegmentDrawing`` draws arcs unless it says otherwise.
    public var drawsArcSegments: Bool { true }
}
