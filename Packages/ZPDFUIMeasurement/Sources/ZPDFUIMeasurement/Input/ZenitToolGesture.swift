import Foundation
import ZPDFUIPresentation

/// How the canvas collects input for one armed tool.
///
/// The canvas used to answer these questions by reaching into
/// `core.measurement.activeKind?.…`, which is why every tool that was not a measurement
/// fell through to Select and why Count drew a polyline through its own dots. One value now
/// answers them for **both** families, and `ZenitToolMode.gesture` is a total function, so a
/// new tool cannot be added without deciding how it is drawn.
public struct ZenitToolGesture: Sendable, Hashable {

    /// Whether the tool collects page points at all.
    public var collectsPoints: Bool
    /// The fewest points that make a committable shape.
    public var minimumPointCount: Int
    /// The exact point count that finishes the tool without a confirmation step, or `nil`
    /// for a variable-vertex tool the user finishes explicitly.
    public var completingPointCount: Int?
    /// Whether one press-drag-release draws the whole shape.
    public var usesDragGesture: Bool
    /// Whether a press and release without movement is a *click* on a drag tool — the
    /// three-point rectangle, Text, and the two-point shapes, which all accept both.
    public var dragAlsoPlacesClicks: Bool
    /// Whether clicking the first vertex again closes and commits.
    public var closesOnFirstVertex: Bool
    /// Whether the live outline is drawn closed and filled.
    public var closesOutline: Bool
    /// Whether the last corner is derived rather than placed (the three-point rectangle).
    public var derivesFourthCorner: Bool
    /// Whether the placed points are *points*, never a path.
    ///
    /// Count's dots are not a polyline. This flag is the one that stops the live overlay
    /// stroking a polygon through them.
    public var isPointPlacement: Bool
    /// Whether committing needs typed text, so the canvas must open its editor.
    public var needsTextEntry: Bool
    /// Whether `⌥` on a click turns the two vertices already placed into one edge of a
    /// three-point rectangle, derives the fourth corner and commits.
    ///
    /// This is how **one** Area tool offers all three area gestures (polygon clicks,
    /// press-drag-release rectangle, three-point rectangle)
    /// without them contradicting each other. A polygon and a three-point rectangle are
    /// indistinguishable from three plain clicks — the third click either finishes a
    /// rectangle or continues a polygon, and it cannot do both — so the rectangle's third
    /// click is the one the user marks. `⌥` is free while an area is being drawn (it
    /// un-places a mark only on the point-placement tools) and it already reads as "the
    /// other meaning of this click" everywhere else in the product: `⌥`-click zooms out,
    /// `⌥`-click un-places a count mark, `⌥`-drop adds a revision.
    ///
    /// `derivesFourthCorner` is the unconditional version, for the dedicated Rectangle
    /// Area tool, where every third click is a depth point because nothing else it could be.
    public var optionDerivesRectangle: Bool

    /// Creates a gesture description.
    public init(
        collectsPoints: Bool = true,
        minimumPointCount: Int = 2,
        completingPointCount: Int? = nil,
        usesDragGesture: Bool = false,
        dragAlsoPlacesClicks: Bool = false,
        closesOnFirstVertex: Bool = false,
        closesOutline: Bool = false,
        derivesFourthCorner: Bool = false,
        isPointPlacement: Bool = false,
        needsTextEntry: Bool = false,
        optionDerivesRectangle: Bool = false
    ) {
        self.collectsPoints = collectsPoints
        self.minimumPointCount = minimumPointCount
        self.completingPointCount = completingPointCount
        self.usesDragGesture = usesDragGesture
        self.dragAlsoPlacesClicks = dragAlsoPlacesClicks
        self.closesOnFirstVertex = closesOnFirstVertex
        self.closesOutline = closesOutline
        self.derivesFourthCorner = derivesFourthCorner
        self.isPointPlacement = isPointPlacement
        self.needsTextEntry = needsTextEntry
        self.optionDerivesRectangle = optionDerivesRectangle
    }

    /// The tool collects nothing on the canvas: Select, Pan and Zoom own the pointer
    /// themselves.
    public static let none = ZenitToolGesture(
        collectsPoints: false,
        minimumPointCount: 0
    )
}

public extension ZenitToolMode {

