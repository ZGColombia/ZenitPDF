import CoreGraphics
import Foundation

/// The compact on-disk form of a ``VectorPageExtraction``.
///
/// Layout: a four-byte magic, a format version, the payload, and an FNV-1a checksum of
/// everything before it. The checksum is there because the file lives in a user's
/// project package and a half-written or bit-rotted entry must be rejected rather than
/// decoded into geometry that looks plausible and is wrong.
///
/// Decoding limits are hard: every count is checked against both a cap and the bytes
/// that remain, so a corrupted length field cannot make the decoder allocate.
public enum VectorExtractionCodec {

    static let magic: [UInt8] = [0x5A, 0x56, 0x58, 0x31]  // "ZVX1"
    /// Bumped when the byte layout changes. Not the same thing as the extractor version.
    ///
    /// 2: layer names are interned in a table after the partial reasons and each
    /// primitive carries a one-byte index into it instead of its own UTF-8 copy
    /// (IM-158). Version 1 is still decoded — a project package written before the
    /// change opens unchanged.
    ///
    /// 3: fill and stroke colours (BH-167). A colour table of distinct ``VectorColor``s
    /// (four doubles each, first-seen order) follows the layer-name table, and each
    /// primitive carries two varint indices into it — fill, then stroke, `0` for none —
    /// just before its layer index. Formats 1 and 2 still decode, with every colour
    /// `nil`; everything written is version 3.
    ///
    /// 4: the Form XObject invocation table (NL-AUTO-12) follows the statistics — a presence
    /// byte (0: the extraction carries no table, as one decoded from an older format), then a
    /// count and per invocation its content digest (fixed 8 bytes), first primitive index,
    /// primitive count and depth (varints) and six transform doubles. Formats 1–3 still decode,
    /// with the table `nil`; everything written is version 4.
    public static let formatVersion: UInt16 = 4
    /// Caps the invocation table of a damaged file.
    public static let maximumFormInvocations = 4_000_000
    /// The oldest layout ``decode(_:)`` still reads.
    public static let oldestDecodableFormatVersion: UInt16 = 1

    /// Caps that bound decoding of a hostile or damaged file.
    ///
    /// Where the extractor has a hard ceiling of its own, the cap *is* that ceiling, read from
    /// the one place it is defined, never a copy of it (S17-10). A decode cap looser than
    /// anything an honest encoder can emit protects nobody and hands the slack to whoever
    /// controls the encoder — the geometry service's reply is attacker-controlled by
    /// definition. The primitive cap was 8 000 000 and the ring cap 4 000 000 until 2026-10-27.
    public static let maximumPrimitives = VectorExtractionBudget.maximumPrimitiveCountCeiling
    public static let maximumRasterRegions = 1_000_000
    /// The scanner stores at most this many diagnostics (it was 8 000 000 here, against 50 000).
    public static let maximumFilterDecisions = VectorScanState.maximumFilterDecisions
    /// A ring is one closed subpath, so its vertices are bounded by the subpath point ceiling.
    public static let maximumRingVertices = VectorExtractionBudget.maximumPointsPerSubpathCeiling
    public static let maximumPartialReasons = 64
    public static let maximumLayerNames = 1 << 16
    /// At most a fill and a stroke colour per primitive.
    public static let maximumColors = 2 * maximumPrimitives

    /// The fewest bytes one primitive can occupy (a line with no parent, no clip, no
    /// layer), so a claimed count reserves no more storage than the bytes could hold.
    static let minimumEncodedPrimitiveBytes = 64

    // MARK: - Encoding

