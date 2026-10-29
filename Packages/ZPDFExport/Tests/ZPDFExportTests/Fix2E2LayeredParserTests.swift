import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
import ZPDFRenderer
@testable import ZPDFExport

/// Bug hunt 2: the layered export's hand-written object parser and incremental
/// writer, attacked with synthetic PDF bytes built here.
///
/// Every source below is written by hand so the test controls the exact byte it is attacking.
/// A test named after a crash (BH-020, BH-135, BH-137) failed on the old code by trapping the
/// test process, which is the defect: a damaged drawing must be a refusal with a sentence.
@Suite(.sharedHeap)
struct Fix2E2LayeredParserTests {

    // MARK: - A tiny PDF assembler

    struct Object {
        var number: Int
        var generation: Int = 0
        var body: String
    }

    /// Objects to a file with a classic xref table. `trailerExtra` lets a test damage the tail.
    static func pdf(
        _ objects: [Object],
        root: String = "1 0 R",
        startxref: String? = nil
    ) -> Data {
        var pdf = Data("%PDF-1.6\n%\u{00E2}\u{00E3}\u{00CF}\u{00D3}\n".utf8)
        var offsets: [Int: (offset: Int, generation: Int)] = [:]
        for object in objects {
            offsets[object.number] = (pdf.count, object.generation)
            pdf.append(Data("\(object.number) \(object.generation) obj\n\(object.body)\nendobj\n".utf8))
        }
        let xref = pdf.count
        let size = (objects.map(\.number).max() ?? 0) + 1
        var table = "xref\n0 \(size)\n0000000000 65535 f \n"
        for number in 1..<size {
            if let entry = offsets[number] {
                table += String(format: "%010d %05d n \n", entry.offset, entry.generation)
            } else {
                table += "0000000000 00000 f \n"
            }
        }
        table += "trailer\n<< /Size \(size) /Root \(root) >>\n"
            + "startxref\n\(startxref ?? String(xref))\n%%EOF\n"
        pdf.append(Data(table.utf8))
        return pdf
    }

    static let pageGeometry = " /MediaBox [0 0 420 340] /CropBox [10 20 410 320]"

    /// A one-page drawing matching `FlattenedPDFWriterTests.page()` (400 x 300 crop at 10, 20).
    static func onePage(
        content: String = LayeredSourceFixtures.drawingContent,
        geometry: String = pageGeometry,
        pageGeneration: Int = 0,
        catalogGeneration: Int = 0,
        extra: [Object] = [],
        startxref: String? = nil
    ) -> Data {
        var objects = [
            Object(number: 1, generation: catalogGeneration, body: "<< /Type /Catalog /Pages 2 0 R >>"),
            Object(number: 2, body: "<< /Type /Pages /Kids [3 \(pageGeneration) R] /Count 1 >>"),
            Object(
                number: 3,
                generation: pageGeneration,
                body: "<< /Type /Page /Parent 2 0 R\(geometry) /Contents 4 0 R /Resources 5 0 R >>"
            ),
            Object(number: 4, body: "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream"),
            Object(number: 5, body: "<< /ProcSet [/PDF] >>")
        ]
        objects += extra
        return pdf(objects, root: "1 \(catalogGeneration) R", startxref: startxref)
    }

    static func job(markups: [RenderableMarkup]? = nil) -> FlattenPage {
        FlattenPage(
            page: FlattenedPDFWriterTests.page(),
            sourcePageIndex: 0,
            markups: markups ?? [
                FlattenedPDFWriterTests.polyline(
                    from: PDFPoint(x: 60, y: 80),
                    to: PDFPoint(x: 300, y: 250)
                ),
                FlattenedPDFWriterTests.filledTriangle(at: PDFPoint(x: 120, y: 120), size: 60)
            ]
        )
    }

