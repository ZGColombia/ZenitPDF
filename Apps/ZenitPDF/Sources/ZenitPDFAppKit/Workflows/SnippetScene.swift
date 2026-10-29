import AppKit
import CoreGraphics
import Foundation
import ZPDFAppCore
import ZPDFContracts
import ZPDFDesignSystem
import ZPDFExport
import ZPDFPersistence
import ZPDFRenderer
import ZPDFUIPresentation

/// Turns the canvas's own drawable scene into the renderer geometry a snippet is composed from
/// (ADR-0006 §1).
///
/// # Why this exists at all, and why it starts from ``CanvasMarkupShape``
///
/// `SnippetExporter` composes a page raster with markups drawn by
/// `CoreGraphicsMarkupRenderer`, and that renderer consumes `RenderableMarkup`. The application
/// canvas does not: it paints `CanvasMarkupShape` with AppKit, because a takeoff canvas needs
/// live previews, handles and hover states that no export ever wants. So something has to map
/// one onto the other, and the only honest place to start is
/// ``CanvasSceneBuilder``'s output — the *same* values the estimator is looking at, already in
/// page space, already derived from `MarkupRecord` by the shipping builder. Starting from the
/// records again would be a second interpretation of the same geometry, and the one that drifted
/// would be the one nobody watches.
///
/// # Nothing here reads a viewport
///
/// Every coordinate below is page space and every size is either a page-point length off the
/// stored style or a view-point decoration constant the renderer scales by the *snippet's* own
/// output scale. No zoom, no scroll offset, no window size reaches this file, which is what
/// makes ADR-0006's zoom-invariance claim a property of the code rather than a promise about it.
///
/// # One markup, several shapes
///
/// A count group is one markup and forty marks; an area is one markup, a filled polygon and a
/// value pill; a stamp is one markup and however many contours its artwork compiled to. Each
/// fragment therefore gets its own identity, derived from the markup's by
/// `StampArtworkScene.shapeIdentity(base:ordinal:)` — the convention ADR-0011 §2.6 settled — so
/// painter order inside a markup is emission order and
/// ``ZPDFExport/SnippetRegionResolver/familyKey(of:)`` can still put the pieces back together
/// when a region names the markup.
enum SnippetSceneBuilder {

    /// Stroke width used when a markup's stored style carries an unusable one.
    static let fallbackLineWidth: Double = 1.5
    /// Text size for a Text or Callout markup's string, in page points.
    ///
    /// Page points, not view points: a text box is authored on the sheet and its letters belong
    /// to the sheet. The measurement grammar's pills are the opposite case and stay view-sized.
    static let markupTextSizePagePoints: Double = 11
    /// Pill text size, in view points — the renderer's own default, restated so the pill
    /// placement below measures the same box the renderer will draw.
    static let pillFontSizeViewPoints: Double = 10
    /// Segment-length labels, a little smaller than the caption, as on the canvas.
    static let segmentLabelFontSize: Double = 9.5

    /// How a page's segment lengths are measured and worded for an export: the page's scale and
    /// the ledger's own formatter — the canvas's rule, so paper and screen say the same length.
    @MainActor
    static func segmentLabelling(core: AppCoreEnvironment, page: UUID) -> CanvasSegmentLabelling {
        CanvasSegmentLabelling.make(snapshot: core.snapshot, page: page)
    }