    public static func encode(_ extraction: VectorPageExtraction) -> Data {
        var writer = BinaryWriter(reservingCapacity: 256 + extraction.primitives.count * 96)
        for byte in magic { writer.write(byte: byte) }
        writer.write(fixed: UInt32(formatVersion))

        encodeCacheKey(extraction.cacheKey, into: &writer)
        encodePageTransform(extraction.pageTransform, into: &writer)
        encodeAvailability(extraction.availability, into: &writer)

        writer.write(varint: extraction.partialReasons.count)
        for reason in extraction.partialReasons { encodePartialReason(reason, into: &writer) }

        // The layer-name table, in first-seen order so two encodings of one page agree.
        var layerNames: [String] = []
        var layerIndex: [String: Int] = [:]
        for primitive in extraction.primitives {
            guard let layerID = primitive.layerID, layerIndex[layerID] == nil else { continue }
            layerIndex[layerID] = layerNames.count
            layerNames.append(layerID)
        }
        writer.write(varint: layerNames.count)
        for name in layerNames { writer.write(string: name) }

        // The colour table (format 3), in first-seen order, fill before stroke.
        var colors: [VectorColor] = []
        var colorIndex: [VectorColor: Int] = [:]
        for primitive in extraction.primitives {
            for color in [primitive.fillColor, primitive.strokeColor] {
                guard let color, colorIndex[color] == nil else { continue }
                colorIndex[color] = colors.count
                colors.append(color)
            }
        }
        writer.write(varint: colors.count)
        for color in colors {
            writer.write(double: color.red)
            writer.write(double: color.green)
            writer.write(double: color.blue)
            writer.write(double: color.alpha)
        }

        writer.write(varint: extraction.primitives.count)
        for primitive in extraction.primitives {
            encodePrimitive(primitive, layerIndex: layerIndex, colorIndex: colorIndex, into: &writer)
        }

        writer.write(varint: extraction.rasterRegions.count)
        for region in extraction.rasterRegions { encodeRasterRegion(region, into: &writer) }

        writer.write(varint: extraction.filterDecisions.count)
        for decision in extraction.filterDecisions { encodeFilterDecision(decision, into: &writer) }

        encodeStatistics(extraction.statistics, into: &writer)

        writer.write(bool: extraction.formInvocations != nil)
        let invocations = extraction.formInvocations ?? []
        if extraction.formInvocations != nil { writer.write(varint: invocations.count) }
        for invocation in invocations {
            writer.write(fixed: invocation.formIdentity)
            writer.write(varint: invocation.firstPrimitiveIndex)
            writer.write(varint: invocation.primitiveCount)
            writer.write(varint: invocation.depth)
            for value in [invocation.a, invocation.b, invocation.c, invocation.d, invocation.tx, invocation.ty] {
                writer.write(double: value)
            }
        }

        var hash = FNVHash()
        hash.combine(writer.bytes)
        writer.write(fixed: hash.value)
        return Data(writer.bytes)
    }

    // MARK: - Decoding

