import CoreText
import Foundation
import ZPDFContracts
import ZPDFRenderer

/// Turns a ``SnippetRegion`` into one page-space rectangle, from geometry alone.
///
/// This is ADR-0006's preparation point 1 — `boundingBox(of: [MarkupID], padding:)` in page
/// space — as an accessor over the geometry the caller already holds. Nothing here reads a
/// view, a viewport or a zoom, which is what makes the zoom-invariance property provable
/// rather than promised.
public enum SnippetRegionResolver {

    /// - Parameters:
    ///   - region: the spec's region.
    ///   - page: the page the region must land on; the result is clamped to its visible box.
    ///   - markups: the page's markups, used for `.markups` bounds.
    ///   - zones: page-space bounds by zone, for `.zone`.
    /// - Returns: a standardized, non-empty page-space rectangle.
    ///   - scaleFactor: the snippet's output scale. A label pill is sized in view points, so its
    ///     page-space extent — and therefore the crop — depends on it.
    public static func resolve(
        _ region: SnippetRegion,
        page: PageDescriptor,
        markups: [RenderableMarkup],
        zones: [ZoneID: PDFRect],
        scaleFactor: Double = 1
    ) throws(SnippetExportError) -> PDFRect {
        let raw: PDFRect
        switch region {
        case let .markups(ids, padding):
            raw = try boundingBox(
                of: ids,
                in: markups,
                padding: padding,
                rotation: page.rotation,
                scaleFactor: scaleFactor
            )
        case let .rect(rect):
            guard rect.isFinite else { throw SnippetExportError.emptyRegion }
            raw = rect.standardized
        case let .zone(id):
            guard let bounds = zones[id], bounds.isFinite else {
                throw SnippetExportError.zoneNotFound(id)
            }
            raw = bounds.standardized
        }
        let page = page.visibleBox
        guard raw.intersects(page) else { throw SnippetExportError.emptyRegion }
        let clamped = PDFRect(
            corner: PDFPoint(
                x: Swift.max(raw.minX, page.minX),
                y: Swift.max(raw.minY, page.minY)
            ),
            opposite: PDFPoint(
                x: Swift.min(raw.maxX, page.maxX),
                y: Swift.min(raw.maxY, page.maxY)
            )
        )
        guard clamped.width > 0, clamped.height > 0 else {
            throw SnippetExportError.emptyRegion
        }
        return clamped
    }

    /// The canonical key of a markup's shape family: its first twelve identity bytes, with the
    /// four-byte ordinal cleared.
    ///
    /// A markup that draws as more than one shape — a count group's marks, a stamp's contours,
    /// an area and its value pill — reaches a renderer as several ``RenderableMarkup`` values
    /// whose ids are derived from the placement's by
    /// `StampArtworkScene.shapeIdentity(base:ordinal:)`. That is the convention ADR-0011 §2.6
    /// settled after the Metal backend collapsed twenty-two contours into one slot, and
    /// `shapeIdentity(base:ordinal: 0)` is exactly "the family, no ordinal", so it doubles as
    /// the key. Matching a region's named ids on exact identity alone would crop a count group
    /// to whichever mark came last and refuse a stamp outright, both silently.
    public static func familyKey(of id: MarkupID) -> MarkupID {
        StampArtworkScene.shapeIdentity(base: id, ordinal: 0)
    }

    /// The subset of `markups` belonging to the families `ids` names, in the given order.
    public static func shapes(
        of ids: [MarkupID],
        in markups: [RenderableMarkup]
    ) -> [RenderableMarkup] {
        let families = Set(ids.map(familyKey(of:)))
        return markups.filter { families.contains(familyKey(of: $0.id)) }
    }

