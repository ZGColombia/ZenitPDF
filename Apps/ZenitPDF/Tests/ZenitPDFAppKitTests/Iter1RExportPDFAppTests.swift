import AppKit
import CoreGraphics
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

/// Loop iteration 1 re-fix, export-pdf, in the app: K-04 (File ▸ Export with Profile says when
/// values were kept under an older scale) and NL-DOCS-08 (Extract Pages and Split into Sheets say
/// what they carried, carry the named destinations through qpdf, and split a 300-sheet layered
/// drawing inside the 20 s budget). Each test says what the code before the re-fix did.
@MainActor
@Suite("Iteration 1 re-fix — export-pdf in the app", .appTierSerialised, .serialized)
struct Iter1RExportPDFAppTests {

    // MARK: - K-04: the profile export

    @Test("K-04: a profile export of a project with a value kept under an older scale says so in the note; the file keeps the profile's columns")
    func profileExportSaysKeptValues() async throws {
        let harness = try await NLMeasureR2Harness.make("Stale Profile.pdf")
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
        let projectionBefore = try await ProjectWindowController.projection(
            core: core, documentName: "Stale Profile", scaleDescription: nil, request: core.ledger.request)
        var profile = ExportProfiles.profile(from: projectionBefore, name: "Office")
        profile.columns = profile.columns.filter { $0.key == "subject" || $0.key == "planLength" }
        profile.encoding = .utf8
        profile.lineEnding = .lf

        // Before the scale changes: nothing kept, the note is the plain one.
        let fresh = harness.directory.appendingPathComponent("fresh.csv")
        #expect(await ExportProfiles.write(profile: profile, document: harness.document, to: fresh))
        let plain = try #require(core.document.warnings.last { $0.id == ExportProfiles.noteID })
        #expect(plain.severity == .info)
        #expect(!plain.message.contains("older scale"))

        _ = try await core.commands.applyScale(.ratio(numerator: 1, denominator: 100, label: nil), toPages: [harness.page], keepExisting: true)
        await core.refresh()
        #expect(await core.session.staleMeasurementIDs == [wall.id])
        let url = harness.directory.appendingPathComponent("office.csv")
        #expect(await ExportProfiles.write(profile: profile, document: harness.document, to: url))
        let note = try #require(core.document.warnings.last { $0.id == ExportProfiles.noteID })
        // Old: "Every column the profile asks for was written." at .info — nothing anywhere said
        // the Wall's length was kept under the older scale.
        #expect(note.severity == .warning)
        #expect(note.message.contains("1 value in this export was kept under an older scale"), "\(note.message)")
        #expect(note.message.contains("tell whoever receives the file"))
        // The receiving system's layout is untouched: the profile's two columns, no scale column.
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.split(separator: "\n").allSatisfy { $0.split(separator: ";", omittingEmptySubsequences: false).count == 2 }, "\(text)")
        #expect(!text.contains("older scale"))
        #expect(try profile.renderDetailed(try await ProjectWindowController.projection(
            core: core, documentName: "Stale Profile", scaleDescription: nil, request: core.ledger.request)).staleScaleNotice != nil)
    }

    // MARK: - NL-DOCS-08

    /// `pageCount` sheets labelled A-101…, each with a line; `layered` puts the line in layer
    /// "Walls" (off by default); `named` adds `/detail` (catalog /Dests) and `(section)` (name tree)
    /// on the second sheet, with sheet 1 linking to both; `outline` adds a bookmark per sheet;
    /// `formsPerSheet` gives each sheet that many small forms of its own, so the drawing has the
    /// object count of a real set rather than of a toy.
    static func drawing(at url: URL, pageCount: Int = 3, layered: Bool, named: Bool, outline: Bool = false, formsPerSheet: Int = 0) throws {
        var objects: [(String, Data?)] = []
        func add(_ dictionary: String, _ stream: Data? = nil) -> Int { objects.append((dictionary, stream)); return objects.count }
        func reserve() -> Int { add("null") }
        let catalog = reserve(), tree = reserve()
        let group = layered ? add("<< /Type /OCG /Name (Walls) >>") : nil
        let pages = (0..<pageCount).map { _ in reserve() }
        var catalogExtras = "/PageLabels << /Nums [0 << /S /D /P (A-) /St 101 >>] >>"
        if let group { catalogExtras += " /OCProperties << /OCGs [\(group) 0 R] /D << /Order [\(group) 0 R] /ON [] /OFF [\(group) 0 R] >> >>" }
        if named, pageCount > 1 {
            catalogExtras += " /Dests << /detail [\(pages[1]) 0 R /XYZ 0 200 0] >> /Names << /Dests << /Names [(section) [\(pages[1]) 0 R /Fit]] >> >>"
        }
        if outline {
            let root = reserve()
            let items = pages.enumerated().map { index, page in
                add("<< /Title (Sheet A-\(101 + index)) /Parent \(root) 0 R /Dest [\(page) 0 R /Fit] >>")
            }
            for (index, item) in items.enumerated() {
                var entry = objects[item - 1].0.dropLast(2)
                if index > 0 { entry += " /Prev \(items[index - 1]) 0 R" }
                if index + 1 < items.count { entry += " /Next \(items[index + 1]) 0 R" }
                objects[item - 1].0 = String(entry) + " >>"
            }
            objects[root - 1].0 = "<< /Type /Outlines /First \(items.first!) 0 R /Last \(items.last!) 0 R /Count \(items.count) >>"
            catalogExtras += " /Outlines \(root) 0 R"
        }
        for (index, page) in pages.enumerated() {
            var content = layered ? "/OC /L1 BDC " : ""
            content += "0 0 0 RG 1 w\n"
            for step in 0..<200 { content += "\(10 + step) 10 m \(10 + step) \(150 + index % 40) l S\n" }
            content += layered ? "EMC\n" : ""
            var forms: [String] = []
            for form in 0..<formsPerSheet {
                let body = Data("0 0 1 RG \(form) 0 m \(form) 20 l S\n".utf8)
                forms.append("/F\(form) \(add("<< /Type /XObject /Subtype /Form /BBox [0 0 40 40] /Length \(body.count) >>", body)) 0 R")
                content += "q 1 0 0 1 \(20 + form * 3) 160 cm /F\(form) Do Q\n"
            }
            let stream = Data(content.utf8)
            let contents = add("<< /Length \(stream.count) >>", stream)
            var resources = "/Resources << "
            if let group { resources += "/Properties << /L1 \(group) 0 R >> " }
            if !forms.isEmpty { resources += "/XObject << \(forms.joined(separator: " ")) >> " }
            resources += ">>"
            var annotations = ""
            if named, index == 0, pageCount > 1 {
                let byName = add("<< /Type /Annot /Subtype /Link /Rect [10 10 50 50] /Border [0 0 0] /Dest /detail >>")
                let byString = add("<< /Type /Annot /Subtype /Link /Rect [60 10 100 50] /Border [0 0 0] /A << /S /GoTo /D (section) >> >>")
                annotations = " /Annots [\(byName) 0 R \(byString) 0 R]"
            }
            objects[page - 1].0 = "<< /Type /Page /Parent \(tree) 0 R /MediaBox [0 0 200 200] /Contents \(contents) 0 R \(resources)\(annotations) >>"
        }
        objects[tree - 1].0 = "<< /Type /Pages /Kids [\(pages.map { "\($0) 0 R" }.joined(separator: " "))] /Count \(pageCount) >>"
        objects[catalog - 1].0 = "<< /Type /Catalog /Pages \(tree) 0 R \(catalogExtras) >>"
        var pdf = Data("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.count)
            pdf.append(Data("\(index + 1) 0 obj\n\(object.0)\n".utf8))
            if let stream = object.1 {
                pdf.append(Data("stream\n".utf8))
                pdf.append(stream)
                pdf.append(Data("\nendstream\n".utf8))
            }
            pdf.append(Data("endobj\n".utf8))
        }
        let xref = pdf.count
        var table = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { table += String(format: "%010d 00000 n \n", offset) }
        table += "trailer\n<< /Size \(objects.count + 1) /Root \(catalog) 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        pdf.append(Data(table.utf8))
        try pdf.write(to: url)
    }

    static func catalogHas(_ url: URL, _ key: String) throws -> Bool {
        let document = try #require(CGPDFDocument(url as CFURL))
        let catalog = try #require(document.catalog)
        var object: CGPDFObjectRef?
        return CGPDFDictionaryGetObject(catalog, key, &object)
    }

    /// The zero-based page `/Dests /detail` names in `url`, `nil` when there is none.
    static func detailPage(_ url: URL) throws -> Int? {
        let document = try #require(CGPDFDocument(url as CFURL))
        let catalog = try #require(document.catalog)
        var dests: CGPDFDictionaryRef?
        var array: CGPDFArrayRef?
        var page: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(catalog, "Dests", &dests), let dests,
              CGPDFDictionaryGetArray(dests, "detail", &array), let array,
              CGPDFArrayGetDictionary(array, 0, &page), let page else { return nil }
        return (0..<document.numberOfPages).first { document.page(at: $0 + 1)?.dictionary == page }
    }

    /// The one label range a single-sheet copy carries, from its catalog (PDFKit numbers a sheet
    /// of such a small file "1" whatever its /PageLabels say).
    static func singleLabel(_ url: URL) throws -> String? {
        let document = try #require(CGPDFDocument(url as CFURL))
        let catalog = try #require(document.catalog)
        var labels: CGPDFDictionaryRef?
        var nums: CGPDFArrayRef?
        var range: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(catalog, "PageLabels", &labels), let labels,
              CGPDFDictionaryGetArray(labels, "Nums", &nums), let nums,
              CGPDFArrayGetDictionary(nums, 1, &range), let range else { return nil }
        var start: CGPDFInteger = 1
        _ = CGPDFDictionaryGetInteger(range, "St", &start)
        var prefix: CGPDFStringRef?
        let text = CGPDFDictionaryGetString(range, "P", &prefix) ? (prefix.flatMap { CGPDFStringCopyTextString($0) as String? } ?? "") : ""
        return text + String(start)
    }

    static func useRepairWorker() throws {
        let worker = try NLPDFR2FormFillTests.productsDirectory().appendingPathComponent("zpdf-repair-worker")
        try #require(FileManager.default.fileExists(atPath: worker.path), "zpdf-repair-worker is built next to the tests")
        DamagedDrawingRepair.clientOverride = ZPDFRepairServiceClient(backend: .subprocess(executableURL: worker), maximumRestarts: 0)
    }

    static func folder(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("it1r-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("NL-DOCS-08: a layered drawing's extract through qpdf carries the named destinations its link uses, and the note says what was kept")
    func layeredExtractCarriesNamedDestinations() async throws {
        let directory = try Self.folder("docs08-named")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Linked Layers.pdf")
        try Self.drawing(at: source, layered: true, named: true)
        try Self.useRepairWorker()
        defer { DamagedDrawingRepair.clientOverride = nil }
        let harness = try await Fix2Harness.make("Linked Layers.pdf", calibrate: false, fixture: source)
        defer { harness.tearDown() }

        let destination = directory.appendingPathComponent("extract.pdf")
        let receipt = try #require(await harness.document.writeExtract(indices: [0, 1], from: source, password: nil, to: destination))
        #expect(receipt.structureNotCarried == [.outline])
        #expect(try Self.catalogHas(destination, "OCProperties"))
        // Old: the service's copy had no /Dests and no /Names, while its link still named
        // `/detail` — and the note said the named destinations were kept.
        #expect(try Self.detailPage(destination) == 1)
        #expect(try Self.catalogHas(destination, "Names"))
        let pdf = try #require(PDFDocument(url: destination))
        let goTo = (pdf.page(at: 0)?.annotations ?? []).compactMap { ($0.action as? PDFActionGoTo)?.destination }.filter { $0.page != nil }
        #expect(goTo.map { $0.page.map { pdf.index(for: $0) } } == [1], "the (section) link lands on the second page")
        let note = try #require(harness.core.document.warnings.last { $0.title == "The pages were extracted." })
        #expect(note.message == "Sheet labels, layer definitions and the named destinations of these pages were kept. The drawing's bookmarks were not carried into the new file.")
    }

    @Test("NL-DOCS-08: a drawing with named destinations and no layers stays with PDFKit, keeps its bookmarks, and the note names only what was lost")
    func namedDestinationsWithoutLayersKeepBookmarks() async throws {
        let directory = try Self.folder("docs08-dests-only")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Linked.pdf")
        try Self.drawing(at: source, layered: false, named: true, outline: true)
        // Old: true — the drawing went to qpdf, which dropped its bookmarks and (then) its named
        // destinations too, so the links broke and nothing was gained.
        #expect(!ZenitPDFProjectDocument.drawingHasLayerDefinitions(source, password: nil))
        let harness = try await Fix2Harness.make("Linked.pdf", calibrate: false, fixture: source)
        defer { harness.tearDown() }

        let destination = directory.appendingPathComponent("extract.pdf")
        let receipt = try #require(await harness.document.writeExtract(indices: [0, 1], from: source, password: nil, to: destination))
        #expect(receipt.structureNotCarried == [.namedDestinations], "PDFKit's receipt, not the qpdf route's [.outline]")
        let pdf = try #require(PDFDocument(url: destination))
        #expect((pdf.outlineRoot?.numberOfChildren ?? 0) == 2, "the bookmarks of the two sheets taken are kept")
        let note = try #require(harness.core.document.warnings.last { $0.title == "The pages were extracted." })
        // Old: "… Layer definitions and named destinations could not be carried …" for a drawing
        // with no layer definitions.
        #expect(note.message == "Sheet labels, bookmarks and links were kept. Named destinations could not be carried into the new file.")
        #expect(ZenitPDFProjectDocument.pdfKitExtractNote(notCarried: []) == nil)
        #expect(ZenitPDFProjectDocument.pdfKitExtractNote(notCarried: [.optionalContent])
            == "Sheet labels, bookmarks and links were kept. Layer definitions could not be carried into the new file.")
    }

    @Test("NL-DOCS-08: Split into Sheets of a 300-sheet layered drawing goes through qpdf in one request and finishes inside 20 s")
    func splitThreeHundredLayeredSheets() async throws {
        let directory = try Self.folder("docs08-split300")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Set 300.pdf")
        try Self.drawing(at: source, pageCount: 300, layered: true, named: false, formsPerSheet: 12)
        let bytes = try Data(contentsOf: source)
        try Self.useRepairWorker()
        defer { DamagedDrawingRepair.clientOverride = nil }
        let loaded = try await DocumentSessionLoader.load(pdfAt: source)
        #expect(loaded.pages.count == 300)
        let pages = loaded.pages.map { page in
            ZenitPDFProjectDocument.SetExportPage(pageID: page.id, drawing: loaded, password: nil, viewRotation: 0,
                                                  sheetNumber: nil, sheetTitle: nil, label: page.label)
        }
        #expect(ZenitPDFProjectDocument.repairServiceRoute([pages[0]], sheetBookmarks: false) != nil, "each sheet takes the qpdf route")
        let folder = directory.appendingPathComponent("split", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let document = ZenitPDFProjectDocument()
        let clock = ContinuousClock()
        var written: [URL] = []
        let elapsed = await clock.measure { written = await document.writeSplit(pages, into: folder) }
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        print("[timing] Split into Sheets, 300 layered sheets (\(bytes.count) bytes) through the repair worker: \(String(format: "%.2f", seconds)) s")
        #expect(written.count == 300)
        // Old: 23.8 s here — one request, one parse of the drawing and two hashes of it per sheet.
        #expect(seconds < 20, "300 files in under 20 s")
        // Through qpdf: every file keeps the layer definitions and its sheet's label.
        for url in [written.first, written[149], written.last].compactMap({ $0 }) {
            #expect(try Self.catalogHas(url, "OCProperties"), "\(url.lastPathComponent)")
        }
        #expect(try Self.singleLabel(written[149]) == "A-250")
        #expect(try Data(contentsOf: source) == bytes, "the drawing is never written")
    }
}