    public static func decode(_ data: Data) throws -> VectorPageExtraction {
        guard data.count >= magic.count + 4 + 8 else {
            throw VectorExtractionError.cacheDecodingFailed(reason: "data is too short")
        }
        // One copy of the payload, shared by the checksum, the trailer and the reader
        // (IM-158): `data.prefix` into a fresh `[UInt8]` per reader was two more.
        let bytes = [UInt8](data)
        let payloadEnd = bytes.count - 8
        var hash = FNVHash()
        hash.combine(bytes[0..<payloadEnd])
        var trailer = BinaryReader(bytes: bytes, from: payloadEnd)
        let recorded = try trailer.readFixedUInt64()
        guard recorded == hash.value else {
            throw VectorExtractionError.cacheDecodingFailed(reason: "checksum mismatch")
        }

        var reader = BinaryReader(bytes: bytes, to: payloadEnd)
        try reader.expect(magic: magic)
        let version = try reader.readFixedUInt32()
        guard version >= UInt32(oldestDecodableFormatVersion), version <= UInt32(formatVersion) else {
            throw VectorExtractionError.cacheDecodingFailed(
                reason: "unsupported format version \(version)"
            )
        }

        let key = try decodeCacheKey(&reader)
        let transform = try decodePageTransform(&reader)
        let availability = try decodeAvailability(&reader)

        let reasonCount = try reader.readCount(limit: maximumPartialReasons)
        var reasons: [VectorPartialReason] = []
        reasons.reserveCapacity(reasonCount)
        for _ in 0..<reasonCount { reasons.append(try decodePartialReason(&reader)) }

        // Format 2 interns the layer names here; format 1 spelled each one out per
        // primitive, which `decodePrimitive` still reads when the table is absent.
        var layerNames: [String]?
        if version >= 2 {
            let nameCount = try reader.readCount(limit: maximumLayerNames)
            var names: [String] = []
            names.reserveCapacity(nameCount)
            for _ in 0..<nameCount { names.append(try reader.readString(limit: 4096)) }
            layerNames = names
        }

        // Format 3 adds the colour table; older formats carry no colour at all.
        var colors: [VectorColor]?
        if version >= 3 {
            let colorCount = try reader.readCount(limit: maximumColors)
            var table: [VectorColor] = []
            table.reserveCapacity(Swift.min(colorCount, reader.remaining / 32 + 1))
            for _ in 0..<colorCount { table.append(try decodeColor(&reader)) }
            colors = table
        }

        let primitiveCount = try reader.readCount(limit: maximumPrimitives)
        var primitives: [VectorPrimitive] = []
        primitives.reserveCapacity(
            Swift.min(primitiveCount, reader.remaining / minimumEncodedPrimitiveBytes + 1)
        )
        for _ in 0..<primitiveCount {
            primitives.append(try decodePrimitive(&reader, layerNames: layerNames, colors: colors))
        }

        let rasterCount = try reader.readCount(limit: maximumRasterRegions)
        var rasters: [VectorRasterRegion] = []
        rasters.reserveCapacity(Swift.min(rasterCount, 1 << 12))
        for _ in 0..<rasterCount { rasters.append(try decodeRasterRegion(&reader)) }

        let decisionCount = try reader.readCount(limit: maximumFilterDecisions)
        var decisions: [VectorFilterDecision] = []
        decisions.reserveCapacity(Swift.min(decisionCount, 1 << 12))
        for _ in 0..<decisionCount { decisions.append(try decodeFilterDecision(&reader)) }

        let statistics = try decodeStatistics(&reader)

        var invocations: [VectorFormInvocation]?
        if version >= 4, try reader.readBool() {
            let count = try reader.readCount(limit: maximumFormInvocations)
            var table: [VectorFormInvocation] = []
            table.reserveCapacity(Swift.min(count, reader.remaining / 59 + 1))
            for _ in 0..<count {
                let identity = try reader.readFixedUInt64()
                // Indices into the primitive list, not element counts: bounded by the list, not
                // by the bytes left.
                let rawFirst = try reader.readVarint()
                let rawLength = try reader.readVarint()
                let rawDepth = try reader.readVarint()
                guard rawFirst <= UInt64(primitives.count), rawLength <= UInt64(primitives.count), rawDepth <= 1 << 16 else {
                    throw VectorExtractionError.cacheDecodingFailed(reason: "form invocation outside the primitive list")
                }
                let first = Int(rawFirst), length = Int(rawLength), depth = Int(rawDepth)
                guard first + length <= primitives.count else {
                    throw VectorExtractionError.cacheDecodingFailed(reason: "form invocation outside the primitive list")
                }
                var parts: [Double] = []
                for _ in 0..<6 { parts.append(try reader.readDouble()) }
                table.append(VectorFormInvocation(
                    formIdentity: identity, firstPrimitiveIndex: first, primitiveCount: length, depth: depth,
                    transform: CGAffineTransform(a: parts[0], b: parts[1], c: parts[2], d: parts[3], tx: parts[4], ty: parts[5])
                ))
            }
            invocations = table
        }

        return VectorPageExtraction(
            cacheKey: key,
            availability: availability,
            partialReasons: reasons,
            primitives: primitives,
            rasterRegions: rasters,
            filterDecisions: decisions,
            pageTransform: transform,
            statistics: statistics,
            formInvocations: invocations
        )
    }

    // MARK: - Cache key

    private static func encodeCacheKey(_ key: VectorCacheKey, into writer: inout BinaryWriter) {
        writer.write(string: key.documentDigest)
        writer.write(varint: key.pageIndex)
        writer.write(varint: key.extractorVersion)
        writer.write(fixed: key.configurationFingerprint)
    }

    private static func decodeCacheKey(_ reader: inout BinaryReader) throws -> VectorCacheKey {
        let digest = try reader.readString(limit: 256)
        let pageIndex = try reader.readBoundedInt()
        let version = try reader.readBoundedInt()
        let fingerprint = try reader.readFixedUInt64()
        return VectorCacheKey(
            documentDigest: digest,
            pageIndex: pageIndex,
            extractorVersion: version,
            configurationFingerprint: fingerprint
        )
    }

    // MARK: - Page transform

    private static func encodePageTransform(_ transform: VectorPageTransform, into writer: inout BinaryWriter) {
        writer.write(byte: transform.convention.rawValue)
        writer.write(bounds: transform.mediaBox)
        writer.write(bounds: transform.cropBox)
        writer.write(varint: transform.rotation)
    }

