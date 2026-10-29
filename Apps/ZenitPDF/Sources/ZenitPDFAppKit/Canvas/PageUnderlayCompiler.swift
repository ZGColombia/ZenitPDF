import CoreGraphics
import Foundation
import ZPDFContracts
import ZPDFRenderer
import ZPDFVectorExtraction

/// Turns a page's extracted vector geometry into shapes `ZPDFRenderer` can draw.
///
/// # What the underlay is, exactly
///
/// It is **the page's linework and nothing else**. The extraction comes from a `CGPDFScanner`
/// walk that was written for the snap engine, and it carries painted path geometry with stroke
/// widths. It does **not** carry:
///
/// - **text** — a `Tj` is not a path, so no lettering, no dimensions, no title block appears;
/// - **paint colour** — every primitive is drawn in one ink, because the extraction records
///   none;
/// - **shading, patterns and transparency groups** — a `sh` or a soft mask is not geometry;
/// - **images** — a CAD sheet's raster logos and stamps are not geometry, and the underlay has
///   none.
///
/// So the underlay is a *sharp skeleton beneath a sharpening page*, and it is drawn under the
/// raster and dropped the instant the raster lands. It is never a claim to be the page, it is
/// never what a measurement is taken against, and nothing in the product may present it as the
/// drawing. What it is good for is the four to thirty milliseconds after a zoom, where the
/// alternative is a stretched picture of the previous zoom.
///
/// # Why it is affordable
///
/// The roughly 17 000 primitives of a typical A1 roof plan compile to about 18 000 line instances in
/// 1.6 MB and cost 0.38 ms of CPU plus 0.19 ms of GPU per frame at every zoom from 5 % to 800 %,
/// which is twenty to forty times cheaper than the blit the canvas performs anyway
/// (historical viewer-benchmark measurements on the reference machine).
enum PageUnderlayCompiler {

    /// Segments a cubic is flattened into. Eight is what the benchmark measured; on this sheet
    /// only 40 primitives are cubics, so the count is not a cost anyone can see.
    static let cubicSegments = 8

    /// The single ink the skeleton is drawn in. It has no relation to the page's own colours,
    /// which the extraction does not record, and it is deliberately lighter than the markup
    /// palette so the underlay never reads as a markup.
    static let ink = RGBAColor(red: 0.42, green: 0.45, blue: 0.50, alpha: 1)

    /// Compiles a page extraction.
    ///
    /// - Parameters:
    ///   - extraction: the page's primitives, in page space.
    ///   - hiddenLayerIDs: marked-content property names whose layer is effectively hidden, so
    ///     the underlay honours a per-project layer override exactly as the content-stream
    ///     renderer does. A skeleton that shows a layer the user hid would be worse than none.
    ///   - limit: the most primitives that will be compiled. A corrupt or adversarial page with
    ///     millions of segments turns into a truncated skeleton, never an unbounded allocation.
    static func markups(
        from extraction: VectorPageExtraction,
        hiddenLayerIDs: Set<String> = [],
        limit: Int = 400_000,
        revision: Int = 0
    ) -> [RenderableMarkup] {
        let filter = VectorLayerVisibilityFilter(hiddenLayerIDs: hiddenLayerIDs)
        var markups: [RenderableMarkup] = []
        markups.reserveCapacity(min(extraction.primitives.count, limit))
        var index = 0
        for primitive in extraction.primitives where filter.admits(primitive) {
            guard markups.count < limit else { break }
            // Parents carry whole subpaths; orphan segments carry open polylines and lone
            // curves. Children of a parent are skipped so no edge is stroked twice — the same
            // rule `LayerFilteredPageRenderer` applies, for the same reason.
            switch primitive.kind {
            case .rectangle, .closedSubpath:
                break
            case .lineSegment, .cubicCurve:
                guard primitive.parentID == nil else { continue }
            }
            guard let polyline = polyline(for: primitive.geometry) else { continue }
            index += 1
            markups.append(
                RenderableMarkup(
                    id: MarkupID(deterministicIdentifier(index)),
                    // Positional ids repeat across compiles, so the revision is what tells the
                    // renderer's instance arena that id 7 is a different line now: with a
                    // constant 0 it kept the old geometry — the layer just hidden — for every
                    // id whose element count matched (BH-345).
                    revision: UInt64(truncatingIfNeeded: revision),
                    zIndex: index,
                    shape: .polyline(polyline),
                    style: RenderStyle(
                        stroke: ink,
                        fill: nil,
                        opacity: 1,
                        lineWidth: max(primitive.strokeWidth, 0.05)
                    )
                )
            )
        }
        return markups
    }

    /// A polyline for one primitive, in page space.
    static func polyline(for geometry: VectorGeometry) -> RenderPolyline? {
        switch geometry {
        case let .line(line):
            return RenderPolyline(
                points: [point(line.start), point(line.end)],
                isClosed: false
            )
        case let .cubic(cubic):
            var points: [PDFPoint] = []
            points.reserveCapacity(cubicSegments + 1)
            for step in 0...cubicSegments {
                let t = Double(step) / Double(cubicSegments)
                points.append(
                    bezier(
                        point(cubic.p0), point(cubic.p1), point(cubic.p2), point(cubic.p3),
                        at: t
                    )
                )
            }
            return RenderPolyline(points: points, isClosed: false)
        case let .rectangle(quad):
            let corners = quad.corners.map(point)
            guard corners.count >= 3 else { return nil }
            return RenderPolyline(points: corners, isClosed: true)
        case let .ring(ring):
            guard ring.vertices.count >= 2 else { return nil }
            return RenderPolyline(points: ring.vertices.map(point), isClosed: ring.isClosed)
        }
    }

    private static func point(_ value: CGPoint) -> PDFPoint {
        PDFPoint(x: Double(value.x), y: Double(value.y))
    }

    private static func bezier(_ p0: PDFPoint, _ p1: PDFPoint, _ p2: PDFPoint, _ p3: PDFPoint, at t: Double) -> PDFPoint {
        let u = 1 - t
        let a = u * u * u
        let b = 3 * u * u * t
        let c = 3 * u * t * t
        let d = t * t * t
        return PDFPoint(
            x: a * p0.x + b * p1.x + c * p2.x + d * p3.x,
            y: a * p0.y + b * p1.y + c * p2.y + d * p3.y
        )
    }

    /// A stable identifier for the n-th compiled primitive.
    ///
    /// Deterministic rather than random because the renderer's update is diff-based on
    /// `(id, revision)`: a fresh `UUID()` per frame would re-upload all 17 827 line instances
    /// every time and turn a 0.38 ms build into an upload storm.
    private static func deterministicIdentifier(_ index: Int) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        // A fixed namespace in the first eight bytes, the index in the last eight. Not a
        // hash, not a UUID version anyone should read meaning into: an identity, nothing more.
        bytes[0] = 0x5A; bytes[1] = 0x50; bytes[2] = 0x44; bytes[3] = 0x46
        bytes[4] = 0x55; bytes[5] = 0x4E; bytes[6] = 0x44; bytes[7] = 0x52
        var value = UInt64(bitPattern: Int64(index))
        for offset in 0..<8 {
            bytes[15 - offset] = UInt8(truncatingIfNeeded: value)
            value >>= 8
        }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
