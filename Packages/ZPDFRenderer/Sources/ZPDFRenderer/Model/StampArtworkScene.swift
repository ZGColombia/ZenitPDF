import Foundation
import ZPDFContracts

/// A stamp's artwork as **geometry**, in unit space.
///
/// This is where "vector artwork stays vector so a stamp is sharp at 400 %"
/// stops being a slogan. Artwork imported from a PDF page is compiled
/// once into contours expressed in a `0...1` box, and from then on it is drawn the way
/// every other markup is drawn: as paths, at whatever transform the viewport is at. There
/// is no image in the pipeline to resample, so there is nothing that can blur — the same
/// argument the vector underlay makes for the drawing itself, applied to the stamp on top
/// of it.
///
/// Unit space rather than page space because a template is resizable: one compilation
/// serves a 96-point stamp in a detail and a 400-point stamp on a title sheet, and 312
/// placements of it share one compiled artwork.
public struct StampArtworkGeometry: Sendable, Hashable, Codable {

    /// Open and closed contours to stroke, in unit space.
    public var strokes: [RenderPolyline]
    /// Regions to fill, in unit space.
    public var fills: [RenderPolygon]

    /// Creates compiled artwork.
    public init(strokes: [RenderPolyline] = [], fills: [RenderPolygon] = []) {
        self.strokes = strokes
        self.fills = fills
    }

    /// Artwork with nothing in it, for a stamp that is fields and a border only.
    public static let empty = StampArtworkGeometry()

    /// Whether there is anything to draw.
    public var isEmpty: Bool { strokes.isEmpty && fills.isEmpty }

    /// How many primitives the artwork costs per placement.
    ///
    /// Worth surfacing rather than hiding: a 40 000-primitive logo stamped on 312 sheets is
    /// 12.5 million primitives, and the batch sheet can warn instead of the frame rate
    /// explaining it later.
    public var primitiveCount: Int { strokes.count + fills.count }
}

/// One resolved field, placed inside the stamp box.
///
/// The text is already resolved and frozen — the renderer never sees a field *kind*, only
/// the string it resolved to, which is the structural reason nothing downstream of
/// placement can re-derive a stamp's date.
public struct StampSceneLabel: Sendable, Hashable, Codable {

    /// The frozen text.
    public var text: String
    /// The field's box inside the stamp, in unit space.
    public var normalizedFrame: PDFRect
    /// Font family name.
    public var fontName: String
    /// Font size as a fraction of the stamp box height.
    public var fontSizeFraction: Double
    /// Where inside its frame the text sits.
    public var anchor: TextAnchor

    /// Creates a scene label.
    public init(
        text: String,
        normalizedFrame: PDFRect,
        fontName: String = "Helvetica",
        fontSizeFraction: Double = 0.2,
        anchor: TextAnchor = .centerLeading
    ) {
        self.text = text
        self.normalizedFrame = normalizedFrame
        self.fontName = fontName
        self.fontSizeFraction = fontSizeFraction
        self.anchor = anchor
    }
}

/// Turning a placed stamp into the renderer's ordinary shapes.
///
/// Deliberately produces `RenderableMarkup` values built from the **existing**
/// ``RenderShape`` cases — polylines, filled polygons and text labels. A stamp is not a new
/// kind of thing to draw; it is a small arrangement of the things this renderer already
/// draws, which is why it needs no new backend code, no new atlas and no new golden
/// pipeline, and why it hit-tests and culls correctly for free.
public enum StampArtworkScene {

