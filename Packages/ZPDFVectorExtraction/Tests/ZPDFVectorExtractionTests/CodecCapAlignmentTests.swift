import CoreGraphics
import Foundation
import Testing
@testable import ZPDFVectorExtraction

/// S17-10 — the decoder's caps are the extractor's ceilings, not looser.
///
/// `VectorExtractionCodec` decodes the geometry service's reply, which is attacker-controlled
/// by definition (see `HostileCodecPayloadTests`). Before this fix its primitive cap was
/// 8 000 000 against the extractor's 2 000 000 and its ring cap 4 000 000 against the
/// extractor's 1 000 000 points per subpath, so a compromised service could make the
/// application materialise four times the largest page an honest extractor can produce, with
/// every count passing. Old output of the two boundary tests below: the count one past the
/// extractor's ceiling passed the cap check and was refused only later, by the garbage after
/// it — "count 2000001 exceeds the decoding limit" never appeared.
struct CodecCapAlignmentTests {

    // MARK: - One source of truth

    @Test("The codec's caps are the extractor's ceilings, read from one place")
    func capsEqualExtractorCeilings() {
        #expect(VectorExtractionCodec.maximumPrimitives == VectorExtractionBudget.maximumPrimitiveCountCeiling)
        #expect(VectorExtractionCodec.maximumRingVertices == VectorExtractionBudget.maximumPointsPerSubpathCeiling)
        #expect(VectorExtractionCodec.maximumFilterDecisions == VectorScanState.maximumFilterDecisions)
        // The standard budget — what the geometry service always extracts with — sits at the
        // ceiling, so nothing an honest service sends can be refused by the cap.
        #expect(VectorExtractionBudget.standard.maximumPrimitiveCount == VectorExtractionCodec.maximumPrimitives)
        #expect(VectorExtractionBudget.standard.maximumPointsPerSubpath == VectorExtractionCodec.maximumRingVertices)
        // The values QUALITY_BAR 3.6 fixes; a change here is a change to the budget, not drift.
        #expect(VectorExtractionCodec.maximumPrimitives == 2_000_000)
        #expect(VectorExtractionCodec.maximumRingVertices == 1_000_000)
    }

    /// The other half of "an honest encoder never exceeds the decoder": a caller cannot run
    /// the extractor with a budget whose output the decoder would refuse.
    @Test("A budget above the ceiling is refused by name before any extraction runs")
    func budgetAboveCeilingIsRefused() {
        var options = VectorExtractionOptions.standard
        options.budget.maximumPrimitiveCount = VectorExtractionBudget.maximumPrimitiveCountCeiling + 1
        #expect(Self.invalidOptionName(options) == "budget.maximumPrimitiveCount")
        options.budget.maximumPrimitiveCount = VectorExtractionBudget.maximumPrimitiveCountCeiling
        #expect(Self.invalidOptionName(options) == nil)

        options.budget.maximumPointsPerSubpath = VectorExtractionBudget.maximumPointsPerSubpathCeiling + 1
        #expect(Self.invalidOptionName(options) == "budget.maximumPointsPerSubpath")
        options.budget.maximumPointsPerSubpath = VectorExtractionBudget.maximumPointsPerSubpathCeiling
        #expect(Self.invalidOptionName(options) == nil)
    }

    // MARK: - Oversized payloads

