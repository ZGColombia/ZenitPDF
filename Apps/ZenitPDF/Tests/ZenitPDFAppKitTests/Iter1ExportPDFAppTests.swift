import AppKit
import CryptoKit
import Foundation
import PDFKit
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFExport
import ZPDFPDFKitBridge
import ZPDFServiceClient
@testable import ZenitPDFAppKit

/// Loop iteration 1, export-pdf, in the app: K-04 (the export says which values were kept under
/// an older scale), R-106 (the seal on a quarter-turned sheet) and NL-DOCS-08 (extract and split
/// through qpdf in the repair service). No window, no panel: the write halves are driven directly.
@MainActor
@Suite("Iteration 1 — export-pdf in the app", .appTierSerialised)
struct Iter1ExportPDFAppTests {

    // MARK: - K-04

    @Test("K-04: a value kept under an older scale reaches every export as a marked row and a notice")
    func keptValueReachesTheExport() async throws {
        let harness = try await NLMeasureR2Harness.make("Stale Export.pdf")
        defer { NLMeasureR2Harness.tearDown(harness) }
        let core = harness.core
        try await core.commands.calibrate(page: harness.page, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
                                          knownLength: 10, knownLengthUnit: .metre)
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let wall = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: DocumentID(core.snapshot.documentID), pageID: harness.page,
            kind: .measurement, tool: .length, subject: "Wall", author: "t",
            geometry: MeasurementGeometry(pageID: harness.page, points: [PDFPoint(x: 200, y: 200), PDFPoint(x: 300, y: 200)]),
            createdAt: stamp, modifiedAt: stamp
        )
        try await core.commands.perform(.addMarkup(wall))
        _ = try await core.commands.applyScale(.ratio(numerator: 1, denominator: 100, label: nil), toPages: [harness.page], keepExisting: true)
        await core.refresh()
        #expect(await core.session.staleMeasurementIDs == [wall.id])

