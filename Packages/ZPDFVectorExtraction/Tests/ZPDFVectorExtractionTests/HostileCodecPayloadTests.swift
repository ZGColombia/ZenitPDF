import CoreGraphics
import Foundation
import Testing
@testable import ZPDFVectorExtraction

/// S17 security review — the decoder's behaviour on payloads no encoder of ours could
/// have produced.
///
/// ``VectorExtractionCodec`` is not only a cache format. It is the **wire format of the
/// reply** that `GeometryService.xpc` sends back to the application
/// (`ZPDFGeometryServiceClient.decodeExtraction`). The whole point of parsing a hostile
/// drawing in a separate, minimally entitled process is that a parser bug there must not
/// become a problem in the application; that guarantee is only worth what the app-side
/// decoding of the service's reply is worth. So the reply is treated here as fully
/// attacker-controlled, as `Docs/Execution/FINAL_SECURITY_REPORT.md` requires: untrusted service
/// replies must be validated before they become application state.
///
/// The codec's own doc comment claims "every count is checked against both a cap and the
/// bytes that remain, so a corrupted length field cannot make the decoder allocate". That
/// claim is about *counts*. It says nothing about the scalar fields that are read as an
/// unbounded `UInt64` varint and then narrowed with `Int(_:)`, which traps rather than
/// throws for anything above `Int.max`. These tests pin every one of those fields.
struct HostileCodecPayloadTests {

    // MARK: - Payload construction

    /// A varint that no encoder in this package can emit: ten bytes carrying
    /// `UInt64.max`, which is `Int.max + 1` and upwards once narrowed.
    static let aboveIntMax: [UInt8] = [
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01
    ]

    /// Where a hostile varint is planted in an otherwise perfectly well-formed payload.
    enum Field: String, CaseIterable {
        case cacheKeyPageIndex
        case cacheKeyExtractorVersion
        case pageRotation
        case partialReasonInlineImageCount
        case primitiveSubpathIndex
        case primitiveNestingDepth
        case rasterRegionNestingDepth
        case filterDecisionSubpathIndex
        case statisticsOperatorCount
        case statisticsEstimatedMemoryBytes
    }

    /// Builds a complete, checksum-correct payload, optionally corrupting one field to a
    /// value above `Int.max`.
    ///
    /// Hand-rolled rather than "encode then patch a byte" because a patched byte changes
    /// the length of a varint and therefore the offset of everything after it; building
    /// the bytes directly is the only way to be sure which field is being tested.
    static func payload(corrupting field: Field?) -> Data {
        var writer = BinaryWriter()
        for byte in VectorExtractionCodec.magic { writer.write(byte: byte) }
        writer.write(fixed: UInt32(VectorExtractionCodec.formatVersion))

        // cacheKey
        writer.write(string: "0000000000000000000000000000000000000000000000000000000000000000")
        write(varint: 0, orHostileIf: field == .cacheKeyPageIndex, into: &writer)
        write(varint: 1, orHostileIf: field == .cacheKeyExtractorVersion, into: &writer)
        writer.write(fixed: UInt64(0x1234_5678_9ABC_DEF0))

        // pageTransform
        writer.write(byte: VectorPageSpaceConvention.pdfUserSpace.rawValue)
        writer.write(bounds: VectorBounds(minX: 0, minY: 0, maxX: 595, maxY: 842))
        writer.write(bounds: VectorBounds(minX: 0, minY: 0, maxX: 595, maxY: 842))
        write(varint: 0, orHostileIf: field == .pageRotation, into: &writer)

        // availability: .available
        writer.write(byte: 0)

        // partialReasons: one `.inlineImageSkipped(count:)`
        writer.write(varint: 1)
        writer.write(byte: 8)
        write(varint: 3, orHostileIf: field == .partialReasonInlineImageCount, into: &writer)

        // layer-name table (format 2): empty
        writer.write(varint: 0)
        // colour table (format 3): empty
        writer.write(varint: 0)

        // primitives: one line
        writer.write(varint: 1)
        writer.write(varint: 1)            // id
        writer.write(bool: false)          // parentID == nil
        writer.write(byte: 0)              // kind: first case
        writer.write(byte: 0)              // geometry tag: line
        writer.write(point: CGPoint(x: 0, y: 0))
        writer.write(point: CGPoint(x: 10, y: 10))
        writer.write(bounds: VectorBounds(minX: 0, minY: 0, maxX: 10, maxY: 10))
        writer.write(varint: 7)            // sourceObjectID
        write(varint: 0, orHostileIf: field == .primitiveSubpathIndex, into: &writer)
        write(varint: 0, orHostileIf: field == .primitiveNestingDepth, into: &writer)
        writer.write(byte: 0)              // paint
        writer.write(double: 1.0)          // strokeWidth
        writer.write(bool: false)          // dashed
        writer.write(byte: 0)              // clipRelation: first case
        writer.write(bool: false)          // clipBounds == nil
        writer.write(float: 1.0)           // confidence
        writer.write(varint: 0)            // fillColor: table index 0 = none (format 3)
        writer.write(varint: 0)            // strokeColor: table index 0 = none (format 3)
        writer.write(varint: 0)            // layerID: table index 0 = none (format 2)

        // rasterRegions: one
        writer.write(varint: 1)
        writer.write(varint: 2)            // id
        writer.write(point: CGPoint(x: 0, y: 0))
        writer.write(point: CGPoint(x: 1, y: 0))
        writer.write(point: CGPoint(x: 1, y: 1))
        writer.write(point: CGPoint(x: 0, y: 1))
        writer.write(bounds: VectorBounds(minX: 0, minY: 0, maxX: 1, maxY: 1))
        write(varint: 0, orHostileIf: field == .rasterRegionNestingDepth, into: &writer)
        writer.write(varint: 9)            // sourceObjectID
        writer.write(bool: false)          // isInline
        writer.write(optionalString: nil)  // resourceName

        // filterDecisions: one
        writer.write(varint: 1)
        writer.write(byte: 0)              // rule: first case
        writer.write(varint: 11)           // sourceObjectID
        write(varint: 0, orHostileIf: field == .filterDecisionSubpathIndex, into: &writer)
        writer.write(varint: 0)            // nestingDepth
        writer.write(bounds: VectorBounds(minX: 0, minY: 0, maxX: 1, maxY: 1))
        writer.write(bool: false)          // measuredValue == nil
        writer.write(bool: false)          // threshold == nil

        // statistics: twelve varints, a fixed elapsed, one varint
        write(varint: 0, orHostileIf: field == .statisticsOperatorCount, into: &writer)
        for _ in 0..<11 { writer.write(varint: 0) }
        writer.write(fixed: UInt64(0))
        write(varint: 0, orHostileIf: field == .statisticsEstimatedMemoryBytes, into: &writer)
        // Format 4 (NL-AUTO-12): no form invocation table.
        writer.write(bool: false)

        var hash = FNVHash()
        hash.combine(writer.bytes)
        writer.write(fixed: hash.value)
        return Data(writer.bytes)
    }