    /// The renderer geometry for a page's canvas scene, in painter order.
    ///
    /// - Parameters:
    ///   - shapes: the canvas scene, in z-order, exactly as
    ///     ``CanvasSceneBuilder/build(records:summaries:pageID:captionOverrides:artwork:)``
    ///     produced it.
    ///   - destination: which consumer is asking. ``Destination/paper`` additionally drops every
    ///     markup whose `printable` flag is off, through `ZPDFExport.PDFFlattenPolicy` — the one
    ///     function that decides it, so a print sheet and a flattened export cannot leave
    ///     different marks off.
    ///   - rotation: the sheet's `/Rotate`. The exports show the sheet turned by it, and an
    ///     area's value pill is placed across the picture, not across the page (U-077).
    ///   - insertedImages: the stored bytes of each inserted picture, by artwork digest
    ///     (``insertedImageBytes(for:package:)``). A picture whose bytes are here is painted from
    ///     its own pixels, as the canvas draws it (ADR-0043, L-81); one whose bytes are not falls
    ///     back to its mosaic, as the canvas does.
    static func renderables(
        from shapes: [CanvasMarkupShape],
        for destination: Destination = .screen,
        rotation: ZPDFContracts.PageRotation = .degrees0,
        insertedImages: [String: Data] = [:]
    ) -> [RenderableMarkup] {
        var output: [RenderableMarkup] = []
        output.reserveCapacity(shapes.count * 2)
        // A band of at least a thousand z slots per markup, widened when a markup emits more:
        // a count group of sixty imported symbols of twenty contours each ran past its band
        // and painted interleaved with the next markup (BH-922).
        var base = 0
        for shape in shapes
        where destination.accepts(hidden: shape.hidden, printable: shape.printable) {
            var emitter = Emitter(shape: shape, baseZIndex: base, rotation: rotation, insertedImages: insertedImages)
            emitter.emit(into: &output)
            base += Swift.max(1_000, emitter.emittedCount + 1)
        }
        return output
    }

    /// The stored bytes of every inserted picture among `records`, by artwork digest — what
    /// ``renderables(from:for:rotation:insertedImages:)`` paints them from, so print and every
    /// export show the picture the canvas shows (ADR-0043, L-81). Empty without a project package
    /// (the canvas then draws the mosaic too) and for records that place no raster picture.
    static func insertedImageBytes(for records: [ZPDFContracts.MarkupRecord], package: ProjectPackage?) async -> [String: Data] {
        guard let package else { return [:] }
        let digests = Set(records.compactMap { record -> String? in
            guard record.kind == .image, record.symbol?.kind == .raster else { return nil }
            return record.symbol?.artworkDigest
        })
        var bytes: [String: Data] = [:]
        for digest in digests.sorted() {
            if let data = try? await ProjectArtworkStore.rasterSourceBytes(forDigest: digest, in: package) {
                bytes[digest] = data
            }
        }
        return bytes
    }

    /// Who the geometry is for.
    ///
    /// The distinction exists for one flag. A snippet is a picture of the screen and shows what
    /// the screen shows; paper is the artefact `MarkupRecord.printable` was frozen for.
    enum Destination: Sendable, Hashable {
        /// A snippet, or anything else that mirrors the canvas.
        case screen
        /// Print, and the flattened and clean PDF export shapes.
        case paper

        func accepts(hidden: Bool, printable: Bool) -> Bool {
            switch self {
            case .screen: !hidden
            case .paper: PDFFlattenPolicy.isOnPaper(hidden: hidden, printable: printable)
            }
        }
    }

    // MARK: - One markup

    private struct Emitter {
        let shape: CanvasMarkupShape
        let baseZIndex: Int
        let rotation: ZPDFContracts.PageRotation
        /// Inserted pictures' stored bytes, by artwork digest (ADR-0043).
        let insertedImages: [String: Data]
        private var ordinal = 0

        /// How many fragment slots this markup used.
        var emittedCount: Int { ordinal }

        init(
            shape: CanvasMarkupShape,
            baseZIndex: Int,
            rotation: ZPDFContracts.PageRotation,
            insertedImages: [String: Data] = [:]
        ) {
            self.shape = shape
            self.baseZIndex = baseZIndex
            self.rotation = rotation
            self.insertedImages = insertedImages
        }

        /// The next fragment identity. Ordinal zero is the markup's own id, so a single-shape
        /// markup keeps exact identity and the common case needs no family lookup at all.
        private mutating func nextID() -> MarkupID {
            defer { ordinal += 1 }
            let base = MarkupID(shape.id)
            return ordinal == 0 ? base : StampArtworkScene.shapeIdentity(base: base, ordinal: ordinal)
        }

        private mutating func nextZIndex() -> Int { baseZIndex + ordinal }

        private var ink: RGBAColor { SnippetSceneBuilder.color(shape.color) }

