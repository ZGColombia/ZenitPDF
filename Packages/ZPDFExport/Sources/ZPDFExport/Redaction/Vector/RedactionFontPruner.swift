import Foundation

/// A font that lost glyphs under a box, reduced to the codes the copy still draws (findings 9,
/// 19, ADR-0033 §11).
///
/// Removing a glyph from the content leaves the font saying it was there: a non-zero width, a
/// Unicode entry, a `/Differences` name, a Type 3 glyph procedure, a glyph outline in the
/// embedded program — together with the kept `TJ` gap, enough to narrow down a short number.
/// The copy therefore carries, for every such font, a new font object holding only what the
/// codes still drawn anywhere in the copy need:
///
/// - `/FirstChar`…`/LastChar` narrowed to the drawn codes, a zero width for every other code;
/// - `/Differences` and `/ToUnicode` with entries for the drawn codes only;
/// - Type 3: `/CharProcs` for the drawn glyphs only, `/Resources` for what they use;
/// - CID fonts: `/W` for the drawn CIDs only, `/CIDToGIDMap` zero for every other CID, the
///   embedded CMap with the drawn codes only;
/// - the font descriptor without `/CharSet` and `/CIDSet` (lists of the glyphs present), and
///   its embedded program with every other glyph's outline removed (``RedactionFontPrograms``).
///
/// The writer puts the new object wherever the original was named.
enum RedactionFontPruner {

    static func prune(_ font: [String: PDFObject], codes: Set<RedactionFont.Code>, context: RedactionRewriteContext) throws -> PDFObject {
        let resolve: (PDFObject?) -> PDFObject? = { context.resolve($0) }
        var copy = font
        switch resolve(font["Subtype"])?.nameValue ?? "" {
        case "Type0":
            try pruneComposite(&copy, codes: codes, context: context)
        case "Type3":
            try pruneType3(&copy, codes: codes, context: context)
        default:
            try pruneSimple(&copy, codes: codes, context: context)
        }
        if font["ToUnicode"] != nil {
            if let toUnicode = prunedToUnicode(font["ToUnicode"], codes: codes, context: context) {
                copy["ToUnicode"] = toUnicode
            } else {
                copy.removeValue(forKey: "ToUnicode")
            }
        }
        return context.pool.add(.dictionary(copy))
    }

    // MARK: - Simple fonts

    private static func singleByteCodes(_ codes: Set<RedactionFont.Code>) -> Set<Int> {
        Set(codes.filter { $0.length == 1 }.map { Int($0.value) })
    }

    /// `/FirstChar`, `/LastChar` and `/Widths` for the drawn codes only.
    private static func pruneWidths(_ copy: inout [String: PDFObject], values: Set<Int>, resolve: (PDFObject?) -> PDFObject?) {
        guard let widths = resolve(copy["Widths"])?.arrayValue, let first = resolve(copy["FirstChar"])?.integerValue else { return }
        let kept = values.filter { $0 >= first && $0 < first + widths.count }.sorted()
        if let low = kept.first, let high = kept.last {
            copy["FirstChar"] = .integer(low)
            copy["LastChar"] = .integer(high)
            copy["Widths"] = .array((low...high).map { values.contains($0) ? widths[$0 - first] : .integer(0) })
        } else {
            copy["FirstChar"] = .integer(first)
            copy["LastChar"] = .integer(first)
            copy["Widths"] = .array([.integer(0)])
        }
    }

    /// The encoding with `/Differences` naming the drawn codes only; the glyph name for each
    /// drawn code is returned (for Type 3 procedures and the embedded program).
    private static func pruneEncoding(_ copy: inout [String: PDFObject], values: Set<Int>, resolve: (PDFObject?) -> PDFObject?) -> [Int: String] {
        guard var encoding = resolve(copy["Encoding"])?.dictionaryValue else { return [:] }
        let names = RedactionFont.differences(encoding, resolve: resolve)
        guard encoding["Differences"] != nil else { return [:] }
        let kept = names.filter { values.contains($0.key) }.sorted { $0.key < $1.key }
        var array: [PDFObject] = []
        var previous = Int.min
        for (code, name) in kept {
            if previous == Int.min || code != previous + 1 { array.append(.integer(code)) }
            array.append(.name(name))
            previous = code
        }
        encoding["Differences"] = .array(array)
        copy["Encoding"] = .dictionary(encoding)
        return Dictionary(uniqueKeysWithValues: kept)
    }

    private static func pruneSimple(_ copy: inout [String: PDFObject], codes: Set<RedactionFont.Code>, context: RedactionRewriteContext) throws {
        let resolve: (PDFObject?) -> PDFObject? = { context.resolve($0) }
        let values = singleByteCodes(codes)
        let original = copy
        pruneWidths(&copy, values: values, resolve: resolve)
        let names = pruneEncoding(&copy, values: values, resolve: resolve)
        guard var descriptor = resolve(copy["FontDescriptor"])?.dictionaryValue else { return }
        descriptor.removeValue(forKey: "CharSet")
        descriptor.removeValue(forKey: "CIDSet")
        try RedactionFontPrograms.pruneSimple(&descriptor, font: original, codes: values, differences: names, context: context)
        copy["FontDescriptor"] = context.pool.add(.dictionary(descriptor))
    }

