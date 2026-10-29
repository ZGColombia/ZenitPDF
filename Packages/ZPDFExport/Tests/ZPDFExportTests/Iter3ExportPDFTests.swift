import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import ZPDFExport

/// Iteration 3: the review items T-037 … T-045. Each test says
/// what the code before the fix did. A "trap" is a Swift runtime trap — the test process dies with
/// SIGTRAP, which `try?` in the shipping code never caught; a "hang" never returns.
@Suite("Iteration 3 — PDF export", .sharedHeap, .serialized)
struct Iter3ExportPDFTests {

    static func identity(_ object: PDFObject?) -> PDFObject? { object }

    // MARK: - T-037: /FirstChar and /Differences

    static func simpleFont(firstChar: Int, widths: [Int], encoding: PDFObject? = nil) -> [String: PDFObject] {
        var dictionary: [String: PDFObject] = [
            "Type": .name("Font"), "Subtype": .name("Type1"), "BaseFont": .name("Hostile"),
            "FirstChar": .integer(firstChar), "Widths": .array(widths.map { .integer($0) }),
        ]
        if let encoding { dictionary["Encoding"] = encoding }
        return dictionary
    }

    @Test("T-037: a /FirstChar outside 0…65535 is refused when the font is read, and a sane one still measures")
    func firstCharIsBounded() throws {
        // Old, Int.min: the font was read, then width(_:) computed Int(65) − Int.min — an
        // arithmetic trap on the first glyph measured.
        for first in [Int.min, -1, 0x1_0000, Int.max] {
            #expect(throws: RedactionUnsupported.self, "FirstChar \(first)") {
                try RedactionFont(dictionary: Self.simpleFont(firstChar: first, widths: [500]), resolve: Self.identity)
            }
        }
        // /FirstChar 65 /Widths [500 600]: A = 0.5 em, B = 0.6 em, C has no width and takes
        // /MissingWidth, which this font does not give: 0.
        let font = try RedactionFont(dictionary: Self.simpleFont(firstChar: 65, widths: [500, 600]), resolve: Self.identity)
        #expect(font.width(RedactionFont.Code(value: 65, length: 1)) == 0.5)
        #expect(font.width(RedactionFont.Code(value: 66, length: 1)) == 0.6)
        #expect(font.width(RedactionFont.Code(value: 67, length: 1)) == 0)
    }

    @Test("T-037: /Differences skips a code past 0…255 with its names and stops a run at 255")
    func differencesAreBounded() throws {
        // Old: code = Int.max, then `code += 1` — an arithmetic trap, while the font was read.
        let hostile: PDFObject = .dictionary(["Differences": .array([.integer(Int.max), .name("a"), .name("b")])])
        #expect(RedactionFont.differences(hostile.dictionaryValue, resolve: Self.identity).isEmpty)
        // Reached by every simple font through its Unicode table: old, a trap in init.
        let font = try RedactionFont(dictionary: Self.simpleFont(firstChar: 0, widths: [500], encoding: hostile), resolve: Self.identity)
        #expect(font.width(RedactionFont.Code(value: 0, length: 1)) == 0.5)
        // -5 /x is skipped with its name; 65 /A /B names 65 and 66; 254 /y /z /over names 254
        // and 255 and drops /over, which would be code 256; Int.min /q is skipped.
        let mixed: PDFObject = .dictionary(["Differences": .array([
            .integer(-5), .name("x"), .integer(65), .name("A"), .name("B"),
            .integer(254), .name("y"), .name("z"), .name("over"), .integer(Int.min), .name("q"),
        ])])
        #expect(RedactionFont.differences(mixed.dictionaryValue, resolve: Self.identity) == [65: "A", 66: "B", 254: "y", 255: "z"])
    }

    // MARK: - T-038: Type 1 lengths, lenIV and callothersubr

    /// An embedded Type 1 program: a clear part, the private part eexec-encrypted and written in
    /// hex (a form the reader accepts, and one no ciphertext byte can be mistaken for), and a
    /// trailer. Each charstring is encrypted with lenIV 4 unless `rawCharStrings`.
    static func type1(lenIV: String? = nil, charStrings: [(name: String, length: String?, commands: [UInt8])]) -> (bytes: [UInt8], length1: Int, length2: Int) {
        let clear = Array("%!PS-AdobeFont-1.0: Hostile 001\n/FontName /Hostile def\n/Encoding StandardEncoding def\ncurrentfile eexec\n".utf8)
        var plain = Array("abcd dup /Private 8 dict dup begin\n".utf8)
        if let lenIV { plain += Array("/lenIV \(lenIV) def\n".utf8) }
        plain += Array("2 index /CharStrings \(charStrings.count) dict dup begin\n".utf8)
        for entry in charStrings {
            let data = RedactionType1.encrypt([0, 0, 0, 0] + entry.commands, key: RedactionType1.charstringKey)
            plain += Array("/\(entry.name) \(entry.length ?? String(data.count)) RD ".utf8) + data + Array(" ND\n".utf8)
        }
        plain += Array("end\nend\nmark currentfile closefile\n".utf8)
        let hex = Array(RedactionType1.encrypt(plain, key: RedactionType1.eexecKey).map { String(format: "%02x", $0) }.joined().utf8)
        let trailer = Array("\n0000000000000000\ncleartomark\n".utf8)
        return (clear + hex + trailer, clear.count, hex.count)
    }

    /// `0 0 hsbw endchar`: a glyph that draws nothing.
    static let empty: [UInt8] = [139, 139, 13, 14]

    @Test("T-038: a program's own entry length, lenIV and callothersubr count are bounded, and a sound program still prunes")
    func type1ProgramIsBounded() throws {
        // Old: `dataStart + 9223372036854775807` in binary(after:length:) — an arithmetic trap.
        let long = Self.type1(charStrings: [(".notdef", nil, Self.empty), ("a", "9223372036854775807", Self.empty)])
        #expect(throws: RedactionUnsupported.self) {
            try RedactionType1.prune(long.bytes, length1: long.length1, length2: long.length2, keepNames: [], keepCodes: [])
        }
        // Old: /a is not kept, so its replacement charstring was
        // `Array(repeating: 0, count: 1000000000000) + …` — a terabyte allocation; the process died.
        for lenIV in ["1000000000000", "65", "-2"] {
            let program = Self.type1(lenIV: lenIV, charStrings: [(".notdef", nil, Self.empty), ("a", nil, Self.empty)])
            #expect(throws: RedactionUnsupported.self, "lenIV \(lenIV)") {
                try RedactionType1.prune(program.bytes, length1: program.length1, length2: program.length2, keepNames: [], keepCodes: [])
            }
        }
        // Old: .notdef (always traced) pushes 2^31 − 1 (255-encoded) and othersubr 0, then
        // callothersubr ran two billion O(n) `insert(_:at: 0)` calls — a hang, then no memory.
        let count: [UInt8] = [255, 0x7F, 0xFF, 0xFF, 0xFF, 139, 12, 16] + Self.empty
        let hostile = Self.type1(charStrings: [(".notdef", nil, count), ("a", nil, Self.empty)])
        #expect(throws: RedactionUnsupported.self) {
            try RedactionType1.prune(hostile.bytes, length1: hostile.length1, length2: hostile.length2, keepNames: [], keepCodes: [])
        }
        // A count of 3 with two arguments on the stack is refused too (old: two nils made up).
        let short = Self.type1(charStrings: [(".notdef", nil, [140, 141, 142, 139, 12, 16] + Self.empty)])
        #expect(throws: RedactionUnsupported.self) {
            try RedactionType1.prune(short.bytes, length1: short.length1, length2: short.length2, keepNames: [], keepCodes: [])
        }

        // Sound: flex's `0 1 callothersubr`, hint replacement's `3 1 3 callothersubr pop`, lenIV
        // -1 and 4 — /a kept, /b replaced by a glyph that draws nothing.
        let flex: [UInt8] = [139, 140, 12, 16] + [142, 140, 142, 12, 16, 12, 17] + Self.empty
        for lenIV in [nil, "4"] as [String?] {
            let sound = Self.type1(lenIV: lenIV, charStrings: [(".notdef", nil, Self.empty), ("a", nil, flex), ("b", nil, flex)])
            let result = try RedactionType1.prune(sound.bytes, length1: sound.length1, length2: sound.length2, keepNames: ["a"], keepCodes: [])
            let privatePart = RedactionType1.decrypt(Array(result.bytes[result.length1..<(result.length1 + result.length2)]), key: RedactionType1.eexecKey)
            let text = String(decoding: privatePart, as: UTF8.self)
            #expect(text.contains("/a 19 RD "), "the kept glyph keeps its 4 + 15 bytes")
            #expect(text.contains("/b 8 RD "), "the removed glyph is 4 + 4 bytes: 0 0 hsbw endchar")
        }
    }

    // MARK: - T-039: Tr converted with Int(Double)

    @Test("T-039: a Tr operand of 1e20, 400 digits, 8 or -1 sends the sheet to the raster path; 0…7 keeps it vector")
    func renderModeIsBounded() throws {
        let folder = try RedactionProof.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let mark = RedactionMark(pageIndex: 0, rect: CGRect(x: 200, y: 300, width: 100, height: 100))
        func assess(_ operand: String, _ name: String) throws -> RedactionAssessment {
            let source = folder.appendingPathComponent("\(name).pdf")
            try RedactionFixturePDF.assemble(pageCount: 1) { _, _ in
                ([HardeningPage("q 20 w 0 0 0 RG 400 100 m 400 700 l S Q BT \(operand) Tr ET", resources: "<< >>")], "")
            }.write(to: source)
            return VectorRedactor.assess(source: source, marks: [mark])
        }
        // Old: `99999999999999999999` lexes as the real 1e20 and a 400-digit run as +inf, and
        // `Int(number(0))` trapped on both during pass 1.
        for (index, operand) in ["99999999999999999999", String(repeating: "9", count: 400), "8", "-1"].enumerated() {
            let assessment = try assess(operand, "hostile-\(index)")
            #expect(assessment.fallbacks.map(\.pageIndex) == [0], "Tr \(operand.prefix(24))")
            #expect(assessment.fallbacks.first?.reason.contains("render mode") == true)
        }
        for (index, operand) in ["0", "3", "7", "2.0"].enumerated() {
            #expect(try assess(operand, "sound-\(index)").vectorQualifies, "Tr \(operand)")
        }
    }

    // MARK: - T-040: step 6 on a box under one pixel

    @Test("T-040: the whole-pixel span of a sub-pixel, an edge and an off-bitmap rect is empty or clipped, never a reversed range")
    func wholePixelSpan() {
        // Old: max(0, Int(100.2.rounded(.up)))..<min(height, Int(100.8.rounded(.down))) = 101..<100,
        // "Range requires lowerBound <= upperBound" — a trap.
        #expect(VectorRedactor.wholePixelSpan(of: CGRect(x: 10, y: 100.2, width: 20, height: 0.6), width: 850, height: 1100) == nil)
        #expect(VectorRedactor.wholePixelSpan(of: CGRect(x: 100.2, y: 10, width: 0.6, height: 20), width: 850, height: 1100) == nil)
        // Wholly past the right edge (old: 900..<850, a trap) and wholly above the top.
        #expect(VectorRedactor.wholePixelSpan(of: CGRect(x: 900, y: 10, width: 50, height: 20), width: 850, height: 1100) == nil)
        #expect(VectorRedactor.wholePixelSpan(of: CGRect(x: 10, y: -80, width: 50, height: 20), width: 850, height: 1100) == nil)
        #expect(VectorRedactor.wholePixelSpan(of: CGRect(x: 1e300, y: 0, width: .infinity, height: 20), width: 850, height: 1100) == nil)
        // Pixels 11…14 lie wholly inside 10.5…15.5; a rect over the corner is clipped to 0…19.
        let inner = VectorRedactor.wholePixelSpan(of: CGRect(x: 10.5, y: 20.5, width: 5, height: 5), width: 850, height: 1100)
        #expect(inner?.columns == 11..<15 && inner?.rows == 21..<25)
        let corner = VectorRedactor.wholePixelSpan(of: CGRect(x: -50, y: -10, width: 70, height: 30), width: 850, height: 1100)
        #expect(corner?.columns == 0..<20 && corner?.rows == 0..<20)
    }

    @Test("T-040: Keep Sharp on a 3.2 pt box at a fractional pixel offset, and on one outside the crop box, does not trap")
    func thinBoxAndOffCropBox() throws {
        let folder = try RedactionProof.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("thin.pdf")
        try Iter2ExportPDFTests.wallFixture(x: 400).write(to: source)
        let box = CGRect(x: 72.1, y: 300, width: 3.2, height: 100)
        // At 100 dpi a US Letter sheet is 850 px wide: x = 72.1 × 850/612 = 100.14 px, the box is
        // 4.44 px wide, and inset by 2 px on each side it spans 102.14…102.58 — no whole pixel.
        let page = try #require(PDFDocument(url: source)?.page(at: 0))
        let inset = box.applying(RasterRedactor.pixelTransform(for: page, dpi: 100, height: 1100)).standardized.insetBy(dx: 2, dy: 2)
        #expect(inset.width > 0 && inset.minX.rounded(.up) > inset.maxX.rounded(.down), "old: 103..<102, a trap")
        let outcome = try VectorRedactor.redact(source: source, marks: [RedactionMark(pageIndex: 0, rect: box)],
                                                to: folder.appendingPathComponent("thin redacted.pdf"))
        #expect(outcome.vectorPages == [0])

        // A box on the sheet but outside its 300 pt crop box (reachable through the public API):
        // old, 489..<417 in step 6 — a trap.
        let cropped = folder.appendingPathComponent("cropped.pdf")
        try RedactionFixturePDF.assemble(pageCount: 1) { _, _ in
            ([HardeningPage("q 20 w 0 0 0 RG 150 100 m 150 700 l S Q", resources: "<< >>", extras: "/CropBox [0 0 300 792]")], "")
        }.write(to: cropped)
        let outside = RedactionMark(pageIndex: 0, rect: CGRect(x: 350, y: 300, width: 50, height: 100))
        let croppedOutcome = try VectorRedactor.redact(source: cropped, marks: [outside], to: folder.appendingPathComponent("cropped redacted.pdf"))
        #expect(croppedOutcome.vectorPages == [0])
    }

    // MARK: - T-041, T-043: profiles over a row with display units of its own

    /// Two 3.81 m walls in an imperial project, the second shown in metres of its own
    /// (``Iter1RDisplayOverrideExportTests``): 3.81 / 0.3048 = 12.5 ft exactly, so the wall reads
    /// 12'-6" and the rebar row 3.81 m; together 7.62 m = 25 ft.
    static func overrideProfile(unit: String? = nil, decimals: Int? = nil, grouped: Bool) -> LedgerExportProfile {
        var profile = LedgerExportProfile(
            name: "Override", columns: [.init(key: "subject", header: "Subject"), .init(key: "planLength", header: "Length", decimals: decimals, unit: unit)],
            delimiter: ";", decimalSeparator: ".", encoding: .utf8, lineEnding: .lf
        )
        if grouped {
            profile.grouping = .init(key: "subject", subtotals: true, subtotalLabel: "{group} subtotal", grandTotal: true, grandTotalLabel: "Total")
        }
        return profile
    }

    static func lines(_ rendered: LedgerExportProfile.Rendered) -> [String] {
        String(decoding: rendered.data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    @Test("T-041: with no profile unit, the row shown in metres is written in the column's feet, like every other row")
    func profileRowInColumnUnit() throws {
        let projection = try Iter1RDisplayOverrideExportTests.projection()
        // Old: "Rebar;3.81" — metres, in a column whose other row is 12.5000 feet.
        let flat = try Self.overrideProfile(grouped: false).renderDetailed(projection)
        #expect(Set(Self.lines(flat)) == ["Subject;Length", "Wall;12.5000", "Rebar;12.5000"])
        #expect(flat.unitMismatchKeys.isEmpty)
        // Two places asked for: 12.5 ft on both rows (old: "Rebar;3.81").
        let twoPlaces = try Self.overrideProfile(decimals: 2, grouped: false).renderDetailed(projection)
        #expect(Set(Self.lines(twoPlaces)) == ["Subject;Length", "Wall;12.50", "Rebar;12.50"])
        // Without an override nothing changes.
        let plain = try Self.overrideProfile(grouped: false).renderDetailed(try Iter1RDisplayOverrideExportTests.projection(overrideSecond: false))
        #expect(Self.lines(plain) == ["Subject;Length", "Wall;12.5000", "Wall;12.5000"])
    }

    @Test("T-041, T-043: grouped, the subtotals and the grand total are in the column's unit and none goes blank")
    func profileTotalsAcrossDisplayUnits() throws {
        let projection = try Iter1RDisplayOverrideExportTests.projection()
        // Old: "Rebar;3.81", "Rebar subtotal;3.81" and "Total;" — the total silently blank.
        let feet = try Self.overrideProfile(grouped: true).renderDetailed(projection)
        let lines = Self.lines(feet)
        #expect(lines.first == "Subject;Length")
        #expect(lines.last == "Total;25.0000", "7.62 m = 25 ft")
        #expect(Set(lines) == ["Subject;Length", "Wall;12.5000", "Wall subtotal;12.5000", "Rebar;12.5000", "Rebar subtotal;12.5000", "Total;25.0000"])
        #expect(feet.unitMismatchKeys.isEmpty)

        // In metres by the profile: every cell converts from SI. Old: "Total;" — poisoned because
        // the rows' display units differed, though the SI sum 7.62 m is exact.
        let metres = try Self.overrideProfile(unit: "m", grouped: true).renderDetailed(projection)
        #expect(Set(Self.lines(metres)) == ["Subject;Length", "Wall;3.810", "Wall subtotal;3.810", "Rebar;3.810", "Rebar subtotal;3.810", "Total;7.620"])
        #expect(Self.lines(metres).last == "Total;7.620")
        #expect(metres.unitMismatchKeys.isEmpty)
    }

    @Test("T-041, T-043: a column whose unit no profile converts to leaves those cells and sums empty, and names the column")
    func profileUnconvertibleColumnIsNamed() throws {
        let base = try Iter1RDisplayOverrideExportTests.projection()
        let columns = base.table.columns.map { column in
            column.key != "planLength" ? column : ExportColumn(
                key: column.key, title: column.title, kind: column.kind, unitSymbol: "chain", decimalPlaces: column.decimalPlaces,
                numberFormatCode: column.numberFormatCode, aggregationSemantics: column.aggregationSemantics,
                formulaCanonicalText: column.formulaCanonicalText, columnID: column.columnID
            )
        }
        let table = ExportTable(columns: columns, groups: base.table.groups, rows: base.table.rows, grandTotals: base.table.grandTotals,
                                metadata: base.table.metadata, carriesRowTraces: base.table.carriesRowTraces,
                                carriesProvenanceLabels: base.table.carriesProvenanceLabels)
        let projection = ExportProjection(table: table, numberLocale: base.numberLocale)
        // Old: "12.5000" and "3.81" under a "chain" column, the total blank, nothing named.
        let rendered = try Self.overrideProfile(grouped: true).renderDetailed(projection)
        #expect(Set(Self.lines(rendered)) == ["Subject;Length", "Wall;", "Wall subtotal;", "Rebar;", "Rebar subtotal;", "Total;"])
        #expect(rendered.unitMismatchKeys == ["planLength"])
    }

    // MARK: - T-042: the printed report's heading over a row in other units

    @Test("T-042: the report heads a column of mixed units without a unit and prints each number with its own")
    func reportNamesEachRowsUnit() throws {
        let url = temporaryURL("pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let options = PDFReportOptions(includeCoverPage: false, recordsDrawnText: true)
        let result = try PDFReportRenderer().render(try Iter1RDisplayOverrideExportTests.projection(), to: url, options: options)
        // Old: "3.81" with no unit, under "planLength (ft)".
        #expect(result.drawnText.contains("3.81 m"))
        #expect(!result.drawnText.contains("3.81"))
        #expect(result.drawnText.contains("12'-6\""), "feet and inches name their units already")
        #expect(result.drawnText.contains("25'-0\""), "the grand total, in the project's units")
        let text = try #require(PDFDocument(url: url)?.page(at: 0)?.string)
        #expect(!text.contains("planLength (ft)"), "old: the heading named feet above a row in metres")
        #expect(text.contains("planLength"))
        #expect(text.contains("3.81 m"))

        // The widths are measured on the strings drawn: the heading without its unit.
        let body = CTFontCreateWithName(options.fontName as CFString, options.bodyFontSize, nil)
        let bold = CTFontCreateWithName(options.boldFontName as CFString, options.bodyFontSize, nil)
        let table = try Iter1RDisplayOverrideExportTests.projection().table
        let index = try #require(table.columns.firstIndex { $0.key == "planLength" })
        #expect(table.mixedUnitColumns() == [index])
        let widths = PDFReportRenderer.columnWidths(table: table, options: options, font: bold, bodyFont: body)
        let expected = max(TextMeasure.width("planLength", font: bold), TextMeasure.width("3.81 m", font: body),
                           TextMeasure.width("12'-6\"", font: body), TextMeasure.width("25'-0\"", font: bold)) + options.columnPadding * 2
        #expect(widths[index] == min(max(expected, options.minimumColumnWidth), options.maximumColumnWidth))
    }

    @Test("T-042: without an override the report keeps the heading's unit and prints the numbers bare")
    func reportWithoutOverrideUnchanged() throws {
        let url = temporaryURL("pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let projection = try Iter1RDisplayOverrideExportTests.projection(overrideSecond: false)
        #expect(projection.table.mixedUnitColumns().isEmpty)
        let result = try PDFReportRenderer().render(projection, to: url, options: PDFReportOptions(includeCoverPage: false, recordsDrawnText: true))
        #expect(result.drawnText.filter { $0 == "12'-6\"" }.count == 2)
        #expect(!result.drawnText.contains { $0.hasSuffix(" ft") })
        let text = try #require(PDFDocument(url: url)?.page(at: 0)?.string)
        #expect(text.contains("planLength (ft)"))
    }

    // MARK: - T-044: fixed-width fields past 2 GiB

    @Test("T-044: an offset of 3 000 000 000 is written in ten digits in every cross-reference and byte-range field")
    func offsetsPastTwoGiB() throws {
        // The old expression, for the record: `%d` reads 32 bits of the Int.
        #expect(String(format: "%010d", 3_000_000_000) == "-1294967296")
        #expect(PDFFixedWidthField.digits(3_000_000_000, width: 10) == "3000000000")
        #expect(PDFFixedWidthField.digits(15, width: 10) == "0000000015")
        #expect(PDFFixedWidthField.digits(10_000_000_000, width: 10) == nil, "eleven digits do not fit")
        #expect(PDFFixedWidthField.digits(-1, width: 10) == nil)

        // PDFIncrementalUpdate.table — old: "-1294967296 00001 n \n", 21 bytes.
        let table = try #require(PDFIncrementalUpdate.table(offsets: [5: 3_000_000_000, 6: 15], generations: [5: 1]))
        #expect(String(decoding: table, as: UTF8.self) == "xref\n0 1\n0000000000 65535 f \n5 2\n3000000000 00001 n \n0000000015 00000 n \n")
        #expect(PDFIncrementalUpdate.table(offsets: [5: 10_000_000_000]) == nil)
        #expect(PDFFixedWidthField.inUseEntry(offset: 3_000_000_000, generation: 0)?.utf8.count == 20)
        #expect(PDFFixedWidthField.inUseEntry(offset: 1, generation: 65_536) == nil)

        // The signature's /ByteRange — old: "[0000000000 -1294967296 …]", one character longer
        // than its placeholder, shifting every byte after it.
        let range = try #require(PDFFixedWidthField.byteRange(open: 3_000_000_000, after: 3_000_010_000, total: 3_100_000_000))
        #expect(range == "[0000000000 3000000000 3000010000 0099990000]")
        #expect(range.utf8.count == PDFSignatureWriter.rangePlaceholder.utf8.count)
        #expect(PDFFixedWidthField.byteRange(open: 10, after: 20, total: 10_000_000_021) == nil)

        // The page-label carrier and the DXF sheet writer format with %ld now.
        #expect(String(format: "%010ld %05ld n \n", 3_000_000_000, 0) == "3000000000 00000 n \n")
    }

    // MARK: - T-045: cmap subtables expanded without a bound

    static func be16(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
    static func be32(_ value: Int) -> [UInt8] { [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }

    /// A `cmap` whose `records` (platform, encoding, subtable index) point into `subtables`.
    static func cmap(records: [(platform: Int, encoding: Int, subtable: Int)], subtables: [[UInt8]]) -> RedactionTrueType.Font {
        var offsets: [Int] = []
        var offset = 4 + records.count * 8
        for table in subtables { offsets.append(offset); offset += table.count }
        var bytes = be16(0) + be16(records.count)
        for record in records { bytes += be16(record.platform) + be16(record.encoding) + be32(offsets[record.subtable]) }
        for table in subtables { bytes += table }
        return RedactionTrueType.Font(version: 0x0001_0000, tables: ["cmap": bytes])
    }

    static func format12(_ groups: [(start: Int, end: Int, glyph: Int)]) -> [UInt8] {
        var table = be16(12) + be16(0) + be32(16 + groups.count * 12) + be32(0) + be32(groups.count)
        for group in groups { table += be32(group.start) + be32(group.end) + be32(group.glyph) }
        return table
    }

    static func format4(_ segments: [(start: Int, end: Int, delta: Int)]) -> [UInt8] {
        let all = segments + [(0xFFFF, 0xFFFF, 1)]
        var table = be16(4) + be16(16 + all.count * 8) + be16(0) + be16(all.count * 2) + be16(0) + be16(0) + be16(0)
        for segment in all { table += be16(segment.end) }
        table += be16(0)
        for segment in all { table += be16(segment.start) }
        for segment in all { table += be16(segment.delta & 0xFFFF) }
        for _ in all { table += be16(0) }
        return table
    }

    @Test("T-045: overlapping format 12 groups and format 4 segments past a real font's codes are refused, not expanded")
    func characterMapsAreBounded() throws {
        // Old: 99 999 groups of 65 536 codes — 6.5 billion dictionary writes from a 1.2 MB table,
        // a hang and then no memory.
        let groups = Array(repeating: (start: 0, end: 0xFFFF, glyph: 1), count: 99_999)
        #expect(throws: RedactionUnsupported.self) {
            try RedactionTrueType.characterMaps(Self.cmap(records: [(3, 10, 0)], subtables: [Self.format12(groups)]))
        }
        // Old: 32 766 overlapping segments of 65 535 codes — about 2.1 billion iterations, a hang.
        let segments = Array(repeating: (start: 0, end: 0xFFFE, delta: 1), count: 32_766)
        #expect(throws: RedactionUnsupported.self) {
            try RedactionTrueType.characterMaps(Self.cmap(records: [(3, 1, 0)], subtables: [Self.format4(segments)]))
        }
        // The pruners reach it through glyphs(forSimpleCodes:) too.
        #expect(throws: RedactionUnsupported.self) {
            try RedactionTrueType.glyphs(forSimpleCodes: [65], font: Self.cmap(records: [(3, 1, 0)], subtables: [Self.format4(segments)]),
                                         names: [:], unicode: [:])
        }

        // Sound: A–Z → glyphs 1…26 (delta 1 − 0x41), and a format 12 group running past
        // U+10FFFF, of which only the codes up to U+10FFFF are read.
        let sound = Self.cmap(records: [(3, 1, 0), (3, 10, 1)], subtables: [
            Self.format4([(0x41, 0x5A, 1 - 0x41)]),
            Self.format12([(0x1F600, 0x1F602, 40), (0x10_FFF0, 0x11_0010, 100)]),
        ])
        let maps = try RedactionTrueType.characterMaps(sound)
        let bmp = try #require(maps[3 << 16 | 1]), full = try #require(maps[3 << 16 | 10])
        #expect(bmp.count == 26 && bmp[0x41] == 1 && bmp[0x5A] == 26)
        #expect(full[0x1F601] == 41)
        #expect(full[0x10_FFFF] == 115, "100 + (0x10FFFF − 0x10FFF0)")
        #expect(full[0x11_0000] == nil, "old: 33 codes, 0x110000…0x110010 among them")
        #expect(full.count == 3 + 16)
    }

    @Test("T-045: records sharing one subtable read it once but pay for every copy; distinct subtables share one budget")
    func characterMapBudgetIsShared() throws {
        // A format 12 table at its ceiling: 17 groups of 65 536 codes = 0x110000.
        let full = Self.format12((0..<17).map { (start: $0 * 0x1_0000, end: $0 * 0x1_0000 + 0xFFFF, glyph: 1) })
        // (0,4) and (3,10) naming one full table, as a real font does: one read and two copies,
        // 3 × 0x110000 of the 4 × 0x110000 budget.
        let pair = try RedactionTrueType.characterMaps(Self.cmap(records: [(0, 4, 0), (3, 10, 0)], subtables: [full]))
        #expect(pair.count == 2 && pair.values.allSatisfy { $0.count == 0x11_0000 })
        // Three records spend the budget exactly; a fourth is past it. The old rule charged only
        // the first read and let every further record copy the table for nothing.
        let three = try RedactionTrueType.characterMaps(Self.cmap(records: (0..<3).map { (0, $0, 0) }, subtables: [full]))
        #expect(three.count == 3 && three.values.allSatisfy { $0.count == 0x11_0000 })
        #expect(throws: RedactionUnsupported.self) {
            try RedactionTrueType.characterMaps(Self.cmap(records: (0..<4).map { (0, $0, 0) }, subtables: [full]))
        }
        // Five distinct copies: past the budget while they are read.
        #expect(throws: RedactionUnsupported.self) {
            try RedactionTrueType.characterMaps(Self.cmap(records: (0..<5).map { (0, $0, $0) }, subtables: Array(repeating: full, count: 5)))
        }
    }

    /// A TrueType program of `glyphs` empty outlines around `font`'s `cmap`, for `prune`.
    static func program(around font: RedactionTrueType.Font, glyphs: Int = 2) -> Data {
        RedactionTrueType.serialize(RedactionTrueType.Font(version: 0x0001_0000, tables: [
            "head": [UInt8](repeating: 0, count: 54), "maxp": be32(0x0000_5000) + be16(glyphs),
            "loca": [UInt8](repeating: 0, count: (glyphs + 1) * 2), "glyf": [], "cmap": font.tables["cmap"] ?? [],
        ]))
    }

    static func format6(first: Int, glyphs: [Int]) -> [UInt8] {
        var table = be16(6) + be16(10 + glyphs.count * 2) + be16(0) + be16(first) + be16(glyphs.count)
        for glyph in glyphs { table += be16(glyph) }
        return table
    }

    @Test("T-045 (re-check): thousands of records naming one full subtable are refused at once, by every entry point",
          .timeLimit(.minutes(1)))
    func characterMapRecordsAreBounded() throws {
        let full = Self.format12((0..<17).map { (start: $0 * 0x1_0000, end: $0 * 0x1_0000 + 0xFFFF, glyph: 1) })
        let clock = ContinuousClock()
        func refusedEverywhere(_ font: RedactionTrueType.Font) -> Duration {
            let program = Self.program(around: font)
            return clock.measure {
                #expect(throws: RedactionUnsupported.self) { try RedactionTrueType.characterMaps(font) }
                #expect(throws: RedactionUnsupported.self) {
                    try RedactionTrueType.glyphs(forSimpleCodes: [65], font: font, names: [:], unicode: [:])
                }
                #expect(throws: RedactionUnsupported.self) { try RedactionTrueType.prune(program, keep: [1]) }
            }
        }
        // Old, 65 535 records → one 220-byte table in a 525 KB cmap: one read, then 65 535 merges
        // of 1.1 million entries — about 7e10 dictionary writes, 1.8 TB — and as many again in
        // rebuiltCharacterMaps. 1 000 records was about 30 GB. Now refused by the record count,
        // before anything is read.
        for records in [1_000, 65_535] {
            let elapsed = refusedEverywhere(Self.cmap(records: (0..<records).map { (0, $0, 0) }, subtables: [full]))
            #expect(elapsed < .seconds(5), "\(records) records: \(elapsed)")
        }
        // At the record ceiling the budget refuses: one read and three copies spend it, the
        // fourth record is refused before it is copied.
        let atCeiling = refusedEverywhere(Self.cmap(records: (0..<64).map { (0, $0, 0) }, subtables: [full]))
        #expect(atCeiling < .seconds(30), "64 records: \(atCeiling)")

        // The record ceiling itself: 64 records naming A–Z are read, a 65th is refused.
        let small = Self.format4([(0x41, 0x5A, 1 - 0x41)])
        #expect(throws: RedactionUnsupported.self) {
            try RedactionTrueType.characterMaps(Self.cmap(records: (0..<65).map { (3, $0, 0) }, subtables: [small]))
        }
        let many = try RedactionTrueType.characterMaps(Self.cmap(records: (0..<64).map { (0, $0, 0) }, subtables: [small]))
        let alphabet = try #require(many[0])
        #expect(many.count == 64 && alphabet.count == 26 && many.values.allSatisfy { $0 == alphabet })
        // Rebuilt, the 64 records share one subtable again; the old writer wrote 64 copies.
        let rebuilt = try RedactionTrueType.rebuiltCharacterMaps(many, keep: Set(1...26))
        let offsets = Set((0..<64).map { Int(RedactionTrueType.u32(rebuilt, 4 + $0 * 8 + 4)) })
        #expect(offsets == [4 + 64 * 8] && rebuilt.count == 4 + 64 * 8 + (16 + 2 * 8))
        let back = try RedactionTrueType.characterMaps(RedactionTrueType.Font(version: 0x0001_0000, tables: ["cmap": rebuilt]))
        #expect(back.count == 64 && back.values.allSatisfy { $0 == alphabet })
    }

    @Test("T-045 (re-check): a rebuilt format 4 table needing more segments than its 16-bit length allows is refused, not trapped")
    func rebuiltFormat4IsBounded() throws {
        let ceiling = RedactionTrueType.format4SegmentCeiling
        #expect(ceiling == 8_189 && 16 + ceiling * 8 <= 0xFFFF && 16 + (ceiling + 1) * 8 > 0xFFFF)
        // Scattered codes naming one kept glyph take a segment each, plus the 0xFFFF end.
        func scattered(_ count: Int) -> [UInt32: [UInt32: Int]] {
            [3 << 16 | 1: Dictionary(uniqueKeysWithValues: (0..<count).map { (UInt32($0 * 2), 5) })]
        }
        let fits = try RedactionTrueType.rebuiltCharacterMaps(scattered(ceiling - 1), keep: [5])
        let back = try RedactionTrueType.characterMaps(RedactionTrueType.Font(version: 0x0001_0000, tables: ["cmap": fits]))
        #expect(back[3 << 16 | 1] == scattered(ceiling - 1)[3 << 16 | 1])
        // Old: UInt16(16 + 8 190 × 8) — a trap.
        #expect(throws: RedactionUnsupported.self) { try RedactionTrueType.rebuiltCharacterMaps(scattered(ceiling), keep: [5]) }

        // Through prune: a 131 KB format 6 table mapping codes 0…65 534 all to glyph 5, which the
        // page still draws. Old: 65 535 one-code segments, UInt16(524 304) — a trap.
        let hostile = Self.cmap(records: [(3, 1, 0)], subtables: [Self.format6(first: 0, glyphs: Array(repeating: 5, count: 0xFFFF))])
        #expect(throws: RedactionUnsupported.self) { try RedactionTrueType.prune(Self.program(around: hostile, glyphs: 6), keep: [5]) }
        // A sound program still prunes, its character map rebuilt.
        let sound = Self.cmap(records: [(3, 1, 0)], subtables: [Self.format4([(0x41, 0x44, 1 - 0x41)])])
        let pruned = try RedactionTrueType.prune(Self.program(around: sound, glyphs: 6), keep: [1, 2])
        let maps = try RedactionTrueType.characterMaps(RedactionTrueType.parse(pruned))
        #expect(maps[3 << 16 | 1] == [0x41: 1, 0x42: 2])
    }
}
