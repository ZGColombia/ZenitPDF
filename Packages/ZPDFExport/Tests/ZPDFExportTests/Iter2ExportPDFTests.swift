import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
@testable import ZPDFExport

/// Iteration 2: the review items S-061 … S-072. Each test says
/// what the code before the fix did. A "trap" is a Swift runtime trap — the test process dies
/// with SIGTRAP, which `try?` in the shipping code never caught.
@Suite("Iteration 2 — PDF export", .sharedHeap, .serialized)
struct Iter2ExportPDFTests {

    // MARK: - S-061: inline image /BPC

    /// `q BI /W 2 /H 1 /BPC <bits> /CS /G ID AB EI Q` as bytes.
    static func inlineImage(bits: String) -> Data {
        Data("q BI /W 2 /H 1 /BPC \(bits) /CS /G ID ".utf8) + Data([0x41, 0x42]) + Data(" EI Q".utf8)
    }

    @Test("S-061: an inline image with /BPC -8000 or Int.max is read by its EI, not by a negative or overflowing length")
    func inlineImageBitsAreBounded() throws {
        // Old, -8000: (2 × 1 × -8000 + 7) / 8 × 1 = -1999 passed `expected <= count - start`, and the
        // probe parser started at a negative index: out-of-range trap.
        // Old, Int.max: 2 × 1 × Int.max overflowed: arithmetic trap.
        for bits in ["-8000", "9223372036854775807", "3", "0"] {
            let operations = try RedactionContentLexer.parse(Self.inlineImage(bits: bits))
            #expect(operations.map(\.name) == ["q", "BI", "Q"], "BPC \(bits)")
            #expect(operations[1].inlineImage?.data == Data([0x41, 0x42]), "BPC \(bits)")
        }
        #expect(RedactionInlineImageKeys.unfilteredLength(["W": .integer(2), "H": .integer(1), "BPC": .integer(-8000), "CS": .name("G")]) == nil)
        #expect(RedactionInlineImageKeys.unfilteredLength(["W": .integer(2), "H": .integer(1), "BPC": .integer(Int.max), "CS": .name("G")]) == nil)
        // A valid depth still gives the stated length: 3 × 1 component × 16 bits = 48 bits = 6 bytes per row.
        #expect(RedactionInlineImageKeys.unfilteredLength(["W": .integer(3), "H": .integer(2), "BPC": .integer(16), "CS": .name("G")]) == 12)
    }

    // MARK: - S-062: TIFF predictor Columns × Colors