        private var fillInk: RGBAColor {
            // The canvas's own rule: a stored fill wins; otherwise the stroke at the design's
            // ~18 % alpha. Restating it rather than deriving a second
            // one is deliberate — an export whose fills are a different colour from the screen
            // is an export nobody trusts.
            if let fill = shape.fill { return SnippetSceneBuilder.color(fill) }
            var tint = ink
            tint.alpha *= 0.18
            return tint
        }

        private var lineWidth: Double {
            shape.lineWidth.isFinite && shape.lineWidth > 0
                ? shape.lineWidth
                : SnippetSceneBuilder.fallbackLineWidth
        }

        /// The markup's own opacity and line style, as the canvas draws them. The export path
        /// never set either, so a dashed "to be demolished" outline printed solid and a 40 %
        /// markup printed at 100 % (BH-389).
        private var opacity: Double {
            shape.opacity.isFinite ? Swift.min(1, Swift.max(0, shape.opacity)) : 1
        }

        private var dash: RenderDash {
            SnippetSceneBuilder.dash(for: shape.lineStyle, lineWidth: lineWidth)
        }

        private func styled(_ style: RenderStyle, dashed: Bool = true) -> RenderStyle {
            var copy = style
            copy.opacity = opacity
            if dashed { copy.dash = dash }
            // A highlighter (ADR-0029 blendMode multiply) paints multiplied on paper as on screen.
            if shape.multiplyBlend { copy.blendMode = .multiply }
            return copy
        }

        mutating func emit(into output: inout [RenderableMarkup]) {
            emitStrokes(into: &output)
            emitText(into: &output)
            emitStamp(into: &output)
            emitCounts(into: &output)
            emitCaption(into: &output)
            emitSegmentLabels(into: &output)
        }

        // MARK: Outlines

        private mutating func emitStrokes(into output: inout [RenderableMarkup]) {
            // A cutout is a hole in the fill (BH-340): the canvas fills the one filled outer
            // ring and its holes as a single even-odd path, and so must paper. The rings are
            // the canvas's own (`CanvasHitTesting.holes(of:)`), so the two cannot disagree
            // about which strokes are holes. Before S-097 every export filled the courtyard.
            let holeRings = CanvasHitTesting.holes(of: shape)
            let holeStrokes = shape.strokes.enumerated().filter { _, stroke in
                stroke.closed && !stroke.filled && holeRings.contains(stroke.points)
            }
            let holeIndices = Set(holeStrokes.map(\.offset))
            // The filled polygon strokes its holes with its outline when it is stroked at all;
            // drawing them again as polylines would double a translucent markup's ink there.
            let holesStrokedByFill = !holeStrokes.isEmpty
                && shape.strokes.first(where: { $0.closed && $0.filled })?.stroked == true
            for (index, stroke) in shape.strokes.enumerated() {
                if holesStrokedByFill, holeIndices.contains(index) { continue }
                let points = stroke.points.map(SnippetSceneBuilder.point(_:))
                guard points.count >= 2 else { continue }
                let style = styled(RenderStyle(
                    // r2-markup: a Text box filled without a border draws no outline.
                    stroke: stroke.stroked ? ink : nil,
                    fill: stroke.filled ? fillInk : nil,
                    lineWidth: lineWidth
                ))
                // An arc edge (NL-MEASURE-05, ADR-0030 §5.6) reaches paper as Bézier curves; the
                // flattened points stay the geometry for everything that is not a vector painter.
                let curve = stroke.arcOutline.flatMap { RenderCurvePath(ring: $0) }
                if stroke.filled, stroke.closed {
                    let holes = holeStrokes.map(\.element)
                    output.append(RenderableMarkup(
                        id: nextID(),
                        zIndex: nextZIndex(),
                        shape: .filledPolygon(RenderPolygon(
                            outer: points,
                            holes: holes.map { $0.points.map(SnippetSceneBuilder.point(_:)) },
                            curves: SnippetSceneBuilder.contourCurves(outer: stroke, holes: holes)
                        )),
                        style: style
                    ))
                } else {
                    output.append(RenderableMarkup(
                        id: nextID(),
                        zIndex: nextZIndex(),
                        shape: .polyline(RenderPolyline(points: points, isClosed: stroke.closed, curve: curve)),
                        style: styled(RenderStyle(stroke: ink, lineWidth: lineWidth))
                    ))
                }
                if stroke.dimensioned {
                    emitDimensionGrammar(points: points, into: &output)
                }
                // nl-markup: the stroke's stored ends. The snippet draws an arrow end as a head
                // and leaves the other decorations to the canvas.
                let arrowEnds: Set<ZPDFContracts.LineCapStyle> = [.closedArrow, .openArrow]
                if arrowEnds.contains(stroke.drawnEndCap), points.count >= 2 {
                    output.append(RenderableMarkup(
                        id: nextID(),
                        zIndex: nextZIndex(),
                        shape: .filledPolygon(RenderPolygon(outer: SnippetSceneBuilder.arrowhead(
                            from: points[points.count - 2],
                            to: points[points.count - 1],
                            lineWidth: lineWidth
                        ))),
                        style: styled(RenderStyle(stroke: nil, fill: ink, lineWidth: 0), dashed: false)
                    ))
                }
                if arrowEnds.contains(stroke.startCap), !stroke.closed, points.count >= 2 {
                    output.append(RenderableMarkup(
                        id: nextID(),
                        zIndex: nextZIndex(),
                        shape: .filledPolygon(RenderPolygon(outer: SnippetSceneBuilder.arrowhead(
                            from: points[1],
                            to: points[0],
                            lineWidth: lineWidth
                        ))),
                        style: styled(RenderStyle(stroke: nil, fill: ink, lineWidth: 0), dashed: false)
                    ))
                }
            }
        }

