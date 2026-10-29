import CoreGraphics
import Foundation
import Testing
@testable import ZPDFDXF

/// NL-PLAT-05 acceptance. Every expected value is derived by hand from the fixture's numbers.
@Suite("DXF intake — NL-PLAT-05")
struct DXFIntakeTests {

    /// Builds an ASCII DXF: header with `$INSUNITS`, a LAYER table, one block, and entities.
    static func dxf(units: Int? = 4, layers: [String], blocks: String = "", entities: String) -> Data {
        var text = "0\nSECTION\n2\nHEADER\n"
        if let units { text += "9\n$INSUNITS\n70\n\(units)\n" }
        text += "0\nENDSEC\n0\nSECTION\n2\nTABLES\n0\nTABLE\n2\nLAYER\n70\n\(layers.count)\n"
        for layer in layers { text += "0\nLAYER\n2\n\(layer)\n70\n0\n62\n7\n6\nCONTINUOUS\n" }
        text += "0\nENDTAB\n0\nENDSEC\n0\nSECTION\n2\nBLOCKS\n\(blocks)0\nENDSEC\n0\nSECTION\n2\nENTITIES\n\(entities)0\nENDSEC\n0\nEOF\n"
        return Data(text.replacingOccurrences(of: "\n", with: "\r\n").utf8)
    }

