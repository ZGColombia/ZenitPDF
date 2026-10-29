import Foundation
import Testing
import ZPDFContracts
import ZPDFRenderer
@testable import ZPDFExport

/// Iteration 5: V-052 (annotated export keeps the drawing's own `/VP`
/// viewports) and V-055 (a count names no unit in a snippet caption). Each test says what the
/// code before the fix did.
@Suite("Iteration 5 — PDF export", .sharedHeap, .serialized)
struct Iter5ExportPDFTests {

    // MARK: - V-052

    /// A one-sheet drawing with the geometry `FlattenedPDFWriterTests.page()` describes, whose
    /// page `/VP` is an indirect array of two CAD viewports: a direct 1:100 plan and a 1:20
    /// detail by reference.
    static func drawingWithViewports() -> Data {
        let content = "30 40 m 390 300 l S"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 420 340] /CropBox [10 20 410 320] /Rotate 0"
                + " /Contents 4 0 R /Resources 5 0 R /VP 6 0 R >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
            "<< /ProcSet [/PDF] >>",
            "[<< /Type /Viewport /BBox [20 30 200 200] /Name (Plan 1:100) /Measure 7 0 R >> 8 0 R]",
            "<< /Type /Measure /Subtype /RL /R (1:100) /X [<< /U (mm) /C 35.2778 >>] /D [<< /U (m) /C 0.001 >>] >>",
            "<< /Type /Viewport /BBox [220 30 400 200] /Name (Detail 1:20)"
                + " /Measure << /Type /Measure /Subtype /RL /R (1:20) /X [<< /U (mm) /C 7.05556 >>] /D [<< /U (m) /C 0.001 >>] >> >>",
        ]
        var pdf = Data("%PDF-1.6\n%\u{00E2}\u{00E3}\u{00CF}\u{00D3}\n".utf8)
        var offsets: [Int] = []
        for (index, body) in objects.enumerated() {
            offsets.append(pdf.count)
            pdf.append(Data("\(index + 1) 0 obj\n\(body)\nendobj\n".utf8))
        }
        let xref = pdf.count
        var table = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { table += String(format: "%010d 00000 n \n", offset) }
        table += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        pdf.append(Data(table.utf8))
        return pdf
    }

    static let ink = RGBAColor(red: 0.1, green: 0.33, blue: 0.81, alpha: 1)

    static func line(_ id: UUID) -> StandardAnnotation {
        let start = PDFPoint(x: 40, y: 60), end = PDFPoint(x: 190, y: 60)
        return StandardAnnotation(
            id: id,
            geometry: .polyLine([start, end]),
            stroke: ink,
            intent: .polyLineDimension,
            appearance: [RenderableMarkup(
                id: MarkupID(id),
                shape: .polyline(RenderPolyline(points: [start, end], isClosed: false)),
                style: RenderStyle(stroke: ink, lineWidth: 1.5)
            )]
        )
    }

    static func scale(_ ratio: Double) -> MeasureScale {
        MeasureScale(ratioLabel: "1:\(Int(ratio))", metresPerPoint: ratio * 0.0254 / 72)
    }

    /// The page's `/VP` after an export: each entry's `/Name`, `/R`, and whether Zenit owns it.
    static func viewports(in data: Data) throws -> [(name: String?, ratio: String?, zenit: Bool)] {
        let scan = try PDFDocumentScan(data: data)
        let page = try #require(try scan.pages().first)
        return StandardAnnotationWriter.existingViewports(of: page, scan: scan).map { element in
            let dictionary = scan.object(element)?.dictionaryValue ?? [:]
            let measure = dictionary["Measure"].flatMap { scan.object($0)?.dictionaryValue }
            return (
                StandardAnnotationWriter.text(dictionary["Name"]),
                StandardAnnotationWriter.text(measure?["R"]),
                dictionary[StandardAnnotationWriter.ownerKey] != nil
            )
        }
    }

    static func export(_ source: Data, annotations: [StandardAnnotation], viewports: [MeasureViewport]) throws -> (data: Data, outcome: StandardAnnotationOutcome) {
        try StandardAnnotationWriter().data(
            source: source,
            pages: [StandardAnnotationPage(
                page: FlattenedPDFWriterTests.page(), sourcePageIndex: 0,
                annotations: annotations, viewports: viewports
            )]
        )
    }

    @Test("V-052: the drawing's own /VP viewports are kept around Zenit's: sheet-wide first, the drawing's next, Scale Regions last")
    func drawingViewportsAreKept() throws {
        let source = Self.drawingWithViewports()
        let sheet = MeasureViewport(bounds: PDFRect(x: 10, y: 20, width: 400, height: 300), name: "Sheet 1:100", measure: Self.scale(100), coverage: .sheet)
        let region = MeasureViewport(bounds: PDFRect(x: 300, y: 220, width: 100, height: 90), name: "Region 1:50", measure: Self.scale(50))
        let produced = try Self.export(source, annotations: [Self.line(UUID())], viewports: [region, sheet])

        let written = try Self.viewports(in: produced.data)
        // Old: [("Region 1:50"), ("Sheet 1:100")] — the page's /VP replaced by Zenit's alone, so
        // every other reader measured the 1:20 detail at the sheet's 1:100.
        #expect(written.map(\.name) == ["Sheet 1:100", "Plan 1:100", "Detail 1:20", "Region 1:50"])
        #expect(written.map(\.ratio) == ["1:100", "1:100", "1:20", "1:50"])
        #expect(written.map(\.zenit) == [true, false, false, true])
        #expect(produced.outcome.viewportCount == 2)
        #expect(produced.outcome.keptDrawingViewportCount == 2)
        #expect(produced.data.prefix(source.count) == source, "the drawing's bytes are the prefix")

        // A re-export replaces Zenit's own viewports and keeps the drawing's.
        let again = try Self.export(produced.data, annotations: [Self.line(UUID())], viewports: [
            MeasureViewport(bounds: sheet.bounds, name: "Sheet 1:200", measure: Self.scale(200), coverage: .sheet)
        ])
        #expect(try Self.viewports(in: again.data).map(\.name) == ["Sheet 1:200", "Plan 1:100", "Detail 1:20"])

        // With no scale left in Zenit, only the drawing's remain — never a stale 1:200.
        let unscaled = try Self.export(again.data, annotations: [Self.line(UUID())], viewports: [])
        #expect(try Self.viewports(in: unscaled.data).map(\.name) == ["Plan 1:100", "Detail 1:20"])
        #expect(unscaled.outcome.viewportCount == 0)
    }

    @Test("V-052: a sheet with only Zenit's old viewports and nothing else to write is still cleared of them")
    func staleZenitViewportsAreRemoved() throws {
        let plain = LayeredSourceFixtures.plain()
        let sheet = MeasureViewport(bounds: PDFRect(x: 10, y: 20, width: 400, height: 300), name: "Sheet 1:100", measure: Self.scale(100), coverage: .sheet)
        let first = try Self.export(plain, annotations: [], viewports: [sheet])
        #expect(try Self.viewports(in: first.data).map(\.name) == ["Sheet 1:100"])
        let cleared = try Self.export(first.data, annotations: [], viewports: [])
        #expect(try Self.viewports(in: cleared.data).isEmpty)
        // And a drawing's own /VP on a page Zenit has nothing for is not touched at all.
        let untouched = try Self.export(Self.drawingWithViewports(), annotations: [], viewports: [])
        #expect(try Self.viewports(in: untouched.data).map(\.name) == ["Plan 1:100", "Detail 1:20"])
    }

    // MARK: - V-055

    @Test("V-055: a count in a snippet caption names no unit, as the ledger shows it")
    func countCaptionNamesNoUnit() throws {
        let markup = MarkupID(ExportFixture.uuid(0))
        let source = SnippetSource(documentName: "A-101", pageIndex: 0, pageLabel: "A-101", revision: "C")
        for notation in [nil, ExportScreenNotation(decimalPlaces: 2)] {
            let projection = try ExportProjector().project(
                ExportFixture.goldenReport(),
                options: ExportProjectionOptions(screenNotation: notation)
            )
            let golden = try #require(projection.table.columns.firstIndex { $0.key == "golden" })
            let row = try #require(projection.table.allRows().first { $0.markupID == markup.rawValue.uuidString })
            let number = try #require(row.cells[golden].number)
            #expect(number.unitSymbol == "1", "the fixture's count carries the base unit's symbol")
            let caption = SnippetCaptionBuilder.build(
                detail: .compact, markupIDs: [markup], projection: projection, source: source,
                options: SnippetCaptionOptions(valueColumnKey: "golden")
            )
            // Old: "L0 · Concrete: 0.44 1" (and "… 0.4449 1" with the screen's rules).
            #expect(caption.lines == ["L0 · Concrete: \(number.text)"], "\(caption.lines)")
            #expect(number.textNamingUnit == number.text)
        }
        // A dimensioned value still names its unit.
        let projection = try ExportProjector().project(ExportFixture.goldenReport())
        let plan = try #require(projection.table.columns.firstIndex { $0.key == "planArea" })
        let area = try #require(projection.table.allRows().first?.cells[plan].number)
        #expect(area.textNamingUnit == "\(area.text) \(area.unitSymbol)")
        #expect(!area.unitSymbol.isEmpty)
    }
}