    /// The matrix is recomputed rather than stored: it is a pure function of the boxes,
    /// the rotation and the convention, so storing it would only create a way for the
    /// file to disagree with itself.
    private static func decodePageTransform(_ reader: inout BinaryReader) throws -> VectorPageTransform {
        let raw = try reader.readByte()
        guard let convention = VectorPageSpaceConvention(rawValue: raw) else {
            throw VectorExtractionError.cacheDecodingFailed(reason: "unknown page-space convention \(raw)")
        }
        let mediaBox = try reader.readBounds()
        let cropBox = try reader.readBounds()
        let rotation = try reader.readBoundedInt()
        return VectorPageTransform(
            convention: convention,
            mediaBox: mediaBox,
            cropBox: cropBox,
            rotation: rotation
        )
    }

    // MARK: - Availability

    private static func encodeAvailability(_ availability: VectorAvailability, into writer: inout BinaryWriter) {
        switch availability {
        case .available:
            writer.write(byte: 0)
        case .partial(let reason):
            writer.write(byte: 1)
            encodePartialReason(reason, into: &writer)
        case .unavailable(let reason):
            writer.write(byte: 2)
            encodeUnavailableReason(reason, into: &writer)
        }
    }

    private static func decodeAvailability(_ reader: inout BinaryReader) throws -> VectorAvailability {
        switch try reader.readByte() {
        case 0: return .available
        case 1: return .partial(reason: try decodePartialReason(&reader))
        case 2: return .unavailable(reason: try decodeUnavailableReason(&reader))
        case let other:
            throw VectorExtractionError.cacheDecodingFailed(reason: "unknown availability tag \(other)")
        }
    }

    private static func encodePartialReason(_ reason: VectorPartialReason, into writer: inout BinaryWriter) {
        switch reason {
        case .budgetExceeded(let kind, let fraction):
            writer.write(byte: 0)
            writer.write(byte: kind.rawValue)
            writer.write(double: fraction)
        case .shadingGeometryNotExtracted:
            writer.write(byte: 1)
        case .type3GlyphGeometryNotExtracted:
            writer.write(byte: 2)
        case .formNestingDepthExceeded(let limit):
            writer.write(byte: 3)
            writer.write(varint: limit)
        case .cyclicFormReference:
            writer.write(byte: 4)
        case .softMaskNotComposited:
            writer.write(byte: 5)
        case .malformedContentStream(let failures):
            writer.write(byte: 6)
            writer.write(varint: failures)
        case .annotationAppearanceStreamsNotExtracted:
            writer.write(byte: 7)
        case .inlineImageSkipped(let count):
            writer.write(byte: 8)
            writer.write(varint: count)
        case .hiddenOptionalContentExcluded(let count):
            writer.write(byte: 9)
            writer.write(varint: count)
        }
    }

    private static func decodePartialReason(_ reader: inout BinaryReader) throws -> VectorPartialReason {
        switch try reader.readByte() {
        case 0:
            let raw = try reader.readByte()
            guard let kind = VectorBudgetKind(rawValue: raw) else {
                throw VectorExtractionError.cacheDecodingFailed(reason: "unknown budget kind \(raw)")
            }
            return .budgetExceeded(kind, consumedFraction: try reader.readDouble())
        case 1: return .shadingGeometryNotExtracted
        case 2: return .type3GlyphGeometryNotExtracted
        case 3: return .formNestingDepthExceeded(limit: try reader.readBoundedInt())
        case 4: return .cyclicFormReference
        case 5: return .softMaskNotComposited
        case 6: return .malformedContentStream(operandFailures: try reader.readBoundedInt())
        case 7: return .annotationAppearanceStreamsNotExtracted
        case 8: return .inlineImageSkipped(count: try reader.readBoundedInt())
        case 9: return .hiddenOptionalContentExcluded(count: try reader.readBoundedInt())
        case let other:
            throw VectorExtractionError.cacheDecodingFailed(reason: "unknown partial reason \(other)")
        }
    }

    private static func encodeUnavailableReason(_ reason: VectorUnavailableReason, into writer: inout BinaryWriter) {
        switch reason {
        case .noVectorContent:
            writer.write(byte: 0)
        case .onlyFilteredGeometry(let count):
            writer.write(byte: 1)
            writer.write(varint: count)
        case .emptyContentStream:
            writer.write(byte: 2)
        }
    }

