import Foundation
import PDFKit
import Testing
import ZPDFContracts
import ZPDFPDFKitBridge
import ZPDFQuantityLedger
@testable import ZPDFExport

/// Iteration 1: export profiles (R-101, R-102), the workbook's sheet names
/// (R-104) and the signature writer (R-105, R-113, R-115). Each test says what the old code did.
@Suite("Iteration 1 — export and signing fixes", .sharedHeap, .serialized)
struct Iter1ExportFixTests {

    // MARK: - R-101: imperial lengths in a profile

    static let runID = ExportFixture.customID("iter1-run-ft")

    /// Two Concrete rows on a feet-and-inches (1/16") column: 3'-4 13/16" and 5'-2".
    ///
    /// By hand: 3'-4 13/16" is 653/192 ft = 653 × 0.3048 / 192 m = 1.0366375 m exactly; 5'-2" is
    /// 62 in = 1.5748 m. As decimal feet to four places: 3.4010 and 5.1667. The subtotal is the sum
    /// of the stored values, 2.6114375 m = 1645/192 ft = 8.567708… ft → 8.5677.
    static func imperialProjection() throws -> ExportProjection {
        var subject = LedgerColumnDefinition(
            id: ExportFixture.standardID(.subject), key: "subject", title: "subject",
            kind: StandardLedgerColumn.subject.kind, standard: .subject, isEditable: StandardLedgerColumn.subject.isUserEditable
        )
        subject.order = 0
        var run = LedgerColumnDefinition(
            id: runID, key: "run", title: "Run", kind: .number, dimension: .length,
            displayUnit: .length(.foot), precision: .imperialFraction(.sixteenth)
        )
        run.order = 1
        let definitions = [subject, run]
        let values = [Decimal(string: "1.0366375")!, Decimal(string: "1.5748")!]
        let markups = values.enumerated().map { index, metres in
            MarkupRecord(
                id: MarkupID(ExportFixture.uuid(7_100 + index)), documentID: DocumentID(ExportFixture.uuid(-71)),
                pageID: PageID(ExportFixture.uuid(-72)), kind: .measurement, tool: .length, subject: "Concrete",
                label: "R\(index)", author: "Ada", customValues: [runID: .number(.length(metres))],
                createdAt: ExportFixture.epoch, modifiedAt: ExportFixture.epoch
            )
        }
        let store = try LedgerStore(markups: markups, columns: try LedgerColumnSet(columns: definitions))
        let report = LedgerReportBuilder(timestamps: FixedTimestampProvider(ExportFixture.epoch))
            .makeReport(store.makeView(LedgerViewSpec()), title: "Imperial")
        return try ExportProjector().project(report, options: ExportProjectionOptions())
    }