    // MARK: - Type 3

    private static func pruneType3(_ copy: inout [String: PDFObject], codes: Set<RedactionFont.Code>, context: RedactionRewriteContext) throws {
        let resolve: (PDFObject?) -> PDFObject? = { context.resolve($0) }
        let values = singleByteCodes(codes)
        let allNames = RedactionFont.differences(resolve(copy["Encoding"])?.dictionaryValue, resolve: resolve)
        pruneWidths(&copy, values: values, resolve: resolve)
        _ = pruneEncoding(&copy, values: values, resolve: resolve)
        let keptNames = Set(values.compactMap { allNames[$0] })
        var procs: [String: PDFObject] = [:]
        var used: [String: Set<String>] = [:]
        for (name, proc) in resolve(copy["CharProcs"])?.dictionaryValue ?? [:] where keptNames.contains(name) {
            procs[name] = proc
            if case let .stream(dictionary, data)? = resolve(proc),
               let decoded = try? RedactionStreamFilters.decode(dictionary: dictionary, data: data).data,
               let operations = try? RedactionContentLexer.parse(decoded) {
                for (category, names) in VectorRedactor.usedNames(operations) { used[category, default: []].formUnion(names) }
            } else {
                throw RedactionUnsupported("a Type 3 glyph procedure cannot be read")
            }
        }
        copy["CharProcs"] = .dictionary(procs)
        if let resources = resolve(copy["Resources"])?.dictionaryValue {
            var pruned: [String: PDFObject] = [:]
            for (key, value) in resources {
                guard ["Font", "XObject", "ExtGState", "Pattern", "Shading", "Properties"].contains(key) else {
                    pruned[key] = value
                    continue
                }
                let entries = (resolve(value)?.dictionaryValue ?? [:]).filter { used[key]?.contains($0.key) ?? false }
                if !entries.isEmpty { pruned[key] = .dictionary(entries) }
            }
            copy["Resources"] = .dictionary(pruned)
        }
    }

    // MARK: - Composite fonts

    private static func pruneComposite(_ copy: inout [String: PDFObject], codes: Set<RedactionFont.Code>, context: RedactionRewriteContext) throws {
        let resolve: (PDFObject?) -> PDFObject? = { context.resolve($0) }
        guard let descendants = resolve(copy["DescendantFonts"])?.arrayValue, var cidFont = resolve(descendants.first)?.dictionaryValue else {
            throw RedactionUnsupported("a composite font has no descendant font")
        }
        // Code → CID through the encoding.
        var cids: Set<UInt32> = []
        switch resolve(copy["Encoding"]) {
        case .name("Identity-H")?, .name("Identity-V")?:
            cids = Set(codes.map(\.value))
        case let .stream(dictionary, data)?:
            let map = try RedactionCMap(try RedactionStreamFilters.decode(dictionary: dictionary, data: data).data)
            cids = Set(codes.map { map.cid(for: $0) ?? 0 })
            copy["Encoding"] = prunedEncodingCMap(dictionary: dictionary, map: map, codes: codes, context: context)
        default:
            throw RedactionUnsupported("a composite font's encoding cannot be read")
        }

        // Widths for the drawn CIDs only.
        if let array = resolve(cidFont["W"])?.arrayValue {
            let (explicit, ranges) = try RedactionFont.readW(array, resolve: resolve)
            var w: [PDFObject] = []
            for cid in cids.sorted() {
                let width = explicit[cid] ?? ranges.first(where: { $0.0 <= cid && cid <= $0.1 })?.2
                guard let width else { continue }
                w.append(.integer(Int(cid)))
                w.append(.array([.real(width)]))
            }
            cidFont["W"] = .array(w)
        }

        // CID → GID: every CID not drawn maps to glyph 0.
        var gids: Set<Int> = []
        switch resolve(cidFont["CIDToGIDMap"]) {
        case let .stream(dictionary, data)?:
            let map = [UInt8](try RedactionStreamFilters.decode(dictionary: dictionary, data: data).data)
            let highest = Int(cids.max() ?? 0)
            var pruned = [UInt8](repeating: 0, count: min(map.count, (highest + 1) * 2))
            for cid in cids where Int(cid) * 2 + 1 < map.count && Int(cid) * 2 + 1 < pruned.count {
                let index = Int(cid) * 2
                pruned[index] = map[index]
                pruned[index + 1] = map[index + 1]
                gids.insert(Int(map[index]) << 8 | Int(map[index + 1]))
            }
            var streamDictionary: [String: PDFObject] = [:]
            var payload = Data(pruned)
            if let flate = PDFStreamCodec.flateEncode(payload) {
                payload = flate
                streamDictionary["Filter"] = .name("FlateDecode")
            }
            cidFont["CIDToGIDMap"] = context.pool.add(.stream(dictionary: streamDictionary, data: payload))
        default:
            gids = Set(cids.map { Int($0) })
        }

        if var descriptor = resolve(cidFont["FontDescriptor"])?.dictionaryValue {
            descriptor.removeValue(forKey: "CharSet")
            descriptor.removeValue(forKey: "CIDSet")
            try RedactionFontPrograms.pruneComposite(&descriptor, cids: cids, gids: gids, context: context)
            cidFont["FontDescriptor"] = context.pool.add(.dictionary(descriptor))
        }
        copy["DescendantFonts"] = .array([context.pool.add(.dictionary(cidFont))])
    }

