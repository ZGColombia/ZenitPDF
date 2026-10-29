import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// Quality-loop iteration 7, ui-presentation-measure, X-037 through the shipping document: the
/// number drawn on a slab with an opening is the ledger's Plan Area — the net area — on the
/// canvas pill and in the annotated PDF's `/Contents`, not the gross outline.
@MainActor
@Suite("Iter7 area headline on the canvas and on paper (X-037)", .appTierSerialised)
struct Iter7AreaHeadlineAppTests {

    private static func square(_ x: Double, _ y: Double, _ side: Double) -> [PDFPoint] {
        [PDFPoint(x: x, y: y), PDFPoint(x: x + side, y: y), PDFPoint(x: x + side, y: y + side), PDFPoint(x: x, y: y + side)]
    }

    /// 50 pt = 1 m. The slab is 500 × 500 pt = 10 × 10 m, the opening 200 × 200 pt = 4 × 4 m.
    /// Hand-derived: 10 × 10 − 4 × 4 = 100 − 16 = 84 m²; the outline alone is 100 m².
    @Test("X-037: a 10 × 10 m slab with a 4 × 4 m opening reads 84.00 m² on the pill and in the annotation")
    func pillAndAnnotationReadTheNetArea() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "SlabWithOpening.pdf")
        let document = try AppTestSupport.makeDocument(opening: url)
        defer {
            Task { @MainActor in
                await document.drawing?.rasterSource.close()
                // A measured document is dirty; closing it dirty would raise the unsaved-takeoff review.
                document.updateChangeCount(.changeCleared)
                document.close()
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
        }
        #expect(await AppTestSupport.wait { document.core != nil && document.drawing != nil })
        let core = try #require(document.core)
        let drawing = try #require(document.drawing)
        let page = try #require(drawing.pages.first)
        _ = try await core.commands.calibrate(
            page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 50, y: 0),
            knownLength: 1, knownLengthUnit: .metre
        )
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let parentID = MarkupID(UUID())
        let cutoutID = MarkupID(UUID())
        func polygon(_ id: MarkupID, tool: ZPDFContracts.MeasurementTool, ring: [PDFPoint]) -> ZPDFContracts.MarkupRecord {
            ZPDFContracts.MarkupRecord(
                id: id, documentID: drawing.documentID, pageID: page.id,
                kind: tool == .area ? .measurement : .polygon, tool: tool,
                subject: tool == .area ? "Slab" : "Opening", author: "A. Berg",
                geometry: MeasurementGeometry(pageID: page.id, polygons: [PolygonGeometry(outer: PolygonRing(points: ring, isClosed: true))]),
                createdAt: stamp, modifiedAt: stamp
            )
        }
        try await core.commands.perform(.addMarkup(polygon(parentID, tool: .area, ring: Self.square(50, 100, 500))))
        try await core.commands.perform(.addCutout(
            parent: parentID, cutout: polygon(cutoutID, tool: .polygonCutout, ring: Self.square(200, 250, 200))
        ))
        await core.commands.settle()
        await core.refresh()

        // The document formats in the person's locale ("84,00 m²" under a decimal comma), through
        // the ledger's one formatter; the numbers are the hand-derived 84 and 100 m².
        let formatter = core.snapshot.ledger.formatter
        let net = formatter.textWithUnit(Shown.Quantity.squareMetres(84))
        let gross = formatter.textWithUnit(Shown.Quantity.squareMetres(100))
        let summary = try #require(core.snapshot.markups.first { $0.id == parentID.rawValue })
        #expect(summary.field(.planArea)?.displayTextWithUnit == gross, "the outline is unchanged")
        // Old output: the gross 100 m² — the pill printed the outline beside a ledger of 84.
        #expect(CanvasSceneBuilder.caption(for: summary) == net)

        // The annotated export builds its appearance and /Contents through the same scene.
        let job = try await StandardAnnotationExport.job(for: document)
        let annotation = try #require(job.pages.flatMap(\.annotations).first { $0.id == parentID.rawValue })
        let contents = try #require(annotation.contents)
        #expect(contents.contains(net), "\(contents)")
        #expect(!contents.contains(gross), "old output: /Contents quoted the outline")
    }
}
