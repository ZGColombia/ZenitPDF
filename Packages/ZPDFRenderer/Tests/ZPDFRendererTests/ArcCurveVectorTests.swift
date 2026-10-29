import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFRenderer
import ZPDFRendererScenario

/// NL-MEASURE-05 (ADR-0030 §5.6): an arc edge reaches a vector destination as cubic Bézier curves.
///
/// The markup is the golden shape at page scale: the rectangle (100,100)–(300,100)–(300,200)–
/// (100,200) whose right side is an outward semicircle, bulge 1 — radius 50. At the 0.01 pt drawing
/// tolerance a quarter-turn cubic strays 2.7e-4 × 50 ≈ 0.0136 pt, too far, so the semicircle is
/// drawn as four eighth-turn cubics (≈ 4.2e-6 × 50 ≈ 0.0002 pt).
@Suite("Arc edges as curves in a vector export (NL-MEASURE-05)", .serialized)
struct ArcCurveVectorTests {

    static let ring = PolygonRing(
        points: [PDFPoint(x: 100, y: 100), PDFPoint(x: 300, y: 100), PDFPoint(x: 300, y: 200), PDFPoint(x: 100, y: 200)],
        isClosed: true,
        bulges: [0, 1, 0, 0]
    )

    static func markup() throws -> RenderableMarkup {
        let curve = try #require(RenderCurvePath(ring: ring))
        return RenderableMarkup(
            id: MarkupID(UUID(uuid: (0xA7, 0xC0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))),
            shape: .filledPolygon(RenderPolygon(outer: ring.flattened(tolerance: 0.01).points, curves: [curve])),
            style: RenderStyle(stroke: .opaqueBlack, fill: .opaqueBlack, lineWidth: 1)
        )
    }

    @Test("The curve path: three lines and four cubics, ends on the ring's vertices")
    func curvePath() throws {
        let curve = try #require(RenderCurvePath(ring: Self.ring))
        let cubics = curve.elements.filter { if case .cubic = $0 { return true } else { return false } }
        let lines = curve.elements.filter { if case .line = $0 { return true } else { return false } }
        #expect(cubics.count == 4 && lines.count == 3)
        #expect(curve.isClosed && curve.start == PDFPoint(x: 100, y: 100))
        if case let .cubic(_, _, end)? = cubics.last { #expect(end == PDFPoint(x: 300, y: 200)) }
        // A straight ring has no curve worth carrying, but the path is still its lines.
        let straight = try #require(RenderCurvePath(ring: PolygonRing(points: Self.ring.points)))
        #expect(straight.elements.count == 4)
    }

    @Test("The compiler carries the curves beside the flattened instances")
    func compilerCarriesCurves() throws {
        let compiler = MarkupCompiler(glyphAtlases: GlyphAtlasCache(), pixelsPerPagePoint: 1)
        let compiled = try #require(compiler.compile(try Self.markup()))
        #expect(compiled.vectorFill.count == 1)
        #expect(compiled.vectorStroke.count == 1)
        // The semicircle flattens at 0.01 pt to π / (2·acos(1 − 0.01/50)) ≈ 79 chords.
        #expect(!compiled.triangles.isEmpty && compiled.segments.count > 60, "the GPU path keeps the flattened outline")
    }

    final class OperatorCount {
        var curves = 0
        var lines = 0
    }

    /// Painted into a PDF context by the CoreGraphics backend (the path every flattened and
    /// annotated export takes), the content stream carries curve operators. Old output: no `c` at
    /// all, and hundreds of `l` for the flattened arc and its triangulated fill.
    @Test("Painted into a PDF: curve operators, not a flattened arc")
    func pdfContentHasCurves() throws {
        let page = SceneIdentity.page()
        let viewport = RenderViewport.fittingWholePage(page, zoom: 1, backingScale: 1)
        let renderer = CoreGraphicsMarkupRenderer()
        defer { renderer.dispose() }
        renderer.update(page: page, markups: [try Self.markup()], selection: .empty, snapFeedback: nil, viewport: viewport)

        let buffer = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: buffer as CFMutableData))
        var box = CGRect(x: 0, y: 0, width: Double(viewport.pixelSize.width), height: Double(viewport.pixelSize.height))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        #expect(renderer.drawCurrentScene(into: context, pixelHeight: viewport.pixelSize.height))
        context.endPDFPage()
        context.closePDF()

        let provider = try #require(CGDataProvider(data: buffer as CFData))
        let document = try #require(CGPDFDocument(provider))
        let pdfPage = try #require(document.page(at: 1))
        let table = try #require(CGPDFOperatorTableCreate())
        CGPDFOperatorTableSetCallback(table, "c") { _, info in
            guard let info else { return }
            Unmanaged<OperatorCount>.fromOpaque(info).takeUnretainedValue().curves += 1
        }
        CGPDFOperatorTableSetCallback(table, "l") { _, info in
            guard let info else { return }
            Unmanaged<OperatorCount>.fromOpaque(info).takeUnretainedValue().lines += 1
        }
        let count = OperatorCount()
        let stream = CGPDFContentStreamCreateWithPage(pdfPage)
        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(count).toOpaque())
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(stream)
        // Fill and stroke: four cubics each; the three straight sides each once per path.
        #expect(count.curves == 8, "curves \(count.curves)")
        #expect(count.lines <= 8, "lines \(count.lines)")
    }
}