        /// The committed-length decoration: an arrowhead at each
        /// end of the path whose tip is exactly the measured point, and a perpendicular
        /// extension tick through every measured point.
        ///
        /// The maths is `DimensionGrammar`'s, not a second copy of it — the same pure function
        /// `CanvasPageView` decorates the screen with. Before this an exported or printed
        /// length arrived as a bare polyline: the shaft without the grammar that says it is a
        /// measurement, which on a tender drawing reads as a stray line.
        ///
        /// The grammar's sizes are **view** points on screen, and page points here, for the
        /// reason `SnippetSceneBuilder.arrowhead(from:to:lineWidth:)` already gives: an export
        /// has no window for decoration to stay constant against, and on paper at 100 % the two
        /// units are the same length anyway.
        private mutating func emitDimensionGrammar(
            points: [PDFPoint],
            into output: inout [RenderableMarkup]
        ) {
            guard points.count >= 2 else { return }
            let decoration = DimensionGrammar.decoration(
                forViewPoints: points.map { CGPoint(x: $0.x, y: $0.y) }
            )
            for tick in decoration.ticks where tick.count == 2 {
                output.append(RenderableMarkup(
                    id: nextID(),
                    zIndex: nextZIndex(),
                    shape: .polyline(RenderPolyline(
                        points: tick.map { PDFPoint(x: Double($0.x), y: Double($0.y)) },
                        isClosed: false
                    )),
                    style: RenderStyle(stroke: ink, lineWidth: lineWidth)
                ))
            }
            for head in decoration.arrowheads where head.count == 3 {
                output.append(RenderableMarkup(
                    id: nextID(),
                    zIndex: nextZIndex(),
                    shape: .filledPolygon(RenderPolygon(
                        outer: head.map { PDFPoint(x: Double($0.x), y: Double($0.y)) }
                    )),
                    style: RenderStyle(stroke: nil, fill: ink, lineWidth: 0)
                ))
            }
        }

        // MARK: Text

