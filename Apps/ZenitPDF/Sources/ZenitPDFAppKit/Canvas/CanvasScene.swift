import Foundation
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation

/// One drawable outline in page space.
public struct CanvasStroke: Sendable, Hashable {
    /// Vertices in page space, in order.
    public var points: [PDFPointValue]
    /// Whether the last vertex joins the first.
    public var closed: Bool
    /// Whether the interior is tinted.
    public var filled: Bool
    /// Whether the stroke is a committed length and gets the drawing's dimension grammar:
    /// arrowheads whose tips are the measured endpoints and a
    /// perpendicular extension tick through every measured point — the same grammar
    /// `RenderDimensionLine` defines for the Metal path. Decoration only; the measured
    /// vertices are never moved by it.
    public var dimensioned: Bool = false
    /// Whether a filled arrowhead is drawn at the last vertex when ``endCap`` names none.
    ///
    /// A fallback for strokes built by hand (previews, snippets). A markup's own strokes carry
    /// their stored ends in ``startCap`` and ``endCap`` instead (nl-markup: until 2026-09-23 the
    /// head came from `kind == .arrow`, so the ends stored on the record were never drawn).
    public var arrowAtEnd: Bool = false
    /// The decoration at the first vertex, from `MarkupStyle.startCap`.
    public var startCap: ZPDFContracts.LineCapStyle = .none
    /// The decoration at the last vertex, from `MarkupStyle.endCap`.
    public var endCap: ZPDFContracts.LineCapStyle = .none
    /// Whether this closed stroke is a callout's text box — a Callout's or a clouded callout's
    /// (ADR-0029) — drawn as the rounded note rather than as a polygon.
    public var calloutBox: Bool = false
    /// Whether the outline is stroked. A Text box with a fill and no border (ADR-0029) is
    /// filled only.
    public var stroked: Bool = true
    /// Whether the path is drawn as a smooth curve through its points (a freehand stroke,
    /// ADR-0029 §2.5). The stored points never change; only the drawing is smoothed.
    public var smooth: Bool = false
    /// The exact outline when it has arc edges (NL-MEASURE-05, ADR-0030 §5.6): ``points`` is its
    /// flattening for the screen, and a vector export paints this as Bézier curves instead.
    public var arcOutline: PolygonRing?

    /// The end decoration actually drawn at the last vertex.
    public var drawnEndCap: ZPDFContracts.LineCapStyle {
        endCap != .none ? endCap : (arrowAtEnd ? .closedArrow : .none)
    }
}

/// A placed stamp, as the canvas has to draw it: a rotated box, its artwork, and its frozen text.
///
/// # Why this is its own value rather than more strokes
///
/// A stamp is the one markup whose picture is not a function of its geometry. The record stores
/// **one anchor point**; the box, the rotation, the artwork digest and the resolved text all live
/// on `MarkupRecord.stamp`, frozen at placement. Flattening that into
/// `CanvasStroke`s would lose the two things the canvas needs to keep straight — which way the
/// stamp is turned, and where its artwork's unit box maps to — and it is exactly that flattening
/// that once left stamps as boxes: the canvas drew the border and the text, because those were
/// the only two things a stroke list could carry.
///
/// Everything here is **page space**, like every other value in this file, so the same
/// `PageDisplayTransform` that puts a measurement on screen puts a stamp on screen — including
/// under a page `/Rotate`, which a `CGContext` rotation applied at draw time would get wrong.
public struct CanvasStampPlacement: Sendable, Hashable {

    /// The stamp's centre in page space — the point the record's geometry stores.
    public var anchor: PDFPointValue
    /// The box's width in page points, before rotation.
    public var widthPoints: Double
    /// The box's height in page points, before rotation.
    public var heightPoints: Double
    /// Rotation about ``anchor``, in degrees counter-clockwise, from `StampInstance`.
    public var rotationDegrees: Double
    /// The compiled artwork the instance's digest names, when the project's store has it.
    ///
    /// `nil` is a visible state, not an error: a stamp whose artwork the store cannot produce
    /// draws its border and its text, which is what every stamp in the product looked like
    /// before this. A stamp that silently drew nothing would be a stamp nobody notices missing.
    public var artwork: ArtworkGeometry?
    /// Whether that artwork stays sharp when magnified. Carried so the canvas never has to
    /// re-derive a fact the import already settled.
    public var artworkKind: ZPDFContracts.StampArtworkKind
    /// The frozen field text, in template order, one line each. Never re-resolved.
    public var lines: [String]
    /// The digest of an inserted image's raster artwork, so the canvas can draw the picture from
    /// its own pixels rather than from the mosaic (ADR-0043, L-81). `nil` for a stamp, whose
    /// artwork stays geometry, and for vector artwork.
    public var rasterImageDigest: String? = nil

    public init(
        anchor: PDFPointValue,
        widthPoints: Double,
        heightPoints: Double,
        rotationDegrees: Double,
        artwork: ArtworkGeometry? = nil,
        artworkKind: ZPDFContracts.StampArtworkKind = .none,
        lines: [String] = []
    ) {
        self.anchor = anchor
        self.widthPoints = widthPoints
        self.heightPoints = heightPoints
        self.rotationDegrees = rotationDegrees
        self.artwork = artwork
        self.artworkKind = artworkKind
        self.lines = lines
    }

    /// Whether the box is one the canvas can actually place.
    public var hasUsableBox: Bool {
        widthPoints.isFinite && heightPoints.isFinite
            && widthPoints >= ArtworkLimits.minimumBoxPoints
            && heightPoints >= ArtworkLimits.minimumBoxPoints
            && widthPoints <= ArtworkLimits.maximumBoxPoints
            && heightPoints <= ArtworkLimits.maximumBoxPoints
            && rotationDegrees.isFinite
    }

    /// A point in the stamp's own space — origin at the centre, x right, y up, **unrotated** —
    /// turned into page space.
    ///
    /// One function, used by the border, the artwork, the text and the rotation handle, so all
    /// four turn together by construction. A second rotation written anywhere else is a stamp
    /// whose seal and whose frame disagree.
    public func pagePoint(localX x: Double, localY y: Double) -> PDFPointValue {
        let radians = rotationDegrees * .pi / 180
        let cosine = cos(radians)
        let sine = sin(radians)
        return PDFPointValue(
            x: anchor.x + x * cosine - y * sine,
            y: anchor.y + x * sine + y * cosine
        )
    }

    /// A unit-space artwork point mapped into page space, aspect preserved.
    ///
    /// Unit space is the `0...1` box with its origin at the lower left (`ArtworkContour`), and a
    /// picture that is not square is **letterboxed** inside the stamp's box rather than
    /// stretched, exactly as `ImportedArtworkScene.fittedSize` does it for the renderer. A
    /// stretched seal is a different seal.
    public func pagePoint(unit point: PDFPoint) -> PDFPointValue {
        let fitted = fittedArtworkSize
        return pagePoint(
            localX: (point.x - 0.5) * fitted.width,
            localY: (point.y - 0.5) * fitted.height
        )
    }

