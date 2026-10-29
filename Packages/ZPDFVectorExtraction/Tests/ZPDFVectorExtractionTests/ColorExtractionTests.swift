import CoreGraphics
import Foundation
import Testing
@testable import ZPDFVectorExtraction

/// Fill and stroke colours on emitted primitives (BH-167, ADR-0011 "Colour in imported
/// vector artwork").
///
/// The document is written out by hand with ``OptionalContentTests/MiniPDF`` so every
/// colour operator and resource is explicit. Each case paints at its own `y`, and every
/// expected colour beside it is derived by hand from PDF 32000-1 8.6 and the conversion
/// formulas documented on ``VectorColor`` — never read back from the code under test.
@Suite("Colour extraction")
struct ColorExtractionTests {

    typealias MiniPDF = OptionalContentTests.MiniPDF

    /// | y | content | expected fill | expected stroke |
    /// |---|---|---|---|
    /// | 5 | stroke before any colour operator | – | black: the initial colour (Table 52) |
    /// | 10 | `1 g … re f` | `(1,1,1,1)` white | – |
    /// | 40 | `1 0 0 RG … S` | – | `(1,0,0,1)` |
    /// | 60 | `0 0 0 1 k … re f` | `(1−0)(1−1) = 0` each → `(0,0,0,1)` | – |
    /// | 90 | `0.5 g … re f` | `(0.5,0.5,0.5,1)` | – |
    /// | 100 | `0.2 0.4 0.6 0.5 k … re f` | r = 0.8·0.5 = 0.4, g = 0.6·0.5 = 0.3, b = 0.4·0.5 = 0.2 | – |
    /// | 120 | `0 1 0 rg q 0 0 1 rg … f` | `(0,0,1,1)` inside the `q` | – |
    /// | 150 | `Q … f` | `(0,1,0,1)`: `Q` restored the green | – |
    /// | 180 | `/Pattern cs /P0 scn … f` | `nil`: a shading pattern is never guessed | – |
    /// | 210 | `0 0 1 RG 1 1 0 rg … B` | `(1,1,0,1)` | `(0,0,1,1)` |
    /// | 240 | `q /GS0 gs` (`ca 0.5`, `CA 0.25`) `1 0 0 rg 0 1 0 RG … B Q` | `(1,0,0,0.5)` | `(0,1,0,0.25)` |
    /// | 270 | `/CS0 cs 0 0 1 sc … f`, CS0 = ICCBased `/N 3` | `(0,0,1,1)`, read as DeviceRGB | – |
    /// | 300 | `/CS1 cs 1 sc … f`, CS1 = Separation | `nil` | – |
    /// | 360 | form `/Fx`: `1 0 0 RG … S` after `0.25 G` outside | – | `(1,0,0,1)` |
    /// | 380 | after the `Do`: `… S` | – | `(0.25,0.25,0.25,1)`: the form's `RG` did not leak |
    /// | 400 | `/DeviceRGB CS 0.2 0.4 0.6 SC … S` | – | `(0.2,0.4,0.6,1)` |
    /// | 420 | `2 g … re f` | `(1,1,1,1)`: out-of-range 2 clamps to 1 (8.6.4) | – |
    static func document() -> Data {
        let page = """
        10 5 m 100 5 l S
        1 g 10 10 50 20 re f
        1 0 0 RG 10 40 m 100 40 l S
        0 0 0 1 k 10 60 50 20 re f
        0.5 g 10 90 50 5 re f
        0.2 0.4 0.6 0.5 k 10 100 50 5 re f
        0 1 0 rg q 0 0 1 rg 10 120 50 20 re f Q
        10 150 50 20 re f
        /Pattern cs /P0 scn 10 180 50 20 re f
        0 0 1 RG 1 1 0 rg 10 210 50 20 re B
        q /GS0 gs 1 0 0 rg 0 1 0 RG 10 240 50 20 re B Q
        /CS0 cs 0 0 1 sc 10 270 50 20 re f
        /CS1 cs 1 sc 10 300 50 20 re f
        0.25 G /Fx Do
        10 380 m 100 380 l S
        /DeviceRGB CS 0.2 0.4 0.6 SC 10 400 m 100 400 l S
        2 g 10 420 50 10 re f
        """
        let form = "1 0 0 RG 10 360 m 100 360 l S"
        let pattern = "<< /PatternType 2 /Shading << /ShadingType 2 /ColorSpace /DeviceRGB "
            + "/Coords [0 0 1 0] /Function << /FunctionType 2 /Domain [0 1] /C0 [1 0 0] /C1 [0 0 1] /N 1 >> >> >>"
        return MiniPDF.data(objects: [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R "
                + "/Resources << /ExtGState << /GS0 << /ca 0.5 /CA 0.25 >> >> "
                + "/ColorSpace << /CS0 [/ICCBased 5 0 R] "
                + "/CS1 [/Separation /Spot /DeviceCMYK << /FunctionType 2 /Domain [0 1] /C0 [0 0 0 0] /C1 [0 1 1 0] /N 1 >>] >> "
                + "/Pattern << /P0 \(pattern) >> "
                + "/XObject << /Fx 6 0 R >> >> >>",
            MiniPDF.stream(page),
            MiniPDF.stream("icc", entries: "/N 3"),
            MiniPDF.stream(form, entries: "/Type /XObject /Subtype /Form /BBox [0 0 612 792]"),
        ])
    }