    /// The union of the named markups' page-space geometry bounds, grown by `padding` on every
    /// side. Throws — never guesses — when an id has no geometry, because a snippet cropped to
    /// the wrong markups is a picture that lies.
    ///
    /// - Parameters:
    ///   - rotation: the page's `/Rotate`. A label without an angle is drawn screen-upright, so
    ///     which page direction it extends in depends on it; a label that turns with its object
    ///     (``RenderTextLabel/rotationDegrees``) is page-anchored and ignores it.
    ///   - scaleFactor: the output scale, which sizes view-point decoration (label pills).
    public static func boundingBox(
        of ids: [MarkupID],
        in markups: [RenderableMarkup],
        padding: Double,
        rotation: PageRotation = .degrees0,
        scaleFactor: Double = 1
    ) throws(SnippetExportError) -> PDFRect {
        guard !ids.isEmpty else { throw SnippetExportError.emptyRegion }
        var boundsByFamily: [MarkupID: PDFRect] = [:]
        boundsByFamily.reserveCapacity(ids.count)
        let wanted = Set(ids.map(familyKey(of:)))
        // **Union, not assignment.** Every shape of a multi-shape markup contributes; the
        // earlier `=` kept whichever fragment happened to come last, so a forty-mark count
        // group would crop to one mark and the picture would disagree with the caption
        // beside it.
        for markup in markups {
            let family = familyKey(of: markup.id)
            guard wanted.contains(family),
                  let bounds = extent(of: markup, rotation: rotation, scaleFactor: scaleFactor)
            else { continue }
            boundsByFamily[family] = boundsByFamily[family].map { $0.union(bounds) } ?? bounds
        }
        var missing: [MarkupID] = []
        var union: PDFRect?
        for id in ids {
            guard let bounds = boundsByFamily[familyKey(of: id)] else {
                missing.append(id)
                continue
            }
            union = union.map { $0.union(bounds) } ?? bounds
        }
        guard missing.isEmpty else { throw SnippetExportError.markupsNotFound(missing) }
        guard let union else { throw SnippetExportError.emptyRegion }
        // `outsetBy`: a positive amount grows the region (CR-92 retired the `insetBy` spelling).
        return union.outsetBy(Swift.max(0, padding))
    }

    // MARK: - Extents

    /// The page-space rectangle a markup's ink occupies.
    ///
    /// `RenderableMarkup.geometryBounds` reports a text label and a label pill as a zero-size
    /// box at the anchor, because their extent is text layout rather than geometry. For a crop
    /// that is a picture that lies: a text note cropped to its corner, the note's words running
    /// out of frame, and — with no padding — a refusal as `emptyRegion` for a markup that is on
    /// the page. So the text is measured here, in the face and size the renderer lays it out
    /// in, and placed the way the renderer places it: offset from the anchor by the anchor's
    /// fractions, screen-upright — or, for a label that carries
    /// ``RenderTextLabel/rotationDegrees`` (a stamp's field, T-065), turned about the anchor so
    /// its baseline runs at that page angle, whatever the page's `/Rotate`.
    static func extent(
        of markup: RenderableMarkup,
        rotation: PageRotation,
        scaleFactor: Double
    ) -> PDFRect? {
        switch markup.shape {
        case let .textLabel(label):
            guard label.anchorPoint.isFinite, label.fontSize.isFinite, label.fontSize > 0,
                  let size = textSize(label.text, fontName: label.fontName, fontSize: label.fontSize)
            else { return markup.geometryBounds }
            let right = (
                -size.width * label.anchor.horizontalFraction,
                size.width * (1 - label.anchor.horizontalFraction)
            )
            let down = (
                -size.height * label.anchor.verticalFraction,
                size.height * (1 - label.anchor.verticalFraction)
            )
            if let degrees = label.rotationDegrees, degrees.isFinite {
                // Page-anchored text (T-065): the renderer lays it out upright and turns it about
                // the anchor until the baseline runs `degrees` counter-clockwise on the page, so
                // "right" is that direction and "down" is it turned a quarter clockwise. The
                // page's `/Rotate` does not enter — the renderer measures the turn through the
                // frame's own map, which already carries it. Measuring this label as a
                // screen-upright box cropped a turned stamp's words off at both ends
                // (a 90° 190 × 64 stamp lost about 19 pt of its first line at each end).
                // A non-finite angle is drawn upright, as the renderer does, and falls through.
                let radians = degrees * .pi / 180
                let baseline = (x: Foundation.cos(radians), y: Foundation.sin(radians))
                return box(
                    at: label.anchorPoint, right: right, down: down,
                    rightAxis: baseline, downAxis: (x: baseline.y, y: -baseline.x)
                )
            }
            return uprightBox(at: label.anchorPoint, right: right, down: down, rotation: rotation)
        case let .labelPill(pill):
            guard pill.anchorPoint.isFinite, scaleFactor.isFinite, scaleFactor > 0,
                  pill.fontSizeViewPoints.isFinite, pill.fontSizeViewPoints > 0,
                  let text = textSize(
                      pill.text, fontName: pill.fontName, fontSize: pill.fontSizeViewPoints
                  )
            else { return markup.geometryBounds }
            // View points to page points at the snippet's zoom (backing scale 1), with the
            // renderer's own pill padding.
            let pagePerView = 1 / scaleFactor
            let halfWidth = (text.width / 2 + MarkupCompiler.DimensionGrammar.pillPaddingXViewPoints) * pagePerView
            let halfHeight = (text.height / 2 + MarkupCompiler.DimensionGrammar.pillPaddingYViewPoints) * pagePerView
            return uprightBox(
                at: pill.anchorPoint,
                right: (-halfWidth, halfWidth),
                down: (-halfHeight, halfHeight),
                rotation: rotation
            )
        default:
            return markup.geometryBounds
        }
    }