    /// The shapes one placed stamp contributes to a page.
    ///
    /// - Parameters:
    ///   - artwork: the compiled artwork, in unit space.
    ///   - labels: the resolved fields, in unit space.
    ///   - center: the stamp's anchor in page space — the point the placement resolved to.
    ///   - size: the stamp box in PDF points.
    ///   - rotationDegrees: rotation about ``center``, counter-clockwise.
    ///   - style: the stroke and fill the markups carry.
    ///   - baseID: the placed markup's identity. Every shape derives an id from it through
    ///     ``shapeIdentity(base:ordinal:)``, so the renderer's one-entry-per-identity indexes
    ///     hold every shape, and every shape's id carries `baseID` as its family: a consumer
    ///     that needs the whole stamp — the layered export, the snippet resolver — matches on
    ///     that family (``isPart(_:of:)`` states the rule). See ADR-0011 §2.6.
    ///   - zIndex: painter's-algorithm order for the whole stamp.
    /// - Returns: the shapes, artwork first and labels on top.
    public static func markups(
        artwork: StampArtworkGeometry,
        labels: [StampSceneLabel],
        center: PDFPoint,
        size: PDFSize,
        rotationDegrees: Double = 0,
        style: RenderStyle = .default,
        baseID: MarkupID,
        zIndex: Int = 0
    ) -> [RenderableMarkup] {
        let place = placement(center: center, size: size, rotationDegrees: rotationDegrees)
        var output: [RenderableMarkup] = []
        output.reserveCapacity(artwork.primitiveCount + labels.count)
        var ordinal = 0
        func nextID() -> MarkupID {
            defer { ordinal += 1 }
            return shapeIdentity(base: baseID, ordinal: ordinal)
        }

        for fill in artwork.fills {
            output.append(RenderableMarkup(
                id: nextID(),
                zIndex: zIndex,
                shape: .filledPolygon(RenderPolygon(
                    outer: fill.outer.map(place),
                    holes: fill.holes.map { $0.map(place) }
                )),
                style: style
            ))
        }
        for stroke in artwork.strokes {
            output.append(RenderableMarkup(
                id: nextID(),
                zIndex: zIndex,
                shape: .polyline(RenderPolyline(
                    points: stroke.points.map(place),
                    isClosed: stroke.isClosed
                )),
                style: style
            ))
        }
        // One label path for composed and imported artwork, so a field sits, and turns, the
        // same way in both (T-065 found the composed path carrying its own copy).
        output.append(contentsOf: labelMarkups(
            labels, place: place, size: size, rotationDegrees: rotationDegrees, style: style,
            baseID: baseID, firstOrdinal: ordinal, zIndex: zIndex
        ))
        return output
    }

    /// The unit-space → page-space map for one placement.
    ///
    /// An affine map and nothing else, which is the property the whole "stays sharp" claim
    /// rests on: enlarging a stamp multiplies coordinates, it does not sample anything.
    public static func placement(
        center: PDFPoint,
        size: PDFSize,
        rotationDegrees: Double = 0
    ) -> (PDFPoint) -> PDFPoint {
        let radians = rotationDegrees * .pi / 180
        let cosine = cos(radians)
        let sine = sin(radians)
        let width = size.width
        let height = size.height
        return { unit in
            // Unit space has its origin at the box's lower-left; the box is centred on the
            // anchor, so the offset is measured from the middle.
            let x = (unit.x - 0.5) * width
            let y = (unit.y - 0.5) * height
            return PDFPoint(
                x: center.x + x * cosine - y * sine,
                y: center.y + x * sine + y * cosine
            )
        }
    }

    /// Where in a label's unit-space frame its text is anchored.
    ///
    /// "Inside the frame" on both axes: a leading anchor puts the text's leading edge on the
    /// frame's leading edge, and a top anchor puts the text's top on the frame's top (unit space
    /// is y-up, so that is `maxY`), where the compiler hangs the glyphs downwards from it. The
    /// vertical used to be the frame's midline for every anchor, so a top-anchored field hung
    /// into the lower half of its slot and a bottom-anchored one rose into the upper half
    /// (BH-635). A centred anchor is unchanged.
    static func labelAnchorPoint(frame: PDFRect, anchor: TextAnchor) -> PDFPoint {
        PDFPoint(
            x: frame.origin.x + anchor.horizontalFraction * frame.size.width,
            y: frame.origin.y + (1 - anchor.verticalFraction) * frame.size.height
        )
    }
}