    static func line(_ layer: String, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> String {
        "0\nLINE\n8\n\(layer)\n10\n\(x1)\n20\n\(y1)\n30\n0\n11\n\(x2)\n21\n\(y2)\n31\n0\n"
    }

    static let twelveLayers = ["A-WALL", "A-DOOR", "A-GLAZ", "A-FLOR", "A-FURN", "A-ANNO", "S-GRID", "S-COLS", "E-LITE", "E-POWR", "M-HVAC", "P-SANR"]

    static var fixture: Data {
        let block = "0\nBLOCK\n8\n0\n2\nDOOR900\n70\n0\n10\n0\n20\n0\n30\n0\n"
            + line("0", 0, 0, 900, 0)
            + "0\nARC\n8\n0\n10\n0\n20\n0\n30\n0\n40\n900\n50\n0\n51\n90\n"
            + "0\nENDBLK\n8\n0\n"
        let entities =
            line("A-WALL", 0, 0, 12_000, 0)                                            // the 12 000 mm wall
            + "0\nLWPOLYLINE\n8\nA-FLOR\n90\n4\n70\n1\n10\n0\n20\n0\n10\n5000\n20\n0\n42\n0\n10\n5000\n20\n4000\n10\n0\n20\n4000\n"
            + "0\nLWPOLYLINE\n8\nA-GLAZ\n90\n2\n70\n0\n10\n6000\n20\n0\n42\n1\n10\n8000\n20\n0\n"   // a half circle via bulge 1
            + "0\nCIRCLE\n8\nS-COLS\n10\n3000\n20\n3000\n30\n0\n40\n200\n"
            + "0\nARC\n8\nA-DOOR\n10\n1000\n20\n1000\n30\n0\n40\n500\n50\n0\n51\n180\n"
            + "0\nTEXT\n8\nA-ANNO\n10\n100\n20\n5000\n30\n0\n40\n250\n1\nRoom 101 – Kök\n"
            + "0\nINSERT\n8\nA-DOOR\n2\nDOOR900\n10\n2000\n20\n0\n30\n0\n41\n1\n42\n1\n50\n90\n"
            + Self.twelveLayers.dropFirst(6).map { line($0, 0, 6000, 1000, 6000) }.joined()
            + line("A-FURN", 0, 7000, 500, 7000)
        return dxf(layers: twelveLayers, blocks: block, entities: entities)
    }

    @Test("12 layers, $INSUNITS = 4: the sheet's layers match and a 12 000 mm wall measures 12.000 m at the sheet's own scale")
    func twelveThousandMillimetreWall() throws {
        let drawing = try DXFReader.read(Self.fixture)
        #expect(drawing.unit == .millimetres && drawing.unitDeclared)
        #expect(drawing.layers == Self.twelveLayers)
        let sheet = try DXFSheetWriter.write(drawing, title: "Fixture", options: { var o = DXFSheetWriter.Options(); o.compress = false; return o }())
        #expect(sheet.layers == Self.twelveLayers)
        #expect(sheet.scaleIsFromFile)
        // Extents 12 000 × 7 900 mm (y from −900, the door arc's circle, to 7 000, the furniture
        // line). Fits A0 less margins (1169 × 821) first at 1:20 (600 × 395 mm). Hand-derived.
        #expect(sheet.scaleDenominator == 20)
        let start = sheet.transform(DXFPoint(x: 0, y: 0)), end = sheet.transform(DXFPoint(x: 12_000, y: 0))
        let points = end.x - start.x
        // 12 000 mm ÷ 20 = 600 mm on paper = 600 / 25.4 × 72 pt.
        #expect(abs(points - 600.0 / 25.4 * 72.0) < 1e-9)
        // A preset 1:20 is 0.0254 / 72 × 20 metres per point (ScaleTransform.preset).
        let metres = points * (0.0254 / 72.0 * 20.0)
        #expect(abs(metres - 12.0) < 1e-9)
        #expect(String(format: "%.3f", metres) == "12.000")

        // The PDF opens, is one page of the stated size, and carries one OCG per layer.
        let document = try #require(CGPDFDocument(CGDataProvider(data: sheet.pdf as CFData)!))
        #expect(document.numberOfPages == 1)
        let box = try #require(document.page(at: 1)).getBoxRect(.mediaBox)
        #expect(abs(box.width - sheet.pageSizePoints.width) < 0.01)
        let catalog = try #require(document.catalog)
        var properties: CGPDFDictionaryRef?
        #expect(CGPDFDictionaryGetDictionary(catalog, "OCProperties", &properties))
        var groups: CGPDFArrayRef?
        #expect(CGPDFDictionaryGetArray(try #require(properties), "OCGs", &groups))
        #expect(CGPDFArrayGetCount(try #require(groups)) == 12)
        // The wall is in the stream on its own layer, as a move and a line. The sheet's origin is
        // the extents' corner: x 0, y −900 (the rotated door arc's circle reaches 900 below the
        // wall), so the wall sits at y (0 + 900) / 20 + 10 = 55 mm = 155.905512 pt, and runs from
        // x 10 mm = 28.346457 pt to (12 000 / 20 + 10) mm = 1729.133858 pt.
        let text = String(decoding: sheet.pdf, as: UTF8.self)
        #expect(text.contains("/OC /L0 BDC\n28.346457 155.905512 m\n1729.133858 155.905512 l\nS\n"))
    }

    @Test("Blocks expand with rotation, arcs become curves, bulges become half circles")
    func geometryIsExact() throws {
        let drawing = try DXFReader.read(Self.fixture)
        // DOOR900 inserted at (2000, 0) rotated 90°: its leaf line (0,0)-(900,0) becomes (2000,0)-(2000,900).
        let door = drawing.entities.filter { $0.layer == "A-DOOR" }
        let leaf = try #require(door.compactMap { entity -> [DXFPoint]? in
            if case let .polyline(points, _, _) = entity.shape { return points } else { return nil }
        }.first)
        #expect(abs(leaf[0].x - 2000) < 1e-9 && abs(leaf[0].y) < 1e-9)
        #expect(abs(leaf[1].x - 2000) < 1e-9 && abs(leaf[1].y - 900) < 1e-9)
        // The block's arc on layer 0 inherits the insert's layer and turns by 90°.
        let arcs = door.compactMap { entity -> (Double, Double)? in
            if case let .arc(_, radius, start, _) = entity.shape, abs(radius - 900) < 1e-9 { return (radius, start) } else { return nil }
        }
        #expect(arcs.count == 1)
        #expect(abs((arcs.first?.1 ?? 0) - .pi / 2) < 1e-12)
        // Bulge 1 on the glazing is a semicircle of radius 1000.
        let glazing = try #require(drawing.entities.first { $0.layer == "A-GLAZ" })
        guard case let .polyline(_, bulges, _) = glazing.shape else { Issue.record("glazing"); return }
        #expect(bulges.first == 1)
        let samples = Expander.bulgeSamples(from: .init(x: 6000, y: 0), to: .init(x: 8000, y: 0), bulge: 1)
        #expect(samples.allSatisfy { abs(hypot($0.x - 7000, $0.y) - 1000) < 1e-6 })
        // Text keeps its non-ASCII letters for the WinAnsi encoder.
        #expect(drawing.entities.contains { if case let .text(_, _, _, s) = $0.shape { return s == "Room 101 – Kök" } else { return false } })
        #expect(PDFAssembler.escape("Kök – (x)") == "K\\366k \\226 \\(x\\)")
    }

    @Test("A unitless drawing is drawn but its scale is not claimed; binary DXF, junk and empty drawings are refused")
    func refusals() throws {
        let unitless = try DXFReader.read(Self.dxf(units: nil, layers: ["0"], entities: Self.line("0", 0, 0, 10, 0)))
        #expect(unitless.unit == .unitless && !unitless.unitDeclared)
        #expect(try !DXFSheetWriter.write(unitless, title: "u").scaleIsFromFile)
        #expect(throws: DXFError.binaryDXF) { try DXFReader.read(Data("AutoCAD Binary DXF\r\n\u{1A}\0".utf8)) }
        #expect(throws: DXFError.notDXF) { try DXFReader.read(Data("hello".utf8)) }
        #expect(throws: DXFError.nothingToDraw) { try DXFReader.read(Self.dxf(layers: ["0"], entities: "")) }
        #expect(throws: DXFError.tooLarge(bytes: 10, limit: 5)) { try DXFReader.read(Data("0\nSECTION\n".utf8), limits: DXFLimits(maximumBytes: 5)) }
        // A block that inserts itself is stopped at the nesting cap, not followed forever.
        let loop = "0\nBLOCK\n2\nSELF\n10\n0\n20\n0\n" + Self.line("0", 0, 0, 1, 0) + "0\nINSERT\n8\n0\n2\nSELF\n10\n1\n20\n0\n0\nENDBLK\n"
        #expect(throws: DXFError.blockNestingTooDeep(limit: 16)) {
            try DXFReader.read(Self.dxf(layers: ["0"], blocks: loop, entities: "0\nINSERT\n8\n0\n2\nSELF\n10\n0\n20\n0\n"))
        }
        // An array insert that would explode is stopped at the entity cap.
        let many = "0\nINSERT\n8\n0\n2\nDOT\n10\n0\n20\n0\n70\n5000\n71\n5000\n44\n1\n45\n1\n"
        let dot = "0\nBLOCK\n2\nDOT\n10\n0\n20\n0\n" + Self.line("0", 0, 0, 1, 0) + "0\nENDBLK\n"
        #expect(throws: DXFError.tooManyEntities(limit: 1_000)) {
            try DXFReader.read(Self.dxf(layers: ["0"], blocks: dot, entities: many), limits: DXFLimits(maximumEntities: 1_000))
        }
    }

    @Test("MTEXT formatting is stripped to its words")
    func mtextIsPlain() {
        #expect(DXFReader.plainMText("{\\fArial|b1;Room}\\P\\H2.5x;101 \\S1/2;") == "Room\n101 1/2")
        #expect(DXFReader.plainMText("A\\~B \\\\ C") == "A B \\ C")
    }

    @Test("10 000 mutated DXFs parse or refuse, and never crash")
    func fuzz() {
        let base = [UInt8](Self.fixture)
        var state: UInt64 = 0x5EED_2026_0923
        func next() -> UInt64 { state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407; return state >> 33 }
        let alphabet = Array("0123456789-.eE\r\n ABCDEFGHIJKLMNOPQRSTUVWXYZ$".utf8)
        var parsed = 0, refused = 0
        for _ in 0..<10_000 {
            var bytes = base
            switch next() % 4 {
            case 0: bytes = Array(bytes.prefix(Int(next() % UInt64(bytes.count))))                         // truncate
            case 1: for _ in 0..<(1 + next() % 8) { bytes[Int(next() % UInt64(bytes.count))] = alphabet[Int(next() % UInt64(alphabet.count))] }
            case 2: let at = Int(next() % UInt64(bytes.count)); bytes.insert(contentsOf: Array("1e308\n".utf8), at: at)  // huge numbers
            default: let at = Int(next() % UInt64(bytes.count)); bytes.removeSubrange(at..<min(bytes.count, at + Int(next() % 40)))
            }
            do {
                let drawing = try DXFReader.read(Data(bytes), limits: DXFLimits(maximumEntities: 50_000))
                _ = try DXFSheetWriter.write(drawing, title: "fuzz")
                parsed += 1
            } catch {
                refused += 1
            }
        }
        #expect(parsed + refused == 10_000)
        #expect(parsed > 0 && refused > 0)
    }
}