    private static func write(varint value: UInt64, orHostileIf hostile: Bool, into writer: inout BinaryWriter) {
        guard hostile else { return writer.write(varint: value) }
        for byte in aboveIntMax { writer.write(byte: byte) }
    }

    // MARK: - Tests

    @Test("The hand-built reference payload is what an honest service would send")
    func referencePayloadDecodes() throws {
        let extraction = try VectorExtractionCodec.decode(Self.payload(corrupting: nil))
        #expect(extraction.cacheKey.pageIndex == 0)
        #expect(extraction.primitives.count == 1)
        #expect(extraction.rasterRegions.count == 1)
        #expect(extraction.filterDecisions.count == 1)
        #expect(extraction.partialReasons.count == 1)
    }

    /// The finding this file exists for: before the S17 fix, every one of these narrowed a
    /// hostile `UInt64` with `Int(_:)` and trapped — a compromised or simply buggy
    /// `GeometryService` could kill the application process on demand, and the same bytes
    /// arriving from a future on-disk cache would do the same on open. A trap is not a
    /// throw: no `catch` sees it, the crash-recovery machinery never runs, and the rule
    /// "no fatalError" is violated by the standard library on our behalf.
    @Test("A scalar above Int.max is refused, never narrowed", arguments: Field.allCases)
    func scalarsAboveIntMaxAreRefused(_ field: Field) throws {
        let hostile = Self.payload(corrupting: field)
        #expect(throws: VectorExtractionError.self) {
            _ = try VectorExtractionCodec.decode(hostile)
        }
    }

    /// The refusal must be the typed decoding failure the callers already handle
    /// (`ZPDFServiceError.malformedReply` on the service path), not some other error that
    /// escapes to a different handler.
    @Test("The refusal is a typed cache-decoding failure")
    func refusalIsTyped() throws {
        do {
            _ = try VectorExtractionCodec.decode(Self.payload(corrupting: .primitiveNestingDepth))
            Issue.record("a hostile payload decoded successfully")
        } catch let error as VectorExtractionError {
            guard case .cacheDecodingFailed = error else {
                Issue.record("wrong case: \(error)")
                return
            }
        }
    }

    /// Sanity: the caps the codec documents really do bite, and they bite by throwing.
    @Test("A count above its cap is refused")
    func countAboveCapIsRefused() throws {
        var writer = BinaryWriter()
        for byte in VectorExtractionCodec.magic { writer.write(byte: byte) }
        writer.write(fixed: UInt32(VectorExtractionCodec.formatVersion))
        writer.write(string: "digest")
        writer.write(varint: 0)
        writer.write(varint: 1)
        writer.write(fixed: UInt64(0))
        writer.write(byte: VectorPageSpaceConvention.pdfUserSpace.rawValue)
        writer.write(bounds: VectorBounds(minX: 0, minY: 0, maxX: 1, maxY: 1))
        writer.write(bounds: VectorBounds(minX: 0, minY: 0, maxX: 1, maxY: 1))
        writer.write(varint: 0)
        writer.write(byte: 0)
        // partialReasons count, one past the documented cap
        writer.write(varint: UInt64(VectorExtractionCodec.maximumPartialReasons + 1))
        var hash = FNVHash()
        hash.combine(writer.bytes)
        writer.write(fixed: hash.value)

        #expect(throws: VectorExtractionError.self) {
            _ = try VectorExtractionCodec.decode(Data(writer.bytes))
        }
    }
}