    /// The artwork's drawn size inside the box, aspect preserved.
    public var fittedArtworkSize: (width: Double, height: Double) {
        let aspect = artwork?.sourceAspectRatio ?? 1
        guard aspect.isFinite, aspect > 0 else { return (widthPoints, heightPoints) }
        let boxAspect = widthPoints / heightPoints
        return aspect >= boxAspect
            ? (widthPoints, widthPoints / aspect)
            : (heightPoints * aspect, heightPoints)
    }

    /// The box's four corners in page space, anticlockwise from the lower left.
    public var corners: [PDFPointValue] {
        let halfWidth = widthPoints / 2
        let halfHeight = heightPoints / 2
        return [
            pagePoint(localX: -halfWidth, localY: -halfHeight),
            pagePoint(localX: halfWidth, localY: -halfHeight),
            pagePoint(localX: halfWidth, localY: halfHeight),
            pagePoint(localX: -halfWidth, localY: halfHeight)
        ]
    }

    /// The axis-aligned box the rotated stamp occupies, which is what the selection ring and
    /// the marquee read.
    public var boundingBox: PDFRectValue {
        let points = corners
        let minX = points.map(\.x).min() ?? anchor.x
        let maxX = points.map(\.x).max() ?? anchor.x
        let minY = points.map(\.y).min() ?? anchor.y
        let maxY = points.map(\.y).max() ?? anchor.y
        return PDFRectValue(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The rotation knob's position in page space, for the current rotation.
    ///
    /// Above the box's **top edge**, on its centre line, so the knob turns with the stamp and
    /// the angle under the pointer is the angle the stamp is at. `gapPoints` is supplied by the
    /// canvas, which knows the zoom.
    public func rotationHandlePoint(gapPoints: Double) -> PDFPointValue {
        pagePoint(localX: 0, localY: heightPoints / 2 + gapPoints)
    }

    /// The rotation the stamp would have if its knob were dragged to `point`.
    ///
    /// Measured from the anchor, with the knob's rest direction (straight up in the stamp's own
    /// space) as zero, so grabbing the knob does not snap the stamp to the pointer's angle.
    public func rotation(draggingHandleTo point: PDFPointValue) -> Double {
        let dx = point.x - anchor.x
        let dy = point.y - anchor.y
        guard dx.isFinite, dy.isFinite, dx * dx + dy * dy > 1e-12 else { return rotationDegrees }
        // `atan2` measures from +x; the knob rests at +y, so a quarter turn comes off.
        let degrees = atan2(dy, dx) * 180 / .pi - 90
        return CanvasStampPlacement.normalised(degrees)
    }

    /// A rotation folded into `0..<360`, so two stamps at the same angle compare equal and an
    /// undo entry never reads "-1080°".
    public static func normalised(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return 0 }
        let wrapped = degrees.truncatingRemainder(dividingBy: 360)
        return wrapped < 0 ? wrapped + 360 : wrapped
    }

    /// The nearest multiple of `increment`, for a rotation drag with Shift held.
    public static func snapped(_ degrees: Double, increment: Double) -> Double {
        guard increment > 0, degrees.isFinite else { return normalised(degrees) }
        return normalised((degrees / increment).rounded() * increment)
    }
}

/// Everything the canvas needs to draw one markup, in page space and free of view geometry.
///
/// Built from `MarkupRecord`, not from `MarkupSummary`: a summary carries only a bounding box, and
/// drawing an L-shaped wall as a rectangle is not a rendering shortcut, it is a different drawing.
/// The record's `MeasurementGeometry` is the geometry the engine measured, so what is on screen and
/// what is in the ledger are the same shape by construction.
public struct CanvasMarkupShape: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let pageID: UUID
    public var color: ColorRGBA
    public var strokes: [CanvasStroke]
    /// The stored fill colour for closed outlines, or `nil` to derive one from the
    /// stroke at the design's ~18 % alpha — the fallback for
    /// markups stored before styles carried a fill.
    public var fill: ColorRGBA? = nil
    /// Count-symbol positions.
    public var counts: [PDFPointValue]
    /// The symbol every one of ``counts`` is drawn as, or `nil` for a mark placed before a
    /// symbol was a property of the mark.
    ///
    /// Read straight off `MarkupRecord.symbol` (ADR-0011 §2.1). It is on the *record*, so a
    /// mark keeps its glyph after the preset that made it is renamed, re-symbolised or
    /// deleted, and two count groups on one page may legitimately disagree about their glyph.
    /// `nil` draws the historical dot, which is what every count made before this build is.
    public var symbol: MarkupSymbol?
    /// The compiled artwork ``symbol`` names, when the project's artwork store has it.
    ///
    /// `nil` is not an error and is not empty: a symbol whose artwork the store cannot produce
    /// falls back to its built-in glyph, **visibly**, because a count of forty that quietly
    /// renders twelve marks is a wrong quantity and a mark drawn as a plain circle is one
    /// somebody notices. The renderer keeps the same rule in
    /// `ImportedArtworkScene.markups(symbol:artwork:…)`.
    public var artwork: ArtworkGeometry?
    /// The placed stamp this markup is, or `nil` for every other family.
    ///
    /// A stamp used to reach the canvas as a rectangle stroke and a string,
    /// so a stamp with imported artwork drew as a box with text in it — at every zoom, on every
    /// sheet, however many contours the import had compiled. The artwork and the rotation are
    /// here because they are on the record and the canvas is the last place that could have
    /// read them.
    public var stamp: CanvasStampPlacement?
    public var bounds: PDFRectValue
    public var hidden: Bool
    /// Whether this markup belongs on paper — `MarkupRecord.printable`, carried through to the
    /// canvas scene so print and every flattened export read the flag from the same value the
    /// screen was drawn from.
    ///
    /// The contract catalogue has said since the freeze that a non-printable markup is
    /// *"excluded from print and flattened export"*, and until this field existed nothing in the
    /// product read the flag at all: it round-tripped through the archive, the database and the
    /// interchange, and changed nothing anybody could see. `ZPDFExport.PDFFlattenPolicy` is the
    /// one function that decides what it means.
    public var printable: Bool = true
    /// The caption drawn in a pill beside the markup, already formatted, or `nil`.
    public var caption: String?
    /// Which markup family this is, so the canvas draws a text box as text and a cloud as
    /// a cloud rather than inferring a shape from its vertex count.
    public var kind: ZPDFUIPresentation.MarkupKind = .measurement
    /// The typed string of a Text or Callout markup.
    public var text: String?
    /// Where that string is drawn, in page space.
    public var textBox: PDFRectValue?
    /// A callout's target point — the far end of its leader line.
    public var leaderTarget: PDFPointValue?
    /// Stroke width in page points, from the stored style.
    public var lineWidth: Double = 1.5
    /// Stroke opacity, 0…1, from the stored style. Multiplied into the colour when drawing.
    public var opacity: Double = 1
    /// Point size of the markup's text, in page points, from the stored style.
    ///
    /// `drawMarkupText` derived its size from the box height until 2026-08-27, so the Inspector's
    /// Text size control changed a stored number that nothing drew.
    public var fontSize: Double = 12
    /// Solid, dashed, dotted, dash-dot, cloud — from the stored style.
    ///
    /// Carried here for the same reason `lineWidth` is, and it had the same fate: the style was
    /// stored, the Inspector edited it, and the canvas drew every markup with a constant stroke.
    /// The Inspector could read *9 pt, Dotted* over an arrow drawn thin and solid: colour was the
    /// only style that reached the canvas.
    public var lineStyle: MarkupLineStyle = .solid
    /// The stored font family of the markup's text, or `nil` for the system font.
    ///
    /// nl-markup: `MarkupStyle.fontName` was stored ("Helvetica" by default) and never read, so
    /// the screen drew the system font whatever the record said.
    public var fontName: String? = nil
    /// The stored horizontal alignment of the markup's text. Never read before nl-markup.
    public var textAlignment: ZPDFContracts.TextAlignment = .leading
    /// A Temporary Measure — the tape. Drawn dashed, never captioned, never selectable ink:
    /// it must never look like a committed measurement while it
    /// is on screen, or somebody reads a number off a drawing that was never recorded.
    public var isTemporary: Bool = false
    /// The editable vertices of the stored geometry, in `MarkupVertexEditing`'s order.
    ///
    /// The Select tool draws a handle at each one and drags it into
    /// `DocumentCommand.editVertices`, so the index here **is** the index the command
    /// edits. Before this the eight handles were the corners and midpoints of the bounding
    /// box: decoration that hit-tested nothing and, had it been wired, would have edited a
    /// rectangle the user never drew.
    public var vertices: [PDFPointValue] = []
    /// Bold, italic, text colour and box border (ADR-0029), or `nil` for plain text.
    public var textStyle: ZPDFContracts.MarkupTextStyle? = nil
    /// The markup's rotation about its box centre in degrees (ADR-0029). The strokes are
    /// already turned; the text box is stored unturned and the text is turned at draw time.
    public var rotationDegrees: Double = 0
    /// The centre the rotation turns about, in page space.
    public var rotationCentre: PDFPointValue? = nil
    /// Whether the ink multiplies with the drawing (the highlighter, ADR-0029).
    public var multiplyBlend: Bool = false
    /// The markup group this shape belongs to (ADR-0029), for group selection.
    public var groupID: UUID? = nil
    /// The unturned box a turnable markup turns about, for its rotation knob; `nil` for a
    /// markup that does not turn (NL-MARKUP-18).
    public var rotationBox: PDFRectValue? = nil
    /// Each count mark's running number, parallel to ``counts``, when the count is numbered
    /// (NL-MEASURE-12); empty otherwise.
    public var countNumbers: [Int] = []
    /// Where the person dragged the caption pill, in page points from its automatic position
    /// (NL-MEASURE-09); `nil` for the automatic position.
    public var captionOffset: PDFPointValue? = nil
    /// A length beside every segment, when the caption asks for them (NL-MEASURE-09).
    public var segmentLabels: [CanvasSegmentLabel] = []
    /// Drawn faintly: the ledger filter left it out and its canvas behaviour is Dim (V-003).
    /// Display only; the markup is still hit and selected like any other.
    public var isDimmed: Bool = false
}