    private static func decodeUnavailableReason(_ reader: inout BinaryReader) throws -> VectorUnavailableReason {
        switch try reader.readByte() {
        case 0: return .noVectorContent
        case 1: return .onlyFilteredGeometry(filteredCount: try reader.readBoundedInt())
        case 2: return .emptyContentStream
        case let other:
            throw VectorExtractionError.cacheDecodingFailed(reason: "unknown unavailable reason \(other)")
        }
    }

    // MARK: - Primitives

    private static func encodePrimitive(
        _ primitive: VectorPrimitive,
        layerIndex: [String: Int],
        colorIndex: [VectorColor: Int],
        into writer: inout BinaryWriter
    ) {
        writer.write(varint: primitive.id)
        if let parentID = primitive.parentID {
            writer.write(bool: true)
            writer.write(varint: parentID)
        } else {
            writer.write(bool: false)
        }
        writer.write(byte: primitive.kind.rawValue)
        encodeGeometry(primitive.geometry, into: &writer)
        writer.write(bounds: primitive.bounds)
        writer.write(varint: primitive.sourceObjectID)
        writer.write(varint: primitive.subpathIndex)
        writer.write(varint: primitive.nestingDepth)
        writer.write(byte: primitive.paint.rawValue)
        writer.write(double: primitive.strokeWidth)
        writer.write(bool: primitive.strokeIsDashed)
        writer.write(byte: primitive.clipRelation.rawValue)
        if let clipBounds = primitive.clipBounds {
            writer.write(bool: true)
            writer.write(bounds: clipBounds)
        } else {
            writer.write(bool: false)
        }
        writer.write(float: primitive.confidence)
        // Indices into the colour table, 0 for none; every colour was entered by `encode`.
        writer.write(varint: primitive.fillColor.flatMap { colorIndex[$0] }.map { $0 + 1 } ?? 0)
        writer.write(varint: primitive.strokeColor.flatMap { colorIndex[$0] }.map { $0 + 1 } ?? 0)
        // Index into the layer-name table, 0 for none. Every name a primitive carries
        // was entered into the table by `encode`, so the lookup cannot miss.
        writer.write(varint: primitive.layerID.flatMap { layerIndex[$0] }.map { $0 + 1 } ?? 0)
    }

    private static func decodePrimitive(
        _ reader: inout BinaryReader,
        layerNames: [String]?,
        colors: [VectorColor]?
    ) throws -> VectorPrimitive {
        let id = try reader.readVarint()
        let parentID: UInt64? = try reader.readBool() ? try reader.readVarint() : nil
        let rawKind = try reader.readByte()
        guard let kind = VectorPrimitiveKind(rawValue: rawKind) else {
            throw VectorExtractionError.cacheDecodingFailed(reason: "unknown primitive kind \(rawKind)")
        }
        let geometry = try decodeGeometry(&reader)
        let bounds = try reader.readBounds()
        let sourceObjectID = try reader.readVarint()
        let subpathIndex = try reader.readBoundedInt()
        let nestingDepth = try reader.readBoundedInt()
        let paint = VectorPaintRole(rawValue: try reader.readByte())
        let strokeWidth = try reader.readDouble()
        let dashed = try reader.readBool()
        let rawClip = try reader.readByte()
        guard let clipRelation = VectorClipRelation(rawValue: rawClip) else {
            throw VectorExtractionError.cacheDecodingFailed(reason: "unknown clip relation \(rawClip)")
        }
        let clipBounds: VectorBounds? = try reader.readBool() ? try reader.readBounds() : nil
        let confidence = try reader.readFloat()
        var fillColor: VectorColor?
        var strokeColor: VectorColor?
        if let colors {
            let fillIndex = try reader.readBoundedInt(limit: colors.count)
            let strokeIndex = try reader.readBoundedInt(limit: colors.count)
            fillColor = fillIndex == 0 ? nil : colors[fillIndex - 1]
            strokeColor = strokeIndex == 0 ? nil : colors[strokeIndex - 1]
        }
        let layerID: String?
        if let layerNames {
            let index = try reader.readBoundedInt(limit: layerNames.count)
            // The decoded names are shared: one `String` instance per distinct layer,
            // whatever the primitive count.
            layerID = index == 0 ? nil : layerNames[index - 1]
        } else {
            layerID = try reader.readOptionalString(limit: 4096)
        }

        return VectorPrimitive(
            id: id,
            parentID: parentID,
            kind: kind,
            geometry: geometry,
            bounds: bounds,
            sourceObjectID: sourceObjectID,
            subpathIndex: subpathIndex,
            nestingDepth: nestingDepth,
            paint: paint,
            strokeWidth: strokeWidth,
            strokeIsDashed: dashed,
            clipRelation: clipRelation,
            clipBounds: clipBounds,
            confidence: confidence,
            layerID: layerID,
            fillColor: fillColor,
            strokeColor: strokeColor
        )
    }