    /// Width and line height of `text` set in `fontName` at `fontSize`, in the units of the size.
    static func textSize(_ text: String, fontName: String, fontSize: Double) -> (width: Double, height: Double)? {
        guard !text.isEmpty else { return nil }
        let font = CTFontCreateWithName(fontName as CFString, CGFloat(fontSize), nil)
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        let height = Double(ascent + descent + leading)
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        return (width, height)
    }

    /// The page-space bounds of a screen-upright box whose extent from `anchor` is `right`
    /// along the screen's x axis and `down` along the screen's downward y axis.
    private static func uprightBox(
        at anchor: PDFPoint,
        right: (Double, Double),
        down: (Double, Double),
        rotation: PageRotation
    ) -> PDFRect {
        // Screen right and screen down as page-space unit vectors, per `/Rotate` (clockwise).
        let screenRight: (x: Double, y: Double)
        let screenDown: (x: Double, y: Double)
        switch rotation {
        case .degrees0: screenRight = (1, 0); screenDown = (0, -1)
        case .degrees90: screenRight = (0, 1); screenDown = (1, 0)
        case .degrees180: screenRight = (-1, 0); screenDown = (0, 1)
        case .degrees270: screenRight = (0, -1); screenDown = (-1, 0)
        }
        return box(at: anchor, right: right, down: down, rightAxis: screenRight, downAxis: screenDown)
    }

    /// The page-space bounds of the box whose extent from `anchor` is `right` along the unit
    /// vector `rightAxis` and `down` along the unit vector `downAxis`: all four corners, so a
    /// box at any angle is covered.
    private static func box(
        at anchor: PDFPoint,
        right: (Double, Double),
        down: (Double, Double),
        rightAxis: (x: Double, y: Double),
        downAxis: (x: Double, y: Double)
    ) -> PDFRect {
        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity
        for r in [right.0, right.1] {
            for d in [down.0, down.1] {
                let x = anchor.x + r * rightAxis.x + d * downAxis.x
                let y = anchor.y + r * rightAxis.y + d * downAxis.y
                minX = Swift.min(minX, x); maxX = Swift.max(maxX, x)
                minY = Swift.min(minY, y); maxY = Swift.max(maxY, y)
            }
        }
        return PDFRect(corner: PDFPoint(x: minX, y: minY), opposite: PDFPoint(x: maxX, y: maxY))
    }
}