    /// A reply claiming one primitive more than the extractor can emit, followed by enough
    /// bytes that the "count must fit in the remaining bytes" guard cannot be what refuses
    /// it. The refusal must come from the cap, by name.
    @Test("A reply with one primitive past the extractor's ceiling is refused by the cap")
    func oversizedPrimitiveCountIsRefused() throws {
        let claimed = VectorExtractionBudget.maximumPrimitiveCountCeiling + 1
        let reason = Self.refusal(of: Self.payload(primitiveCount: claimed, padding: claimed + 64))
        #expect(reason?.contains("count \(claimed) exceeds the decoding limit \(VectorExtractionCodec.maximumPrimitives)") == true,
                "refused for \(reason ?? "nothing") instead")
    }

    /// The boundary is exact: a count *at* the ceiling clears the cap (and is then refused for
    /// the padding that follows it, which is not a primitive), so the cap is neither looser
    /// nor tighter than the extractor.
    @Test("A reply at exactly the extractor's ceiling clears the cap")
    func primitiveCountAtCeilingClearsTheCap() throws {
        let claimed = VectorExtractionBudget.maximumPrimitiveCountCeiling
        let reason = Self.refusal(of: Self.payload(primitiveCount: claimed, padding: claimed + 64))
        #expect(reason != nil, "padding decoded as primitives")
        #expect(reason?.contains("decoding limit") == false, "the cap refused a legal count: \(reason ?? "")")
    }

    @Test("A ring with one vertex past the subpath ceiling is refused by the cap")
    func oversizedRingIsRefused() throws {
        let claimed = VectorExtractionBudget.maximumPointsPerSubpathCeiling + 1
        let reason = Self.refusal(of: Self.payload(ringVertexCount: claimed, padding: claimed + 64))
        #expect(reason?.contains("count \(claimed) exceeds the decoding limit \(VectorExtractionCodec.maximumRingVertices)") == true,
                "refused for \(reason ?? "nothing") instead")
    }

    @Test("A ring at exactly the subpath ceiling clears the cap")
    func ringAtCeilingClearsTheCap() throws {
        let claimed = VectorExtractionBudget.maximumPointsPerSubpathCeiling
        let reason = Self.refusal(of: Self.payload(ringVertexCount: claimed, padding: claimed + 64))
        #expect(reason != nil, "padding decoded as ring vertices")
        #expect(reason?.contains("decoding limit") == false, "the cap refused a legal count: \(reason ?? "")")
    }

    /// The real geometry-service reply path, end to end through `encode`: an honest
    /// extraction with a closed ring still round-trips after the caps were tightened.
    @Test("An honest extraction with a ring still round-trips")
    func honestRingRoundTrips() throws {
        let ring = VectorRing(
            vertices: (0..<1_000).map { CGPoint(x: Double($0), y: Double($0 % 7)) },
            isClosed: true, containsCurves: false
        )
        let reference = try VectorExtractionCodec.decode(Self.payload(primitiveCount: 0, padding: 0, terminated: true))
        let primitive = VectorPrimitive(
            id: 1, parentID: nil, kind: .closedSubpath, geometry: .ring(ring),
            bounds: VectorBounds(minX: 0, minY: 0, maxX: 999, maxY: 6),
            sourceObjectID: 1, subpathIndex: 0, nestingDepth: 0, paint: [.filled],
            strokeWidth: 0, strokeIsDashed: false, clipRelation: .unclipped, clipBounds: nil,
            confidence: 1, layerID: nil
        )
        let extraction = VectorPageExtraction(
            cacheKey: reference.cacheKey, availability: .available, partialReasons: [],
            primitives: [primitive], rasterRegions: [], filterDecisions: [],
            pageTransform: reference.pageTransform, statistics: reference.statistics,
            formInvocations: nil
        )
        #expect(try VectorExtractionCodec.decode(VectorExtractionCodec.encode(extraction)) == extraction)
    }

    // MARK: - Payload construction

    private static func invalidOptionName(_ options: VectorExtractionOptions) -> String? {
        do {
            _ = try options.validated()
            return nil
        } catch VectorExtractionError.invalidOption(let name, _) {
            return name
        } catch {
            return "unexpected error \(error)"
        }
    }

    /// The decoding failure's reason, or `nil` when the payload decoded.
    private static func refusal(of data: Data) -> String? {
        do {
            _ = try VectorExtractionCodec.decode(data)
            return nil
        } catch VectorExtractionError.cacheDecodingFailed(let reason) {
            return reason
        } catch {
            return "unexpected error \(error)"
        }
    }

    private static func header(into writer: inout BinaryWriter) {
        for byte in VectorExtractionCodec.magic { writer.write(byte: byte) }
        writer.write(fixed: UInt32(VectorExtractionCodec.formatVersion))
        writer.write(string: "0000000000000000000000000000000000000000000000000000000000000000")
        writer.write(varint: 0)                       // pageIndex
        writer.write(varint: 1)                       // extractorVersion
        writer.write(fixed: UInt64(0x1234_5678_9ABC_DEF0))
        writer.write(byte: VectorPageSpaceConvention.pdfUserSpace.rawValue)
        writer.write(bounds: VectorBounds(minX: 0, minY: 0, maxX: 595, maxY: 842))
        writer.write(bounds: VectorBounds(minX: 0, minY: 0, maxX: 595, maxY: 842))
        writer.write(varint: 0)                       // rotation
        writer.write(byte: 0)                         // availability: .available
        writer.write(varint: 0)                       // partial reasons
        writer.write(varint: 0)                       // layer-name table (format 2)
        writer.write(varint: 0)                       // colour table (format 3)
    }

    private static func finish(_ writer: inout BinaryWriter) -> Data {
        var hash = FNVHash()
        hash.combine(writer.bytes)
        writer.write(fixed: hash.value)
        return Data(writer.bytes)
    }

    /// A checksum-correct payload whose primitive count is `primitiveCount`, followed by
    /// `padding` zero bytes. With `terminated`, the rest of a well-formed empty page follows
    /// instead (used only with a zero count, to borrow a valid key and statistics).
    private static func payload(primitiveCount: Int, padding: Int, terminated: Bool = false) -> Data {
        var writer = BinaryWriter(reservingCapacity: padding + 512)
        header(into: &writer)
        writer.write(varint: UInt64(primitiveCount))
        if terminated {
            writer.write(varint: 0)                   // raster regions
            writer.write(varint: 0)                   // filter decisions
            for _ in 0..<12 { writer.write(varint: 0) }
            writer.write(fixed: UInt64(0))
            writer.write(varint: 0)
            writer.write(bool: false)                 // no form invocation table
        }
        for _ in 0..<padding { writer.write(byte: 0) }
        return finish(&writer)
    }

    /// A checksum-correct payload with one ring primitive whose vertex count is
    /// `ringVertexCount`, followed by `padding` zero bytes where the vertices would be.
    private static func payload(ringVertexCount: Int, padding: Int) -> Data {
        var writer = BinaryWriter(reservingCapacity: padding + 512)
        header(into: &writer)
        writer.write(varint: 1)                       // one primitive
        writer.write(varint: 1)                       // id
        writer.write(bool: false)                     // parentID == nil
        writer.write(byte: 0)                         // kind: first case
        writer.write(byte: 3)                         // geometry tag: ring
        writer.write(bool: true)                      // isClosed
        writer.write(bool: false)                     // containsCurves
        writer.write(varint: UInt64(ringVertexCount))
        for _ in 0..<padding { writer.write(byte: 0) }
        return finish(&writer)
    }
}