    static func string(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

    static func refusal(_ body: () throws -> Void) -> String? {
        do {
            try body()
        } catch let ExportError.layeredSourceUnreadable(message) {
            return message
        } catch {
            return "other: \(error)"
        }
        return nil
    }

    // MARK: - BH-020: an integer too long for Int is a refusal, not a trap

    @Test("BH-020: a real outside Int's range reads as no integer instead of trapping")
    func overlongIntegersDoNotTrap() {
        // Old: `Int(1e20)` — a runtime trap that killed the process.
        #expect(PDFObject.real(1e20).integerValue == nil)
        #expect(PDFObject.real(-1e20).integerValue == nil)
        #expect(PDFObject.real(9.223372036854775807e18).integerValue == nil)
        #expect(PDFObject.real(12.9).integerValue == 12)
        #expect(PDFObject.real(-3.5).integerValue == -3)
    }

    @Test("BH-020: startxref, /Length and /N of twenty nines are read as damage, not a crash")
    func overlongDigitRunsInADrawingAreRefused() throws {
        let nines = "99999999999999999999"
        // A truncated startxref: the export must refuse with "no usable startxref".
        let brokenTail = Self.onePage(startxref: nines)
        let tailMessage = Self.refusal {
            _ = try LayeredMarkupExporter().data(source: brokenTail, pages: [Self.job()])
        }
        #expect(tailMessage?.contains("startxref") == true, "\(tailMessage ?? "no refusal")")

        // An overlong /Length: the declared-length branch is skipped and the search finds the
        // payload. Old: trapped in `parseDictionaryOrStream`.
        let content = LayeredSourceFixtures.drawingContent
        let overlongLength = Self.pdf([
            Object(number: 1, body: "<< /Type /Catalog /Pages 2 0 R >>"),
            Object(number: 2, body: "<< /Length \(nines) >>\nstream\n\(content)\nendstream")
        ])
        let scan = try PDFDocumentScan(data: overlongLength)
        guard case let .stream(_, data)? = scan.objects[2]?.object else {
            Issue.record("the stream with an overlong /Length was not read")
            return
        }
        #expect(Self.string(data) == content)

        // An object stream whose /N and /First are overlong is skipped, not trapped on.
        let objectStream = Self.pdf([
            Object(number: 1, body: "<< /Type /Catalog /Pages 2 0 R >>"),
            Object(number: 7, body: "<< /Type /ObjStm /N \(nines) /First \(nines) /Length 3 >>\nstream\n1 0\nendstream")
        ])
        let streamScan = try PDFDocumentScan(data: objectStream)
        #expect(streamScan.objects[1] != nil)
    }

    // MARK: - BH-135: a hostile object-stream offset

    @Test("BH-135: an /ObjStm header offset near Int.max is skipped, the other members still read")
    func objectStreamOffsetOverflowIsSkipped() throws {
        // Old: `first + pair.offset` overflowed and trapped.
        let bodies = "<< /Type /Catalog /Pages 3 0 R >>\n<< /Marker (still read) >>\n"
        let header = "2 0 9 9223372036854775807 11 34 "
        let payload = header + bodies
        let objectStream = Self.pdf([
            Object(
                number: 1,
                body: "<< /Type /ObjStm /N 3 /First \(header.utf8.count) /Length \(payload.utf8.count) >>"
                    + "\nstream\n\(payload)\nendstream"
            )
        ], root: "2 0 R")
        let scan = try PDFDocumentScan(data: objectStream)
        #expect(scan.objects[9] == nil, "the hostile member should have been skipped")
        #expect(scan.dictionary(.reference(number: 2, generation: 0))?["Type"]?.nameValue == "Catalog")
        #expect(scan.dictionary(.reference(number: 11, generation: 0))?["Marker"] == .string(Array("still read".utf8)))
    }

    // MARK: - BH-137: a /Length that overflows start + declared

    @Test("BH-137: /Length 9223372036854775807 falls through to the endstream search")
    func hugeDeclaredLengthFallsThrough() throws {
        // Old: `start + declared` overflowed and trapped before the promised fall-through.
        let content = "0 0 m 10 10 l S"
        let source = Self.pdf([
            Object(number: 1, body: "<< /Type /Catalog /Pages 2 0 R >>"),
            Object(number: 2, body: "<< /Length 9223372036854775807 >>\nstream\n\(content)\nendstream")
        ])
        let scan = try PDFDocumentScan(data: source)
        guard case let .stream(_, data)? = scan.objects[2]?.object else {
            Issue.record("the stream was not read")
            return
        }
        #expect(Self.string(data) == content)
    }

    // MARK: - BH-136: generations survive the update

    @Test("BH-136: a page and catalog at generation 1 are superseded as `n 1 obj` with a 00001 entry")
    func supersededObjectsKeepTheirGeneration() throws {
        // Old: `3 0 obj` / `1 0 obj` and `... 00000 n` while /Kids and /Root still said `n 1 R`,
        // so a strict reader did not resolve the update to the superseded page or catalog.
        let source = Self.onePage(pageGeneration: 1, catalogGeneration: 1)
        let produced = try LayeredMarkupExporter().data(source: source, pages: [Self.job()])
        let appended = Self.string(produced.data.dropFirst(source.count))
        #expect(appended.contains("\n3 1 obj\n") || appended.hasPrefix("3 1 obj\n"))
        #expect(appended.contains("1 1 obj\n"))
        #expect(!appended.contains("\n3 0 obj\n"))
        #expect(!appended.contains("\n1 0 obj\n"))
        #expect(appended.contains(" 00001 n \n"))
        #expect(appended.contains("/Root 1 1 R"))

        let inspector = try #require(OptionalContentInspector(data: produced.data))
        #expect(inspector.groupNames == ["Zenit Markups"])
        #expect(inspector.pages.first?.spans.count == 2)
    }

    @Test("BH-136: the cross-reference stream writes the generation in its third field")
    func crossReferenceStreamCarriesGenerations() {
        let data = PDFIncrementalUpdate.crossReferenceStream(
            entries: [3: 0x0102, 4: 0x0304],
            generations: [3: 1]
        )
        let bytes = [UInt8](data)
        // Row 0 (free head), row 3, row 4: 7 bytes each.
        #expect(bytes.count == 21)
        #expect(Array(bytes[7..<14]) == [1, 0, 0, 0x01, 0x02, 0, 1])
        #expect(Array(bytes[14..<21]) == [1, 0, 0, 0x03, 0x04, 0, 0])
    }

    // MARK: - BH-521: offsets past 4 GiB

    @Test("BH-521: an offset of 5 GiB widens the offset field instead of losing its high bits")
    func largeOffsetsAreNotTruncated() {
        // Old: /W [1 4 2] and `(offset >> 24) & 0xFF` downward — 5_000_000_000 became 705_032_704.
        let offset = 5_000_000_000
        let entries = [9: offset]
        let width = PDFIncrementalUpdate.offsetFieldWidth(for: entries)
        #expect(width == 5)
        #expect(PDFIncrementalUpdate.offsetFieldWidth(for: [9: 1_000]) == 4)
        let bytes = [UInt8](PDFIncrementalUpdate.crossReferenceStream(entries: entries, offsetWidth: width))
        let rowLength = 1 + width + 2
        #expect(bytes.count == 2 * rowLength)
        let row = Array(bytes[rowLength..<(2 * rowLength)])
        #expect(row[0] == 1)
        let decoded = row[1...width].reduce(0) { $0 << 8 | Int($1) }
        #expect(decoded == offset)
    }

    // MARK: - BH-520: a sliced source

    @Test("BH-520: a source handed in as a slice produces the same artefact as the plain bytes")
    func slicedSourcesAreDigestedCorrectly() throws {
        // Old: `out.suffix(from: source.count)` indexed a slice by a count, so the /ID digest
        // covered the wrong bytes (or trapped when startIndex exceeded the count).
        let plain = Self.onePage()
        var padded = Data(repeating: 0x20, count: plain.count + 17)
        padded.append(plain)
        let slice = padded[(plain.count + 17)...]
        #expect(slice.startIndex > slice.count)
        let job = Self.job()
        let fromPlain = try LayeredMarkupExporter().data(source: plain, pages: [job])
        let fromSlice = try LayeredMarkupExporter().data(source: slice, pages: [job])
        #expect(Data(fromSlice.data) == fromPlain.data)
    }

    // MARK: - BH-522: the last byte of a stream ending in CR

    @Test("BH-522: an indirect /Length is resolved, so a payload ending in CR keeps that byte")
    func indirectLengthKeepsATrailingCarriageReturn() throws {
        // Old: the search path trimmed the writer's LF and then the payload's own CR — the
        // stream came back one byte short (4 bytes instead of 5).
        var source = Data("%PDF-1.6\n".utf8)
        let payload: [UInt8] = [0x41, 0x42, 0x43, 0x44, 0x0D]
        source.append(Data("1 0 obj\n<< /Length 2 0 R >>\nstream\n".utf8))
        source.append(contentsOf: payload)
        source.append(Data("\nendstream\nendobj\n2 0 obj\n\(payload.count)\nendobj\n".utf8))
        source.append(Data("trailer\n<< /Size 3 >>\nstartxref\n0\n%%EOF\n".utf8))
        let scan = try PDFDocumentScan(data: source)
        guard case let .stream(_, data)? = scan.objects[1]?.object else {
            Issue.record("the stream was not read")
            return
        }
        #expect([UInt8](data) == payload)
    }

    @Test("BH-522: with no usable length, one end-of-line marker is stripped, never two")
    func searchPathStripsOneEndOfLine() throws {
        func payload(of text: String) throws -> [UInt8]? {
            var source = Data("%PDF-1.6\n1 0 obj\n<< >>\nstream\n".utf8)
            source.append(Data(text.utf8))
            source.append(Data("endstream\nendobj\n".utf8))
            guard case let .stream(_, data)? = try PDFDocumentScan(data: source).objects[1]?.object
            else { return nil }
            return [UInt8](data)
        }
        #expect(try payload(of: "AB\r\n") == [0x41, 0x42])
        #expect(try payload(of: "AB\n") == [0x41, 0x42])
        #expect(try payload(of: "AB\r") == [0x41, 0x42])
        #expect(try payload(of: "AB\n\n") == [0x41, 0x42, 0x0A])
    }

    // MARK: - BH-523: the inflate ceiling binds while inflating

    @Test("BH-523: a decompression bomb is refused before the output passes the ceiling")
    func inflateRefusesDuringDecompression() throws {
        // 16 MB of zeros deflates to a few kilobytes. Old: `NSData.decompressed(using:)` inflated
        // all 16 MB and only then compared against the ceiling.
        let zeros = Data(count: 16 * 1024 * 1024)
        let bomb = try #require(PDFStreamCodec.flateEncode(zeros))
        #expect(bomb.count < 100_000)
        let limit = 1024 * 1024
        var peak = 0
        let refused = PDFStreamCodec.inflate(bomb, limit: limit) { peak = max(peak, $0) }
        #expect(refused == nil)
        #expect(peak <= limit, "the inflater held \(peak) bytes against a \(limit)-byte ceiling")

        // Under the ceiling the same stream round-trips.
        let small = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let encoded = try #require(PDFStreamCodec.flateEncode(small))
        #expect(PDFStreamCodec.inflate(encoded) == small)
    }

    // MARK: - BH-519: a non-ASCII layer name

    @Test("BH-519: a layer name with å is a UTF-16BE text string, and a reader reads it back")
    func nonASCIILayerNamesAreTextStrings() throws {
        // Old: `.string(Array(name.utf8))` — read as PDFDocEncoding, the panel showed "pÃ¥".
        let name = "Markeringar på ritning"
        guard case let .hexString(bytes)? = OptionalContentCatalog.group(named: name)
            .dictionaryValue?["Name"] else {
            Issue.record("a non-ASCII name was not written as a UTF-16 text string")
            return
        }
        #expect(Array(bytes.prefix(2)) == [0xFE, 0xFF])
        #expect(OptionalContentCatalog.textString("Zenit Markups") == .string(Array("Zenit Markups".utf8)))

        var options = LayeredMarkupExporter.Options()
        options.layerName = name
        let produced = try LayeredMarkupExporter().data(
            source: Self.onePage(),
            pages: [Self.job()],
            options: options
        )
        let inspector = try #require(OptionalContentInspector(data: produced.data))
        #expect(inspector.groupNames == [name])
    }

    // MARK: - BH-517 / BH-518: the sheet check

    @Test("BH-517: a /CropBox with indirect elements is still checked, and a mismatch refused")
    func indirectBoxElementsAreResolvedAndChecked() throws {
        // Old: `rectangle()` returned nil for indirect elements and the guard treated that as
        // verified, so a 500 pt-wide measurement was placed on the 400 pt sheet.
        let source = Self.onePage(
            geometry: " /MediaBox [0 0 420 340] /CropBox [10 20 6 0 R 320]",
            extra: [Object(number: 6, body: "410")]
        )
        let mismatched = FlattenPage(
            page: FlattenedPDFWriterTests.page(width: 500),
            sourcePageIndex: 0,
            markups: [FlattenedPDFWriterTests.polyline(from: PDFPoint(x: 60, y: 80), to: PDFPoint(x: 300, y: 250))]
        )
        let message = Self.refusal {
            _ = try LayeredMarkupExporter().data(source: source, pages: [mismatched])
        }
        #expect(message?.contains("wrong drawing") == true, "\(message ?? "exported anyway")")
        // The right sheet passes the same, resolved check.
        let produced = try LayeredMarkupExporter().data(source: source, pages: [Self.job()])
        #expect(produced.outcome.markupSpanCount == 2)
    }

    @Test("BH-517: a /CropBox that cannot be read at all is a refusal, not a skipped check")
    func unreadableBoxesAreRefused() {
        let source = Self.onePage(geometry: " /MediaBox [0 0 420 340] /CropBox [10 20 410]")
        let message = Self.refusal {
            _ = try LayeredMarkupExporter().data(source: source, pages: [Self.job()])
        }
        #expect(message?.contains("/CropBox") == true, "\(message ?? "exported anyway")")
    }

    @Test("BH-518: a /CropBox overhanging the /MediaBox is compared after clipping to it")
    func overhangingCropBoxIsClippedBeforeComparison() throws {
        // The media box is exactly the measured 400 x 300 sheet; the crop box has 6 pt of bleed.
        // Old: compared the raw 412 x 312 crop with 400 x 300 and refused "the wrong drawing".
        let source = Self.onePage(geometry: " /MediaBox [10 20 410 320] /CropBox [4 14 416 326]")
        let produced = try LayeredMarkupExporter().data(source: source, pages: [Self.job()])
        #expect(produced.outcome.markupSpanCount == 2)
    }

    // MARK: - BH-515: nothing to export

    @Test("BH-515: pages without markups say there are no markups, not that painting failed")
    func zeroMarkupExportSaysSo() {
        let message = Self.refusal {
            _ = try LayeredMarkupExporter().data(
                source: Self.onePage(),
                pages: [Self.job(markups: [])]
            )
        }
        // Old: "none of the markups given to the layered export could be painted ...".
        #expect(message?.contains("carry no markups") == true, "\(message ?? "no refusal")")
        #expect(message?.contains("could not be painted") == false)
    }

    // MARK: - BH-516: a drawing that leaves a q open

    @Test("BH-516: the q/Q counter skips strings, comments, names and inline image data")
    func stateBalanceReadsOnlyOperators() {
        func measure(_ text: String) -> PDFContentStateBalance {
            PDFContentStateBalance.measure(Array(text.utf8))
        }
        #expect(measure("q 1 0 0 1 0 0 cm Q") == .balanced)
        #expect(measure("q q 0 0 m S Q") == PDFContentStateBalance(final: 1, minimum: 0))
        #expect(measure("Q q") == PDFContentStateBalance(final: 0, minimum: -1))
        #expect(measure("(q) Tj (a \\) q) Tj <71> Tj /q gs % q q q\n") == .balanced)
        #expect(measure("[(q) 3 (Q)] TJ") == .balanced)
        var inline = Array("q BI /W 2 /H 1 /BPC 8 /CS /G ID ".utf8)
        inline += [0x51, 0x71, 0x20, 0x51]  // "Qq Q" as image bytes
        inline += Array("\nEI Q".utf8)
        #expect(PDFContentStateBalance.measure(inline) == .balanced)
        #expect(PDFContentStateBalance(final: 2, minimum: -1).savesBefore == 2)
        #expect(PDFContentStateBalance(final: 2, minimum: -1).restoresAfter == 4)
    }

    @Test("BH-516: a drawing with a dangling scaled q still gets its layer where the flatten path paints it")
    func danglingSaveDoesNotMoveTheLayer() throws {
        // The drawing scales by one half at its top level, then opens a `q` it never closes.
        // Old: the single leading `Q` popped that dangling `q`, not the bracket, which left the
        // half-scale CTM in force, so the whole markup layer was drawn at half size in the
        // bottom-left quarter of the sheet.
        let content = "0.5 0 0 0.5 0 0 cm q\n" + LayeredSourceFixtures.drawingContent
        let source = Self.onePage(content: content)
        let job = Self.job()
        let produced = try LayeredMarkupExporter().data(source: source, pages: [job])

        let sourceURL = try LayeredMarkupExportTests.write(source, named: "dangling-q.pdf")
        let pageContent = try #require(CGPDFPageContentSource(url: sourceURL))
        let flattened = try FlattenedPDFWriter().data(shape: .flattened, pages: [job], content: pageContent)
        let layered = try #require(PageRaster.render(produced.data, pageIndex: 0))
        let flat = try #require(PageRaster.render(flattened, pageIndex: 0))
        let difference = PageRaster.difference(layered, flat)
        #expect(difference < 0.005, "the layered sheet differs from the flattened one in \(difference * 100)% of pixels")
    }
}