/// How segment labels are measured and worded on one page (NL-MEASURE-09): the page scale's
/// factors, for a separate X/Y scale, each Scale Region's factors, and the ledger formatter's
/// length text.
public struct CanvasSegmentLabelling {
    public let metresPerPoint: (x: Double, y: Double)?
    /// The factors of the page's Scale Regions, by region identity (R-008).
    public let regionMetresPerPoint: [UUID: (x: Double, y: Double)]
    public let format: (Decimal) -> String
    /// What ``format`` writes with — the display units, precision and number locale — as a
    /// value, so the scene's shape cache can key a record's labels on their inputs and skip
    /// formatting them on a hit (S-006). `nil` for a closure nobody can name: its labels are
    /// then formatted to be compared, as before.
    public let formatToken: AnyHashable?

    public init(
        metresPerPoint: (x: Double, y: Double)?,
        regionMetresPerPoint: [UUID: (x: Double, y: Double)] = [:],
        formatToken: AnyHashable? = nil,
        format: @escaping (Decimal) -> String
    ) {
        self.metresPerPoint = metresPerPoint
        self.regionMetresPerPoint = regionMetresPerPoint
        self.formatToken = formatToken
        self.format = format
    }

    /// The factors a record was measured with: its Scale Region's when it has one, else the
    /// page's. The page's alone put a separate X/Y page scale on every segment of a markup
    /// measured inside a region at another scale (R-008).
    public func metresPerPoint(for record: MarkupRecord) -> (x: Double, y: Double)? {
        if let region = record.scaleRegionID, let factors = regionMetresPerPoint[region.rawValue] { return factors }
        return metresPerPoint
    }

    /// The labelling of one page from a snapshot — the canvas's and every export's, so paper
    /// and screen say the same length.
    @MainActor
    public static func make(snapshot: DocumentSnapshot, page: UUID) -> CanvasSegmentLabelling {
        let scale = snapshot.scale(onPage: page)
        let formatter = snapshot.ledger.formatter
        var regions: [UUID: (x: Double, y: Double)] = [:]
        for region in snapshot.scaleRegions where region.pageID == page {
            regions[region.id] = (region.scale.sx, region.scale.sy)
        }
        return CanvasSegmentLabelling(
            metresPerPoint: scale.map { ($0.sx, $0.sy) },
            regionMetresPerPoint: regions,
            formatToken: AnyHashable(SegmentFormatToken(units: formatter.units, localeIdentifier: formatter.localeIdentifier)),
            format: { formatter.textWithUnit(Shown.Quantity.metres($0)) }
        )
    }

    /// Everything ``QuantityFormatter`` writes a length with.
    private struct SegmentFormatToken: Hashable {
        let units: DisplayUnitSelection
        let localeIdentifier: String
    }
}

/// One segment's length label (NL-MEASURE-09): display only, derived from the stored geometry.
public struct CanvasSegmentLabel: Sendable, Hashable {
    public let start: PDFPointValue
    public let end: PDFPointValue
    public let text: String
}

/// Compiled shapes from the last scene build, reused for every record that did not change.
///
/// Before this the canvas recompiled every markup on the sheet — strokes, 72-gon circles,
/// cloud outlines, vertex lists — on every scene pass, including every frame of a drag of one
/// wall across a sheet of five thousand (IM-042). The key is the whole record (a drag's
/// preview record differs from the committed one, so it recompiles; the others do not), the
/// caption it was drawn with, and whether its artwork had arrived.
public final class CanvasShapeCache {

    struct Key: Hashable {
        let record: MarkupRecord
        let caption: String?
        let symbolArtwork: Bool
        let stampArtwork: Bool
        /// NL-MEASURE-09: segment labels depend on the scale and the display unit, which the
        /// record does not carry.
        var segments: SegmentInputs = .none
    }