    /// Four doubles, each finite and within `0…1`; anything else is a damaged file.
    private static func decodeColor(_ reader: inout BinaryReader) throws -> VectorColor {
        let components = [
            try reader.readDouble(), try reader.readDouble(),
            try reader.readDouble(), try reader.readDouble()
        ]
        guard components.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else {
            throw VectorExtractionError.cacheDecodingFailed(reason: "colour component out of range")
        }
        return VectorColor(
            red: components[0], green: components[1], blue: components[2], alpha: components[3]
        )
    }

    private static func encodeGeometry(_ geometry: VectorGeometry, into writer: inout BinaryWriter) {
        switch geometry {
        case .line(let line):
            writer.write(byte: 0)
            writer.write(point: line.start)
            writer.write(point: line.end)
        case .cubic(let cubic):
            writer.write(byte: 1)
            writer.write(point: cubic.p0)
            writer.write(point: cubic.p1)
            writer.write(point: cubic.p2)
            writer.write(point: cubic.p3)
        case .rectangle(let quad):
            writer.write(byte: 2)
            writer.write(point: quad.c0)
            writer.write(point: quad.c1)
            writer.write(point: quad.c2)
            writer.write(point: quad.c3)
        case .ring(let ring):
            writer.write(byte: 3)
            writer.write(bool: ring.isClosed)
            writer.write(bool: ring.containsCurves)
            writer.write(varint: ring.vertices.count)
            for vertex in ring.vertices { writer.write(point: vertex) }
        }
    }

    private static func decodeGeometry(_ reader: inout BinaryReader) throws -> VectorGeometry {
        switch try reader.readByte() {
        case 0:
            return .line(VectorLine(start: try reader.readPoint(), end: try reader.readPoint()))
        case 1:
            return .cubic(
                VectorCubic(
                    p0: try reader.readPoint(),
                    p1: try reader.readPoint(),
                    p2: try reader.readPoint(),
                    p3: try reader.readPoint()
                )
            )
        case 2:
            return .rectangle(
                VectorQuad(
                    c0: try reader.readPoint(),
                    c1: try reader.readPoint(),
                    c2: try reader.readPoint(),
                    c3: try reader.readPoint()
                )
            )
        case 3:
            let isClosed = try reader.readBool()
            let containsCurves = try reader.readBool()
            let count = try reader.readCount(limit: maximumRingVertices)
            var vertices: [CGPoint] = []
            vertices.reserveCapacity(Swift.min(count, 1 << 14))
            for _ in 0..<count { vertices.append(try reader.readPoint()) }
            return .ring(
                VectorRing(vertices: vertices, isClosed: isClosed, containsCurves: containsCurves)
            )
        case let other:
            throw VectorExtractionError.cacheDecodingFailed(reason: "unknown geometry tag \(other)")
        }
    }

    // MARK: - Raster regions

    private static func encodeRasterRegion(_ region: VectorRasterRegion, into writer: inout BinaryWriter) {
        writer.write(varint: region.id)
        writer.write(point: region.placement.c0)
        writer.write(point: region.placement.c1)
        writer.write(point: region.placement.c2)
        writer.write(point: region.placement.c3)
        writer.write(bounds: region.bounds)
        writer.write(varint: region.nestingDepth)
        writer.write(varint: region.sourceObjectID)
        writer.write(bool: region.isInline)
        writer.write(optionalString: region.resourceName)
    }