        let projection = try await ProjectWindowController.projection(
            core: core, documentName: "Stale Export", scaleDescription: nil, request: core.ledger.request
        )
        // Old: 0 — the export never heard of the kept value.
        #expect(projection.table.metadata.staleScaleRowCount == 1)
        #expect(projection.table.allRows().first { $0.markupID == wall.id.rawValue.uuidString }?.keptUnderOlderScale == true)
        #expect(projection.table.metadata.staleScaleNotice?.hasPrefix("1 value in this export was kept under an older scale") == true)
    }

    // MARK: - R-106

    @Test("R-106: the seal of a /Rotate 90 sheet is laid out on the displayed sheet and turned with it")
    func sealOnARotatedSheet() {
        let page = PageDescriptor(
            id: PageID(UUID()), documentID: DocumentID(UUID()), index: 0, label: "A-201",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 612, height: 792), crop: PDFRect(x: 0, y: 0, width: 612, height: 792)),
            rotation: .degrees90
        )
        let seal = SignDrawingCopy.seal(on: page, signer: "Jane Engineer", reason: nil, at: Date(timeIntervalSince1970: 1_790_164_800), artwork: nil)
        // Displayed 792 × 612: the seal 200 × 64 at displayed (580, 12). Through the placement
        // matrix for 90°, (x, y) → (612 − y, x): page (536, 580), 64 × 200.
        // Old: page (400, 12, 200, 64) — the displayed bottom-left, drawn sideways.
        #expect(seal.rect == PDFRect(x: 536, y: 580, width: 64, height: 200))
        #expect(seal.rotation == .degrees90)
    }

    // MARK: - NL-DOCS-08

    /// Three sheets labelled A-101…A-103, their line in layer "Walls" (off by default).
    static func labelledLayeredDrawing(at url: URL) throws {
        let content = "/OC /L1 BDC 0 0 0 RG 10 10 m 190 190 l S EMC\n"
        var objects: [(String, String?)] = [
            ("<< /Type /Catalog /Pages 2 0 R /PageLabels << /Nums [0 << /S /D /P (A-) /St 101 >>] >>"
                + " /OCProperties << /OCGs [7 0 R] /D << /Order [7 0 R] /ON [] /OFF [7 0 R] >> >> >>", nil),
            ("<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 >>", nil),
        ]
        for _ in 0..<3 {
            objects.append(("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Contents 6 0 R /Resources << /Properties << /L1 7 0 R >> >> >>", nil))
        }
        objects.append(("<< /Length \(content.utf8.count) >>", content))
        objects.append(("<< /Type /OCG /Name (Walls) >>", nil))
        var pdf = Data("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.count)
            var body = "\(index + 1) 0 obj\n\(object.0)\n"
            if let stream = object.1 { body += "stream\n\(stream)\nendstream\n" }
            pdf.append(Data((body + "endobj\n").utf8))
        }
        let xref = pdf.count
        var table = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { table += String(format: "%010d 00000 n \n", offset) }
        table += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        pdf.append(Data(table.utf8))
        try pdf.write(to: url)
    }

    static func hasLayerDefinitions(_ url: URL) throws -> Bool {
        // The document stays alive while its catalog is read: the catalog belongs to it.
        let document = try #require(CGPDFDocument(url as CFURL))
        let catalog = try #require(document.catalog)
        var properties: CGPDFDictionaryRef?
        return CGPDFDictionaryGetDictionary(catalog, "OCProperties", &properties)
    }

    @Test("NL-DOCS-08: Extract Pages of a layered drawing runs through qpdf in the repair worker and keeps labels and layers")
    func extractThroughTheRepairService() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("iter1-docs08-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Layers.pdf")
        try Self.labelledLayeredDrawing(at: source)
        let before = SHA256.hash(data: try Data(contentsOf: source))
        let worker = try NLPDFR2FormFillTests.productsDirectory().appendingPathComponent("zpdf-repair-worker")
        try #require(FileManager.default.fileExists(atPath: worker.path), "zpdf-repair-worker is built next to the tests")
        DamagedDrawingRepair.clientOverride = ZPDFRepairServiceClient(backend: .subprocess(executableURL: worker), maximumRestarts: 0)
        defer { DamagedDrawingRepair.clientOverride = nil }

        let document = ZenitPDFProjectDocument()
        let destination = directory.appendingPathComponent("extract.pdf")
        let receipt = try #require(await document.writeExtract(indices: [2, 0], from: source, password: nil, to: destination))
        #expect(receipt.pageCount == 2)
        #expect(receipt.sourceIsUnchanged)
        #expect(SHA256.hash(data: try Data(contentsOf: source)) == before, "the drawing is never written")
        // Old: PDFKit's copy — the labels kept, the layer definitions gone, so "Walls", off in the
        // drawing, drew in the extract.
        #expect(try Self.hasLayerDefinitions(destination))
        let extracted = try #require(PDFDocument(url: destination))
        #expect(extracted.page(at: 0)?.label == "A-103" && extracted.page(at: 1)?.label == "A-101")
        #expect(receipt.structureNotCarried == [.outline], "the drawing's bookmarks are the one thing said to stay behind")

        // The drawing itself as the destination is never handed to the service.
        #expect(await document.extractThroughRepairService((source, nil, [0]), to: source) == nil)
        #expect(SHA256.hash(data: try Data(contentsOf: source)) == before)
    }

    @Test("NL-DOCS-08: the qpdf route is taken only when nothing but PDFKit can do what the export asks")
    func routeChoice() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("iter1-docs08-route-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let layered = directory.appendingPathComponent("Layers.pdf")
        try Self.labelledLayeredDrawing(at: layered)
        let harness = try await Fix2Harness.make("Layers.pdf", calibrate: false, fixture: layered)
        defer { harness.tearDown() }
        let pages = await harness.document.setExportPages()
        #expect(pages.count == 3)
        let route = try #require(ZenitPDFProjectDocument.repairServiceRoute(Array(pages.reversed()), sheetBookmarks: false))
        #expect(route.indices == [2, 1, 0])
        // Sheet-name bookmarks, a turned sheet, or a sheet number the drawing does not carry: PDFKit.
        #expect(ZenitPDFProjectDocument.repairServiceRoute(pages, sheetBookmarks: true) == nil)
        let ids = await harness.core.session.pageOrderIDs
        _ = try await harness.core.commands.perform(.setPageViews([ids[0]: PageViewSettings(rotation: 90)]))
        #expect(ZenitPDFProjectDocument.repairServiceRoute(await harness.document.setExportPages(), sheetBookmarks: false) == nil)
        _ = try await harness.core.commands.perform(.setPageViews([ids[0]: PageViewSettings(rotation: 0)]))
        _ = try await harness.core.commands.perform(.setSheetIdentities(
            [ids[1]: SheetIdentity(number: "Z-900", title: nil, source: .manual)], overwriteManual: true
        ))
        #expect(ZenitPDFProjectDocument.repairServiceRoute(await harness.document.setExportPages(), sheetBookmarks: false) == nil)
        // A drawing with no layer definitions: PDFKit keeps everything it has.
        #expect(!ZenitPDFProjectDocument.drawingHasLayerDefinitions(try AppTestSupport.writeFixturePDF(named: "Plain.pdf"), password: nil))
    }
}