    /// What a record's segment labels are made from, beyond the record itself (S-006).
    enum SegmentInputs: Hashable {
        /// The record shows no segment lengths.
        case none
        /// The factors the record is measured with and the formatter's identity: known before
        /// any label is formatted, so a hit formats nothing.
        case inputs(x: Double?, y: Double?, format: AnyHashable)
        /// A labelling whose formatter has no identity: the formatted texts themselves.
        case texts([String])
    }

    private var entries: [UUID: (key: Key, shape: CanvasMarkupShape?)] = [:]
    private var touched: Set<UUID> = []
    private var pageID: UUID?

    /// Records compiled since the cache was created. The counter IM-042's test reads.
    public private(set) var compileCount = 0

    public init() {}

    func begin(pageID: UUID) {
        if self.pageID != pageID {
            entries.removeAll(keepingCapacity: true)
            self.pageID = pageID
        }
        touched.removeAll(keepingCapacity: true)
    }

    func lookup(_ key: Key) -> CanvasMarkupShape?? {
        guard let entry = entries[key.record.id.rawValue], entry.key == key else { return nil }
        touched.insert(key.record.id.rawValue)
        return .some(entry.shape)
    }

    func store(_ shape: CanvasMarkupShape?, for key: Key) {
        compileCount += 1
        entries[key.record.id.rawValue] = (key, shape)
        touched.insert(key.record.id.rawValue)
    }

    /// Drops entries for records the pass did not see — deleted, moved off the page, hidden.
    func end() {
        guard entries.count != touched.count else { return }
        entries = entries.filter { touched.contains($0.key) }
    }

    public func removeAll() {
        entries.removeAll()
        touched.removeAll()
        pageID = nil
    }
}

/// Turns engine records into drawable outlines.
public enum CanvasSceneBuilder {