        private mutating func emitText(into output: inout [RenderableMarkup]) {
            guard let text = shape.text, !text.isEmpty, let box = shape.textBox else { return }
            // r2-markup (ADR-0029): the text colour, and the face with its bold and italic.
            let textInk = shape.textStyle?.textColor ?? ink
            let size = shape.fontSize.isFinite && shape.fontSize > 0 ? shape.fontSize : SnippetSceneBuilder.markupTextSizePagePoints
            if shape.rotationDegrees != 0, let centre = shape.rotationCentre {
                // A turned box's words turn with it, as outlines (`MarkupTextOutlines`).
                for polygon in MarkupTextOutlines.polygons(
                    text: text, box: box, fontName: shape.fontName, fontSize: size,
                    bold: shape.textStyle?.bold ?? false, italic: shape.textStyle?.italic ?? false,
                    degrees: shape.rotationDegrees, centre: centre
                ) {
                    output.append(RenderableMarkup(
                        id: nextID(),
                        zIndex: nextZIndex(),
                        shape: .filledPolygon(polygon),
                        style: styled(RenderStyle(stroke: nil, fill: textInk, lineWidth: 0), dashed: false)
                    ))
                }
                return
            }
            let face = CanvasMarkupFont.font(
                named: shape.fontName, size: CGFloat(size), weight: .regular,
                bold: shape.textStyle?.bold ?? false, italic: shape.textStyle?.italic ?? false
            )
            // Anchored at the box's top-left, which is where `drawMarkupText` starts it. The
            // renderer's `.topLeading` measures downward from the anchor in the same sense.
            output.append(RenderableMarkup(
                id: nextID(),
                zIndex: nextZIndex(),
                shape: .textLabel(RenderTextLabel(
                    anchorPoint: PDFPoint(x: box.origin.x, y: box.origin.y + box.size.height),
                    text: text,
                    fontName: face.fontName,
                    // The markup's own size, as on the canvas: a 24 pt callout printed at 11 pt.
                    fontSize: size,
                    anchor: .topLeading
                )),
                style: styled(RenderStyle(stroke: textInk, fill: textInk, lineWidth: lineWidth), dashed: false)
            ))
        }

        // MARK: Stamps

        private mutating func emitStamp(into output: inout [RenderableMarkup]) {
            guard let stamp = shape.stamp, stamp.hasUsableBox else { return }
            let center = SnippetSceneBuilder.point(stamp.anchor)
            let size = PDFSize(width: stamp.widthPoints, height: stamp.heightPoints)
            let style = RenderStyle(stroke: ink, fill: nil, lineWidth: lineWidth)
            let base = MarkupID(shape.id)
            let labels = SnippetSceneBuilder.stampLabels(stamp)
            if let digest = stamp.rasterImageDigest, let bytes = insertedImages[digest], labels.isEmpty {
                // ADR-0043 (L-81): an inserted picture from its own pixels, through the same unit
                // mapping the canvas draws it with — letterboxed, turned and placed identically.
                // It reached paper as its 96-cell mosaic before.
                let corner = { (x: Double, y: Double) in SnippetSceneBuilder.point(stamp.pagePoint(unit: PDFPoint(x: x, y: y))) }
                output.append(RenderableMarkup(
                    id: nextID(),
                    zIndex: nextZIndex(),
                    shape: .image(RenderImage(
                        origin: corner(0, 0), xEnd: corner(1, 0), yEnd: corner(0, 1),
                        source: bytes, opacity: ink.alpha
                    )),
                    style: style
                ))
                return
            }
            if let artwork = stamp.artwork, !artwork.isEmpty {
                // The renderer's own placement maths, so the seal in the snippet is the seal
                // on the sheet — including its rotation, which a second implementation is
                // exactly the thing to get wrong.
                let shapes = StampArtworkScene.markups(
                    artwork: artwork,
                    labels: labels,
                    center: center,
                    size: size,
                    rotationDegrees: stamp.rotationDegrees,
                    style: style,
                    baseID: base,
                    zIndex: nextZIndex()
                )
                output.append(contentsOf: shapes)
                ordinal += Swift.max(1, shapes.count)
                return
            }
            // No artwork: the border and the frozen text, which is what the canvas draws in
            // the same case. Visibly a stamp, never silently nothing.
            let corners = [
                stamp.pagePoint(localX: -stamp.widthPoints / 2, localY: -stamp.heightPoints / 2),
                stamp.pagePoint(localX: stamp.widthPoints / 2, localY: -stamp.heightPoints / 2),
                stamp.pagePoint(localX: stamp.widthPoints / 2, localY: stamp.heightPoints / 2),
                stamp.pagePoint(localX: -stamp.widthPoints / 2, localY: stamp.heightPoints / 2)
            ].map(SnippetSceneBuilder.point(_:))
            output.append(RenderableMarkup(
                id: nextID(),
                zIndex: nextZIndex(),
                shape: .polyline(RenderPolyline(points: corners, isClosed: true)),
                style: style
            ))
            let lineHeight = stamp.heightPoints / Double(Swift.max(1, stamp.lines.count))
            for (line, text) in stamp.lines.enumerated() where !text.isEmpty {
                let offset = stamp.heightPoints / 2 - (Double(line) + 0.5) * lineHeight
                output.append(RenderableMarkup(
                    id: nextID(),
                    zIndex: nextZIndex(),
                    shape: .textLabel(RenderTextLabel(
                        anchorPoint: SnippetSceneBuilder.point(
                            stamp.pagePoint(localX: 0, localY: offset)
                        ),
                        text: text,
                        fontSize: Swift.max(5, Swift.min(lineHeight * 0.62, 200)),
                        anchor: .center,
                        // Turned with the box, as the canvas draws it (T-065).
                        rotationDegrees: stamp.rotationDegrees.isFinite ? stamp.rotationDegrees : 0
                    )),
                    style: style
                ))
            }
        }

