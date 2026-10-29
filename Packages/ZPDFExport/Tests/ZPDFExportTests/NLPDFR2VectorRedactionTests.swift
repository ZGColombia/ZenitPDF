import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
@testable import ZPDFExport

/// NL-PDF-14 phase 2: vector-preserving redaction. Each test proves both halves — what stood
/// under the box is gone from every extraction path and from the file, and nothing outside the
/// box changed (text still searchable, linework still vector, pixels unchanged).
///
/// Old behaviour for every test here: only phase 1 existed, which turned each marked sheet into
/// a 300-dpi picture — no searchable text anywhere on it and no vector linework.
@Suite("Redaction, phase 2 — vector (NL-PDF-14)", .sharedHeap, .serialized)
struct NLPDFR2VectorRedactionTests {

    static func write(_ data: Data, to folder: URL, _ name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    // MARK: - Simple TrueType text

    @Test("TrueType text: the figure under the box is gone, the title outside stays searchable, the sheet stays vector")
    func trueTypeText() throws {
        let folder = try RedactionProof.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("tender.pdf"), output = folder.appendingPathComponent("tender redacted.pdf")
        try RedactionFixturePDF.tender(at: source)
        let original = try Data(contentsOf: source)
        let box = NLPDFR2RedactionTests.secretRect

        let outcome = try VectorRedactor.redact(source: source, marks: [RedactionMark(pageIndex: 0, rect: box)], to: output)
        RedactionProof.keep(output, as: "truetype.pdf")
        #expect(outcome.method == .vector)
        #expect(outcome.vectorPages == [0])
        #expect(outcome.rasterFallbacks.isEmpty)
        #expect(outcome.checks.count >= 6)
        #expect(try Data(contentsOf: source) == original, "the drawing itself is untouched")

        let after = try #require(PDFDocument(url: output))
        let text = after.page(at: 0)?.string ?? ""
        #expect(text.contains("Tender summary"), "text outside the box is still searchable: \(text)")
        #expect(!text.contains("4820000") && !text.contains("BIDAMOUNT") && !text.contains("SEK"))
        #expect(after.page(at: 0)?.selection(for: box)?.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        #expect(after.page(at: 0)?.annotations.isEmpty == true, "the note over the figure is gone")
        #expect(after.page(at: 1)?.string?.contains("Level 3 plan notes") == true)
        let bytes = try RedactionProof.decompressed(output)
        for secret in ["4820000", "BIDAMOUNT", "privatenote", "Estimator Name"] {
            #expect(bytes.range(of: Data(secret.utf8)) == nil, "\(secret) is not in the file")
        }
        #expect(try RedactionProof.readbackViolations(output, page: 0, boxes: [box]).isEmpty)
        #expect(!(try RedactionProof.readbackViolations(source, page: 0, boxes: [box]).isEmpty), "the readback does see the original's text")
        #expect(try RedactionProof.pageHasNoPicture(output, page: 0), "the sheet is still vector")
        #expect(try RedactionProof.changedShareOutside(source: source, output: output, page: 0, boxes: [box]) <= 0.001)
        #expect(RedactionProof.close(try RedactionProof.bounds(of: "Tender summary", in: source, page: 0),
                                     try RedactionProof.bounds(of: "Tender summary", in: output, page: 0)))
    }

    @Test("TrueType text cut mid-line: the number goes, the words either side keep their exact positions")
    func trueTypeMidLine() throws {
        let folder = try RedactionProof.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("line.pdf"), output = folder.appendingPathComponent("line redacted.pdf")
        var media = CGRect(x: 0, y: 0, width: 420, height: 300)
        let context = try #require(CGContext(source as CFURL, mediaBox: &media, nil))
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 16, nil)
        context.textPosition = CGPoint(x: 40, y: 150)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "TOTAL 4820000 SEK DUE", attributes: [.init(kCTFontAttributeName as String): font])), context)
        context.endPDFPage()
        context.closePDF()
        let digits = try RedactionProof.bounds(of: "4820000", in: source, page: 0)
        let box = digits.dropFirst().reduce(digits[0]) { $0.union($1) }.insetBy(dx: 1, dy: -4)

        _ = try VectorRedactor.redact(source: source, marks: [RedactionMark(pageIndex: 0, rect: box)], to: output)
        let text = try #require(PDFDocument(url: output)?.page(at: 0)?.string)
        #expect(!text.contains("4820000") && !text.contains("482"))
        for kept in ["TOTAL", "SEK DUE"] {
            #expect(RedactionProof.close(try RedactionProof.bounds(of: kept, in: source, page: 0), try RedactionProof.bounds(of: kept, in: output, page: 0)),
                    "“\(kept)” keeps its glyph positions")
        }
        #expect(try RedactionProof.readbackViolations(output, page: 0, boxes: [box]).isEmpty)
        #expect(try RedactionProof.changedShareOutside(source: source, output: output, page: 0, boxes: [box]) <= 0.001)
    }

    // MARK: - CID text with kerning inside TJ

    static func cidFixture() -> Data {
        // Codes are the letters' own values; /W gives each a distinct width so a wrong split shows.
        let letters = Array(" ACEIKLPRSTU")
        var widths: [String] = []
        var map: [String] = []
        for (offset, letter) in letters.enumerated() {
            let code = Int(letter.asciiValue ?? 32)
            widths.append("\(code) [\(letter == " " ? 280 : 560 + offset * 10)]")
            map.append(String(format: "<%04X> <%04X>", code, code))
        }
        let toUnicode = """
        /CIDInit /ProcSet findresource begin 12 dict begin begincmap
        /CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def
        /CMapName /Adobe-Identity-UCS def /CMapType 2 def
        1 begincodespacerange <0000> <FFFF> endcodespacerange
        \(map.count) beginbfchar
        \(map.joined(separator: "\n"))
        endbfchar endcmap CMapName currentdict /CMap defineresource pop end end
        """
        func hex(_ text: String) -> String { "<" + text.map { String(format: "%04X", Int($0.asciiValue ?? 32)) }.joined() + ">" }
        let content = "BT /F1 20 Tf 40 150 Td [\(hex("KEE")) -150 \(hex("P")) 80 \(hex(" ")) \(hex("SEC")) -40 \(hex("RET")) 200 \(hex(" TAIL"))] TJ ET"
        return RedactionFixturePDF.document(
            pages: [(content, nil)],
            resources: "<< /Font << /F1 FONT >> >>",
            extraObjects: { pdf in
                let unicode = pdf.addStream("", toUnicode)
                let descriptor = pdf.add("<< /Type /FontDescriptor /FontName /Helvetica /Flags 32 /FontBBox [-166 -225 1000 931] /ItalicAngle 0 /Ascent 718 /Descent -207 /CapHeight 718 /StemV 88 >>")
                let descendant = pdf.add("<< /Type /Font /Subtype /CIDFontType2 /BaseFont /Helvetica /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /FontDescriptor \(descriptor) 0 R /DW 600 /W [\(widths.joined(separator: " "))] /CIDToGIDMap /Identity >>")
                let font = pdf.add("<< /Type /Font /Subtype /Type0 /BaseFont /Helvetica /Encoding /Identity-H /DescendantFonts [\(descendant) 0 R] /ToUnicode \(unicode) 0 R >>")
                return ["FONT": "\(font) 0 R"]
            }
        )
    }

    @Test("CID text with kerning inside TJ: the word under the box goes, the kerned glyphs around it stay exactly put")
    func cidKerning() throws {
        let folder = try RedactionProof.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try Self.write(Self.cidFixture(), to: folder, "cid.pdf"), output = folder.appendingPathComponent("cid redacted.pdf")
        let sourceText = try #require(PDFDocument(url: source)?.page(at: 0)?.string)
        #expect(sourceText.contains("SECRET"), "the fixture's text reads through ToUnicode: \(sourceText)")
        let secret = try RedactionProof.bounds(of: "SECRET", in: source, page: 0)
        let box = secret.dropFirst().reduce(secret[0]) { $0.union($1) }.insetBy(dx: 1.5, dy: -3)

        let outcome = try VectorRedactor.redact(source: source, marks: [RedactionMark(pageIndex: 0, rect: box)], to: output)
        RedactionProof.keep(output, as: "cid.pdf")
        #expect(outcome.vectorPages == [0])
        let text = try #require(PDFDocument(url: output)?.page(at: 0)?.string)
        #expect(!text.contains("SEC") && !text.contains("RET"), "removed: \(text)")
        // PDFKit reads the −150 kern as a word gap ("KEE P"), in the source and in the copy alike.
        for kept in ["KEE", "P", "TAIL"] {
            #expect(RedactionProof.close(try RedactionProof.bounds(of: kept, in: source, page: 0), try RedactionProof.bounds(of: kept, in: output, page: 0)),
                    "“\(kept)” keeps its kerned positions")
        }
        // The kerning between kept glyphs survives as written, and the removed run becomes one
        // adjustment equal to its advance. /W widths: S 650, E 590, C 580, R 640, T 660, so
        // S E C R E T = 650 + 590 + 580 + 640 + 590 + 660 = 3710 thousandths of an em. The −40
        // kern inside the run and the 200 after it sit next to it and merge into the same number:
        // −3710 + (−40) + 200 = −3550.
        let operations = try pageOperations(output, page: 0)
        let tj = try #require(operations.first { $0.name == "TJ" }?.operands.first?.arrayValue)
        let numbers = tj.compactMap(\.doubleValue)
        #expect(numbers == [-150, 80, -3550], "kept kerning untouched, one adjustment for the removed run: \(numbers)")
        #expect(try RedactionProof.readbackViolations(output, page: 0, boxes: [box]).isEmpty)
        #expect(try RedactionProof.changedShareOutside(source: source, output: output, page: 0, boxes: [box]) <= 0.001)
    }

    func pageOperations(_ url: URL, page index: Int) throws -> [RedactionOperation] {
        let scan = try PDFDocumentScan(data: try Data(contentsOf: url))
        let entry = try scan.pages()[index]
        let context = RedactionRewriteContext(scan: scan, pool: RedactionObjectPool())
        return try RedactionContentLexer.parse(try VectorRedactor.pageContent(entry, context: context))
    }

    // MARK: - Type 3 text

    static func type3Fixture() -> Data {
        let content = "BT /T3 24 Tf 40 120 Td (ABABAB) Tj ET BT /F1 12 Tf 40 250 Td (Legend) Tj ET"
        return RedactionFixturePDF.document(
            pages: [(content, nil)],
            resources: "<< /Font << /T3 TYPE3 /F1 HELV >> >>",
            extraObjects: { pdf in
                let square = pdf.addStream("", "1000 0 0 0 900 900 d1 0 0 900 900 re f")
                let triangle = pdf.addStream("", "800 0 0 0 700 900 d1 0 0 m 700 0 l 350 900 l h f")
                let unicode = pdf.addStream("", "/CIDInit /ProcSet findresource begin 12 dict begin begincmap 1 begincodespacerange <00> <FF> endcodespacerange 2 beginbfchar <41> <0041> <42> <0042> endbfchar endcmap end end")
                let font = pdf.add("<< /Type /Font /Subtype /Type3 /FontBBox [0 0 1000 1000] /FontMatrix [0.001 0 0 0.001 0 0] /CharProcs << /sq \(square) 0 R /tri \(triangle) 0 R >> /Encoding << /Type /Encoding /Differences [65 /sq /tri] >> /FirstChar 65 /LastChar 66 /Widths [1000 800] /ToUnicode \(unicode) 0 R /Resources << >> >>")
                let helvetica = pdf.add(RedactionFixturePDF.helveticaWithWidths)
                return ["TYPE3": "\(font) 0 R", "HELV": "\(helvetica) 0 R"]
            }
        )
    }

    @Test("Type 3 text: glyph procedures measured through FontMatrix; the two glyphs under the box go, the others stay put")
    func type3Text() throws {
        let folder = try RedactionProof.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try Self.write(Self.type3Fixture(), to: folder, "type3.pdf"), output = folder.appendingPathComponent("type3 redacted.pdf")
        // Advances at 24 pt: A 24, B 19.2. Glyphs 3 and 4 run from 83.2 to 126.4.
        let box = CGRect(x: 84, y: 110, width: 41, height: 40)
        let outcome = try VectorRedactor.redact(source: source, marks: [RedactionMark(pageIndex: 0, rect: box)], to: output)
        RedactionProof.keep(output, as: "type3.pdf")
        #expect(outcome.vectorPages == [0])
        let operations = try pageOperations(output, page: 0)
        let tj = try #require(operations.first { $0.name == "TJ" }?.operands.first?.arrayValue)
        // (AB) then A (1000) and B (800) removed as −1800, then (AB).
        #expect(tj.count == 3 && tj[0] == .string(Array("AB".utf8)) && tj[1].doubleValue == -1800 && tj[2] == .string(Array("AB".utf8)), "\(tj)")
        // Core Graphics reads the Type 3 text back through its ToUnicode map: four glyphs remain.
        let document = try #require(CGPDFDocument(output as CFURL)), page = try #require(document.page(at: 1))
        let readback = RedactionCGReadback.scan(page: page, boxes: []).text
        #expect(readback.filter { $0 == "A" || $0 == "B" }.count == 4, "four Type 3 glyphs remain: \(readback)")
        #expect(try #require(PDFDocument(url: output)?.page(at: 0)?.string).contains("Legend"))
        #expect(try RedactionProof.readbackViolations(output, page: 0, boxes: [box]).isEmpty)
        #expect(try RedactionProof.changedShareOutside(source: source, output: output, page: 0, boxes: [box]) <= 0.001, "kept glyphs did not move")
    }

    // MARK: - Rotated and scaled text

    @Test("Rotated and scaled text: glyph boxes are placed through Tm and the CTM; only glyphs touching the box go")
    func rotatedScaledText() throws {
        let folder = try RedactionProof.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("rotated.pdf"), output = folder.appendingPathComponent("rotated redacted.pdf")
        var media = CGRect(x: 0, y: 0, width: 420, height: 300)
        let context = try #require(CGContext(source as CFURL, mediaBox: &media, nil))
        context.beginPDFPage(nil)
        let placement = CGAffineTransform(translationX: 60, y: 60).rotated(by: .pi / 7).scaledBy(x: 1.4, y: 0.9)
        context.saveGState()
        context.concatenate(placement)
        let font = CTFontCreateWithName("Helvetica" as CFString, 16, nil)
        context.textPosition = .zero
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "ANGLED 55501234 END", attributes: [.init(kCTFontAttributeName as String): font]))
        CTLineDraw(line, context)
        context.restoreGState()
        context.endPDFPage()
        context.closePDF()
        // A small box on the sheet at the middle of the number (between its 4th and 5th digit,
        // half a cap height up), placed through the same rotation and scale as the text.
        let middleX = CTLineGetOffsetForStringIndex(line, 11, nil)
        let centre = CGPoint(x: middleX, y: 5).applying(placement)
        let box = CGRect(x: centre.x - 4, y: centre.y - 3, width: 8, height: 6)

        let prepared = try VectorRedactor.prepare(source: source, password: nil, marks: [RedactionMark(pageIndex: 0, rect: box)])
        let removed = try #require(prepared.rewritten[0]).work
        #expect(removed.removedGlyphs >= 2 && removed.removedGlyphs <= 4, "only the digits the box touches: \(removed.removedGlyphs)")
        _ = try VectorRedactor.redact(source: source, marks: [RedactionMark(pageIndex: 0, rect: box)], to: output)
        RedactionProof.keep(output, as: "rotated.pdf")
        let text = try #require(PDFDocument(url: output)?.page(at: 0)?.string)
        #expect(!text.contains("55501234"))
        for kept in ["ANGLED", "END"] {
            #expect(RedactionProof.close(try RedactionProof.bounds(of: kept, in: source, page: 0), try RedactionProof.bounds(of: kept, in: output, page: 0)))
        }
        #expect(try RedactionProof.readbackViolations(output, page: 0, boxes: [box]).isEmpty)
        let glyphs = removed.removedGlyphQuads.map { quad -> CGRect in
            let xs = quad.map(\.x), ys = quad.map(\.y)
            return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        }
        #expect(try RedactionProof.changedShareOutside(source: source, output: output, page: 0, boxes: [box], ignoring: glyphs) <= 0.001)
    }

    // MARK: - Paths crossing a box

    static func pathFixture(at url: URL) throws {
        var media = CGRect(x: 0, y: 0, width: 420, height: 300)
        let context = try #require(CGContext(url as CFURL, mediaBox: &media, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 0.6, alpha: 1))
        context.move(to: CGPoint(x: 150, y: 30)); context.addLine(to: CGPoint(x: 300, y: 30)); context.addLine(to: CGPoint(x: 225, y: 270)); context.closePath()
        context.fillPath()
        // A frame with a hole, even-odd, crossing the box.
        context.addRect(CGRect(x: 170, y: 60, width: 120, height: 60)); context.addRect(CGRect(x: 190, y: 75, width: 30, height: 30))
        context.setFillColor(CGColor(gray: 0.3, alpha: 1))
        context.fillPath(using: .evenOdd)
        context.setStrokeColor(CGColor(gray: 0, alpha: 1))
        context.setLineWidth(3)
        context.move(to: CGPoint(x: 20, y: 150)); context.addLine(to: CGPoint(x: 400, y: 150)); context.strokePath()
        context.setLineWidth(2)
        context.setLineDash(phase: 0, lengths: [6, 4])
        context.move(to: CGPoint(x: 20, y: 130)); context.addLine(to: CGPoint(x: 400, y: 130)); context.strokePath()
        context.setLineDash(phase: 0, lengths: [])
        context.move(to: CGPoint(x: 40, y: 200))
        context.addCurve(to: CGPoint(x: 380, y: 220), control1: CGPoint(x: 150, y: 300), control2: CGPoint(x: 270, y: 60))
        context.strokePath()
        context.stroke(CGRect(x: 160, y: 90, width: 140, height: 120))
        context.endPDFPage()
        context.closePDF()
    }

    @Test("Paths crossing a box: fills, even-odd holes, strokes, dashes and curves are cut at the box edges; nothing inside remains")
    func pathsCrossingBox() throws {
        let folder = try RedactionProof.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("paths.pdf"), output = folder.appendingPathComponent("paths redacted.pdf")
        try Self.pathFixture(at: source)
        let box = CGRect(x: 180, y: 100, width: 80, height: 90)
        #expect(!(try RedactionProof.readbackViolations(source, page: 0, boxes: [box]).isEmpty), "the original has geometry inside the box")

        let outcome = try VectorRedactor.redact(source: source, marks: [RedactionMark(pageIndex: 0, rect: box)], to: output)
        RedactionProof.keep(output, as: "paths.pdf")
        #expect(outcome.vectorPages == [0])
        #expect(try RedactionProof.readbackViolations(output, page: 0, boxes: [box]).isEmpty, "no path point or segment inside the box")
        #expect(try RedactionProof.pageHasNoPicture(output, page: 0))
        #expect(try RedactionProof.changedShareOutside(source: source, output: output, page: 0, boxes: [box]) <= 0.001)
        // The dashes to the right of the box keep their phase.
        let dashed = CGRect(x: box.maxX + 3, y: 126, width: 400 - box.maxX - 3, height: 8)
        let everythingElse = [CGRect(x: 0, y: 0, width: 420, height: 125), CGRect(x: 0, y: 135, width: 420, height: 165), CGRect(x: 0, y: 125, width: box.maxX + 3, height: 10)]
        #expect(dashed.width > 100)
        #expect(try RedactionProof.changedShareOutside(source: source, output: output, page: 0, boxes: [box], ignoring: everythingElse, delta: 24) == 0,
                "the dashed line right of the box is pixel-identical")
        let operations = try pageOperations(output, page: 0)
        #expect(operations.contains { $0.name == "c" }, "the curve is still a curve outside the box")
        #expect(operations.contains { $0.name == "f*" }, "the even-odd fill keeps its rule")
    }

    // MARK: - Images

    static func imageSamples(width: Int, height: Int, components: Int) -> [UInt8] {
        (0..<(width * height * components)).map { UInt8(40 + ($0 * 7) % 200) }
    }

    static func imageFixture() -> Data {
        let rgb = imageSamples(width: 40, height: 20, components: 3)
        let mask = (0..<(40 * 20)).map { UInt8(128 + $0 % 128) }
        let content = "q 200 0 0 100 50 100 cm /Im1 Do Q q 30 0 0 20 60 110 cm /Im2 Do Q q 60 0 0 40 320 40 cm /Im3 Do Q"
        return RedactionFixturePDF.document(
            pages: [(content, nil)],
            resources: "<< /XObject << /Im1 IM1 /Im2 IM2 /Im3 IM3 >> >>",
            extraObjects: { pdf in
                let smask = pdf.addStream("/Type /XObject /Subtype /Image /Width 40 /Height 20 /BitsPerComponent 8 /ColorSpace /DeviceGray /Filter /FlateDecode",
                                          PDFStreamCodec.flateEncode(Data(mask))!)
                let first = pdf.addStream("/Type /XObject /Subtype /Image /Width 40 /Height 20 /BitsPerComponent 8 /ColorSpace /DeviceRGB /Filter /FlateDecode /SMask \(smask) 0 R",
                                          PDFStreamCodec.flateEncode(Data(rgb))!)
                let inside = pdf.addStream("/Type /XObject /Subtype /Image /Width 4 /Height 4 /BitsPerComponent 8 /ColorSpace /DeviceGray", Data(repeating: 0x55, count: 16))
                let outside = pdf.addStream("/Type /XObject /Subtype /Image /Width 4 /Height 4 /BitsPerComponent 8 /ColorSpace /DeviceGray", Data((0..<16).map { UInt8($0 * 16) }))
                return ["IM1": "\(first) 0 R", "IM2": "\(inside) 0 R", "IM3": "\(outside) 0 R"]
            }
        )
    }

    @Test("An image partly under the box: exactly the covered samples are blanked in the data (and its soft mask); the rest is unchanged")
    func imagePartlyCovered() throws {
        let folder = try RedactionProof.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try Self.write(Self.imageFixture(), to: folder, "image.pdf"), output = folder.appendingPathComponent("image redacted.pdf")
        // Image 1 is 40 × 20 samples on 200 × 100 pt at (50, 100): 5 pt a sample. The box covers
        // sample centres with x < 140 and y < 150 → columns 0…17, rows 10…19.
        let box = CGRect(x: 40, y: 90, width: 100, height: 60)
        let outcome = try VectorRedactor.redact(source: source, marks: [RedactionMark(pageIndex: 0, rect: box)], to: output)
        RedactionProof.keep(output, as: "image.pdf")
        #expect(outcome.vectorPages == [0])

        let scan = try PDFDocumentScan(data: try Data(contentsOf: output))
        let entry = try scan.pages()[0]
        let xobjects = try #require(scan.dictionary(scan.dictionary(entry.inheritedResources)?["XObject"]))
        #expect(xobjects["Im2"] == nil, "the image wholly under the box is gone")
        #expect(xobjects["Im1"] == nil, "the covered image is replaced, not kept beside its copy")
        guard case let .stream(copyDictionary, copyData)? = scan.object(xobjects.first { $0.key.hasPrefix("ZRdIm") }?.value) else {
            Issue.record("no blanked copy")
            return
        }
        let samples = [UInt8](try RedactionStreamFilters.decode(dictionary: copyDictionary, data: copyData).data)
        let original = Self.imageSamples(width: 40, height: 20, components: 3)
        var blanked = 0, kept = 0
        for row in 0..<20 {
            for column in 0..<40 {
                let offset = (row * 40 + column) * 3
                let covered = column <= 17 && row >= 10
                if covered {
                    #expect(samples[offset..<(offset + 3)].allSatisfy { $0 == 0 }, "sample \(column),\(row) blanked")
                    blanked += 1
                } else if Array(samples[offset..<(offset + 3)]) == Array(original[offset..<(offset + 3)]) {
                    kept += 1
                }
            }
        }
        #expect(blanked == 180)
        #expect(kept == 800 - 180, "every sample outside the box is the original's")
        guard case let .stream(maskDictionary, maskData)? = scan.object(copyDictionary["SMask"]) else {
            Issue.record("the copy has no soft mask")
            return
        }
        let mask = [UInt8](try RedactionStreamFilters.decode(dictionary: maskDictionary, data: maskData).data)
        #expect((10..<20).allSatisfy { row in (0...17).allSatisfy { mask[row * 40 + $0] == 0 } }, "the soft mask is blanked under the box too")
        #expect(mask[0] == 128, "and kept outside it")
        #expect(try RedactionProof.readbackViolations(output, page: 0, boxes: [box]).isEmpty)
        #expect(try RedactionProof.changedShareOutside(source: source, output: output, page: 0, boxes: [box], ignoring: [box.insetBy(dx: -5, dy: -5)]) <= 0.001)
    }

    @Test("An inline image partly under the box: covered samples blanked, re-emitted as ASCIIHex, the rest unchanged")
    func inlineImage() throws {
        let folder = try RedactionProof.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let samples = (0..<128).map { UInt8(0x10 + $0) }
        var content = Data("q 160 0 0 80 200 150 cm BI /W 16 /H 8 /BPC 8 /CS /G ID ".utf8)
        content.append(contentsOf: samples)
        content.append(Data("\nEI Q BT /F1 12 Tf 30 30 Td (Inline caption) Tj ET".utf8))
        var pdf = RedactionFixturePDF()
        let catalog = pdf.reserve(), tree = pdf.reserve()
        let font = pdf.add(RedactionFixturePDF.helveticaWithWidths)
        let stream = pdf.addStream("", content)
        let page = pdf.add("<< /Type /Page /Parent \(tree) 0 R /MediaBox [0 0 420 300] /Resources << /Font << /F1 \(font) 0 R >> >> /Contents \(stream) 0 R >>")
        pdf.set(tree, "<< /Type /Pages /Kids [\(page) 0 R] /Count 1 >>")
        pdf.set(catalog, "<< /Type /Catalog /Pages \(tree) 0 R >>")
        let source = try Self.write(pdf.data(root: catalog), to: folder, "inline.pdf"), output = folder.appendingPathComponent("inline redacted.pdf")
        // 10 pt a sample from (200, 150): the box covers columns 0…3 and rows 4…7.
        let box = CGRect(x: 180, y: 130, width: 60, height: 60)
        _ = try VectorRedactor.redact(source: source, marks: [RedactionMark(pageIndex: 0, rect: box)], to: output)
        RedactionProof.keep(output, as: "inline.pdf")

        let operations = try pageOperations(output, page: 0)
        let image = try #require(operations.first { $0.name == "BI" }?.inlineImage)
        #expect(image.dictionary["F"] == .name("AHx"))
        let decoded = [UInt8](RedactionStreamFilters.asciiHex(image.data))
        for row in 0..<8 {
            for column in 0..<16 {
                let covered = column <= 3 && row >= 4
                #expect(decoded[row * 16 + column] == (covered ? 0 : samples[row * 16 + column]), "sample \(column),\(row)")
            }
        }
        let caption = PDFDocument(url: output)?.page(at: 0)?.string ?? ""
        #expect(caption.contains("Inline caption"))
        #expect(try RedactionProof.readbackViolations(output, page: 0, boxes: [box]).isEmpty)
        #expect(try RedactionProof.changedShareOutside(source: source, output: output, page: 0, boxes: [box], ignoring: [box.insetBy(dx: -10, dy: -10)]) <= 0.001)
    }

    // MARK: - A shared form XObject

    static func formFixture() -> Data {
        let form = "0.2 g 0 0 80 40 re f 0 0 1 RG 3 w 0 20 m 80 20 l S BT /F1 10 Tf 5 45 Td (FORMTEXT) Tj ET"
        let content = "q 1 0 0 1 40 50 cm /Fm1 Do Q q 1 0 0 1 240 50 cm /Fm1 Do Q"
        return RedactionFixturePDF.document(
            pages: [(content, nil)],
            resources: "<< /XObject << /Fm1 FORM >> >>",
            extraObjects: { pdf in
                let font = pdf.add(RedactionFixturePDF.helveticaWithWidths)
                let stream = pdf.addStream("/Type /XObject /Subtype /Form /BBox [0 0 100 60] /Resources << /Font << /F1 \(font) 0 R >> >>", form)
                return ["FORM": "\(stream) 0 R"]
            }
        )
    }

    @Test("A form XObject drawn inside and outside the box: the inside placement gets a cut copy, the outside one keeps the original")
    func sharedFormXObject() throws {
        let folder = try RedactionProof.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try Self.write(Self.formFixture(), to: folder, "form.pdf"), output = folder.appendingPathComponent("form redacted.pdf")
        let box = CGRect(x: 230, y: 40, width: 50, height: 80)
        let outcome = try VectorRedactor.redact(source: source, marks: [RedactionMark(pageIndex: 0, rect: box)], to: output)
        RedactionProof.keep(output, as: "form.pdf")
        #expect(outcome.vectorPages == [0])

        let scan = try PDFDocumentScan(data: try Data(contentsOf: output))
        let entry = try scan.pages()[0]
        let xobjects = try #require(scan.dictionary(scan.dictionary(entry.inheritedResources)?["XObject"]))
        #expect(xobjects.count == 2, "the original and one cut copy: \(xobjects.keys.sorted())")
        let sourceScan = try PDFDocumentScan(data: try Data(contentsOf: source))
        let sourceForm = try RedactionStreamFilters.decodeFully(sourceScan.object(sourceScan.dictionary(sourceScan.dictionary(try sourceScan.pages()[0].inheritedResources)?["XObject"])?["Fm1"]))
        #expect(try RedactionStreamFilters.decodeFully(scan.object(xobjects["Fm1"])) == sourceForm, "the shared original is written unchanged")
        let copyReference = try #require(xobjects.first { $0.key.hasPrefix("ZRdFm") }?.value)
        let copy = try RedactionContentLexer.parse(try RedactionStreamFilters.decodeFully(scan.object(copyReference)))
        #expect(copy.contains { $0.name == "TJ" }, "the copy's text lost the glyphs under the box")
        let operations = try pageOperations(output, page: 0)
        #expect(operations.filter { $0.name == "Do" }.count == 2)
        let text = try #require(PDFDocument(url: output)?.page(at: 0)?.string)
        #expect(RedactionWordSearch.occurrences(of: "FORMTEXT", in: text) == 1, "the outside placement still reads: \(text)")
        #expect(try RedactionProof.readbackViolations(output, page: 0, boxes: [box]).isEmpty)
        #expect(try RedactionProof.changedShareOutside(source: source, output: output, page: 0, boxes: [box]) <= 0.001)
    }

    // MARK: - Annotations, links, bookmarks

    static func annotationFixture() -> Data {
        let content = "BT /F1 14 Tf 60 200 Td (Bid figure 4820000) Tj ET BT /F1 14 Tf 60 270 Td (Cover) Tj ET 0 0 1 RG 20 20 380 260 re S"
        return RedactionFixturePDF.document(
            pages: [(content, "[LINKA NOTE SQUARE LINKB LINKC]")],
            resources: "<< /Font << /F1 HELV >> >>",
            extraObjects: { pdf in
                let helvetica = pdf.add(RedactionFixturePDF.helveticaWithWidths)
                let linkA = pdf.reserve(), note = pdf.reserve(), square = pdf.reserve(), linkB = pdf.reserve(), linkC = pdf.reserve()
                let outlines = pdf.reserve(), first = pdf.reserve(), second = pdf.reserve()
                // The page comes right after these extras and its content stream.
                let pageNumber = pdf.count + 2
                pdf.set(linkA, "<< /Type /Annot /Subtype /Link /Rect [70 195 150 215] /Border [0 0 0] /A << /S /URI /URI (https://example.invalid/secret-bid) >> >>")
                pdf.set(note, "<< /Type /Annot /Subtype /Text /Rect [200 195 220 215] /Contents (internal remark about the bid) >>")
                pdf.set(square, "<< /Type /Annot /Subtype /Square /Rect [300 40 360 80] /Contents (kept remark) /C [1 0 0] >>")
                pdf.set(linkB, "<< /Type /Annot /Subtype /Link /Rect [300 250 380 265] /Border [0 0 0] /Dest [\(pageNumber) 0 R /XYZ 100 205 0] >>")
                pdf.set(linkC, "<< /Type /Annot /Subtype /Link /Rect [300 230 380 245] /Border [0 0 0] /Dest [\(pageNumber) 0 R /XYZ 10 290 0] >>")
                pdf.set(first, "<< /Title (Bid figure) /Parent \(outlines) 0 R /Next \(second) 0 R /Dest [\(pageNumber) 0 R /XYZ 100 205 0] >>")
                pdf.set(second, "<< /Title (Cover) /Parent \(outlines) 0 R /Prev \(first) 0 R /Dest [\(pageNumber) 0 R /Fit] >>")
                pdf.set(outlines, "<< /Type /Outlines /First \(first) 0 R /Last \(second) 0 R /Count 2 >>")
                return [
                    "HELV": "\(helvetica) 0 R", "LINKA": "\(linkA) 0 R", "NOTE": "\(note) 0 R", "SQUARE": "\(square) 0 R",
                    "LINKB": "\(linkB) 0 R", "LINKC": "\(linkC) 0 R", "OUTLINES": "\(outlines) 0 R",
                    "NAMES": "<< /Dests << /Names [(bid) [\(pageNumber) 0 R /XYZ 100 205 0] (cover) [\(pageNumber) 0 R /Fit]] >> >>"
                ]
            },
            catalogExtras: "/Outlines OUTLINES /Names NAMES"
        )
    }

    @Test("A link and a note inside the box go; a link pointing into the box, its bookmark and named destination go; the rest stays")
    func annotationsAndLinks() throws {
        let folder = try RedactionProof.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try Self.write(Self.annotationFixture(), to: folder, "annotations.pdf"), output = folder.appendingPathComponent("annotations redacted.pdf")
        let sourceDocument = try #require(PDFDocument(url: source))
        #expect(sourceDocument.page(at: 0)?.annotations.count == 5)
        #expect(sourceDocument.outlineRoot?.numberOfChildren == 2)
        let box = CGRect(x: 60, y: 185, width: 180, height: 40)

        _ = try VectorRedactor.redact(source: source, marks: [RedactionMark(pageIndex: 0, rect: box)], to: output)
        RedactionProof.keep(output, as: "annotations.pdf")
        let after = try #require(PDFDocument(url: output))
        let kinds = (after.page(at: 0)?.annotations ?? []).map { $0.type ?? "" }.sorted()
        #expect(kinds == ["Link", "Square"], "the note, the link in the box and the link into the box are gone: \(kinds)")
        #expect(after.outlineRoot?.numberOfChildren == 1)
        #expect(after.outlineRoot?.child(at: 0)?.label == "Cover")
        let bytes = try RedactionProof.decompressed(output)
        for secret in ["secret-bid", "internal remark", "4820000", "(bid)"] {
            #expect(bytes.range(of: Data(secret.utf8)) == nil, "\(secret) is gone")
        }
        #expect(bytes.range(of: Data("kept remark".utf8)) != nil)
        #expect(bytes.range(of: Data("(cover)".utf8)) != nil, "the named destination outside the box is kept")
        #expect(after.page(at: 0)?.string?.contains("Cover") == true)
        #expect(try RedactionProof.changedShareOutside(source: source, output: output, page: 0, boxes: [box]) <= 0.002)
    }

    // MARK: - Document metadata and earlier revisions

    static func metadataFixture() -> Data {
        let content = "BT /F1 14 Tf 60 200 Td (CURRENT 4820000) Tj ET BT /F1 14 Tf 60 260 Td (Cover page) Tj ET"
        let xmp = "<x:xmpmeta xmlns:x='adobe:ns:meta/'><dc:creator>Estimator Name</dc:creator><dc:title>Secret Tender</dc:title></x:xmpmeta>"
        let base = RedactionFixturePDF.document(
            pages: [("BT /F1 14 Tf 60 200 Td (OLDREVISION 777) Tj ET", nil)],
            resources: "<< /Font << /F1 HELV >> >>",
            extraObjects: { pdf in
                let helvetica = pdf.add(RedactionFixturePDF.helveticaWithWidths)
                let metadata = pdf.addStream("/Type /Metadata /Subtype /XML", xmp)
                let embedded = pdf.addStream("/Type /EmbeddedFile", "attachment-secret-data")
                let spec = pdf.add("<< /Type /Filespec /F (bid.xlsx) /EF << /F \(embedded) 0 R >> >>")
                let element = pdf.add("<< /Type /StructElem /S /Figure /Alt (alt-secret description) >>")
                let root = pdf.add("<< /Type /StructTreeRoot /K [\(element) 0 R] >>")
                return [
                    "HELV": "\(helvetica) 0 R", "META": "\(metadata) 0 R", "SPEC": "\(spec) 0 R", "STRUCT": "\(root) 0 R"
                ]
            },
            catalogExtras: "/Metadata META /OpenAction << /S /JavaScript /JS (app.alert\\('secretscript'\\)) >> /Names << /JavaScript << /Names [(js1) << /S /JavaScript /JS (secretscript2) >>] >> /EmbeddedFiles << /Names [(bid.xlsx) SPEC] >> >> /StructTreeRoot STRUCT /MarkInfo << /Marked true >>",
            info: "<< /Author (Estimator Name) /Title (Secret Tender) /Subject (bid) /Keywords (confidential) /Creator (Estimating Suite) >>"
        )
        // An incremental update: the page's content is replaced; the old one stays in the file as
        // an earlier revision, as it does in real drawings saved many times.
        let scan = try! PDFDocumentScan(data: base)
        let pageEntry = try! scan.pages()[0]
        var page = pageEntry.dictionary
        let next = scan.nextObjectNumber
        page["Contents"] = .reference(number: next, generation: 0)
        page["PieceInfo"] = .dictionary(["Private": .string(Array("pieceinfo-secret".utf8))])
        var update = PDFIncrementalUpdate()
        update.objects[next] = .stream(dictionary: [:], data: Data(content.utf8))
        update.objects[pageEntry.number] = .dictionary(page)
        return try! update.appended(to: base, scan: scan)
    }

    @Test("Metadata, XMP, scripts, attachments, tagged structure, private data and earlier revisions do not travel")
    func documentMetadata() throws {
        let folder = try RedactionProof.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try Self.write(Self.metadataFixture(), to: folder, "metadata.pdf"), output = folder.appendingPathComponent("metadata redacted.pdf")
        let sourceBytes = try RedactionProof.decompressed(source)
        for secret in ["OLDREVISION", "Estimator Name", "secretscript", "attachment-secret-data", "alt-secret", "pieceinfo-secret"] {
            #expect(sourceBytes.range(of: Data(secret.utf8)) != nil, "the fixture carries \(secret)")
        }
        let box = CGRect(x: 50, y: 190, width: 250, height: 35)
        _ = try VectorRedactor.redact(source: source, marks: [RedactionMark(pageIndex: 0, rect: box)], to: output)
        RedactionProof.keep(output, as: "metadata.pdf")

        let bytes = try RedactionProof.decompressed(output)
        for secret in ["OLDREVISION", "4820000", "Estimator Name", "Secret Tender", "confidential", "Estimating Suite", "secretscript",
                       "attachment-secret-data", "bid.xlsx", "alt-secret", "pieceinfo-secret", "xmpmeta"] {
            #expect(bytes.range(of: Data(secret.utf8)) == nil, "\(secret) does not travel")
        }
        let raw = try Data(contentsOf: output)
        #expect(raw.ranges(of: Data("startxref".utf8)).count == 1, "one revision")
        let after = try #require(PDFDocument(url: output))
        #expect(after.documentAttributes?[PDFDocumentAttribute.authorAttribute] == nil)
        #expect(after.documentAttributes?[PDFDocumentAttribute.titleAttribute] == nil)
        #expect(after.page(at: 0)?.string?.contains("Cover page") == true)
        let scan = try PDFDocumentScan(data: raw)
        let catalog = try #require(scan.dictionary(scan.rootReference))
        #expect(Set(catalog.keys) == ["Type", "Pages"], "\(catalog.keys.sorted())")
        #expect(try RedactionProof.changedShareOutside(source: source, output: output, page: 0, boxes: [box]) <= 0.001)
    }

    // MARK: - Marked content

    static func markedContentFixture() -> Data {
        // Helvetica with 500-unit widths at 14 pt: 7 pt a glyph from x = 60, so "BID " runs to
        // 88, the digits 88…137, " END" 137…165.
        let content = """
        /Span << /ActualText (BID 4820000 END) >> BDC BT /F1 14 Tf 60 200 Td (BID 4820000 END) Tj ET EMC
        /P << /MCID 0 >> BDC BT /F1 14 Tf 60 260 Td (Visible heading) Tj ET EMC
        /Figure /MC0 BDC 0 0 1 rg 100 215 30 30 re f EMC
        """
        return RedactionFixturePDF.document(
            pages: [(content, nil)],
            resources: "<< /Font << /F1 HELV >> /Properties << /MC0 << /Alt (secret figure alt) /MCID 1 >> >> >>",
            extraObjects: { pdf in ["HELV": "\(pdf.add(RedactionFixturePDF.helveticaWithWidths)) 0 R"] }
        )
    }

    @Test("Marked content: /ActualText keeps only the kept glyphs' text, /Alt of a cut figure goes, its named property list is not written")
    func markedContent() throws {
        let folder = try RedactionProof.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try Self.write(Self.markedContentFixture(), to: folder, "marked.pdf"), output = folder.appendingPathComponent("marked redacted.pdf")
        let box = CGRect(x: 89, y: 190, width: 47, height: 40)
        let outcome = try VectorRedactor.redact(source: source, marks: [RedactionMark(pageIndex: 0, rect: box)], to: output)
        #expect(outcome.vectorPages == [0])
        let operations = try pageOperations(output, page: 0)
        let spans = operations.filter { $0.name == "BDC" }.compactMap { $0.operands.count > 1 ? $0.operands[1].dictionaryValue : nil }
        let actual = try #require(spans.compactMap { VectorRedactor.stringBytes($0["ActualText"]) }.first)
        #expect(VectorRedactor.text(actual) == "BID  END", "the replacement text keeps only what is left: \(VectorRedactor.text(actual))")
        #expect(spans.contains { $0["MCID"] == .integer(0) }, "marked content that lost nothing is untouched")
        #expect(!spans.contains { $0["Alt"] != nil }, "the cut figure's alternate description is gone")
        let bytes = try RedactionProof.decompressed(output)
        for secret in ["4820000", "secret figure alt"] { #expect(bytes.range(of: Data(secret.utf8)) == nil, "\(secret) is gone") }
        let text = try #require(PDFDocument(url: output)?.page(at: 0)?.string)
        #expect(text.contains("Visible heading") && text.contains("BID") && text.contains("END"))
        #expect(try RedactionProof.readbackViolations(output, page: 0, boxes: [box]).isEmpty)
        #expect(try RedactionProof.changedShareOutside(source: source, output: output, page: 0, boxes: [box]) <= 0.001)
    }

    @Test("An encrypted drawing: every marked sheet falls back to raster with the reason stated, and the copy is still checked")
    func encryptedFallsBack() throws {
        let folder = try RedactionProof.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("locked.pdf"), output = folder.appendingPathComponent("locked redacted.pdf")
        var media = CGRect(x: 0, y: 0, width: 420, height: 300)
        let context = try #require(CGContext(source as CFURL, mediaBox: &media, [
            kCGPDFContextUserPassword: "open-sesame", kCGPDFContextOwnerPassword: "owner-sesame"
        ] as CFDictionary))
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
        context.textPosition = CGPoint(x: 70, y: 192)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "LOCKEDBID 4820000", attributes: [.init(kCTFontAttributeName as String): font])), context)
        context.endPDFPage()
        context.closePDF()
        let marks = [RedactionMark(pageIndex: 0, rect: NLPDFR2RedactionTests.secretRect)]
        let assessment = VectorRedactor.assess(source: source, password: "open-sesame", marks: marks)
        #expect(assessment.fallbacks.first?.reason.contains("encrypted") == true, "\(assessment.fallbacks)")
        let outcome = try VectorRedactor.redact(source: source, password: "open-sesame", marks: marks, to: output)
        #expect(outcome.vectorPages.isEmpty)
        #expect(outcome.rasterFallbacks == assessment.fallbacks)
        let after = try #require(PDFDocument(url: output))
        #expect(!after.isEncrypted)
        let text = after.page(at: 0)?.string ?? ""
        #expect(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    // MARK: - Fallback

    static func fallbackFixture() -> Data {
        RedactionFixturePDF.document(
            pages: [
                ("BT /Std 14 Tf 60 200 Td (STANDARD 111222) Tj ET 0 0 1 RG 20 20 m 400 280 l S", nil),
                ("BT /F1 14 Tf 60 200 Td (MEASURED 333444) Tj ET BT /F1 14 Tf 60 260 Td (Sheet two) Tj ET 0 0 1 RG 20 20 m 400 280 l S", nil)
            ],
            resources: "<< /Font << /Std STD /F1 HELV >> >>",
            extraObjects: { pdf in
                let standard = pdf.add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
                let helvetica = pdf.add(RedactionFixturePDF.helveticaWithWidths)
                return ["STD": "\(standard) 0 R", "HELV": "\(helvetica) 0 R"]
            }
        )
    }

    @Test("A sheet with a font it cannot measure falls back to raster, says why, and the other marked sheet stays vector")
    func fallbackToRaster() throws {
        let folder = try RedactionProof.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try Self.write(Self.fallbackFixture(), to: folder, "fallback.pdf"), output = folder.appendingPathComponent("fallback redacted.pdf")
        let box = CGRect(x: 50, y: 190, width: 250, height: 35)
        let marks = [RedactionMark(pageIndex: 0, rect: box), RedactionMark(pageIndex: 1, rect: box)]

        let assessment = VectorRedactor.assess(source: source, marks: marks)
        #expect(assessment.markedPages == [0, 1])
        #expect(!assessment.vectorQualifies && assessment.anyVector)
        #expect(assessment.vectorPages == [1])
        #expect(assessment.fallbacks.map(\.pageIndex) == [0])
        #expect(assessment.fallbacks.first?.reason.contains("width table") == true, "\(assessment.fallbacks)")

        let outcome = try VectorRedactor.redact(source: source, marks: marks, to: output)
        RedactionProof.keep(output, as: "fallback.pdf")
        #expect(outcome.vectorPages == [1])
        #expect(outcome.rasterFallbacks == assessment.fallbacks)
        let after = try #require(PDFDocument(url: output))
        let fallenBackText = after.page(at: 0)?.string ?? ""
        #expect(fallenBackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "the fallen-back sheet is a picture")
        #expect(!(try RedactionProof.pageHasNoPicture(output, page: 0)))
        #expect(try RedactionProof.pageHasNoPicture(output, page: 1), "the other sheet stays vector")
        #expect(after.page(at: 1)?.string?.contains("Sheet two") == true)
        let bytes = try RedactionProof.decompressed(output)
        #expect(bytes.range(of: Data("111222".utf8)) == nil && bytes.range(of: Data("333444".utf8)) == nil)
        #expect(try RedactionProof.changedShareOutside(source: source, output: output, page: 1, boxes: [box]) <= 0.001)
    }

    @Test("Refusals: a removed word still on another sheet refuses the copy, and a leaky rewrite is caught before anything is written")
    func refusals() throws {
        let folder = try RedactionProof.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("tender.pdf"), output = folder.appendingPathComponent("leaky.pdf")
        try RedactionFixturePDF.tender(at: source, secretOnSheetTwo: true)
        let marks = [RedactionMark(pageIndex: 0, rect: NLPDFR2RedactionTests.secretRect)]
        #expect(throws: RedactionRefusal.checkFailed("“BIDAMOUNT” is still readable on sheet 2; mark it there as well")) {
            try VectorRedactor.redact(source: source, marks: marks, to: output)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))

        // A rewriter that forgot to remove anything: the verifier refuses the copy.
        let clean = folder.appendingPathComponent("clean.pdf")
        try RedactionFixturePDF.tender(at: clean)
        var prepared = try VectorRedactor.prepare(source: clean, password: nil, marks: marks)
        let scan = try #require(prepared.scan), entries = try #require(prepared.entries)
        let context = RedactionRewriteContext(scan: scan, pool: prepared.pool)
        let untouched = try RedactionContentLexer.parse(try VectorRedactor.pageContent(entries[0], context: context))
        prepared.rewritten[0]?.operations = untouched
        prepared.rewritten[0]?.resources = scan.dictionary(entries[0].inheritedResources) ?? [:]
        let built = try VectorRedactor.build(prepared, scan: scan, entries: entries, dpi: 150)
        #expect(throws: RedactionRefusal.self) { try VectorRedactor.verify(built, prepared: prepared) }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(".zpdf-redact") }
        #expect(leftovers.isEmpty)
    }

    // MARK: - Geometry

    @Test("Region difference keeps every winding number outside the box and zeroes it inside, for both fill rules")
    func regionDifference() {
        let square = RedactionSubpath(start: CGPoint(x: 0, y: 0), segments: [
            .line(CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)), .line(CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100)),
            .line(CGPoint(x: 100, y: 100), CGPoint(x: 0, y: 100)), .line(CGPoint(x: 0, y: 100), CGPoint(x: 0, y: 0))
        ], closed: true)
        let hole = RedactionSubpath(start: CGPoint(x: 10, y: 10), segments: [
            .line(CGPoint(x: 10, y: 10), CGPoint(x: 40, y: 10)), .line(CGPoint(x: 40, y: 10), CGPoint(x: 40, y: 90)),
            .line(CGPoint(x: 40, y: 90), CGPoint(x: 10, y: 90)), .line(CGPoint(x: 10, y: 90), CGPoint(x: 10, y: 10))
        ], closed: true)
        let circle = RedactionSubpath(start: CGPoint(x: 150, y: 50), segments: [
            .cubic(CGPoint(x: 150, y: 50), CGPoint(x: 150, y: 77.6), CGPoint(x: 127.6, y: 100), CGPoint(x: 100, y: 100))
        ], closed: true)
        let box = CGRect(x: 30, y: 30, width: 90, height: 40)
        let result = RedactionGeometry.difference([square, hole, circle], boxes: [box])
        func path(_ subpaths: [RedactionSubpath]) -> CGPath {
            let path = CGMutablePath()
            for subpath in subpaths {
                path.move(to: subpath.start)
                for segment in subpath.segments {
                    switch segment {
                    case let .line(_, b): path.addLine(to: b)
                    case let .cubic(_, c1, c2, e): path.addCurve(to: e, control1: c1, control2: c2)
                    }
                }
                path.closeSubpath()
            }
            return path
        }
        let before = path([square, hole, circle]), after = path(result)
        for rule in [CGPathFillRule.winding, .evenOdd] {
            for x in stride(from: 1.5, to: 160, by: 3) {
                for y in stride(from: 1.5, to: 110, by: 3) {
                    let point = CGPoint(x: x, y: y)
                    let inside = box.insetBy(dx: 0.01, dy: 0.01).contains(point)
                    if inside {
                        #expect(!after.contains(point, using: rule), "nothing inside the box at \(point)")
                    } else if !box.insetBy(dx: -0.01, dy: -0.01).contains(point) {
                        #expect(after.contains(point, using: rule) == before.contains(point, using: rule), "unchanged at \(point), rule \(rule)")
                    }
                }
            }
        }
    }

    @Test("A cubic cut at the box keeps exactly the original curve outside it")
    func strokeClipIsExact() {
        let curve = RedactionSegment.cubic(CGPoint(x: 0, y: 0), CGPoint(x: 40, y: 120), CGPoint(x: 80, y: -60), CGPoint(x: 120, y: 60))
        let box = CGRect(x: 30, y: 10, width: 50, height: 40)
        let pieces = RedactionGeometry.clipStroke([RedactionSubpath(start: curve.start, segments: [curve], closed: false)], boxes: [box]) { $0.length }
        #expect(pieces.count >= 2)
        for piece in pieces {
            for segment in piece.subpath.segments {
                for t in stride(from: 0.0, through: 1.0, by: 0.05) {
                    let point = segment.point(at: t)
                    #expect(!box.insetBy(dx: 1e-6, dy: 1e-6).contains(point) || point.x == box.minX, "kept point outside: \(point)")
                    // On the original curve: some parameter reproduces it.
                    let nearest = stride(from: 0.0, through: 1.0, by: 0.0005).map { curve.point(at: $0) }
                        .map { hypot($0.x - point.x, $0.y - point.y) }.min() ?? 1
                    #expect(nearest < 0.2, "kept point lies on the original curve")
                }
            }
        }
        // Where a piece ends inside the page, it ends on the box edge.
        for piece in pieces {
            for end in [piece.subpath.start, piece.subpath.segments.last!.end] where end != curve.start && end != curve.end {
                let onEdge = abs(end.x - box.minX) < 1e-6 || abs(end.x - box.maxX) < 1e-6 || abs(end.y - box.minY) < 1e-6 || abs(end.y - box.maxY) < 1e-6
                #expect(onEdge, "cut point \(end) on the box edge")
            }
        }
    }
}
