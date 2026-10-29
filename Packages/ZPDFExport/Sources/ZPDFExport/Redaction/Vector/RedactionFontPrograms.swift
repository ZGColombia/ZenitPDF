import Foundation

/// Embedded font programs reduced to the glyphs a redacted copy still draws (finding 19).
///
/// TrueType outlines (`/FontFile2`, or `/FontFile3` of subtype `/OpenType` with a `glyf` table)
/// go through ``RedactionTrueType``; CFF outlines (`/FontFile3` `/Type1C`, `/CIDFontType0C`, or
/// OpenType with a `CFF ` table) through ``RedactionCFF``; Type 1 programs (`/FontFile`) through
/// ``RedactionType1``. A program none of them can read is a refusal: the copy never carries
/// outlines of characters that stood only in the removed text.
enum RedactionFontPrograms {

    /// A simple font's program keeping only the glyphs of `codes`.
    static func pruneSimple(
        _ descriptor: inout [String: PDFObject], font: [String: PDFObject], codes: Set<Int>, differences: [Int: String],
        context: RedactionRewriteContext
    ) throws {
        let resolve: (PDFObject?) -> PDFObject? = { context.resolve($0) }
        var unicode: [Int: String] = [:]
        if case let .stream(dictionary, data)? = resolve(font["ToUnicode"]),
           let decoded = try? RedactionStreamFilters.decode(dictionary: dictionary, data: data).data, let map = try? RedactionCMap(decoded) {
            for code in codes { unicode[code] = map.unicode(for: RedactionFont.Code(value: UInt32(code), length: 1)) }
        }
        let names = differences.merging(standardNames(for: codes, font: font, resolve: resolve)) { kept, _ in kept }
        if let program = descriptor["FontFile2"] {
            descriptor["FontFile2"] = try pruneSFNT(program, context: context) { sfnt in
                try RedactionTrueType.glyphs(forSimpleCodes: codes, font: sfnt, names: names, unicode: unicode)
            } cff: { _ in throw RedactionUnsupported("a TrueType program holds CFF outlines") }
        } else if let program = descriptor["FontFile3"] {
            descriptor["FontFile3"] = try pruneFontFile3(program, context: context,
                                                         trueType: { try RedactionTrueType.glyphs(forSimpleCodes: codes, font: $0, names: names, unicode: unicode) },
                                                         cff: { try RedactionCFF.prune($0, simpleCodes: codes, names: names) })
        } else if let program = descriptor["FontFile"] {
            descriptor["FontFile"] = try pruneType1(program, names: Set(codes.compactMap { names[$0] }), codes: codes, context: context)
        }
    }

    /// A CID font's program keeping only the glyphs of `gids` (TrueType) or `cids` (CFF).
    static func pruneComposite(_ descriptor: inout [String: PDFObject], cids: Set<UInt32>, gids: Set<Int>, context: RedactionRewriteContext) throws {
        if let program = descriptor["FontFile2"] {
            descriptor["FontFile2"] = try pruneSFNT(program, context: context) { _ in gids } cff: { _ in
                throw RedactionUnsupported("a TrueType program holds CFF outlines")
            }
        } else if let program = descriptor["FontFile3"] {
            descriptor["FontFile3"] = try pruneFontFile3(program, context: context, trueType: { _ in gids },
                                                         cff: { try RedactionCFF.prune($0, cids: cids) })
        } else if descriptor["FontFile"] != nil {
            throw RedactionUnsupported("a CID font carries a Type 1 program")
        }
    }

    /// Glyph names the standard encodings give the codes a font draws without `/Differences`.
    private static func standardNames(for codes: Set<Int>, font: [String: PDFObject], resolve: (PDFObject?) -> PDFObject?) -> [Int: String] {
        let encoding = resolve(font["Encoding"])
        let base = encoding?.nameValue ?? resolve(encoding?.dictionaryValue?["BaseEncoding"])?.nameValue
        var out: [Int: String] = [:]
        for code in codes {
            if let name = RedactionGlyphTables.name(code: code, encoding: base) { out[code] = name }
        }
        return out
    }

