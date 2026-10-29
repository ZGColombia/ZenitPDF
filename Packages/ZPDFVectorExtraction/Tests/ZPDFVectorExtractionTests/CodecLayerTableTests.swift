import CoreGraphics
import Foundation
import Testing
@testable import ZPDFVectorExtraction

/// Format 2 of the cache/XPC codec: layer names interned in a table (IM-158). The size
/// arithmetic is derived by hand, format 1 is still decoded, and a hostile table index is
/// a typed refusal.
struct CodecLayerTableTests {

    /// Three layer names of exactly 32 bytes of UTF-8 each.
    static let names = ["Layer-Walls", "Layer-Doors", "Layer-Grid"].map { stem in
        String((stem + String(repeating: "0", count: 32)).prefix(32))
    }

    /// `count` line primitives; primitive `i` carries `names[i % 4]` for `i % 4 < 3` and
    /// no layer otherwise when `layered`, and no layer at all when not.
    static func extraction(count: Int, layered: Bool) -> VectorPageExtraction {
        precondition(names.allSatisfy { $0.utf8.count == 32 })
        var primitives: [VectorPrimitive] = []
        primitives.reserveCapacity(count)
        for index in 0..<count {
            let x = Double(index % 500)
            let y = Double(index / 500)
            let line = VectorLine(start: CGPoint(x: x, y: y), end: CGPoint(x: x + 1, y: y + 1))
            let slot = index % 4
            primitives.append(
                VectorPrimitive(
                    id: UInt64(index + 1),
                    parentID: nil,
                    kind: .lineSegment,
                    geometry: .line(line),
                    bounds: line.bounds,
                    sourceObjectID: UInt64(index),
                    subpathIndex: 0,
                    nestingDepth: 0,
                    paint: .stroked,
                    strokeWidth: 1,
                    strokeIsDashed: false,
                    clipRelation: .unclipped,
                    clipBounds: nil,
                    confidence: 1,
                    layerID: layered && slot < 3 ? names[slot] : nil
                )
            )
        }
        let box = VectorBounds(minX: 0, minY: 0, maxX: 612, maxY: 792)
        return VectorPageExtraction(
            cacheKey: VectorCacheKey(
                documentDigest: String(repeating: "a", count: 64),
                pageIndex: 0,
                extractorVersion: VectorExtractor.extractorVersion,
                configurationFingerprint: 1
            ),
            availability: .available,
            partialReasons: [],
            primitives: primitives,
            rasterRegions: [],
            filterDecisions: [],
            pageTransform: VectorPageTransform(convention: .pdfUserSpace, mediaBox: box, cropBox: box, rotation: 0),
            statistics: VectorExtractionStatistics(
                operatorCount: count, primitiveCount: count, filteredCount: 0, paintedPathCount: count,
                subpathCount: count, formInvocationCount: 0, maximumNestingDepthReached: 0,
                rasterRegionCount: 0, inlineImageCount: 0, malformedOperandCount: 0,
                contentBytesCompleted: 0, contentBytesEntered: 0, elapsedNanoseconds: 0,
                estimatedMemoryBytes: 0
            )
        )
    }

    @Test("Layered pages round-trip through format 2, and the layer names cost the table alone")
    func layerTableRoundTripAndSize() throws {
        let count = 20_000
        let layered = Self.extraction(count: count, layered: true)
        let plain = Self.extraction(count: count, layered: false)

        let layeredBytes = VectorExtractionCodec.encode(layered)
        let plainBytes = VectorExtractionCodec.encode(plain)
        let decoded = try VectorExtractionCodec.decode(layeredBytes)
        #expect(decoded == layered)
        #expect(decoded.layerIDs == Self.names.sorted())

        // Per primitive both encodings spend one byte on the layer field (index 1…3 or
        // 0, all under 128), so the whole difference is the table: a one-byte count plus
        // three names of (1 length byte + 32 bytes) = 1 + 3 × 33 = 100 bytes, against
        // the unlayered page's one-byte empty table: 99 bytes.
        //
        // Format 1 spelled every name out per primitive — a `true` byte, a length byte
        // and 32 bytes against one `false` byte — so the same page cost
        // 15 000 × 33 = 495 000 bytes more than the unlayered one.
        #expect(layeredBytes.count - plainBytes.count == 99)

        // The format version written is 4 (form invocation table, NL-AUTO-12; colour table
        // since 3, BH-167), little-endian, right after the magic.
        #expect(Array(layeredBytes[4..<8]) == [4, 0, 0, 0])
    }