    /// Builds the drawable scene for one page.
    ///
    /// - Parameters:
    ///   - records: the session's markups, in z-order.
    ///   - summaries: the presenter's summaries, used only for the caption text, which is already
    ///     formatted for the user's units and locale there.
    ///   - captionOverrides: captions that replace the summary's, keyed by markup. The
    ///     Select tool's live recompute writes here while a markup is being dragged, so the
    ///     pill on the drawing shows the quantity the engine just produced rather than the
    ///     one the last snapshot carried.
    ///   - artwork: compiled artwork the project holds, keyed by digest. Only symbols that
    ///     name a digest consult it, and a digest the store does not have draws the glyph.
    public static func build(
        records: [MarkupRecord],
        summaries: [MarkupSummary],
        pageID: UUID,
        captionOverrides: [UUID: String] = [:],
        artwork: [String: ArtworkGeometry] = [:],
        cache: CanvasShapeCache? = nil,
        segmentLabelling: CanvasSegmentLabelling? = nil
    ) -> [CanvasMarkupShape] {
        // NL-MEASURE-09: a record's caption choice lives on its style.
        let choices = Dictionary(
            records.compactMap { record in record.style.measurementCaption.map { (record.id.rawValue, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        let captions = Dictionary(
            summaries.map { ($0.id, caption(for: $0, choice: choices[$0.id])) },
            uniquingKeysWith: { first, _ in first }
        )
        cache?.begin(pageID: pageID)
        let shapes: [CanvasMarkupShape] = records.compactMap { record in
            guard record.pageID.rawValue == pageID, !record.hidden else { return nil }
            let caption = captionOverrides[record.id.rawValue] ?? captions[record.id.rawValue] ?? nil
            // S-006: the key names the labels' inputs, and they are formatted only on a miss.
            // They used to be computed and formatted before the lookup, on every scene pass —
            // each Select-drag frame — for every record showing segment lengths.
            var segments: [CanvasSegmentLabel]?
            let segmentInputs: CanvasShapeCache.SegmentInputs
            if let labelling = segmentLabelling, showsSegmentLabels(record) {
                if let token = labelling.formatToken {
                    let factors = labelling.metresPerPoint(for: record)
                    segmentInputs = .inputs(x: factors?.x, y: factors?.y, format: token)
                } else {
                    let labels = segmentLabels(for: record, labelling: labelling)
                    segments = labels
                    segmentInputs = .texts(labels.map(\.text))
                }
            } else {
                segmentInputs = .none
            }
            let key = CanvasShapeCache.Key(
                record: record,
                caption: caption,
                symbolArtwork: record.symbol?.artworkDigest.map { artwork[$0] != nil } ?? false,
                stampArtwork: record.stamp?.artworkDigest.map { artwork[$0] != nil } ?? false,
                segments: segmentInputs
            )
            if let cache, let hit = cache.lookup(key) { return hit }
            var built = compile(record, pageID: pageID, caption: caption, artwork: artwork)
            built?.segmentLabels = segments ?? segmentLabelling.map { segmentLabels(for: record, labelling: $0) } ?? []
            built?.captionOffset = record.style.measurementCaption?.labelOffset.map { PDFPointValue(x: $0.x, y: $0.y) }
            cache?.store(built, for: key)
            return built
        }
        cache?.end()
        return shapes
    }

    /// Compiles one record into its drawable shape. The expensive half of ``build``, and the
    /// half the cache skips for every record that did not change (IM-042).
    private static func compile(
        _ record: MarkupRecord,
        pageID: UUID,
        caption: String?,
        artwork: [String: ArtworkGeometry]
    ) -> CanvasMarkupShape? {
        do {
            let shape = strokes(of: record)
            // A text markup has no outline and no count, and it is still a markup. Before
            // this clause `build` dropped every shapeless record, so a committed text box
            // was invisible even though it was in the archive and in History.
            guard !shape.strokes.isEmpty || !shape.counts.isEmpty || shape.text != nil else {
                return nil
            }
            let box = record.geometry?.bounds
            // ADR-0029: text and shapes turn about their box centre. Stamps turn through their
            // own instance, and measurements are never turned (their geometry is the quantity).
            let rotation = rotates(record) ? record.style.effectiveRotationDegrees : 0
            // A markup that turns is bounded, turned about and given its knob by the one rule
            // the controller grabs the knob with (U-006, iteration 4). Otherwise a clouded
            // callout's bounds are the cloud, the leader and the box together, and every other
            // text-bearing markup is bounded by its text box, as before.
            let turnBox = rotationBox(of: record)
            let unturnedBounds = turnBox ?? (record.kind == .cloud
                ? (box.map(value(of:)) ?? .zero)
                : (shape.textBox ?? box.map(value(of:)) ?? .zero))
            let centre = PDFPointValue(
                x: unturnedBounds.minX + unturnedBounds.size.width / 2,
                y: unturnedBounds.minY + unturnedBounds.size.height / 2
            )
            let strokes = rotation == 0 ? shape.strokes : shape.strokes.map { stroke in
                var turned = stroke
                turned.points = stroke.points.map { turn($0, about: centre, degrees: rotation) }
                // A turn is a rotation, so an arc's bulge (relative to its chord) is unchanged.
                turned.arcOutline = stroke.arcOutline.map { ring in
                    PolygonRing(
                        points: ring.points.map { point in
                            let moved = turn(PDFPointValue(x: point.x, y: point.y), about: centre, degrees: rotation)
                            return PDFPoint(x: moved.x, y: moved.y)
                        },
                        isClosed: ring.isClosed,
                        bulges: ring.bulges
                    )
                }
                return turned
            }
            let bounds = rotation == 0 ? unturnedBounds : turnedBounds(unturnedBounds, about: centre, degrees: rotation)
            var built = CanvasMarkupShape(
                id: record.id.rawValue,
                pageID: pageID,
                color: ColorRGBA(
                    red: record.style.color.red,
                    green: record.style.color.green,
                    blue: record.style.color.blue,
                    alpha: record.style.color.alpha
                ),
                strokes: strokes,
                fill: record.style.fill.map {
                    ColorRGBA(red: $0.red, green: $0.green, blue: $0.blue, alpha: $0.alpha)
                },
                counts: shape.counts,
                symbol: record.symbol,
                artwork: record.symbol?.artworkDigest.flatMap { artwork[$0] },
                stamp: stampPlacement(of: record, artwork: artwork),
                bounds: bounds,
                hidden: record.hidden,
                printable: record.printable,
                caption: caption,
                kind: Shown.Markup(domain: record.kind),
                text: shape.text,
                textBox: shape.textBox,
                leaderTarget: shape.leaderTarget.map { rotation == 0 ? $0 : turn($0, about: centre, degrees: rotation) },
                lineWidth: record.style.lineWidth,
                opacity: record.style.opacity,
                fontSize: record.style.fontSize,
                lineStyle: MarkupLineStyle(domain: record.style.lineStyle),
                fontName: record.style.fontName,
                textAlignment: record.style.textAlignment,
                // A turned markup edits by its box, not its stored vertices: a handle drawn at
                // a turned vertex would write an unturned point back (ADR-0029).
                vertices: rotation == 0
                    ? MarkupVertexEditing.vertices(of: record.geometry ?? MeasurementGeometry(pageID: record.pageID))
                        .map(value(of:))
                    : [],
                textStyle: record.style.textStyle,
                rotationDegrees: rotation,
                rotationCentre: rotation == 0 ? nil : centre,
                multiplyBlend: record.style.blendMode == .multiply,
                groupID: record.groupID?.rawValue,
                rotationBox: turnBox
            )
            built.countNumbers = CountNumbering.numbers(of: record)
            return built
        }
    }

    /// The committed pill text, design grammar: the label
    /// prefixes the value — "Length A: 14.72 m", "Area C: 21.34 m²". A markup without a
    /// label keeps the bare value; a markup without a value gets no pill at all.
    ///
    /// A repeated markup carries its multiplier on the ink — "Area C: 21.34 m² ×6" — because
    /// the pill shows the *drawn instance* while the ledger shows the effective quantity, and
    /// the badge is what stops those two honest numbers from looking like a contradiction.
    /// The pill text under a caption choice (NL-MEASURE-09): the chosen fields, or the headline
    /// alone when there is no choice — exactly ``caption(for:)``.
    static func caption(for summary: MarkupSummary, choice: MeasurementCaption?) -> String? {
        guard let choice, !choice.fields.isEmpty else { return caption(for: summary) }
        return MeasurementCaptionText.text(
            label: summary.label,
            fields: summary.measurementFields,
            primary: summary.measurementKind?.primaryField,
            chosen: choice.fields.compactMap { Shown.Field(domain: $0) },
            repetition: summary.repetitionText
        )
    }

    /// The largest chord sagitta, in page points, an arc edge is drawn with (ADR-0030 §5): a
    /// hundredth of a point is invisible at any zoom the canvas offers.
    static let arcDrawingTolerance = 0.01

    /// Whether a record asks for a length beside every segment (NL-MEASURE-09).
    static func showsSegmentLabels(_ record: MarkupRecord) -> Bool {
        record.style.measurementCaption?.showsSegmentLengths == true
            && MeasurementCaptionText.offersSegmentLengths(record.tool)
    }

    /// The segment labels a record asks for, formatted in the display unit.
    static func segmentLabels(for record: MarkupRecord, labelling: CanvasSegmentLabelling) -> [CanvasSegmentLabel] {
        guard showsSegmentLabels(record) else { return [] }
        return MeasurementCaptionText.segments(of: record, metresPerPoint: labelling.metresPerPoint(for: record)).map { segment in
            CanvasSegmentLabel(
                start: value(of: segment.start),
                end: value(of: segment.end),
                text: labelling.format(segment.metres)
            )
        }
    }

    static func caption(for summary: MarkupSummary) -> String? {
        guard let value = summary.primaryField?.displayTextWithUnit, !value.isEmpty else {
            return nil
        }
        let label = summary.label.trimmingCharacters(in: .whitespaces)
        let text = label.isEmpty ? value : "\(label): \(value)"
        guard let badge = summary.repetitionText else { return text }
        return "\(text) \(badge)"
    }

    /// Everything drawable about one record.
    typealias DrawableShape = (
        strokes: [CanvasStroke],
        counts: [PDFPointValue],
        text: String?,
        textBox: PDFRectValue?,
        leaderTarget: PDFPointValue?
    )

    private static func strokes(of record: MarkupRecord) -> DrawableShape {
        guard let geometry = record.geometry else { return ([], [], nil, nil, nil) }
        // The markup family reads its own storage schema (`ZenitMarkupGeometry`): a text
        // box is two corners, a callout is a target plus two corners, an ellipse is its
        // bounding box. Inferring those from a vertex count is how a rectangle ends up
        // drawn as a line.
        if let markup = markupShape(of: record, geometry: geometry) { return markup }
        if let ellipse = measuredEllipse(of: record) { return ellipse }

        var strokes: [CanvasStroke] = []

        if let chain = record.drawnPointChain {
            // An open point path is a committed length: it gets the dimension grammar. A chain
            // with arc edges (ADR-0030 §5) draws its arcs as arcs, without the per-point ticks the
            // flattening would otherwise sprout. The chain is the record's (one rule with the snap
            // index): a three-point Arc Length is the arc it measures, not two chords (X-042).
            var stroke = CanvasStroke(
                points: chain.flattened(tolerance: Self.arcDrawingTolerance).points.map(value(of:)),
                closed: false,
                filled: false,
                dimensioned: !chain.hasArcs
            )
            if chain.hasArcs { stroke.arcOutline = chain }
            strokes.append(stroke)
        }
        for segment in geometry.segments {
            strokes.append(
                CanvasStroke(
                    points: [value(of: segment.start), value(of: segment.end)],
                    closed: false,
                    filled: false,
                    dimensioned: true
                )
            )
        }
        // A cutout child is the parent's hole, which the parent's even-odd fill already leaves
        // clear; filling the child too tinted the deducted region a second time (BH-340).
        let isCutout = record.parentMarkupID != nil
        // nl-markup: the Style popup's "Cloud" on a Rectangle or a Polygon wrote a style and an
        // undo step and drew solid. The two markup kinds now scallop their ring exactly as the
        // Cloud kind does; a measurement's outline is never reshaped by a style.
        let scallops = record.style.lineStyle == .cloud && (record.kind == .rectangle || record.kind == .polygon)
        for polygon in geometry.polygons {
            // Arc edges (ADR-0030 §5) drawn as arcs, flattened finely for the screen only.
            let ring = polygon.outer.flattened(tolerance: Self.arcDrawingTolerance).points.map(value(of:))
            var outline = CanvasStroke(
                points: scallops && ring.count >= 3
                    ? ZenitMarkupGeometry.cloudOutline(ring, radius: scallopRadius(of: record, ring: ring))
                    : ring,
                closed: true,
                filled: !isCutout
            )
            if polygon.outer.hasArcs, !scallops { outline.arcOutline = polygon.outer }
            strokes.append(outline)
            for hole in polygon.holes {
                var holeStroke = CanvasStroke(points: hole.flattened(tolerance: Self.arcDrawingTolerance).points.map(value(of:)), closed: true, filled: false)
                if hole.hasArcs { holeStroke.arcOutline = hole }
                strokes.append(holeStroke)
            }
        }
        for circle in geometry.circles {
            strokes.append(
                CanvasStroke(points: circlePoints(center: circle.center, radius: circle.radius), closed: true, filled: !isCutout)
            )
        }
        for arc in geometry.arcs {
            strokes.append(
                CanvasStroke(points: arcPoints(arc), closed: false, filled: false)
            )
        }
        return (strokes, geometry.countPoints.map { value(of: $0.position) }, nil, nil, nil)
    }

    /// An Ellipse Area or an Ellipse Cutout drawn as the ellipse it measures, or `nil` for any
    /// other record (ADR-0037 §4.3, T-071).
    ///
    /// The engine measures, the parent loses and the snap index offers the ellipse inscribed in
    /// the record's box (``MarkupRecord/inscribedEllipseBox``), and this draws that one box's
    /// ellipse: closed, never dimensioned, filled for an Ellipse Area and left clear for a cutout
    /// child, whose hole the parent's even-odd fill already leaves (BH-340). Before it an Ellipse
    /// Area (kind `.measurement`) fell through to the point-path branch and was drawn as a
    /// dimensioned line through its stored corners, and an Ellipse Cutout (kind `.polygon`) as its
    /// box — while the quantity and the snap were the ellipse.
    private static func measuredEllipse(of record: MarkupRecord) -> DrawableShape? {
        guard record.tool == .ellipseArea || record.tool == .ellipseCutout,
              let box = record.inscribedEllipseBox else { return nil }
        let outline = ZenitMarkupGeometry.ellipseOutline(in: value(of: box))
        return (
            [CanvasStroke(points: outline, closed: true, filled: record.parentMarkupID == nil)],
            [], nil, nil, nil
        )
    }

    /// The drawable form of a Text, Callout or Shape markup, or `nil` when the record is a
    /// measurement and the measurement path above owns it.
    ///
    /// This is the read half of `ZenitMarkupGeometry`'s schema; `AppMarkupToolPresenter`
    /// is the write half. Both call the same maths for the ellipse and the cloud, so the
    /// shape that was committed and the shape that is drawn are one object.
    private static func markupShape(
        of record: MarkupRecord,
        geometry: MeasurementGeometry
    ) -> DrawableShape? {
        let points = geometry.points.map(value(of:))
        // NL-COLLAB-18: the drawn words, not the review note (`MarkupVisibleText`).
        let text = MarkupVisibleText.drawnText(of: record)
        switch record.kind {
        case .text:
            guard points.count >= 2 else { return nil }
            let box = ZenitMarkupGeometry.boundingRect(points[0], points[1])
            // ADR-0029: a Text box may carry a border (in the stroke colour) and a fill. Whether
            // it draws a frame is the record's rule (`drawnFrameBox`, ADR-0037 §4.3), the one the
            // snap index reads, so an unframed box offers nothing at its corners.
            let border = record.style.textStyle?.boxBorder == true
            guard record.drawnFrameBox != nil else { return ([], [], text, box, nil) }
            let corners = ZenitMarkupGeometry.rectangleCorners(
                PDFPointValue(x: box.minX, y: box.minY),
                PDFPointValue(x: box.maxX, y: box.maxY)
            )
            var frame = CanvasStroke(points: corners, closed: true, filled: record.style.fill != nil)
            frame.stroked = border
            return ([frame], [], text, box, nil)

        case .callout:
            guard points.count >= 3 else { return nil }
            let target = points[0]
            let box = ZenitMarkupGeometry.boundingRect(points[1], points[2])
            let attachment = ZenitMarkupGeometry.leaderAttachment(target: target, box: box)
            let border = ZenitMarkupGeometry.rectangleCorners(
                PDFPointValue(x: box.minX, y: box.minY),
                PDFPointValue(x: box.maxX, y: box.maxY)
            )
            return (
                [
                    // The leader is drawn box → target so the arrowhead lands on the thing
                    // the callout is pointing at, which is the end that carries meaning.
                    // Its head is the stored `endCap` (nl-markup), no longer a constant.
                    CanvasStroke(
                        points: [attachment, target], closed: false, filled: false,
                        endCap: record.style.endCap
                    ),
                    CanvasStroke(points: border, closed: true, filled: record.style.fill != nil, calloutBox: true)
                ],
                [], text, box, target
            )

        case .line, .arrow, .polyline:
            // The ends are the record's, not the kind's (nl-markup, NL-MARKUP-07): an Arrow is
            // created with a closed end, so it looks as it always did, and a Line or an Arrow
            // whose ends were edited draws what the Inspector says.
            guard points.count >= 2 else { return nil }
            return (
                [CanvasStroke(
                    points: points,
                    closed: false,
                    filled: false,
                    startCap: record.style.startCap,
                    endCap: record.style.endCap
                )],
                [], nil, nil, nil
            )

        case .freehand:
            // ADR-0029 §2.5: the sampled points, drawn smooth; a highlighter is the same kind
            // with a multiply blend.
            guard points.count >= 2 else { return nil }
            var stroke = CanvasStroke(
                points: points, closed: false, filled: false,
                startCap: record.style.startCap, endCap: record.style.endCap
            )
            stroke.smooth = true
            return ([stroke], [], nil, nil, nil)

        case .hyperlink:
            // NL-MARKUP-17: a link region is a frame on the canvas; ⌘-click follows it. The
            // region is its box, so a click anywhere inside selects it (L-101): as an unfilled
            // frame only its edge did, and Edit Link could never reach a link to set its target.
            guard points.count >= 2 else { return nil }
            let corners = ZenitMarkupGeometry.rectangleCorners(points[0], points[1])
            let region = ZenitMarkupGeometry.boundingRect(points[0], points[1])
            return ([CanvasStroke(points: corners, closed: true, filled: record.style.fill != nil)], [], nil, region, nil)

        case .image:
            // NL-MARKUP-17: the picture is drawn from its artwork through the stamp placement
            // (`imagePlacement`); the frame is only there when the style asks for a fill.
            guard points.count >= 2 else { return nil }
            let box = ZenitMarkupGeometry.boundingRect(points[0], points[1])
            let corners = ZenitMarkupGeometry.rectangleCorners(points[0], points[1])
            var frame = CanvasStroke(points: corners, closed: true, filled: record.style.fill != nil)
            frame.stroked = false
            return ([frame], [], nil, box, nil)

        case .note:
            // A reviewer's sticky note, imported from a marked-up PDF (NL-COLLAB-08): a small
            // outlined square at the note's box. Its words are its note, read on the Comments tab.
            guard points.count >= 2 else { return nil }
            let corners = ZenitMarkupGeometry.rectangleCorners(points[0], points[1])
            return ([CanvasStroke(points: corners, closed: true, filled: record.style.fill != nil)], [], nil, nil, nil)

        case .ellipse:
            // The box the snap index inscribes its ellipse in (ADR-0037): the first two points.
            guard let box = record.inscribedEllipseBox.map(value(of:)) else { return nil }
            let outline = record.style.lineStyle == .cloud
                ? cloudedEllipse(in: box, radius: record.style.effectiveCloudArcSize)
                : ZenitMarkupGeometry.ellipseOutline(in: box)
            return (
                [CanvasStroke(points: outline, closed: true, filled: record.style.fill != nil)],
                [], nil, nil, nil
            )

        case .cloud:
            guard let ring = geometry.polygons.first?.outer.points.map(value(of:)), ring.count >= 3 else {
                return nil
            }
            let outline = ZenitMarkupGeometry.cloudOutline(ring, radius: scallopRadius(of: record, ring: ring))
            let cloud = CanvasStroke(points: outline, closed: true, filled: record.style.fill != nil)
            // ADR-0029 §2.4: a cloud with [target, corner, corner] is a clouded callout — the
            // leader runs from the box to the target and the box holds the words.
            guard points.count >= 3 else { return ([cloud], [], nil, nil, nil) }
            let target = points[0]
            let box = ZenitMarkupGeometry.boundingRect(points[1], points[2])
            let attachment = ZenitMarkupGeometry.leaderAttachment(target: target, box: box)
            let frame = ZenitMarkupGeometry.rectangleCorners(
                PDFPointValue(x: box.minX, y: box.minY),
                PDFPointValue(x: box.maxX, y: box.maxY)
            )
            return (
                [
                    cloud,
                    CanvasStroke(points: [attachment, target], closed: false, filled: false, endCap: record.style.endCap),
                    CanvasStroke(points: frame, closed: true, filled: false, calloutBox: true)
                ],
                [], text, box, target
            )

        case .stamp:
            // A stamp is drawn from its placed instance, not from its geometry: the record
            // stores one anchor point, and the box, the rotation and the text all live on
            // `record.stamp` where they were frozen at placement. A stamp
            // whose instance is missing — a record written before v7 — falls through to
            // `nil` rather than being drawn as a box with nothing in it.
            guard let placement = placement(of: record) else { return nil }
            // The border is the box's **rotated** corners, in page space. Drawing it as an
            // axis-aligned rectangle and turning it in the context at draw time is what used
            // to make a rotated stamp hit-test as an unrotated one, and it would have gone
            // wrong again under a page `/Rotate`.
            let border = CanvasStroke(
                points: placement.corners,
                closed: true,
                filled: record.style.fill != nil
            )
            // The text is on the placement, not here, because it has to turn with the box.
            // `textBox` stays the axis-aligned bounding box: it is what the selection ring,
            // the marquee and `CanvasHitTesting`'s solid-box rule read, and a stamp is a solid
            // object to all three.
            return ([border], [], nil, placement.boundingBox, nil)

        case .rectangle, .polygon:
            // Rectangles and polygons are stored as one closed ring; the generic polygon
            // path below draws them, so only a cutout child needs to reach it. Returning
            // `nil` hands them to it rather than duplicating the fill logic here.
            return nil

        default:
            return nil
        }
    }

    /// The placed stamp a record carries, with its artwork resolved, or `nil`.
    ///
    /// The half of stamp artwork a person sees. Two lookups had to be added and neither of
    /// them existed: `record.stamp` was read for its box and its text and never for its
    /// **artwork digest**, and the digest was never offered to the store — so the compiled
    /// contours the importer had produced, addressed, stored and golden-tested reached the
    /// canvas exactly never, and every stamp on every sheet drew as a box with text in it.
    ///
    /// A digest the store cannot produce leaves ``CanvasStampPlacement/artwork`` `nil`, and the
    /// stamp draws its border and its text — the behaviour it has always had, which is a
    /// visible answer rather than a blank.
    static func placement(of record: MarkupRecord) -> CanvasStampPlacement? {
        stampPlacement(of: record, artwork: [:])
    }

    /// The placed stamp a record carries, with its artwork looked up in `artwork`.
    static func stampPlacement(
        of record: MarkupRecord,
        artwork: [String: ArtworkGeometry]
    ) -> CanvasStampPlacement? {
        if record.kind == .image { return imagePlacement(of: record, artwork: artwork) }
        guard record.kind == .stamp,
              let stamp = record.stamp,
              let anchor = record.geometry?.points.first
        else { return nil }
        let placement = CanvasStampPlacement(
            anchor: value(of: anchor),
            widthPoints: stamp.widthPoints,
            heightPoints: stamp.heightPoints,
            rotationDegrees: CanvasStampPlacement.normalised(stamp.rotationDegrees),
            artwork: stamp.artworkDigest.flatMap { artwork[$0] },
            artworkKind: stamp.artworkKind,
            // The frozen values, in template order, one per line. They are read from the
            // instance and never re-derived, which is why a stamp placed last year still
            // draws last year's date.
            lines: stamp.fields.map(\.resolvedText).filter { !$0.isEmpty }
        )
        return placement.hasUsableBox ? placement : nil
    }

    /// An image markup's picture as a placement over its box (NL-MARKUP-17): the artwork its
    /// symbol names, letterboxed, turned by the style's rotation.
    static func imagePlacement(
        of record: MarkupRecord,
        artwork: [String: ArtworkGeometry]
    ) -> CanvasStampPlacement? {
        guard let points = record.geometry?.points, points.count >= 2 else { return nil }
        let box = ZenitMarkupGeometry.boundingRect(value(of: points[0]), value(of: points[1]))
        var placement = CanvasStampPlacement(
            anchor: PDFPointValue(x: box.minX + box.size.width / 2, y: box.minY + box.size.height / 2),
            widthPoints: box.size.width,
            heightPoints: box.size.height,
            rotationDegrees: record.style.effectiveRotationDegrees,
            artwork: record.symbol?.artworkDigest.flatMap { artwork[$0] },
            artworkKind: record.symbol?.kind ?? .none,
            lines: []
        )
        // ADR-0043 (L-81): a raster picture is drawn from its pixels when the canvas has them.
        if record.symbol?.kind == .raster { placement.rasterImageDigest = record.symbol?.artworkDigest }
        return placement.hasUsableBox ? placement : nil
    }

    /// Whether a record turns by `MarkupStyle.rotationDegrees` (ADR-0029): text and shapes do;
    /// stamps turn by their instance, images by their placement, and a measurement never turns.
    /// The rule lives on the record (`MarkupRecord.turnsWithStyleRotation`, ADR-0037) so the snap
    /// index turns exactly what the canvas turns (T-071).
    static func rotates(_ record: MarkupRecord) -> Bool {
        record.turnsWithStyleRotation
    }

    /// The unturned box a record turns about by its style (ADR-0029), or `nil` when it does not
    /// turn: a callout's note box, a text box's or an image's two corners, otherwise the
    /// geometry's bounds (a clouded callout's included). One rule for the knob the scene draws
    /// and the knob the controller grabs (`markupRotationHandle`); they were two copies kept in
    /// step by hand (U-006, iteration 4). The box itself is the record's
    /// (`MarkupRecord.styleRotationBox`), which the snap index turns about too (X-046).
    static func rotationBox(of record: MarkupRecord) -> PDFRectValue? {
        guard rotates(record) else { return nil }
        return record.styleRotationBox.map(value(of:))
    }

    /// A point turned counter-clockwise about `centre` in page space (y up).
    static func turn(_ point: PDFPointValue, about centre: PDFPointValue, degrees: Double) -> PDFPointValue {
        let radians = degrees * .pi / 180
        let dx = point.x - centre.x
        let dy = point.y - centre.y
        return PDFPointValue(
            x: centre.x + dx * cos(radians) - dy * sin(radians),
            y: centre.y + dx * sin(radians) + dy * cos(radians)
        )
    }

    /// The axis-aligned box a turned box occupies.
    static func turnedBounds(_ box: PDFRectValue, about centre: PDFPointValue, degrees: Double) -> PDFRectValue {
        let corners = [
            PDFPointValue(x: box.minX, y: box.minY), PDFPointValue(x: box.maxX, y: box.minY),
            PDFPointValue(x: box.maxX, y: box.maxY), PDFPointValue(x: box.minX, y: box.maxY)
        ].map { turn($0, about: centre, degrees: degrees) }
        let xs = corners.map(\.x), ys = corners.map(\.y)
        let minX = xs.min() ?? box.minX, minY = ys.min() ?? box.minY
        return PDFRectValue(x: minX, y: minY, width: (xs.max() ?? minX) - minX, height: (ys.max() ?? minY) - minY)
    }

    /// The scallop radius a record's cloud is drawn with: the stored arc size when there is one
    /// (NL-MARKUP-16, ADR-0029), otherwise the automatic size.
    static func scallopRadius(of record: MarkupRecord, ring: [PDFPointValue]) -> Double {
        record.style.effectiveCloudArcSize ?? cloudScallopRadius(of: ring)
    }

    /// The scallop size of a cloud: about a twelfth of the outline's longest edge, floored
    /// at 8 page points so a small cloud still reads as a row of bumps rather than a fuzzy
    /// line (arc radius ~8 pt), capped at 18.
    static func cloudScallopRadius(of ring: [PDFPointValue]) -> Double {
        var longest = 0.0
        for index in ring.indices {
            let next = ring[(index + 1) % ring.count]
            longest = Swift.max(longest, ring[index].distance(to: next))
        }
        return Swift.max(minimumCloudScallopRadius, Swift.min(18, longest / 12))
    }

    /// The smallest scallop a revision cloud is drawn with, in page points.
    static let minimumCloudScallopRadius: Double = 8

    /// An ellipse drawn in the Cloud line style: the outline resampled so each facet is one
    /// scallop wide, then scalloped like a Cloud ring (nl-markup).
    ///
    /// The 72-facet outline would give 72 tiny bumps on any ellipse, so the facet count comes
    /// from the scallop size the cloud rule picks for the ellipse's bounding box.
    static func cloudedEllipse(in box: PDFRectValue, radius stored: Double? = nil) -> [PDFPointValue] {
        let corners = ZenitMarkupGeometry.rectangleCorners(
            PDFPointValue(x: box.minX, y: box.minY),
            PDFPointValue(x: box.maxX, y: box.maxY)
        )
        let radius = stored ?? cloudScallopRadius(of: corners)
        let a = box.size.width / 2
        let b = box.size.height / 2
        // Ramanujan's perimeter approximation; exact enough to choose a facet count.
        let h = a + b > 0 ? pow(a - b, 2) / pow(a + b, 2) : 0
        let perimeter = Double.pi * (a + b) * (1 + 3 * h / (10 + (4 - 3 * h).squareRoot()))
        // U-072: clamp in Double before converting; `Int(_:)` trapped on a box of 1e30 pt.
        let wanted = (perimeter / (radius * 2)).rounded()
        let facets = wanted.isFinite ? Int(Swift.max(6, Swift.min(360, wanted))) : 6
        let ring = ZenitMarkupGeometry.ellipseOutline(in: box, segments: facets)
        guard ring.count >= 3 else { return ring }
        return ZenitMarkupGeometry.cloudOutline(ring, radius: radius)
    }

    /// A circle as a 72-gon: the canvas draws outlines, and 5-degree facets are below one device
    /// pixel at every zoom the product supports.
    private static func circlePoints(center: PDFPoint, radius: Double) -> [PDFPointValue] {
        (0..<72).map { step in
            let angle = Double(step) / 72 * 2 * Double.pi
            return PDFPointValue(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
        }
    }

    static func arcPoints(_ arc: ArcGeometry) -> [PDFPointValue] {
        // A file can carry any finite sweep: 1e300 trapped the Int conversion and 1e12 asked
        // for 10^13 points (BH-882). More than one turn draws nothing new, so it is clamped
        // to ±2π, which also bounds the step count at 72.
        let fullTurn = 2 * Double.pi
        let sweep = arc.sweepAngle.isFinite ? min(max(arc.sweepAngle, -fullTurn), fullTurn) : 0
        let steps = max(8, Int(abs(sweep) / (Double.pi / 36)))
        return (0...steps).map { step in
            let t = Double(step) / Double(steps)
            let angle = arc.startAngle + sweep * t
            return PDFPointValue(
                x: arc.center.x + arc.radius * cos(angle),
                y: arc.center.y + arc.radius * sin(angle)
            )
        }
    }

    private static func value(of point: PDFPoint) -> PDFPointValue {
        PDFPointValue(x: point.x, y: point.y)
    }

    private static func value(of rect: PDFRect) -> PDFRectValue {
        let standard = rect.standardized
        return PDFRectValue(
            x: standard.origin.x,
            y: standard.origin.y,
            width: standard.size.width,
            height: standard.size.height
        )
    }
}