        // MARK: Counts

        private mutating func emitCounts(into output: inout [RenderableMarkup]) {
            guard !shape.counts.isEmpty else { return }
            let style = styled(RenderStyle(stroke: ink, fill: ink, lineWidth: lineWidth), dashed: false)
            for mark in shape.counts {
                let center = SnippetSceneBuilder.point(mark)
                guard let symbol = shape.symbol else {
                    // A mark placed before a symbol was a property of the mark: the eight-point
                    // dot it has always been, restated from `CanvasCountSymbolPainter` so the
                    // snippet and the canvas agree about the historical case too.
                    output.append(RenderableMarkup(
                        id: nextID(),
                        zIndex: nextZIndex(),
                        shape: .countSymbol(RenderCountSymbol(
                            center: center,
                            symbol: .filledCircle,
                            size: Double(CanvasCountSymbolPainter.unsymbolledSizePoints)
                        )),
                        style: style
                    ))
                    continue
                }
                // Each mark its own identity family: with the group's id as every mark's base,
                // mark 2's contour 0 had mark 1's contour 0's id, and an id-keyed consumer drew
                // one mark of forty (BH-390).
                let markBase = StampArtworkScene.shapeIdentity(base: MarkupID(shape.id), ordinal: ordinal + 1)
                let shapes = StampArtworkScene.markups(
                    symbol: symbol,
                    artwork: shape.artwork,
                    center: center,
                    style: style,
                    baseID: markBase,
                    zIndex: nextZIndex()
                )
                output.append(contentsOf: shapes)
                // One more than the fragments: the mark's base ordinal itself is now taken.
                ordinal += Swift.max(1, shapes.count) + 1
            }
        }

        // MARK: The value pill