    private static func pruneFontFile3(
        _ reference: PDFObject, context: RedactionRewriteContext,
        trueType: (RedactionTrueType.Font) throws -> Set<Int>, cff: ([UInt8]) throws -> [UInt8]
    ) throws -> PDFObject {
        guard case let .stream(dictionary, _)? = context.resolve(reference) else { throw RedactionUnsupported("an embedded font program is missing") }
        switch context.resolve(dictionary["Subtype"])?.nameValue {
        case "OpenType"?:
            return try pruneSFNT(reference, context: context, trueType: trueType, cff: cff)
        case "Type1C"?, "CIDFontType0C"?:
            return try pruneStream(reference, context: context) { Data(try cff([UInt8]($0))) }
        default:
            throw RedactionUnsupported("an embedded font program of an unknown kind cannot be reduced")
        }
    }

    /// A TrueType or OpenType program: TrueType outlines kept for the glyphs `trueType` names,
    /// or its CFF table reduced by `cff`.
    private static func pruneSFNT(
        _ reference: PDFObject, context: RedactionRewriteContext,
        trueType: (RedactionTrueType.Font) throws -> Set<Int>, cff: ([UInt8]) throws -> [UInt8]
    ) throws -> PDFObject {
        try pruneStream(reference, context: context) { data in
            var font = try RedactionTrueType.parse(data)
            if font.tables["glyf"] != nil {
                return try RedactionTrueType.prune(data, keep: try trueType(font))
            }
            guard let table = font.tables["CFF "] else { throw RedactionUnsupported("an OpenType program has neither TrueType nor CFF outlines") }
            let pruned = try cff(table)
            // The wrapper's character map keeps only glyphs that still have outlines.
            let outlines = try RedactionCFF.parse(pruned).charStrings
            let kept = Set(outlines.indices.filter { $0 == 0 || outlines[$0] != [14] })
            font.tables["cmap"] = try RedactionTrueType.rebuiltCharacterMaps(RedactionTrueType.characterMaps(font), keep: kept)
            font.tables["CFF "] = pruned
            font.tables = font.tables.filter { RedactionTrueType.keptTables.contains($0.key) || $0.key == "CFF " }
            if let post = font.tables["post"], post.count >= 32 {
                var header = Array(post.prefix(32))
                header[0] = 0; header[1] = 3; header[2] = 0; header[3] = 0
                font.tables["post"] = header
            }
            return RedactionTrueType.serialize(font)
        }
    }

    private static func pruneType1(_ reference: PDFObject, names: Set<String>, codes: Set<Int>, context: RedactionRewriteContext) throws -> PDFObject {
        guard case let .stream(dictionary, data)? = context.resolve(reference) else { throw RedactionUnsupported("an embedded font program is missing") }
        let decoded = try RedactionStreamFilters.decode(dictionary: dictionary, data: data).data
        let length1 = context.resolve(dictionary["Length1"])?.integerValue ?? 0
        let length2 = context.resolve(dictionary["Length2"])?.integerValue ?? 0
        let pruned = try RedactionType1.prune([UInt8](decoded), length1: length1, length2: length2, keepNames: names, keepCodes: codes)
        var entries: [String: PDFObject] = [
            "Length1": .integer(pruned.length1), "Length2": .integer(pruned.length2), "Length3": .integer(pruned.length3)
        ]
        var payload = Data(pruned.bytes)
        if let flate = PDFStreamCodec.flateEncode(payload) {
            payload = flate
            entries["Filter"] = .name("FlateDecode")
        }
        return context.pool.add(.stream(dictionary: entries, data: payload))
    }

    /// The program stream decoded, transformed, and written back Flate-compressed with the
    /// length and subtype keys a reader needs.
    private static func pruneStream(_ reference: PDFObject, context: RedactionRewriteContext, _ transform: (Data) throws -> Data) throws -> PDFObject {
        guard case let .stream(dictionary, data)? = context.resolve(reference) else { throw RedactionUnsupported("an embedded font program is missing") }
        let decoded = try RedactionStreamFilters.decode(dictionary: dictionary, data: data).data
        let pruned = try transform(decoded)
        var entries: [String: PDFObject] = [:]
        if let subtype = dictionary["Subtype"] { entries["Subtype"] = subtype } else { entries["Length1"] = .integer(pruned.count) }
        var payload = pruned
        if let flate = PDFStreamCodec.flateEncode(pruned) {
            payload = flate
            entries["Filter"] = .name("FlateDecode")
        }
        return context.pool.add(.stream(dictionary: entries, data: payload))
    }
}