    private static func decodeRasterRegion(_ reader: inout BinaryReader) throws -> VectorRasterRegion {
        let id = try reader.readVarint()
        let quad = VectorQuad(
            c0: try reader.readPoint(),
            c1: try reader.readPoint(),
            c2: try reader.readPoint(),
            c3: try reader.readPoint()
        )
        let bounds = try reader.readBounds()
        let depth = try reader.readBoundedInt()
        let sourceObjectID = try reader.readVarint()
        let isInline = try reader.readBool()
        let name = try reader.readOptionalString(limit: 4096)
        return VectorRasterRegion(
            id: id,
            placement: quad,
            bounds: bounds,
            nestingDepth: depth,
            sourceObjectID: sourceObjectID,
            isInline: isInline,
            resourceName: name
        )
    }

    // MARK: - Filter decisions

    private static func encodeFilterDecision(_ decision: VectorFilterDecision, into writer: inout BinaryWriter) {
        writer.write(byte: decision.rule.rawValue)
        writer.write(varint: decision.sourceObjectID)
        writer.write(varint: decision.subpathIndex)
        writer.write(varint: decision.nestingDepth)
        writer.write(bounds: decision.bounds)
        if let measured = decision.measuredValue {
            writer.write(bool: true)
            writer.write(double: measured)
        } else {
            writer.write(bool: false)
        }
        if let threshold = decision.threshold {
            writer.write(bool: true)
            writer.write(double: threshold)
        } else {
            writer.write(bool: false)
        }
    }

    private static func decodeFilterDecision(_ reader: inout BinaryReader) throws -> VectorFilterDecision {
        let rawRule = try reader.readByte()
        guard let rule = VectorFilterRule(rawValue: rawRule) else {
            throw VectorExtractionError.cacheDecodingFailed(reason: "unknown filter rule \(rawRule)")
        }
        let sourceObjectID = try reader.readVarint()
        let subpathIndex = try reader.readBoundedInt()
        let depth = try reader.readBoundedInt()
        let bounds = try reader.readBounds()
        let measured: Double? = try reader.readBool() ? try reader.readDouble() : nil
        let threshold: Double? = try reader.readBool() ? try reader.readDouble() : nil
        return VectorFilterDecision(
            rule: rule,
            sourceObjectID: sourceObjectID,
            subpathIndex: subpathIndex,
            nestingDepth: depth,
            bounds: bounds,
            measuredValue: measured,
            threshold: threshold
        )
    }

    // MARK: - Statistics

    private static func encodeStatistics(_ statistics: VectorExtractionStatistics, into writer: inout BinaryWriter) {
        writer.write(varint: statistics.operatorCount)
        writer.write(varint: statistics.primitiveCount)
        writer.write(varint: statistics.filteredCount)
        writer.write(varint: statistics.paintedPathCount)
        writer.write(varint: statistics.subpathCount)
        writer.write(varint: statistics.formInvocationCount)
        writer.write(varint: statistics.maximumNestingDepthReached)
        writer.write(varint: statistics.rasterRegionCount)
        writer.write(varint: statistics.inlineImageCount)
        writer.write(varint: statistics.malformedOperandCount)
        writer.write(varint: statistics.contentBytesCompleted)
        writer.write(varint: statistics.contentBytesEntered)
        // Deliberately not persisted. The elapsed time is a measurement of one run, not
        // a property of the page: writing it would make two encodings of the same page
        // differ, which defeats both byte-level determinism checks and any hope of a
        // cache file that diffs cleanly inside a project package.
        writer.write(fixed: UInt64(0))
        writer.write(varint: statistics.estimatedMemoryBytes)
    }

    private static func decodeStatistics(_ reader: inout BinaryReader) throws -> VectorExtractionStatistics {
        VectorExtractionStatistics(
            operatorCount: try reader.readBoundedInt(),
            primitiveCount: try reader.readBoundedInt(),
            filteredCount: try reader.readBoundedInt(),
            paintedPathCount: try reader.readBoundedInt(),
            subpathCount: try reader.readBoundedInt(),
            formInvocationCount: try reader.readBoundedInt(),
            maximumNestingDepthReached: try reader.readBoundedInt(),
            rasterRegionCount: try reader.readBoundedInt(),
            inlineImageCount: try reader.readBoundedInt(),
            malformedOperandCount: try reader.readBoundedInt(),
            contentBytesCompleted: try reader.readBoundedInt(),
            contentBytesEntered: try reader.readBoundedInt(),
            elapsedNanoseconds: try reader.readFixedUInt64(),
            estimatedMemoryBytes: try reader.readBoundedInt()
        )
    }
}