        private mutating func emitCaption(into output: inout [RenderableMarkup]) {
            guard let caption = shape.caption, !caption.isEmpty else { return }
            let anchor: PDFPoint
            if let area = shape.strokes.first(where: { $0.closed && $0.filled }) {
                let polygon = area.points.map(SnippetSceneBuilder.point(_:))
                let extents = SnippetSceneBuilder.pillHalfExtents(text: caption)
                // Never inside a cutout (BH-880), and on the canvas's leader when the pill
                // cannot sit in the fill (S-101): the same rule, the same holes, the same line.
                // Decided in the sheet's display frame (U-077): the pill is screen-upright, so
                // its extents run across the picture, and the leader hangs down the picture —
                // on a `/Rotate 90` sheet that is page +x, not page −y.
                let frame = SnippetSceneBuilder.DisplayFrame(rotation: rotation)
                let displayed = AreaPillPlacement.placement(
                    polygon: polygon.map(frame.toDisplay),
                    holes: CanvasHitTesting.holes(of: shape).map { $0.map { frame.toDisplay(SnippetSceneBuilder.point($0)) } },
                    pillHalfWidth: extents.halfWidth,
                    pillHalfHeight: extents.halfHeight
                )
                let placement = displayed.map { placed in
                    (center: frame.toPage(placed.center),
                     leaderStart: placed.leaderStart.map(frame.toPage),
                     leaderEnd: placed.leaderEnd.map(frame.toPage))
                }
                if let start = placement?.leaderStart, let end = placement?.leaderEnd {
                    output.append(RenderableMarkup(
                        id: nextID(),
                        zIndex: nextZIndex(),
                        shape: .polyline(RenderPolyline(points: [start, end], isClosed: false)),
                        style: RenderStyle(stroke: ink, lineWidth: Double(ZPDFStroke.measurement))
                    ))
                }
                anchor = placement?.center
                    ?? AreaPillPlacement.centroid(of: polygon)
                    ?? SnippetSceneBuilder.point(shape.bounds.origin)
            } else if let first = shape.strokes.first?.points.first {
                anchor = SnippetSceneBuilder.point(first)
            } else if let mark = shape.counts.first {
                anchor = SnippetSceneBuilder.point(mark)
            } else {
                return
            }
            // NL-MEASURE-09: a caption the person dragged sits at its stored
            // offset in page points, with a dashed leader back to its automatic place — as the
            // canvas draws it.
            var placed = anchor
            if let offset = shape.captionOffset, offset.x != 0 || offset.y != 0, offset.x.isFinite, offset.y.isFinite {
                placed = PDFPoint(x: anchor.x + offset.x, y: anchor.y + offset.y)
                output.append(RenderableMarkup(
                    id: nextID(),
                    zIndex: nextZIndex(),
                    shape: .polyline(RenderPolyline(points: [anchor, placed], isClosed: false)),
                    style: RenderStyle(stroke: ink, lineWidth: Swift.max(0.5, lineWidth * 0.5),
                                       dash: .pattern(runs: [3, 2], phase: 0))
                ))
            }
            output.append(RenderableMarkup(
                id: nextID(),
                zIndex: nextZIndex(),
                shape: .labelPill(RenderLabelPill(
                    anchorPoint: placed,
                    text: caption,
                    fontSizeViewPoints: SnippetSceneBuilder.pillFontSizeViewPoints
                )),
                style: RenderStyle(stroke: ink, fill: ink, lineWidth: lineWidth)
            ))
        }

        // MARK: Segment lengths

        /// A small light pill at every segment's midpoint, lifted off the line along its normal,
        /// as the canvas draws them (NL-MEASURE-09); skipped when the segment is too short for
        /// its label, so labels never pile up.
        private mutating func emitSegmentLabels(into output: inout [RenderableMarkup]) {
            for label in shape.segmentLabels {
                let a = SnippetSceneBuilder.point(label.start), b = SnippetSceneBuilder.point(label.end)
                let dx = b.x - a.x, dy = b.y - a.y
                let length = (dx * dx + dy * dy).squareRoot()
                let size = SnippetSceneBuilder.segmentLabelFontSize
                guard length.isFinite, length >= Double(label.text.count) * size * 0.55 * 0.8 else { continue }
                let lift = size * 1.35
                let centre = PDFPoint(x: (a.x + b.x) / 2 - dy / length * lift, y: (a.y + b.y) / 2 + dx / length * lift)
                output.append(RenderableMarkup(
                    id: nextID(),
                    zIndex: nextZIndex(),
                    shape: .labelPill(RenderLabelPill(
                        anchorPoint: centre,
                        text: label.text,
                        fontSizeViewPoints: size,
                        pillFill: RGBAColor(red: 0.2, green: 0.22, blue: 0.26, alpha: 0.92)
                    )),
                    style: RenderStyle(stroke: ink, fill: ink, lineWidth: lineWidth)
                ))
            }
        }
    }

    // MARK: - Small conversions

    /// A sheet's upright display frame: page space turned clockwise by its `/Rotate`, y up, so
    /// "across" and "down" mean across and down the exported picture (U-077). A rotation about
    /// the origin only — placement is the same wherever the frame's origin sits.
    struct DisplayFrame: Sendable, Hashable {
        let rotation: ZPDFContracts.PageRotation

        func toDisplay(_ point: PDFPoint) -> PDFPoint {
            switch rotation {
            case .degrees0: point
            case .degrees90: PDFPoint(x: point.y, y: -point.x)
            case .degrees180: PDFPoint(x: -point.x, y: -point.y)
            case .degrees270: PDFPoint(x: -point.y, y: point.x)
            }
        }