    @Test("S-062: a TIFF predictor whose Columns × Colors overflows is refused, and a sane one still decodes")
    func tiffPredictorIsBounded() throws {
        let payload = try #require(PDFStreamCodec.flateEncode(Data([1, 2, 3, 4])))
        func dictionary(columns: Int, colors: Int) -> [String: PDFObject] {
            ["Filter": .name("FlateDecode"),
             "DecodeParms": .dictionary(["Predictor": .integer(2), "Columns": .integer(columns), "Colors": .integer(colors)])]
        }
        // Old: 4611686018427387904 × 4 = 2^64, an arithmetic trap before the first byte.
        #expect(throws: RedactionUnsupported.self) {
            try RedactionStreamFilters.decode(dictionary: dictionary(columns: 4_611_686_018_427_387_904, colors: 4), data: payload)
        }
        #expect(throws: RedactionUnsupported.self) {
            try RedactionStreamFilters.decode(dictionary: dictionary(columns: 2, colors: 33), data: payload)
        }
        // Rows of two one-colour samples: [1, 1+2] and [3, 3+4].
        #expect(try RedactionStreamFilters.decode(dictionary: dictionary(columns: 2, colors: 1), data: payload).data == Data([1, 3, 3, 7]))
    }

    // MARK: - S-063: CIDs past UInt32

    @Test("S-063: a /W array naming a CID past UInt32 or overflowing first + offset is refused")
    func widthArrayCIDsAreBounded() throws {
        let identity: (PDFObject?) -> PDFObject? = { $0 }
        // Old: UInt32(4294967296) — a conversion trap.
        #expect(throws: RedactionUnsupported.self) {
            try RedactionFont.readW([.integer(4_294_967_296), .array([.integer(500)])], resolve: identity)
        }
        // Old: Int.max + 1 — an arithmetic trap.
        #expect(throws: RedactionUnsupported.self) {
            try RedactionFont.readW([.integer(Int.max), .array([.integer(500), .integer(600)])], resolve: identity)
        }
        #expect(throws: RedactionUnsupported.self) {
            try RedactionFont.readW([.integer(0), .integer(4_294_967_296), .integer(500)], resolve: identity)
        }
        let (explicit, ranges) = try RedactionFont.readW(
            [.integer(1), .array([.integer(500)]), .integer(10), .integer(20), .integer(600)], resolve: identity
        )
        #expect(explicit == [1: 500])
        #expect(ranges.count == 1 && ranges[0].0 == 10 && ranges[0].1 == 20 && ranges[0].2 == 600)
    }

    @Test("S-063: a CMap entry with a CID past UInt32 is skipped, and a range that would carry past it maps nothing")
    func cmapCIDsAreBounded() throws {
        let text = """
        /CIDInit /ProcSet findresource begin
        1 begincodespacerange <00> <FF> endcodespacerange
        2 begincidrange <00> <0F> 4294967296 <10> <1F> 7 endcidrange
        1 begincidchar <20> 99999999999 endcidchar
        1 begincidrange <30> <3F> 4294967295 endcidrange
        """
        // Old: UInt32(4294967296) in the cidrange case — a conversion trap while the font was read.
        let map = try RedactionCMap(Data(text.utf8))
        func code(_ value: UInt32) -> RedactionFont.Code { RedactionFont.Code(value: value, length: 1) }
        #expect(map.cid(for: code(0x05)) == nil, "the out-of-range entry was skipped")
        #expect(map.cid(for: code(0x15)) == 12, "7 + (0x15 − 0x10)")
        #expect(map.cid(for: code(0x20)) == nil)
        #expect(map.cid(for: code(0x30)) == 4_294_967_295)
        // Old: 4294967295 + 1 in UInt32 — an arithmetic trap on the second code of the range.
        #expect(map.cid(for: code(0x31)) == nil)
    }

    // MARK: - S-064: CFF and Type 1 offsets

    /// A one-font CFF program: header, Name INDEX ("A"), the Top DICT, empty String and Global
    /// Subr INDEXes, then `tail` (a Top DICT offset points into it).
    static func cff(topDict: [UInt8], tail: [UInt8] = []) -> [UInt8] {
        let header: [UInt8] = [1, 0, 4, 1]
        let names: [UInt8] = [0, 1, 1, 1, 2, 0x41]
        let tops: [UInt8] = [0, 1, 1, 1, UInt8(topDict.count + 1)] + topDict
        return header + names + tops + [0, 0] + [0, 0] + tail
    }

    @Test("S-064: CFF offsets below zero and Type 1 lengths that overflow are refused, not indexed")
    func fontProgramOffsetsAreBounded() throws {
        // Old: `start + 2 <= count` held for -1, then bytes[-1] — an out-of-range trap.
        #expect(throws: RedactionUnsupported.self) { try RedactionCFF.readIndex([0, 1, 1, 1, 2, 65], at: -1) }

        // CharStrings at -5 (operator 28, 0xFFFB).
        let negativeCharStrings = Self.cff(topDict: [28, 0xFF, 0xFB, 17])
        #expect(negativeCharStrings.count == 23)
        #expect(throws: RedactionUnsupported.self) { try RedactionCFF.parse(negativeCharStrings) }

        // A CID-keyed font whose FDSelect is at -3: ROS, CharStrings at 44, FDArray at 50.
        // Top DICT 25 bytes → its INDEX ends at 40; String and Global Subr INDEXes end at 44.
        let top: [UInt8] = [28, 0, 0, 28, 0, 0, 28, 0, 0, 12, 30, 28, 0, 44, 17, 28, 0, 50, 12, 36, 28, 0xFF, 0xFD, 12, 37]
        let charStrings: [UInt8] = [0, 1, 1, 1, 2, 14]
        let fdArray: [UInt8] = [0, 1, 1, 1, 1]
        let cidKeyed = Self.cff(topDict: top, tail: charStrings + fdArray)
        #expect(cidKeyed.count == 55)
        #expect(Array(cidKeyed[44..<50]) == charStrings)
        // Old: `selectOffset < count` held for -3, then bytes[-3] — an out-of-range trap.
        #expect(throws: RedactionUnsupported.self) { try RedactionCFF.parse(cidKeyed) }
        // The same program with FDSelect at 55 (format 0, one glyph, FD 0) parses. The Top DICT
        // starts at 15, so its FDSelect operand is bytes 35…37.
        var sound = cidKeyed
        #expect(Array(sound[35..<38]) == [28, 0xFF, 0xFD])
        sound.replaceSubrange(35..<38, with: [28, 0, 55])
        sound += [0, 0]
        #expect(try RedactionCFF.parse(sound).fdSelect == [0])
        // FDSelect format 3 (iteration-2 re-fix): nRanges 1, first 5, FD 0, sentinel 10, for a
        // one-glyph font. Old: `first..<min(max(first, next), count)` = 5..<1 — "Range requires
        // lowerBound <= upperBound", a trap. A range past the glyph count selects nothing.
        var ranged = sound
        ranged.replaceSubrange(55..<57, with: [3, 0, 1, 0, 5, 0, 0, 10])
        #expect(try RedactionCFF.parse(ranged).fdSelect == [0])
        // A range that ends before it starts (first 1, sentinel 0) selects nothing either.
        ranged.replaceSubrange(55..<63, with: [3, 0, 1, 0, 1, 0, 0, 0])
        #expect(try RedactionCFF.parse(ranged).fdSelect == [0])
        // The sound format 3 twin (first 0, FD 0, sentinel 1) parses, and a truncated one is refused.
        ranged.replaceSubrange(55..<63, with: [3, 0, 1, 0, 0, 0, 0, 1])
        #expect(try RedactionCFF.parse(ranged).fdSelect == [0])
        #expect(throws: RedactionUnsupported.self) { try RedactionCFF.parse(Array(ranged.dropLast())) }

        // Old: 1 + Int.max — an arithmetic trap in the length check.
        #expect(throws: RedactionUnsupported.self) {
            try RedactionType1.prune([UInt8](repeating: 0, count: 16), length1: 1, length2: Int.max, keepNames: [], keepCodes: [])
        }
        #expect(throws: RedactionUnsupported.self) {
            try RedactionType1.prune([UInt8](repeating: 0, count: 16), length1: Int.max, length2: 1, keepNames: [], keepCodes: [])
        }
    }

    // MARK: - S-065: image placements near singular

    @Test("S-065: blanking an image placed by 1000 0 0 1e-14 x y cm does not convert 1e20 to Int")
    func nearSingularImagePlacement() {
        let layout = RedactionImages.Layout(width: 4, height: 4, bitsPerComponent: 8, components: 1, blank: [0])
        let placement = CGAffineTransform(a: 1000, b: 0, c: 0, d: 1e-14, tx: 100, ty: 100)
        #expect(abs(placement.a * placement.d - placement.b * placement.c) > 1e-12, "passes the rewriter's determinant guard")
        let box = CGRect(x: 0, y: -1e6, width: 2000, height: 2e6)
        // Old: the inverse scaled v by 1e14, so (1 − maxV) × 4 ≈ -4e20 and Int(Double) trapped.
        var bytes = [UInt8](repeating: 0xFF, count: 16)
        #expect(RedactionImages.blank(&bytes, layout: layout, placement: placement, boxes: [box]) == 16, "every centre lies in the box")
        #expect(bytes == [UInt8](repeating: 0, count: 16))
        // The copy cut to one placement: the same conversion (old: trap); every cell meets the rectangle.
        var kept = [UInt8](repeating: 0xFF, count: 16)
        #expect(RedactionImages.blank(&kept, layout: layout, placement: placement, outside: box) == 0)
        #expect(kept == [UInt8](repeating: 0xFF, count: 16))
        // A non-finite corner scans the whole image.
        let bounds = RedactionImages.unitBounds([CGPoint(x: Double.nan, y: 0), CGPoint(x: 1, y: 1)])
        #expect(bounds.minU == -1 && bounds.maxU == 2 && bounds.minV == -1 && bounds.maxV == 2)
    }

    @Test("S-065: a tiling step just above the guard against a wide area is many tiles, not an Int trap")
    func tileIndicesAreBounded() {
        let corners = [CGPoint(x: -1e6, y: -1e6), CGPoint(x: 1e6, y: 1e6)]
        // Old (rewriter and read-back): 1e6 / 1e-8 = 1e14 fits, but 1e12 / 1e-8 = 1e20 trapped.
        let wide = [CGPoint(x: -1e12, y: 0), CGPoint(x: 1e12, y: 1)]
        let cell = CGRect(x: 0, y: 0, width: 10, height: 10)
        #expect(RedactionGeometry.tileCover(corners: wide, cell: cell, xStep: 1e-8, yStep: 10) == .many)
        #expect(RedactionGeometry.tileCover(corners: corners, cell: cell, xStep: 1e-8, yStep: 1e-8) == .many)
        // One tile, the one at (2, 0): its cell spans x 20…30.
        #expect(RedactionGeometry.tileCover(corners: [CGPoint(x: 22, y: 2), CGPoint(x: 28, y: 8)], cell: cell, xStep: 10, yStep: 10) == .one(2, 0))
        #expect(RedactionGeometry.tileCover(corners: [CGPoint(x: 12, y: 2), CGPoint(x: 28, y: 8)], cell: cell, xStep: 10, yStep: 10) == .many)
    }

    // MARK: - S-067: mitred corners reach past half the width

    @Test("S-067: the stroke reach is 1/sin(θ/2) at a mitred corner within the limit, √2 for square caps, 1 otherwise")
    func strokeReach() {
        func path(_ points: [CGPoint], closed: Bool = false) -> RedactionSubpath {
            RedactionSubpath(start: points[0], segments: zip(points, points.dropFirst()).map { .line($0, $1) }, closed: closed)
        }
        let square = path([CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 0, y: 10)], closed: true)
        // Right angles: 1 / sin(45°) = √2.
        #expect(abs(RedactionGeometry.strokeReach([square], lineCap: 0, lineJoin: 0, miterLimit: 10) - 2.0.squareRoot()) < 1e-12)
        let corner = path([CGPoint(x: 100, y: 500), CGPoint(x: 300, y: 500), CGPoint(x: 100, y: 500 + 200 * tan(20 * Double.pi / 180))])
        let expected = 1 / sin(10 * Double.pi / 180)  // 5.7588
        #expect(abs(RedactionGeometry.strokeReach([corner], lineCap: 0, lineJoin: 0, miterLimit: 10) - expected) < 1e-9)
        // Past the limit the corner is bevelled; round and bevel joins stay within half the width.
        #expect(RedactionGeometry.strokeReach([corner], lineCap: 0, lineJoin: 0, miterLimit: 4) == 1)
        #expect(RedactionGeometry.strokeReach([corner], lineCap: 0, lineJoin: 1, miterLimit: 10) == 1)
        #expect(RedactionGeometry.strokeReach([corner], lineCap: 0, lineJoin: 2, miterLimit: 10) == 1)
        // The same 20° corner at the start vertex: open, only the right angle at (100, 500)
        // joins (√2); closed, the closing join and the start join count (1/sin 10°).
        let triangle = [CGPoint(x: 300, y: 500), CGPoint(x: 100, y: 500), CGPoint(x: 100, y: 500 + 200 * tan(20 * Double.pi / 180))]
        #expect(abs(RedactionGeometry.strokeReach([path(triangle)], lineCap: 0, lineJoin: 0, miterLimit: 10) - 2.0.squareRoot()) < 1e-12)
        #expect(abs(RedactionGeometry.strokeReach([path(triangle, closed: true)], lineCap: 0, lineJoin: 0, miterLimit: 10) - expected) < 1e-9)
        let line = path([CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0)])
        #expect(RedactionGeometry.strokeReach([line], lineCap: 0, lineJoin: 0, miterLimit: 10) == 1)
        #expect(abs(RedactionGeometry.strokeReach([line], lineCap: 2, lineJoin: 0, miterLimit: 10) - 2.0.squareRoot()) < 1e-12)
        // The largest singular value of a shear [1 0; 1 1] is the golden ratio; the old estimate
        // (the longer column) was √2.
        #expect(abs(RedactionGeometry.largestStretch(CGAffineTransform(a: 1, b: 0, c: 1, d: 1, tx: 0, ty: 0)) - (1 + 5.0.squareRoot()) / 2) < 1e-12)
        #expect(abs(RedactionGeometry.largestStretch(CGAffineTransform(scaleX: 3, y: -2)) - 3) < 1e-12)
    }

    @Test("S-067: a 4 pt line with a 20° mitred corner 5 pt from a box is cut, and Keep Sharp succeeds")
    func mitredCornerBesideABox() throws {
        let folder = try RedactionProof.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("corner.pdf"), output = folder.appendingPathComponent("corner redacted.pdf")
        // Vertex (300, 500); the mitre's tip reaches 2 × 5.7588 = 11.5 pt past it, to x ≈ 311.3.
        let data = RedactionFixturePDF.assemble(pageCount: 1) { _, _ in
            ([HardeningPage("q 4 w 0 j 10 M 0 0 0 RG 100 500 m 300 500 l 100 572.794 l S Q", resources: "<< >>")], "")
        }
        try data.write(to: source)
        let box = CGRect(x: 305, y: 470, width: 60, height: 60)
        // Old: checkFailed("something is still painted under a box on sheet 1") — the hull grew by
        // 4 / 2 + 1 = 3 pt to x = 303, short of the box, so the spike was copied uncut.
        let outcome = try VectorRedactor.redact(source: source, marks: [RedactionMark(pageIndex: 0, rect: box)], to: output)
        #expect(outcome.vectorPages == [0])
        let render = try HardeningProof.coreGraphicsRender(output, page: 0)
        // Inside the 4 pt ink (y 498…502) of the first leg, well away from the box.
        let lineOutside = CGRect(x: 150, y: 499.2, width: 100, height: 1.6).applying(render.transform).standardized
        #expect(HardeningProof.brightestMean(render.bitmap, inside: lineOutside) < 60, "the line is still drawn outside the box")
    }

    @Test("S-067: s, b and b* close the path before its reach is measured — a 20° corner at the start vertex beside a box",
          arguments: ["s", "b", "b*"])
    func closedCornerBesideABox(close: String) throws {
        let folder = try RedactionProof.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("closed.pdf"), output = folder.appendingPathComponent("closed redacted.pdf")
        // The path starts at the vertex (300, 500); only the closing segment back to it makes the
        // 20° corner, whose mitre tip reaches 2 × 5.7588 = 11.5 pt past it, to x ≈ 311.5. The fill
        // of b and b* is white, so the only ink under the box is the stroke's mitre.
        let fill = close == "s" ? "" : "1 1 1 rg "
        let data = RedactionFixturePDF.assemble(pageCount: 1) { _, _ in
            ([HardeningPage("q 4 w 0 j 10 M 0 0 0 RG \(fill)300 500 m 100 500 l 100 572.794 l \(close) Q", resources: "<< >>")], "")
        }
        try data.write(to: source)
        let box = CGRect(x: 305, y: 470, width: 60, height: 60)
        // Old: paint() closed only its local copy of the path, after the touched test, so the
        // reach was √2 (the open path's right angle), the hull stopped at x ≈ 303.8 and the mitre
        // was copied uncut: checkFailed("something is still painted under a box on sheet 1").
        let outcome = try VectorRedactor.redact(source: source, marks: [RedactionMark(pageIndex: 0, rect: box)], to: output)
        #expect(outcome.vectorPages == [0], "Keep Sharp keeps the vector page (\(close))")
        let render = try HardeningProof.coreGraphicsRender(output, page: 0)
        // Inside the 4 pt ink (y 498…502) of the bottom leg, well away from the box.
        let lineOutside = CGRect(x: 150, y: 499.2, width: 100, height: 1.6).applying(render.transform).standardized
        #expect(HardeningProof.brightestMean(render.bitmap, inside: lineOutside) < 60, "the line is still drawn outside the box (\(close))")
        // And the closing leg, from (100, 572.8) back towards the vertex, is still drawn.
        let closingLeg = CGRect(x: 198, y: 535.4, width: 4, height: 1.8).applying(render.transform).standardized
        #expect(HardeningProof.brightestMean(render.bitmap, inside: closingLeg) < 60, "the closing leg is still drawn (\(close))")
    }

    // MARK: - S-068: decomposed accents in Windows-1252 profiles

    @Test("S-068: a Windows-1252 profile writes a decomposed ö or é as one byte, and still names a character it lacks")
    func windows1252ComposesFirst() throws {
        let projection = try ExportFixture.projection(try ExportFixture.goldenReport())
        var profile = LedgerExportProfile(name: "Code page", columns: [.init(key: "subject", header: "Zo\u{0308}e Cafe\u{0301}")],
                                          encoding: .windows1252, lineEnding: .crlf)
        // Old: ProfileError.notEncodable(character: "\u{0308}") — scalar by scalar, the combining
        // diaeresis has no byte.
        let bytes = [UInt8](try profile.renderDetailed(projection).data)
        #expect(Array(bytes.prefix(10)) == [0x5A, 0xF6, 0x65, 0x20, 0x43, 0x61, 0x66, 0xE9, 0x0D, 0x0A], "Z ö e space C a f é CR LF")
        #expect(try profile.encode("Zöe Café") == Data([0x5A, 0xF6, 0x65, 0x20, 0x43, 0x61, 0x66, 0xE9]))
        profile.columns[0].header = "Ω"
        #expect(throws: LedgerExportProfile.ProfileError.notEncodable(character: "Ω")) { try profile.renderDetailed(projection) }
    }

    // MARK: - S-069: a total's label never takes a quantity's place

    static func profile(_ columns: [LedgerExportProfile.Column]) -> LedgerExportProfile {
        var profile = LedgerExportProfile(name: "Quantity first", columns: columns,
                                          delimiter: ";", decimalSeparator: ",", encoding: .utf8, lineEnding: .lf)
        profile.grouping = .init(key: "subject", subtotals: true, subtotalLabel: "{group} subtotal",
                                 grandTotal: true, grandTotalLabel: "Total")
        return profile
    }

    @Test("S-069: with a quantity first, the grand total's label goes to the first text column and the sum stays")
    func quantityFirstKeepsItsTotal() throws {
        let projection = try ExportFixture.projection(try ExportFixture.goldenReport())
        let profile = Self.profile([
            .init(key: "planArea", header: "Plan area ft2", decimals: 3, unit: "ft2"),
            .init(key: "subject", header: "Subject"),
            .init(key: "footprint", header: "Footprint m2", decimals: 1, unit: "m2"),
        ])
        // The values are ProfileUnitsAndGroupingTests' hand-derived reference: plan areas (i+1)/8 m²
        // in ft² (÷ 0.09290304), subtotals and the total from the stored values converted once.
        // Old last line: "Total;;210,0" — the label sat in planArea's column and 28,255 was lost.
        let reference = """
        Plan area ft2;Subject;Footprint m2
        1,345;Concrete;10,0
        4,036;Concrete;30,0
        6,727;Concrete;50,0
        12,109;Concrete subtotal;90,0
        2,691;Steel;20,0
        5,382;Steel;40,0
        8,073;Steel;60,0
        16,146;Steel subtotal;120,0
        28,255;Total;210,0

        """
        #expect(String(decoding: try profile.renderDetailed(projection).data, as: UTF8.self) == reference)
    }

    @Test("S-069: when every column is a quantity, subtotal and total rows keep all their sums and drop the label")
    func allQuantityColumnsKeepEverySum() throws {
        let projection = try ExportFixture.projection(try ExportFixture.goldenReport())
        let profile = Self.profile([
            .init(key: "planArea", header: "Plan area ft2", decimals: 3, unit: "ft2"),
            .init(key: "footprint", header: "Footprint m2", decimals: 1, unit: "m2"),
        ])
        // Old: "Concrete subtotal;90,0", "Steel subtotal;120,0" and "Total;210,0" — each label
        // overwrote the plan-area sum (12,109, 16,146, 28,255).
        let reference = """
        Plan area ft2;Footprint m2
        1,345;10,0
        4,036;30,0
        6,727;50,0
        12,109;90,0
        2,691;20,0
        5,382;40,0
        8,073;60,0
        16,146;120,0
        28,255;210,0

        """
        #expect(String(decoding: try profile.renderDetailed(projection).data, as: UTF8.self) == reference)
    }

    // MARK: - S-070: the PDF report cover wraps

    @Test("S-070: the PDF report's cover carries the whole scale notice, wrapped inside the margin")
    func coverWrapsTheScaleNotice() throws {
        let projection = try Iter1ExportFixTests.staleProjection()
        let notice = try #require(projection.table.metadata.staleScaleNotice)
        let url = temporaryURL("pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try PDFReportRenderer().render(projection, to: url)
        #expect(result.rightMarginOverrun == 0)
        let cover = try #require(PDFDocument(url: url)?.page(at: 0)?.string)
        func flattened(_ text: String) -> String {
            text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        }
        // Old: one line cut at about 95 characters with "…"; "recalculated" and the remedy were missing.
        #expect(flattened(cover).contains(flattened(notice)))
        #expect(cover.contains("Recalculate Stale Measurements"))

        let font = CTFontCreateWithName("Helvetica" as CFString, 8, nil)
        let lines = Painter.wrapped(notice, font: font, maxWidth: 415)
        #expect(lines.count >= 2, "\(lines)")
        #expect(lines.allSatisfy { TextMeasure.width($0, font: font) <= 415 })
        #expect(lines.joined(separator: " ") == notice)
        #expect(Painter.wrapped("Rows\r\n\r\nsecond", font: font, maxWidth: 415) == ["Rows", "second"])
    }

    // MARK: - S-071: one preparation per redaction

    static func wallFixture(x: Int = 195) -> Data {
        RedactionFixturePDF.assemble(pageCount: 1) { _, _ in
            ([HardeningPage("q 20 w 0 0 0 RG \(x) 100 m \(x) 700 l S Q", resources: "<< >>")], "")
        }
    }

    @Test("S-071: the session redacts from the preparation its assessment made, and prepares again when anything changed")
    func sessionPreparesOnce() async throws {
        let folder = try RedactionProof.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("wall.pdf")
        try Self.wallFixture().write(to: source)
        let marks = [RedactionMark(pageIndex: 0, rect: CGRect(x: 200, y: 300, width: 100, height: 100))]

        let session = VectorRedactionSession()
        let assessment = await session.assess(source: source, marks: marks)
        #expect(assessment.vectorQualifies)
        #expect(await session.preparations == 1)
        let first = folder.appendingPathComponent("first.pdf")
        let outcome = try await session.redact(source: source, marks: marks, to: first)
        // Old (VectorRedactor.assess then .redact): two preparations for one Apply.
        #expect(await session.preparations == 1, "the copy was built from the assessment's preparation")
        #expect(outcome.vectorPages == [0])
        #expect(outcome.checks.count > 0)
        // Spent: a second redact prepares again.
        _ = try await session.redact(source: source, marks: marks, to: folder.appendingPathComponent("again.pdf"))
        #expect(await session.preparations == 2)

        // Other marks than those assessed: prepared afresh.
        _ = await session.assess(source: source, marks: marks)
        let moved = [RedactionMark(pageIndex: 0, rect: CGRect(x: 150, y: 300, width: 100, height: 100))]
        _ = try await session.redact(source: source, marks: moved, to: folder.appendingPathComponent("moved.pdf"))
        #expect(await session.preparations == 4)

        // The drawing changed on disk between the two: never redacted from the old bytes.
        _ = await session.assess(source: source, marks: marks)
        try Self.wallFixture(x: 400).write(to: source)
        let changed = folder.appendingPathComponent("changed.pdf")
        _ = try await session.redact(source: source, marks: marks, to: changed)
        #expect(await session.preparations == 6)
        let render = try HardeningProof.coreGraphicsRender(changed, page: 0)
        let newWall = CGRect(x: 395, y: 500, width: 10, height: 100).applying(render.transform).standardized
        #expect(HardeningProof.brightestMean(render.bitmap, inside: newWall) < 60, "the copy is of the drawing as it is now")

        // Discarded (the person cancelled): nothing is kept.
        _ = await session.assess(source: source, marks: marks)
        await session.discard()
        _ = try await session.redact(source: source, marks: marks, to: folder.appendingPathComponent("discarded.pdf"))
        #expect(await session.preparations == 8)
        // It refuses its source as the static entry point does.
        await #expect(throws: RedactionRefusal.self) { try await session.redact(source: source, marks: marks, to: source) }
    }

    @Test("S-071: measured — assess then redact through the session against the two static calls")
    func sessionMeasurement() async throws {
        let folder = try RedactionProof.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("sheets.pdf")
        // Three marked sheets of 200 wall lines each, so preparation is a large part of the work.
        let lines = (0..<200).map { "\(100 + 2 * $0) 100 m \(100 + 2 * $0) 700 l" }.joined(separator: " ")
        let data = RedactionFixturePDF.assemble(pageCount: 3) { _, _ in
            ((0..<3).map { _ in HardeningPage("q 0.5 w 0 0 0 RG \(lines) S Q", resources: "<< >>") }, "")
        }
        try data.write(to: source)
        let marks = (0..<3).map { RedactionMark(pageIndex: $0, rect: CGRect(x: 300, y: 300, width: 50, height: 50)) }
        let clock = ContinuousClock()
        let twice = try clock.measure {
            _ = VectorRedactor.assess(source: source, marks: marks)
            _ = try VectorRedactor.redact(source: source, marks: marks, to: folder.appendingPathComponent("static.pdf"))
        }
        let session = VectorRedactionSession()
        let start = clock.now
        _ = await session.assess(source: source, marks: marks)
        _ = try await session.redact(source: source, marks: marks, to: folder.appendingPathComponent("session.pdf"))
        let once = clock.now - start
        print("S-071 measurement: static assess + redact \(twice), session \(once), preparations \(await session.preparations)")
        #expect(await session.preparations == 1)
    }

    // MARK: - S-072: one CSV escaping rule

    @Test("S-072: the profile escapes every field exactly as the CSV exporter does")
    func profileEscapeIsTheExporters() {
        let fields = ["plain", "=cmd", "+1", "-2+3", "@x", "\tTab", "\rCR", "a;b", "a,b", "say \"hi\"", "line\r\nbreak",
                      " lead", "trail ", "-40.00", "", "ö"]
        for quoteAll in [false, true] {
            var profile = LedgerExportProfile(name: "P", columns: [], delimiter: ";", quoteAllFields: quoteAll)
            profile.quoteAllFields = quoteAll
            for field in fields {
                for isNumber in [false, true] {
                    let exporter = CSVExporter.escape(field, delimiter: ";", quoting: quoteAll ? .all : .minimal,
                                                      guardFormulas: isNumber ? .none : .apostrophe)
                    #expect(profile.escape(field, delimiter: ";", isNumber: isNumber) == exporter, "\(field) \(isNumber) \(quoteAll)")
                }
            }
        }
    }
}