    /// An embedded encoding CMap reduced to the drawn codes, each mapped to its CID.
    private static func prunedEncodingCMap(
        dictionary: [String: PDFObject], map: RedactionCMap, codes: Set<RedactionFont.Code>, context: RedactionRewriteContext
    ) -> PDFObject {
        var text = "/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n/CMapName /Zenit-Redacted def\n/CMapType 1 def\n"
        text += codeSpaceSection(map.codeSpace, codes: codes)
        let entries = codes.sorted { ($0.length, $0.value) < ($1.length, $1.value) }
        for chunk in stride(from: 0, to: entries.count, by: 100) {
            let slice = entries[chunk..<min(entries.count, chunk + 100)]
            text += "\(slice.count) begincidchar\n"
            for code in slice { text += "<\(hex(code))> \(map.cid(for: code) ?? 0)\n" }
            text += "endcidchar\n"
        }
        text += "endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n"
        var streamDictionary: [String: PDFObject] = ["Type": .name("CMap"), "CMapName": .name("Zenit-Redacted"), "WMode": .integer(0)]
        if let info = dictionary["CIDSystemInfo"] { streamDictionary["CIDSystemInfo"] = info }
        return context.pool.add(stream(Data(text.utf8), dictionary: streamDictionary))
    }

    // MARK: - ToUnicode

    /// A ToUnicode CMap with entries for the drawn codes only, or `nil` when the original cannot
    /// be read (then none travels: an unreadable map cannot be reduced).
    static func prunedToUnicode(_ object: PDFObject?, codes: Set<RedactionFont.Code>, context: RedactionRewriteContext) -> PDFObject? {
        guard case let .stream(dictionary, data)? = context.resolve(object),
              let decoded = try? RedactionStreamFilters.decode(dictionary: dictionary, data: data).data,
              let map = try? RedactionCMap(decoded) else { return nil }
        var text = "/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n"
        text += "/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n/CMapName /Adobe-Identity-UCS def\n/CMapType 2 def\n"
        text += codeSpaceSection(map.codeSpace, codes: codes)
        let entries = codes.sorted { ($0.length, $0.value) < ($1.length, $1.value) }.compactMap { code -> (RedactionFont.Code, String)? in
            guard let unicode = map.unicode(for: code), !unicode.isEmpty else { return nil }
            return (code, unicode)
        }
        for chunk in stride(from: 0, to: entries.count, by: 100) {
            let slice = entries[chunk..<min(entries.count, chunk + 100)]
            text += "\(slice.count) beginbfchar\n"
            for (code, unicode) in slice {
                text += "<\(hex(code))> <\(unicode.utf16.map { String(format: "%04X", $0) }.joined())>\n"
            }
            text += "endbfchar\n"
        }
        text += "endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n"
        return context.pool.add(stream(Data(text.utf8), dictionary: [:]))
    }

    private static func codeSpaceSection(_ ranges: [RedactionCMap.Range], codes: Set<RedactionFont.Code>) -> String {
        var lines: [String] = ranges.map { range in
            "<\(range.low.map { String(format: "%02X", $0) }.joined())> <\(range.high.map { String(format: "%02X", $0) }.joined())>"
        }
        if lines.isEmpty {
            let lengths = Set(codes.map(\.length)).sorted()
            lines = (lengths.isEmpty ? [1] : lengths).map { length in
                "<\(String(repeating: "00", count: length))> <\(String(repeating: "FF", count: length))>"
            }
        }
        return "\(lines.count) begincodespacerange\n" + lines.joined(separator: "\n") + "\nendcodespacerange\n"
    }

    private static func hex(_ code: RedactionFont.Code) -> String {
        (0..<code.length).reversed().map { String(format: "%02X", (code.value >> (8 * UInt32($0))) & 0xFF) }.joined()
    }

    static func stream(_ data: Data, dictionary: [String: PDFObject]) -> PDFObject {
        var entries = dictionary
        var payload = data
        if let flate = PDFStreamCodec.flateEncode(data) {
            payload = flate
            entries["Filter"] = .name("FlateDecode")
        }
        return .stream(dictionary: entries, data: payload)
    }
}