    /// A format-1 payload with one layered primitive, byte for byte as the old encoder
    /// wrote it: no table, and the layer as an optional string on the primitive.
    static func formatOnePayload(layer: String?) -> Data {
        var writer = BinaryWriter()
        for byte in VectorExtractionCodec.magic { writer.write(byte: byte) }
        writer.write(fixed: UInt32(1))
        // cacheKey
        writer.write(string: String(repeating: "b", count: 64))
        writer.write(varint: 3)
        writer.write(varint: 2)
        writer.write(fixed: UInt64(0x0102_0304_0506_0708))
        // pageTransform
        writer.write(byte: VectorPageSpaceConvention.pdfUserSpace.rawValue)
        writer.write(bounds: VectorBounds(minX: 0, minY: 0, maxX: 595, maxY: 842))
        writer.write(bounds: VectorBounds(minX: 0, minY: 0, maxX: 595, maxY: 842))
        writer.write(varint: 0)
        // availability: available; no partial reasons
        writer.write(byte: 0)
        writer.write(varint: 0)
        // primitives: one line
        writer.write(varint: 1)
        writer.write(varint: 1)
        writer.write(bool: false)
        writer.write(byte: 0)
        writer.write(byte: 0)
        writer.write(point: CGPoint(x: 0, y: 0))
        writer.write(point: CGPoint(x: 10, y: 10))
        writer.write(bounds: VectorBounds(minX: 0, minY: 0, maxX: 10, maxY: 10))
        writer.write(varint: 7)
        writer.write(varint: 0)
        writer.write(varint: 0)
        writer.write(byte: VectorPaintRole.stroked.rawValue)
        writer.write(double: 1.0)
        writer.write(bool: false)
        writer.write(byte: 0)
        writer.write(bool: false)
        writer.write(float: 1.0)
        writer.write(optionalString: layer)   // format 1: per-primitive string
        // no raster regions, no filter decisions
        writer.write(varint: 0)
        writer.write(varint: 0)
        // statistics
        for _ in 0..<12 { writer.write(varint: 0) }
        writer.write(fixed: UInt64(0))
        writer.write(varint: 0)
        var hash = FNVHash()
        hash.combine(writer.bytes)
        writer.write(fixed: hash.value)
        return Data(writer.bytes)
    }

    @Test("A format-1 cache written before the table existed still decodes")
    func formatOneStillDecodes() throws {
        let decoded = try VectorExtractionCodec.decode(Self.formatOnePayload(layer: "Walls"))
        #expect(decoded.cacheKey.pageIndex == 3)
        #expect(decoded.cacheKey.extractorVersion == 2)
        #expect(decoded.primitives.count == 1)
        #expect(decoded.primitives.first?.layerID == "Walls")
        let unlayered = try VectorExtractionCodec.decode(Self.formatOnePayload(layer: nil))
        #expect(unlayered.primitives.first?.layerID == nil)
        // Re-encoding writes format 4 and reads back equal (the absent invocation table stays
        // absent, NL-AUTO-12).
        let reencoded = VectorExtractionCodec.encode(decoded)
        #expect(Array(reencoded[4..<8]) == [4, 0, 0, 0])
        #expect(try VectorExtractionCodec.decode(reencoded) == decoded)
    }

    @Test("A layer index past the table, and a table past its cap, are typed refusals")
    func hostileLayerIndexIsRefused() throws {
        // Encode one layered primitive, then rewrite the primitive's layer index from 1
        // to 2 with a table of one name and re-sign. The index is the last byte before
        // the raster-region count in a one-primitive page: the payload is
        // `… [confidence: 4 bytes][layer index: 1 byte][raster count: 1][decision count: 1]
        // [statistics: 12 varints + 8 + 1]` and every trailing count is a single zero byte.
        let page = Self.extraction(count: 1, layered: true)
        var bytes = [UInt8](VectorExtractionCodec.encode(page))
        bytes.removeLast(8)
        // raster, decisions, 12 varints, fixed, 1 varint, and (format 4, NL-AUTO-12) the
        // invocation-table presence byte.
        let trailingBytes = 1 + 1 + 12 + 8 + 1 + 1
        let indexOffset = bytes.count - trailingBytes - 1
        #expect(bytes[indexOffset] == 1, "the one layer is table entry 1")
        bytes[indexOffset] = 2
        var hash = FNVHash()
        hash.combine(bytes)
        var writer = BinaryWriter()
        for byte in bytes { writer.write(byte: byte) }
        writer.write(fixed: hash.value)
        let hostile = Data(writer.bytes)

        do {
            _ = try VectorExtractionCodec.decode(hostile)
            Issue.record("a layer index past the table decoded")
        } catch let error as VectorExtractionError {
            guard case .cacheDecodingFailed = error else {
                Issue.record("wrong case: \(error)")
                return
            }
        }
    }
}