    @Test("R-101: a feet-and-inches column is written as decimal feet to four places, and its subtotal is not rounded to whole feet")
    func imperialProfile() throws {
        let projection = try Self.imperialProjection()
        let run = try #require(projection.table.rows.first?.cells[1].number)
        #expect(run.text == "3'-4 13/16\"", "the fixture is the ledger's own feet and inches")
        var profile = LedgerExportProfile(name: "Imperial", columns: [.init(key: "subject"), .init(key: "run")],
                                          delimiter: ";", decimalSeparator: ".", encoding: .utf8, lineEnding: .lf)
        profile.grouping = .init(key: "subject", subtotals: true, subtotalLabel: "{group} subtotal")
        let text = String(decoding: try profile.renderDetailed(projection).data, as: UTF8.self)
        // Old: "Concrete;3.40104166666666666666666666666666666666", "…;5.16666666666666666666666666666666666666"
        // and "Concrete subtotal;9" — the subtotal took zero places from the second row.
        #expect(text == """
        subject;Run
        Concrete;3.4010
        Concrete;5.1667
        Concrete subtotal;8.5677

        """)
        // The workbook's own format for these cells is four places too: one rule.
        #expect(run.numberFormatCode.hasSuffix(".0000"))
    }

    // MARK: - R-102: the profile's formula guard

    static func hostileProjection() throws -> ExportProjection {
        let subjects = ["-2+3+cmd|' /C calc'!A0", "+1+HYPERLINK(\"x\")", "-abc", "@SUM(A1)", "plain"]
        let markups = subjects.enumerated().map { index, subject in
            MarkupRecord(
                id: MarkupID(ExportFixture.uuid(7_200 + index)), documentID: DocumentID(ExportFixture.uuid(-73)),
                pageID: PageID(ExportFixture.uuid(-74)), kind: .measurement, tool: .area, subject: subject,
                label: "L\(index)", author: "Ada",
                customValues: [ExportFixture.costID: .currency(amount: index == 0 ? Decimal(string: "-40")! : 12, code: "SEK")],
                createdAt: ExportFixture.epoch, modifiedAt: ExportFixture.epoch
            )
        }
        let store = try LedgerStore(markups: markups, columns: try ExportFixture.columnSet())
        let report = LedgerReportBuilder(timestamps: FixedTimestampProvider(ExportFixture.epoch))
            .makeReport(store.makeView(LedgerViewSpec()), title: "Hostile")
        return try ExportFixture.projection(report)
    }

    @Test("R-102: every text cell starting with = + - @ is guarded — numeric-looking prefix or not — and numbers never are")
    func profileFormulaGuard() throws {
        var profile = LedgerExportProfile(name: "Guard", columns: [.init(key: "subject"), .init(key: "cost", decimals: 2)],
                                          delimiter: ";", decimalSeparator: ".", encoding: .utf8, lineEnding: .lf)
        profile.includeHeader = false
        let lines = String(decoding: try profile.renderDetailed(try Self.hostileProjection()).data, as: UTF8.self)
            .split(separator: "\n").map(String.init)
        // Old: the first two went out unguarded — Decimal(string:) read "-2" and "+1" as numbers.
        #expect(Set(lines) == [
            "'-2+3+cmd|' /C calc'!A0;-40.00",
            "\"'+1+HYPERLINK(\"\"x\"\")\";12.00",
            "'-abc;12.00",
            "'@SUM(A1);12.00",
            "plain;12.00",
        ])
        // A header or group label is text too.
        #expect(profile.escape("=cmd", delimiter: ";") == "'=cmd")
        #expect(profile.escape("-40.00", delimiter: ";", isNumber: true) == "-40.00")
    }

    // MARK: - R-104: sheet names

    @Test("R-104: a group labelled like the metadata or round-trip sheet no longer fails the export; the fixed sheets keep their names")
    func groupLabelCollidesWithFixedSheet() throws {
        let url = temporaryURL("xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        var options = XLSXExportOptions(includeUnitColumns: false)
        options.includeGroupSheets = true
        // The golden ledger's groups are "Concrete" and "Steel"; name the fixed sheets after them.
        options.metadataSheetName = "Concrete"
        options.rowIdentity = XLSXRowIdentity(projectID: "P", exportedAt: "2026-09-26", editableColumnKeys: [], sheetName: "Steel")
        // Old: ExportError.xlsx(worksheetCreationFailed) — the group sheet claimed "Concrete" first
        // and the metadata sheet's raw name was a duplicate.
        try XLSXExporter().export(try ExportFixture.projection(try ExportFixture.goldenReport(grouped: true)), to: url, options: options)
        let workbook = try XLSXInspector.entry("xl/workbook.xml", of: url)
        for name in ["Ledger", "Concrete", "Steel", "Concrete (2)", "Steel (2)"] {
            #expect(workbook.contains("name=\"\(name)\""), "\(name) in \(workbook)")
        }
    }

    @Test("R-104: apostrophes are stripped from both ends after the 31-character cut, in a loop")
    func sheetNameApostrophes() {
        // Old: "'x" (one leading apostrophe left) and a name ending in "'" after the cut.
        #expect(XLSXExporter.SheetNames.sanitised("''x") == "x")
        #expect(XLSXExporter.SheetNames.sanitised(String(repeating: "a", count: 30) + "'bcd") == String(repeating: "a", count: 30))
        #expect(XLSXExporter.SheetNames.sanitised("'''") == "Sheet")
        #expect(XLSXExporter.SheetNames.sanitised("' History '") == "Sheet")
    }

    // MARK: - R-105, R-113, R-115: signing

    @Test("R-105: countersigning adds a field of its own name; both signatures verify separately")
    func countersignatureHasItsOwnField() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("zenit-iter1-sign-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let signer = try PDFSignatureWriterTests.signer(in: directory)
        let once = try PDFSignatureWriter().data(source: LayeredSourceFixtures.plain(), options: .init(signerName: "First"), signer: signer)
        let twice = try PDFSignatureWriter().data(source: once, options: .init(signerName: "Second"), signer: signer)
        let signatures = SignatureInspector.signatures(in: twice)
        // Old: both fields were called "Signature" — one field under the PDF field model.
        #expect(signatures.map(\.fieldName) == ["Signature", "Signature 2"])
        #expect(signatures.map(\.integrity) == [.intactWithLaterRevisions, .intact])
        #expect(PDFSignatureWriter.freeFieldName("Signature", among: ["Signature", "Signature 2", "Form.Signature 3"]) == "Signature 3")
    }

    @Test("R-115: a page annotation with a hex /Contents no longer receives the signature")
    func hexContentsOnThePage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("zenit-iter1-hex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = RedactionFixturePDF.assemble(pageCount: 1) { _, _ in
            ([HardeningPage("0 0 10 10 re f", resources: "<< >>",
                            extras: "/Annots [<< /Type /Annot /Subtype /Text /Rect [10 10 30 30] /Contents <48656C6C6F> >>]")], "")
        }
        let signed = try PDFSignatureWriter().data(source: source, signer: try PDFSignatureWriterTests.signer(in: directory))
        // Old: "/Contents <" was first found in the rewritten page, so the byte range and the DER
        // went into the note's text; the signature read unverifiable.
        #expect(SignatureInspector.signatures(in: signed).first?.integrity == .intact)
        let note = try #require(PDFDocument(data: signed)?.page(at: 0)?.annotations.first { $0.type == "Text" })
        #expect(note.contents == "Hello")
    }

    @Test("R-113: the seal, the OCR layer and the profiles share one Windows-1252 table")
    func oneWindows1252Table() throws {
        let text = "Reviewed… ™ Šolić Œuvre Žan €5 (é)"
        // Old seal: "Reviewed? ? ?oli? ?uvre ?an ?5 \\(e?\\)" for a decomposed é — only Latin-1 and
        // seven punctuation marks were known.
        let expected = "Reviewed\\205 \\231 \\212oli? \\214uvre \\216an \\2005 \\(\\351\\)"
        #expect(PDFSignatureWriter.winAnsiLiteral(text.decomposedStringWithCanonicalMapping) == expected)
        #expect(SearchableTextLayerWriter.escaped(text) == expected)
        #expect(PDFSignatureWriter.winAnsiLiteral("a\tb") == "a b", "a seal line turns control characters into spaces")
        var profile = LedgerExportProfile(name: "1252", columns: [.init(key: "subject")], encoding: .windows1252)
        profile.includeHeader = false
        #expect(try profile.encode("Š…€") == Data([0x8A, 0x85, 0x80]))
    }
}

// MARK: - R-109: the takeoff probe on every open

extension Iter1ExportFixTests {

    /// A drawing of `objects` small objects on one page, and no associated file.
    static func largeDrawing(objects: Int) -> Data {
        RedactionFixturePDF.assemble(pageCount: 1) { pdf, _ in
            var names: [String] = []
            for index in 0..<objects {
                let number = pdf.addStream("/Type /XObject /Subtype /Form /BBox [0 0 10 10]", "0 0 \(index % 10) 10 re f")
                names.append("/F\(index) \(number) 0 R")
            }
            return ([HardeningPage("0 0 10 10 re f", resources: "<< /XObject << \(names.joined(separator: " ")) >> >>")], "")
        }
    }

    @Test("R-109: a drawing with no associated file is answered from the catalog, without a full scan; a takeoff file is still read")
    func takeoffProbeIsLazy() throws {
        let drawing = Self.largeDrawing(objects: 20_000)
        #expect(EmbeddedTakeoffReader.mayCarryTakeoff(drawing) == false)
        let clock = ContinuousClock()
        let probe = clock.measure { #expect(EmbeddedTakeoffReader.entries(in: drawing).isEmpty) }
        let scan = clock.measure { _ = try? PDFDocumentScan(data: drawing) }
        print("[R-109] \(drawing.count) bytes, \(20_000) objects: probe \(probe), full scan \(scan)")
        // Old: the reader always ran the full scan, so it cost at least what `scan` costs.
        #expect(probe * 5 < scan, "probe \(probe) against a full scan of \(scan)")

        // A file that carries a takeoff still reads, verified.
        let fixture = StandardAnnotationWriterTests.fixture()
        let source = LayeredSourceFixtures.plain()
        let produced = try StandardAnnotationWriter().data(
            source: source,
            pages: [StandardAnnotationPage(page: fixture.page, sourcePageIndex: 0, annotations: fixture.all)],
            takeoff: StandardAnnotationWriterTests.takeoff(for: source)
        )
        #expect(EmbeddedTakeoffReader.mayCarryTakeoff(produced.data) == true)
        #expect(EmbeddedTakeoffReader.entries(in: produced.data).first?.prefixVerified == true)
    }
}

// MARK: - R-106: the seal on a quarter-turned sheet

extension Iter1ExportFixTests {

    /// The layered export's source drawing with /Rotate 90: media 420 × 340, crop 400 × 300 at
    /// (10, 20), displayed 300 wide × 400 tall.
    static func rotatedSheet() -> (data: Data, page: PageDescriptor) {
        let page = PageDescriptor(
            id: PageID(UUID()), documentID: DocumentID(UUID()), index: 0, label: "A-201",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 420, height: 340), crop: PDFRect(x: 10, y: 20, width: 400, height: 300)),
            rotation: .degrees90
        )
        return (LayeredSourceFixtures.plain(rotate: 90), page)
    }

    @Test("R-106: on a /Rotate 90 sheet the seal sits in the displayed bottom-right corner and reads upright")
    func sealOnRotatedSheet() throws {
        let (source, page) = Self.rotatedSheet()
        // Displayed 300 × 400; the seal 200 × 64, 12 pt in → displayed (88, 12)–(288, 76).
        // Page space by the placement matrix for 90° with the crop at (10, 20), 400 wide:
        // (x, y) → (410 − y, x + 20): (334, 108)–(398, 308).
        let seal = PDFSignatureWriter.Seal(on: page, displayed: PDFRect(x: 88, y: 12, width: 200, height: 64),
                                           lines: ["Digitally signed by Jane Engineer", "2026-09-26"], color: RGBAColor(red: 1, green: 0, blue: 0))
        #expect(seal.rect == PDFRect(x: 334, y: 108, width: 64, height: 200))
        #expect(seal.rotation == .degrees90)
        guard case let .stream(appearance, _) = PDFSignatureWriter.sealAppearance(seal) else { Issue.record("no stream"); return }
        #expect(appearance["Matrix"] == .array([.integer(0), .integer(1), .integer(-1), .integer(0), .integer(0), .integer(0)]))
        #expect(appearance["BBox"] == .array([.integer(0), .integer(0), .real(200), .real(64)]), "drawn in the displayed orientation")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("zenit-iter1-seal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let signed = try PDFSignatureWriter().data(source: source, options: .init(seal: seal),
                                                   signer: try PDFSignatureWriterTests.signer(in: directory))
        #expect(SignatureInspector.signatures(in: signed).first?.integrity == .intact)

        // Where a reader draws it, read back from the file and placed by ISO 32000-1 §12.5.5: the
        // form's BBox through its /Matrix, fitted onto the widget's /Rect; then onto the displayed
        // sheet by /Rotate 90 with the crop at (10, 20), 400 wide: (u, v) → (v − 20, 410 − u).
        let scan = try PDFDocumentScan(data: signed)
        let widget = try #require(scan.objects.values.compactMap { $0.object.dictionaryValue }.first { $0["FT"]?.nameValue == "Sig" })
        let rect = try #require(scan.object(widget["Rect"])?.arrayValue).compactMap { $0.doubleValue }
        let form = try #require(scan.dictionary(scan.dictionary(widget["AP"])?["N"]))
        let m = try #require(scan.object(form["Matrix"])?.arrayValue).compactMap { $0.doubleValue }
        let bbox = try #require(scan.object(form["BBox"])?.arrayValue).compactMap { $0.doubleValue }
        func formToPage(_ x: Double, _ y: Double) -> (Double, Double) { (m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5]) }
        let turned = [(bbox[0], bbox[1]), (bbox[2], bbox[1]), (bbox[0], bbox[3]), (bbox[2], bbox[3])].map { formToPage($0.0, $0.1) }
        let (tMinX, tMinY) = (turned.map(\.0).min() ?? 0, turned.map(\.1).min() ?? 0)
        let (tMaxX, tMaxY) = (turned.map(\.0).max() ?? 0, turned.map(\.1).max() ?? 0)
        func toDisplay(_ x: Double, _ y: Double) -> (Double, Double) {
            let placed = formToPage(x, y)
            let u = rect[0] + (placed.0 - tMinX) * (rect[2] - rect[0]) / (tMaxX - tMinX)
            let v = rect[1] + (placed.1 - tMinY) * (rect[3] - rect[1]) / (tMaxY - tMinY)
            return (v - 20, 410 - u)
        }
        // Old: the form's origin at displayed (12, 212) and its x axis running down the sheet.
        let origin = toDisplay(0, 0), alongText = toDisplay(200, 0), up = toDisplay(0, 64)
        #expect(abs(origin.0 - 88) < 0.001 && abs(origin.1 - 12) < 0.001, "the seal's corner is at displayed (88, 12): \(origin)")
        #expect(abs(alongText.0 - 288) < 0.001 && abs(alongText.1 - 12) < 0.001, "its text runs left to right: \(alongText)")
        #expect(abs(up.0 - 88) < 0.001 && abs(up.1 - 76) < 0.001, "and upward is up: \(up)")
    }
}

// MARK: - K-04: values kept under an older scale

extension Iter1ExportFixTests {

    /// The golden ledger with rows 1 and 3 kept under an older scale.
    static func staleProjection(stale: Set<Int> = [1, 3]) throws -> ExportProjection {
        try ExportProjector().project(try ExportFixture.goldenReport(), options: ExportProjectionOptions(
            staleScaleRowIDs: Set(stale.map { ExportFixture.uuid($0).uuidString })
        ))
    }

    @Test("K-04: CSV, XLSX, JSON and the PDF report each say which values were kept under an older scale")
    func staleScaleNoticeInEveryFormat() throws {
        let projection = try Self.staleProjection()
        let notice = "2 values in this export were kept under an older scale: the scale changed after they were measured and they were not"
            + " recalculated. Measure ▸ Recalculate Stale Measurements in Zenit PDF brings them to the current scale."
        #expect(projection.table.metadata.staleScaleRowCount == 2)
        #expect(projection.table.metadata.staleScaleNotice == notice)

        // CSV: no metadata block, so a last column — on the kept rows only.
        // Old: nothing in any format; the file read as a takeoff at today's scale.
        let csv = String(decoding: try CSVExporter().export(projection), as: UTF8.self)
        let records = CSVReader.records(csv, delimiter: ",").filter { $0 != [""] }
        #expect(records.first?.last == "Scale status")
        let kept = records.dropFirst().filter { $0.last == "kept under an older scale" }.count
        #expect(kept == 2)

        // XLSX: the notice beside the scale on the metadata sheet, and the same column.
        let url = temporaryURL("xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        try XLSXExporter().export(projection, to: url)
        let shared = try XLSXInspector.entry("xl/sharedStrings.xml", of: url)
        #expect(shared.contains("Scale notice") && shared.contains("Scale status") && shared.contains("kept under an older scale"))

        // JSON: the notice on the ledger object, the flag on the rows, and back through the reader.
        let json = ZenitJSONExporter().export(projection)
        let document = try ZenitJSONImporter().document(from: json)
        #expect(document.ledger.staleScaleNotice == notice)
        #expect(document.rows.filter(\.keptUnderOlderScale).map(\.markupID).sorted()
            == [ExportFixture.uuid(1).uuidString, ExportFixture.uuid(3).uuidString].sorted())

        // PDF report: on the cover, after the scale.
        let cover = Painter.coverEntries(projection.table.metadata)
        #expect(cover.contains { $0.label == "Scale notice" && $0.value == notice })
    }

    @Test("K-04: an export with no kept values is byte for byte what it was")
    func noStaleValuesNoChange() throws {
        let plain = try ExportFixture.projection(try ExportFixture.goldenReport())
        let empty = try Self.staleProjection(stale: [])
        #expect(empty.table.metadata.staleScaleNotice == nil)
        #expect(try CSVExporter().export(plain) == CSVExporter().export(empty))
        #expect(!String(decoding: ZenitJSONExporter().export(empty), as: UTF8.self).contains("staleScale"))
        #expect(!Painter.coverEntries(empty.table.metadata).contains { $0.label == "Scale notice" })
        // One kept row reads in the singular.
        #expect(try Self.staleProjection(stale: [0]).table.metadata.staleScaleNotice?.hasPrefix("1 value in this export was kept") == true)
    }
}