        func toPage(_ point: PDFPoint) -> PDFPoint {
            switch rotation {
            case .degrees0: point
            case .degrees90: PDFPoint(x: -point.y, y: point.x)
            case .degrees180: PDFPoint(x: -point.x, y: -point.y)
            case .degrees270: PDFPoint(x: point.y, y: -point.x)
            }
        }
    }

    /// The renderer's dash for a markup line style, the canvas's patterns in page units.
    static func dash(for style: MarkupLineStyle, lineWidth: Double) -> RenderDash {
        let unit = Swift.max(1, lineWidth)
        switch style {
        case .solid, .cloud: return .solid
        case .dashed: return .pattern(runs: [unit * 4, unit * 3], phase: 0)
        case .dotted: return .pattern(runs: [0.01, unit * 2.2], phase: 0)
        case .dashDot: return .pattern(runs: [unit * 4, unit * 2, 0.01, unit * 2], phase: 0)
        }
    }

    static func point(_ value: PDFPointValue) -> PDFPoint {
        PDFPoint(x: value.x, y: value.y)
    }

    /// The vector form of a filled area's contours, outer ring first and then every hole — the
    /// order `RenderPolygon.curves` documents — or `nil` when no contour has an arc edge.
    ///
    /// A curve list that describes fewer contours than the polygon has is ignored by the
    /// compiler, so once any ring is curved every ring gets a path: its arcs as Béziers, a
    /// straight ring as lines through its points.
    static func contourCurves(outer: CanvasStroke, holes: [CanvasStroke]) -> [RenderCurvePath]? {
        let contours = [outer] + holes
        guard contours.contains(where: { $0.arcOutline != nil }) else { return nil }
        var curves: [RenderCurvePath] = []
        curves.reserveCapacity(contours.count)
        for contour in contours {
            if let ring = contour.arcOutline, let curve = RenderCurvePath(ring: ring) {
                curves.append(curve)
                continue
            }
            let points = contour.points.map(point(_:))
            guard let first = points.first else { return nil }
            curves.append(RenderCurvePath(
                start: first,
                elements: points.dropFirst().map { .line(to: $0) },
                isClosed: true
            ))
        }
        return curves
    }

    static func color(_ value: ColorRGBA) -> RGBAColor {
        RGBAColor(red: value.red, green: value.green, blue: value.blue, alpha: value.alpha)
    }

    /// The stamp's frozen lines in the unit-space form ``StampArtworkScene`` places them in.
    static func stampLabels(_ stamp: CanvasStampPlacement) -> [StampSceneLabel] {
        let count = Swift.max(1, stamp.lines.count)
        return stamp.lines.enumerated().compactMap { line, text in
            guard !text.isEmpty else { return nil }
            let height = 1 / Double(count)
            return StampSceneLabel(
                text: text,
                normalizedFrame: PDFRect(
                    x: 0,
                    y: 1 - Double(line + 1) * height,
                    width: 1,
                    height: height
                ),
                fontSizeFraction: 0.62 * height,
                anchor: .center
            )
        }
    }

    /// A pill's half-extents, estimated from the text the way the renderer's own scene library
    /// estimates them: Helvetica's average advance is close enough to 0.55 em for a placement
    /// decision, and the decision only has to be stable, not exact.
    static func pillHalfExtents(text: String) -> (halfWidth: Double, halfHeight: Double) {
        let size = pillFontSizeViewPoints
        let width = Double(text.count) * size * 0.55 + 12
        return (halfWidth: width / 2, halfHeight: (size * 1.5) / 2)
    }

    /// The triangle drawn at the end of an Arrow or a callout's leader.
    ///
    /// Page-space, sized off the stroke width, because the snippet's arrowheads must scale with
    /// the picture rather than with a window that is not there.
    static func arrowhead(from: PDFPoint, to: PDFPoint, lineWidth: Double) -> [PDFPoint] {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length.isFinite, length > 0 else { return [] }
        let ux = dx / length
        let uy = dy / length
        let head = Swift.max(4, lineWidth * 4)
        let half = head * 0.4
        let baseX = to.x - ux * head
        let baseY = to.y - uy * head
        return [
            to,
            PDFPoint(x: baseX - uy * half, y: baseY + ux * half),
            PDFPoint(x: baseX + uy * half, y: baseY - ux * half)
        ]
    }
}