    static func extract() async throws -> VectorPageExtraction {
        let url = try MiniPDF.write(document())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        return try await VectorExtractor(options: .standard).extract(documentAt: url, pageIndex: 0)
    }

    /// Every primitive inside the band `y…y + height`. A `re` emits a rectangle shape and
    /// four edges; a stroked line (height 0) emits one segment. All of them must carry the
    /// same colours.
    static func primitives(atY y: Double, height: Double = 20, in extraction: VectorPageExtraction) -> [VectorPrimitive] {
        extraction.primitives.filter { $0.bounds.minY >= y && $0.bounds.maxY <= y + height }
    }

    static func expectColors(
        atY y: Double,
        height: Double = 20,
        fill: VectorColor?,
        stroke: VectorColor?,
        in extraction: VectorPageExtraction,
        tolerance: Double = 1e-12,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let found = primitives(atY: y, height: height, in: extraction)
        // A `re` band holds its shape and four edges; a line band its one segment.
        #expect(found.count == (height == 0 ? 1 : 5), "y \(y): \(found.count) primitives", sourceLocation: sourceLocation)
        #expect(!found.isEmpty, "no primitive at y \(y)", sourceLocation: sourceLocation)
        for primitive in found {
            #expect(
                near(primitive.fillColor, fill, tolerance),
                "y \(y): fill \(String(describing: primitive.fillColor)), expected \(String(describing: fill))",
                sourceLocation: sourceLocation
            )
            #expect(
                near(primitive.strokeColor, stroke, tolerance),
                "y \(y): stroke \(String(describing: primitive.strokeColor)), expected \(String(describing: stroke))",
                sourceLocation: sourceLocation
            )
        }
    }

    static func near(_ a: VectorColor?, _ b: VectorColor?, _ tolerance: Double) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?):
            return abs(a.red - b.red) <= tolerance && abs(a.green - b.green) <= tolerance
                && abs(a.blue - b.blue) <= tolerance && abs(a.alpha - b.alpha) <= tolerance
        default: return false
        }
    }

    // MARK: - Scanner

    @Test("Every paint role carries the colour in force, converted by the documented formula")
    func colorsFollowTheGraphicsState() async throws {
        let extraction = try await Self.extract()
        let white = VectorColor(red: 1, green: 1, blue: 1, alpha: 1)
        Self.expectColors(atY: 5, height: 0, fill: nil, stroke: VectorColor(red: 0, green: 0, blue: 0), in: extraction)
        Self.expectColors(atY: 10, fill: white, stroke: nil, in: extraction)
        Self.expectColors(atY: 40, height: 0, fill: nil, stroke: VectorColor(red: 1, green: 0, blue: 0), in: extraction)
        Self.expectColors(atY: 60, fill: VectorColor(red: 0, green: 0, blue: 0), stroke: nil, in: extraction)
        Self.expectColors(atY: 90, height: 5, fill: VectorColor(red: 0.5, green: 0.5, blue: 0.5), stroke: nil, in: extraction)
        Self.expectColors(atY: 100, height: 5, fill: VectorColor(red: 0.4, green: 0.3, blue: 0.2), stroke: nil, in: extraction)
        Self.expectColors(atY: 120, fill: VectorColor(red: 0, green: 0, blue: 1), stroke: nil, in: extraction)
        Self.expectColors(atY: 150, fill: VectorColor(red: 0, green: 1, blue: 0), stroke: nil, in: extraction)
        Self.expectColors(atY: 180, fill: nil, stroke: nil, in: extraction)
        Self.expectColors(
            atY: 210,
            fill: VectorColor(red: 1, green: 1, blue: 0),
            stroke: VectorColor(red: 0, green: 0, blue: 1),
            in: extraction
        )
        Self.expectColors(
            atY: 240,
            fill: VectorColor(red: 1, green: 0, blue: 0, alpha: 0.5),
            stroke: VectorColor(red: 0, green: 1, blue: 0, alpha: 0.25),
            in: extraction
        )
        Self.expectColors(atY: 270, fill: VectorColor(red: 0, green: 0, blue: 1), stroke: nil, in: extraction)
        Self.expectColors(atY: 300, fill: nil, stroke: nil, in: extraction)
        Self.expectColors(atY: 360, height: 0, fill: nil, stroke: VectorColor(red: 1, green: 0, blue: 0), in: extraction)
        Self.expectColors(
            atY: 380, height: 0, fill: nil, stroke: VectorColor(red: 0.25, green: 0.25, blue: 0.25), in: extraction
        )
        Self.expectColors(
            atY: 400, height: 0, fill: nil, stroke: VectorColor(red: 0.2, green: 0.4, blue: 0.6), in: extraction
        )
        Self.expectColors(atY: 420, height: 10, fill: white, stroke: nil, in: extraction)

        // The importer's test: exactly the white knockout fills are opaque white.
        let whiteFills = extraction.primitives.filter { $0.fillColor?.isOpaqueWhite == true }
        #expect(whiteFills.count == 10, "two white `re` bands of five primitives each")
        #expect(Set(whiteFills.map(\.sourceObjectID)).count == 2)
        #expect(whiteFills.allSatisfy { (10...30).contains($0.bounds.minY) || (420...430).contains($0.bounds.minY) })
        // The half-transparent red at y 240 is not opaque, and neither is anything nil.
        #expect(Self.primitives(atY: 240, in: extraction).allSatisfy { $0.fillColor?.isOpaqueWhite == false })
    }

    @Test("Colour changes neither geometry nor filtering: the page is complete and every band is emitted")
    func colourDoesNotChangeAvailability() async throws {
        let extraction = try await Self.extract()
        #expect(extraction.availability == .available)
        #expect(extraction.statistics.malformedOperandCount == 0)
        // 17 bands: 12 `re` paints × (1 shape + 4 edges) + 5 single strokes = 65.
        #expect(extraction.primitives.count == 12 * 5 + 5)
    }

    @Test("Extraction with colours is deterministic, byte for byte")
    func deterministic() async throws {
        let first = try await Self.extract()
        let second = try await Self.extract()
        #expect(first.primitives == second.primitives)
        #expect(VectorExtractionCodec.encode(first) == VectorExtractionCodec.encode(second))
    }

    // MARK: - Conversions

    @Test("The device conversions are the documented naive formulas, clamped")
    func conversions() {
        // CMYK (0.1, 0.2, 0.3, 0.4): r = 0.9·0.6 = 0.54, g = 0.8·0.6 = 0.48, b = 0.7·0.6 = 0.42.
        let cmyk = VectorColor(deviceCyan: 0.1, magenta: 0.2, yellow: 0.3, black: 0.4)
        #expect(Self.near(cmyk, VectorColor(red: 0.54, green: 0.48, blue: 0.42), 1e-12))
        #expect(VectorColor(deviceCyan: 0, magenta: 0, yellow: 0, black: 0).isOpaqueWhite)
        #expect(VectorColor(deviceGray: 0.5) == VectorColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        #expect(VectorColor(red: -1, green: 2, blue: .nan, alpha: .infinity)
            == VectorColor(red: 0, green: 1, blue: 0, alpha: 0))
        #expect(!VectorColor(red: 1, green: 1, blue: 1, alpha: 0.99).isOpaqueWhite)
        // Codec 4 since the form invocation table (NL-AUTO-12); extractor 6 since a composite
        // form's identity covers its sub-forms (W-080).
        #expect(VectorExtractor.extractorVersion == 6)
        #expect(VectorExtractionCodec.formatVersion == 4)
    }

    // MARK: - Codec

    @Test("Colours round-trip through format 3 and are interned in a table")
    func codecRoundTrip() async throws {
        let extraction = try await Self.extract()
        let bytes = VectorExtractionCodec.encode(extraction)
        #expect(Array(bytes[4..<8]) == [4, 0, 0, 0])
        let decoded = try VectorExtractionCodec.decode(bytes)
        #expect(decoded == extraction)
        #expect(decoded.primitives.map(\.fillColor) == extraction.primitives.map(\.fillColor))
        #expect(decoded.primitives.map(\.strokeColor) == extraction.primitives.map(\.strokeColor))

        // Distinct colours on the page, by hand from the table above: black, white, red,
        // grey 0.5, (0.4,0.3,0.2), blue, green, yellow, red@0.5, green@0.25, grey 0.25,
        // (0.2,0.4,0.6) = 12. Each costs 32 bytes once; each primitive pays two index
        // bytes (all indices < 128). Against the same page with colours stripped:
        // table 12 × 32 = 384 bytes, and the one-byte table count is present in both.
        let stripped = Self.strippingColors(extraction)
        let strippedBytes = VectorExtractionCodec.encode(stripped)
        #expect(bytes.count - strippedBytes.count == 12 * 32)
        #expect(try VectorExtractionCodec.decode(strippedBytes) == stripped)
    }

    @Test("Uncoloured JSON (the pre-colour shape) still decodes; coloured JSON round-trips")
    func jsonCompatibility() async throws {
        let extraction = try await Self.extract()
        let coloured = try #require(Self.primitives(atY: 210, in: extraction).first)
        let json = try JSONEncoder().encode(coloured)
        #expect(try JSONDecoder().decode(VectorPrimitive.self, from: json) == coloured)

        let plain = try #require(Self.strippingColors(extraction).primitives.first)
        let plainJSON = try JSONEncoder().encode(plain)
        let text = String(decoding: plainJSON, as: UTF8.self)
        #expect(!text.contains("fillColor") && !text.contains("strokeColor"))
        let back = try JSONDecoder().decode(VectorPrimitive.self, from: plainJSON)
        #expect(back.fillColor == nil && back.strokeColor == nil)
    }

    @Test("A format-2 payload, written before colours existed, decodes with every colour nil")
    func formatTwoStillDecodes() throws {
        let decoded = try VectorExtractionCodec.decode(Self.payload(version: 2))
        #expect(decoded.primitives.count == 1)
        #expect(decoded.primitives[0].fillColor == nil)
        #expect(decoded.primitives[0].strokeColor == nil)
        #expect(decoded.primitives[0].layerID == nil)
        #expect(decoded.primitives[0].strokeWidth == 1)
    }

    @Test("A hand-built format-3 payload decodes to the colours it names")
    func formatThreeHandBuilt() throws {
        let red = VectorColor(red: 1, green: 0, blue: 0)
        let white = VectorColor.white
        let decoded = try VectorExtractionCodec.decode(
            Self.payload(version: 3, colors: [red, white], fillIndex: 2, strokeIndex: 1)
        )
        #expect(decoded.primitives[0].fillColor == white)
        #expect(decoded.primitives[0].strokeColor == red)
    }

    @Test("A colour index past the table, or a component outside 0…1, is a typed refusal")
    func hostileColorsAreRefused() throws {
        let red = VectorColor(red: 1, green: 0, blue: 0)
        let pastTable = Self.payload(version: 3, colors: [red], fillIndex: 2, strokeIndex: 0)
        let outOfRange = Self.payload(version: 3, rawComponents: [[0, 0, 1.5, 1]], fillIndex: 1, strokeIndex: 0)
        let nonFinite = Self.payload(version: 3, rawComponents: [[0, .nan, 0, 1]], fillIndex: 1, strokeIndex: 0)
        for hostile in [pastTable, outOfRange, nonFinite] {
            do {
                _ = try VectorExtractionCodec.decode(hostile)
                Issue.record("a hostile colour payload decoded")
            } catch let error as VectorExtractionError {
                guard case .cacheDecodingFailed = error else {
                    Issue.record("wrong case: \(error)")
                    continue
                }
            }
        }
    }

    // MARK: - Helpers

    static func strippingColors(_ extraction: VectorPageExtraction) -> VectorPageExtraction {
        VectorPageExtraction(
            cacheKey: extraction.cacheKey,
            availability: extraction.availability,
            partialReasons: extraction.partialReasons,
            primitives: extraction.primitives.map { p in
                VectorPrimitive(
                    id: p.id, parentID: p.parentID, kind: p.kind, geometry: p.geometry, bounds: p.bounds,
                    sourceObjectID: p.sourceObjectID, subpathIndex: p.subpathIndex,
                    nestingDepth: p.nestingDepth, paint: p.paint, strokeWidth: p.strokeWidth,
                    strokeIsDashed: p.strokeIsDashed, clipRelation: p.clipRelation,
                    clipBounds: p.clipBounds, confidence: p.confidence, layerID: p.layerID
                )
            },
            rasterRegions: extraction.rasterRegions,
            filterDecisions: extraction.filterDecisions,
            pageTransform: extraction.pageTransform,
            statistics: extraction.statistics,
            formInvocations: extraction.formInvocations
        )
    }

    /// A complete, checksum-correct one-line payload in the given format. Format 2 has no
    /// colour table and no per-primitive colour indices; format 3 has both.
    static func payload(
        version: UInt32,
        colors: [VectorColor] = [],
        rawComponents: [[Double]]? = nil,
        fillIndex: UInt64 = 0,
        strokeIndex: UInt64 = 0
    ) -> Data {
        var writer = BinaryWriter()
        for byte in VectorExtractionCodec.magic { writer.write(byte: byte) }
        writer.write(fixed: version)
        writer.write(string: String(repeating: "c", count: 64))
        writer.write(varint: 0)
        writer.write(varint: 3)
        writer.write(fixed: UInt64(42))
        writer.write(byte: VectorPageSpaceConvention.pdfUserSpace.rawValue)
        writer.write(bounds: VectorBounds(minX: 0, minY: 0, maxX: 612, maxY: 792))
        writer.write(bounds: VectorBounds(minX: 0, minY: 0, maxX: 612, maxY: 792))
        writer.write(varint: 0)
        writer.write(byte: 0)               // available
        writer.write(varint: 0)             // no partial reasons
        writer.write(varint: 0)             // empty layer table
        if version >= 3 {
            let table = rawComponents ?? colors.map { [$0.red, $0.green, $0.blue, $0.alpha] }
            writer.write(varint: table.count)
            for components in table { for value in components { writer.write(double: value) } }
        }
        writer.write(varint: 1)             // one primitive
        writer.write(varint: 1)
        writer.write(bool: false)
        writer.write(byte: VectorPrimitiveKind.lineSegment.rawValue)
        writer.write(byte: 0)               // geometry: line
        writer.write(point: CGPoint(x: 0, y: 0))
        writer.write(point: CGPoint(x: 10, y: 0))
        writer.write(bounds: VectorBounds(minX: 0, minY: 0, maxX: 10, maxY: 0))
        writer.write(varint: 0)
        writer.write(varint: 0)
        writer.write(varint: 0)
        writer.write(byte: VectorPaintRole([.stroked, .filled]).rawValue)
        writer.write(double: 1.0)
        writer.write(bool: false)
        writer.write(byte: 0)
        writer.write(bool: false)
        writer.write(float: 1.0)
        if version >= 3 {
            writer.write(varint: fillIndex)
            writer.write(varint: strokeIndex)
        }
        writer.write(varint: 0)             // layer index: none
        writer.write(varint: 0)             // raster regions
        writer.write(varint: 0)             // filter decisions
        for _ in 0..<12 { writer.write(varint: 0) }
        writer.write(fixed: UInt64(0))
        writer.write(varint: 0)
        var hash = FNVHash()
        hash.combine(writer.bytes)
        writer.write(fixed: hash.value)
        return Data(writer.bytes)
    }
}