    /// How this tool is drawn. Total by construction: every case, both families.
    var gesture: ZenitToolGesture {
        switch self {
        case .select, .pan, .zoom:
            return .none
        case .calibrate:
            return ZenitToolGesture(minimumPointCount: 2, completingPointCount: 2)
        case .measure(let kind):
            return Self.gesture(measuring: kind)
        case .markup(let kind):
            return Self.gesture(marking: kind)
        }
    }

    /// The measurement family's gesture, derived from the semantics the measurement input
    /// state machine already enforces — one source of truth, not a second table.
    ///
    /// **Area is the one kind whose gesture is deliberately wider than its semantics.**
    /// `MeasurementKind.area` describes the *geometry* a polygon area measures, which is
    /// why `usesDragGesture` and `derivesFourthCorner` are false on it — the calculator
    /// neither knows nor cares how the ring was drawn. The Area tool offers three ways to
    /// draw that same ring from one button, so the extra two live here, where "how the
    /// canvas collects input" belongs, rather than being three separate kinds the estimator
    /// has to pick between.
    private static func gesture(measuring kind: MeasurementKind) -> ZenitToolGesture {
        let isArea = kind == .area
        return ZenitToolGesture(
            minimumPointCount: kind.minimumPointCount,
            completingPointCount: kind.completingPointCount,
            // Press-drag-release draws the area as a rectangle between two opposite
            // corners, and release finishes it — the same press-drag-release rule every drag
            // tool follows.
            usesDragGesture: kind.usesDragGesture || isArea,
            // …and a press that never moves is still a polygon vertex, so the click path
            // is untouched.
            dragAlsoPlacesClicks: kind.derivesFourthCorner || isArea,
            closesOnFirstVertex: kind.closesOnFirstVertex,
            // The outline the canvas draws closed is the outline that closes on its first
            // vertex. A second literal list of the same five kinds sat here, which is how
            // `.volume` once closed its outline without closing on its first vertex (R-143, S-095).
            closesOutline: kind.closesOnFirstVertex,
            derivesFourthCorner: kind.derivesFourthCorner,
            isPointPlacement: kind == .count,
            optionDerivesRectangle: isArea
        )
    }

    /// The markup family's gesture: Text, Callout and the shape tools.
    private static func gesture(marking kind: MarkupKind) -> ZenitToolGesture {
        switch kind {
        case .text:
            // "click places an insertion point, or drag defines a box": one gesture that
            // is a click when it does not move and a box when it does.
            return ZenitToolGesture(
                minimumPointCount: 1,
                completingPointCount: 1,
                usesDragGesture: true,
                dragAlsoPlacesClicks: true,
                needsTextEntry: true
            )
        case .callout:
            // "click the target point, then click or drag where the box goes".
            return ZenitToolGesture(
                minimumPointCount: 2,
                completingPointCount: 2,
                usesDragGesture: true,
                dragAlsoPlacesClicks: true,
                needsTextEntry: true
            )
        case .line, .arrow, .rectangle, .ellipse:
            // Press-drag-release for the two-point shapes; two clicks work too.
            return ZenitToolGesture(
                minimumPointCount: 2,
                completingPointCount: 2,
                usesDragGesture: true,
                dragAlsoPlacesClicks: true,
                closesOutline: kind == .rectangle || kind == .ellipse
            )
        case .polyline:
            // Click per vertex, finished by Return, double-click or a
            // secondary click.
            return ZenitToolGesture(minimumPointCount: 2)
        case .polygon, .cloud:
            return ZenitToolGesture(
                minimumPointCount: 3,
                closesOnFirstVertex: true,
                closesOutline: true
            )
        case .freehand:
            // Pen and Highlighter (NL-MARKUP-06): one press-drag-release samples the stroke.
            // A click without movement draws nothing.
            return ZenitToolGesture(minimumPointCount: 2, usesDragGesture: true)
        case .hyperlink:
            // A link region is drawn like a rectangle (NL-MARKUP-17).
            return ZenitToolGesture(
                minimumPointCount: 2,
                completingPointCount: 2,
                usesDragGesture: true,
                dragAlsoPlacesClicks: true,
                closesOutline: true
            )
        case .note:
            // A click places the note and opens its text in place (NL-MARKUP-17).
            return ZenitToolGesture(minimumPointCount: 1, completingPointCount: 1, needsTextEntry: true)
        case .highlight, .underline, .strikeout, .stamp, .image,
             .measurement, .count, .revisionCloud, .issue:
            // No tool in the product arms these; `ZenitToolMode.limitationNote` says so out
            // loud when one is armed, and collecting nothing is the honest behaviour.
            return .none
        }
    }
}
