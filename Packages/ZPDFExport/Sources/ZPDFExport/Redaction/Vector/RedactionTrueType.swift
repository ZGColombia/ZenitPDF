import Foundation

/// An embedded TrueType program (or an OpenType one with TrueType outlines) reduced to the
/// glyphs a redacted copy still draws (finding 19).
///
/// Every other glyph's outline is removed (its `glyf` entry becomes empty), its metrics zeroed,
/// and every table that lists glyphs by name or by character — `cmap`, `post` names — keeps only
/// the kept glyphs. Tables a PDF renderer does not use and that describe glyph relations
/// (kerning, substitution, positioning) do not travel. Glyph numbering is unchanged, so the
/// font dictionary's `/CIDToGIDMap` and encoding still point at the right glyphs.
enum RedactionTrueType {

    struct Font {
        var version: UInt32
        var tables: [String: [UInt8]]
    }

    // MARK: - Reading

    static func parse(_ data: Data) throws -> Font {
        let bytes = [UInt8](data)
        guard bytes.count >= 12 else { throw RedactionUnsupported("an embedded TrueType program is truncated") }
        let version = u32(bytes, 0)
        guard version == 0x0001_0000 || version == 0x7472_7565 || version == 0x4F54_544F else {
            throw RedactionUnsupported("an embedded font program is not TrueType or OpenType")
        }
        let count = Int(u16(bytes, 4))
        guard 12 + count * 16 <= bytes.count else { throw RedactionUnsupported("an embedded TrueType program is truncated") }
        var tables: [String: [UInt8]] = [:]
        for index in 0..<count {
            let record = 12 + index * 16
            let tag = String(decoding: bytes[record..<(record + 4)], as: UTF8.self)
            let offset = Int(u32(bytes, record + 8)), length = Int(u32(bytes, record + 12))
            guard offset >= 0, length >= 0, offset <= bytes.count, length <= bytes.count - offset else {
                throw RedactionUnsupported("an embedded TrueType program has a table outside the file")
            }
            tables[tag] = Array(bytes[offset..<(offset + length)])
        }
        return Font(version: version, tables: tables)
    }

    static func numberOfGlyphs(_ font: Font) throws -> Int {
        guard let maxp = font.tables["maxp"], maxp.count >= 6 else { throw RedactionUnsupported("an embedded TrueType program has no glyph count") }
        return Int(u16(maxp, 4))
    }

    /// Each glyph's byte range in `glyf`.
    static func glyphRanges(_ font: Font) throws -> [Range<Int>] {
        guard let head = font.tables["head"], head.count >= 54, let loca = font.tables["loca"], let glyf = font.tables["glyf"] else {
            throw RedactionUnsupported("an embedded TrueType program has no glyph table")
        }
        let count = try numberOfGlyphs(font)
        let long = i16(head, 50) != 0
        var offsets: [Int] = []
        for index in 0...count {
            if long {
                guard index * 4 + 4 <= loca.count else { throw RedactionUnsupported("an embedded TrueType program's glyph index is short") }
                offsets.append(Int(u32(loca, index * 4)))
            } else {
                guard index * 2 + 2 <= loca.count else { throw RedactionUnsupported("an embedded TrueType program's glyph index is short") }
                offsets.append(Int(u16(loca, index * 2)) * 2)
            }
        }
        return try (0..<count).map { index in
            let start = offsets[index], end = offsets[index + 1]
            guard start <= end, end <= glyf.count else { throw RedactionUnsupported("an embedded TrueType program's glyph index points outside its glyphs") }
            return start..<end
        }
    }

    /// The glyphs a composite glyph is built from.
    static func components(_ glyph: ArraySlice<UInt8>) -> [Int] {
        let bytes = Array(glyph)
        guard bytes.count >= 10, i16(bytes, 0) < 0 else { return [] }
        var out: [Int] = []
        var offset = 10
        while offset + 4 <= bytes.count {
            let flags = u16(bytes, offset)
            out.append(Int(u16(bytes, offset + 2)))
            offset += 4
            offset += flags & 0x0001 != 0 ? 4 : 2
            if flags & 0x0008 != 0 { offset += 2 } else if flags & 0x0040 != 0 { offset += 4 } else if flags & 0x0080 != 0 { offset += 8 }
            guard flags & 0x0020 != 0 else { break }
        }
        return out
    }

    /// Codes one format 4 subtable may map: the whole 16-bit code space. Its segments do not
    /// overlap in a real font, so their lengths add up to at most this.
    static let format4CodeCeiling = 0x1_0000
    /// Codes one format 12 subtable may map: every Unicode scalar value, 0…0x10FFFF.
    static let format12CodeCeiling = 0x11_0000
    /// Work one character map may cost: one unit per code a subtable read visits, and one per
    /// entry each encoding record puts into the result, whether or not it shares its subtable
    /// with another record. A large real font — a BMP table and a full Unicode table, each named
    /// by two records — spends well under a million.
    static let characterMapCodeCeiling = 4 * 0x11_0000
    /// Encoding records one `cmap` may list. A real font has two to six (Unicode, Windows
    /// Unicode or symbol, Macintosh Roman); the table's count field allows 65 535.
    static let characterMapRecordCeiling = 64

    private static func tooManyCodes() -> RedactionUnsupported {
        RedactionUnsupported("an embedded TrueType program's character map lists more codes than a font can have")
    }

    /// Every (platform, encoding) subtable of `cmap` this reader understands, as code → glyph.
    ///
    /// The codes the subtables map are counted, and a table that maps more than a real font can
    /// is refused. Format 12 used to accept 100 000 groups of 65 536 codes each — 6.5 billion
    /// dictionary writes from a 1.2 MB table — and format 4 32 767 overlapping segments of
    /// 65 536, about 2.1 billion from 260 KB: a hang, or no memory, in-process (T-045). Records
    /// that share an offset read the subtable once, but every record pays for the entries it
    /// adds to the result: 65 535 records naming one 0x110000-code table used to cost one read
    /// and then 65 535 copies of 1.1 million entries here, and as many again in
    /// ``rebuiltCharacterMaps(_:keep:)`` (T-045, re-check). So the result holds at most
    /// ``characterMapRecordCeiling`` keys and at most ``characterMapCodeCeiling`` entries in all,
    /// which bounds every caller's per-key work too.
    static func characterMaps(_ font: Font) throws -> [UInt32: [UInt32: Int]] {
        guard let cmap = font.tables["cmap"], cmap.count >= 4 else { return [:] }
        let count = Int(u16(cmap, 2))
        guard count <= characterMapRecordCeiling else {
            throw RedactionUnsupported("an embedded TrueType program's character map lists more encodings than a font has")
        }
        var out: [UInt32: [UInt32: Int]] = [:]
        var read: [Int: [UInt32: Int]] = [:]
        var budget = characterMapCodeCeiling
        for index in 0..<count {
            let record = 4 + index * 8
            guard record + 8 <= cmap.count else { break }
            let key = UInt32(u16(cmap, record)) << 16 | UInt32(u16(cmap, record + 2))
            let offset = Int(u32(cmap, record + 4))
            guard offset + 2 <= cmap.count else { continue }
            let map: [UInt32: Int]
            if let known = read[offset] {
                map = known
            } else {
                guard let parsed = try subtable(cmap, at: offset, budget: &budget) else { continue }
                read[offset] = parsed
                map = parsed
            }
            // Charged before any copy is made, shared subtable or not.
            budget -= map.count
            guard budget >= 0 else { throw tooManyCodes() }
            if out[key] == nil { out[key] = map } else { out[key]?.merge(map) { first, _ in first } }
        }
        return out
    }

    /// One subtable, spending one unit of `budget` per code it visits.
    private static func subtable(_ cmap: [UInt8], at offset: Int, budget: inout Int) throws -> [UInt32: Int]? {
        var map: [UInt32: Int] = [:]
        func spend(_ codes: Int, ceiling: inout Int) throws {
            ceiling -= codes
            budget -= codes
            guard ceiling >= 0, budget >= 0 else { throw tooManyCodes() }
        }
        var unbounded = Int.max
        switch u16(cmap, offset) {
        case 0:
            guard offset + 6 + 256 <= cmap.count else { return nil }
            try spend(256, ceiling: &unbounded)
            for code in 0..<256 where cmap[offset + 6 + code] != 0 { map[UInt32(code)] = Int(cmap[offset + 6 + code]) }
        case 4:
            guard offset + 14 <= cmap.count else { return nil }
            let segments = Int(u16(cmap, offset + 6)) / 2
            let ends = offset + 14, starts = ends + segments * 2 + 2, deltas = starts + segments * 2, ranges = deltas + segments * 2
            guard ranges + segments * 2 <= cmap.count else { return nil }
            var ceiling = format4CodeCeiling
            for segment in 0..<segments {
                let end = Int(u16(cmap, ends + segment * 2)), start = Int(u16(cmap, starts + segment * 2))
                let delta = Int(u16(cmap, deltas + segment * 2)), rangeOffset = Int(u16(cmap, ranges + segment * 2))
                guard start <= end, end - start < 0x10000 else { continue }
                try spend(end - start + 1, ceiling: &ceiling)
                for code in start...end where code != 0xFFFF {
                    var glyph: Int
                    if rangeOffset == 0 {
                        glyph = (code + delta) & 0xFFFF
                    } else {
                        let address = ranges + segment * 2 + rangeOffset + (code - start) * 2
                        guard address + 2 <= cmap.count else { continue }
                        glyph = Int(u16(cmap, address))
                        if glyph != 0 { glyph = (glyph + delta) & 0xFFFF }
                    }
                    if glyph != 0 { map[UInt32(code)] = glyph }
                }
            }
        case 6:
            guard offset + 10 <= cmap.count else { return nil }
            let first = Int(u16(cmap, offset + 6)), count = Int(u16(cmap, offset + 8))
            guard offset + 10 + count * 2 <= cmap.count else { return nil }
            try spend(count, ceiling: &unbounded)
            for index in 0..<count {
                let glyph = Int(u16(cmap, offset + 10 + index * 2))
                if glyph != 0 { map[UInt32(first + index)] = glyph }
            }
        case 12:
            guard offset + 16 <= cmap.count else { return nil }
            let groups = Int(u32(cmap, offset + 12))
            guard groups < 100_000, offset + 16 + groups * 12 <= cmap.count else { return nil }
            var ceiling = format12CodeCeiling
            for group in 0..<groups {
                let base = offset + 16 + group * 12
                // Codes past U+10FFFF name no character: dropped, never visited.
                let start = u32(cmap, base), end = min(u32(cmap, base + 4), 0x10_FFFF), glyph = Int(u32(cmap, base + 8))
                guard start <= end, end - start < 0x10000 else { continue }
                try spend(Int(end - start) + 1, ceiling: &ceiling)
                for code in start...end { map[code] = glyph + Int(code - start) }
            }
        default:
            return nil
        }
        return map
    }

    /// Glyph names from a format 2 `post` table.
    static func postNames(_ font: Font) -> [Int: String] {
        guard let post = font.tables["post"], post.count >= 34, u32(post, 0) == 0x0002_0000 else { return [:] }
        let count = Int(u16(post, 32))
        guard 34 + count * 2 <= post.count else { return [:] }
        var custom: [String] = []
        var offset = 34 + count * 2
        while offset < post.count {
            let length = Int(post[offset])
            guard offset + 1 + length <= post.count else { break }
            custom.append(String(decoding: post[(offset + 1)..<(offset + 1 + length)], as: UTF8.self))
            offset += 1 + length
        }
        var out: [Int: String] = [:]
        for glyph in 0..<count {
            let index = Int(u16(post, 34 + glyph * 2))
            if index < 258 {
                out[glyph] = RedactionGlyphTables.macintoshNames.indices.contains(index) ? RedactionGlyphTables.macintoshNames[index] : nil
            } else if index - 258 < custom.count {
                out[glyph] = custom[index - 258]
            }
        }
        return out
    }

    /// The glyphs a simple TrueType font draws for `codes`, found every way a renderer may look
    /// them up (ISO 32000-1 §9.6.6.4): the (3,0) table at the code and at 0xF000–0xF2FF plus
    /// the code, the (1,0) table, the Unicode tables through the glyph name or Unicode text the
    /// code stands for, and `post` names. A glyph found any of these ways is kept.
    static func glyphs(forSimpleCodes codes: Set<Int>, font: Font, names: [Int: String], unicode: [Int: String]) throws -> Set<Int> {
        let maps = try characterMaps(font)
        let post = postNames(font)
        var byName: [String: Int] = [:]
        for (glyph, name) in post where byName[name] == nil { byName[name] = glyph }
        var out: Set<Int> = [0]
        for code in codes {
            let value = UInt32(code)
            for (key, map) in maps {
                let platform = key >> 16, encoding = key & 0xFFFF
                if platform == 3, encoding == 0 {
                    for candidate in [value, 0xF000 | value, 0xF100 | value, 0xF200 | value] { if let glyph = map[candidate] { out.insert(glyph) } }
                } else if platform == 1, encoding == 0 {
                    if let glyph = map[value] { out.insert(glyph) }
                } else if platform == 0 || (platform == 3 && (encoding == 1 || encoding == 10)) {
                    var scalars: [UInt32] = []
                    if let name = names[code], let text = RedactionGlyphNames.unicode(for: name) { scalars += text.unicodeScalars.map(\.value) }
                    if let text = unicode[code] { scalars += text.unicodeScalars.map(\.value) }
                    if names[code] == nil, (32...126).contains(code) { scalars.append(value) }
                    for scalar in scalars { if let glyph = map[scalar] { out.insert(glyph) } }
                }
            }
            if let name = names[code], let glyph = byName[name] { out.insert(glyph) }
            // With no character table a renderer uses the code as the glyph number.
            if maps.isEmpty { out.insert(code) }
        }
        return out
    }

    // MARK: - Writing

    /// Tables a PDF renderer draws with; the rest (kerning, substitution, positioning, vertical
    /// metrics, device records, signatures) list glyph relations and do not travel.
    static let keptTables: Set<String> = ["head", "hhea", "maxp", "loca", "glyf", "hmtx", "cmap", "post", "OS/2", "name", "cvt ", "fpgm", "prep", "gasp"]

    /// The program with only `keep` (plus the components of kept composite glyphs) outlined.
    static func prune(_ data: Data, keep requested: Set<Int>) throws -> Data {
        var font = try parse(data)
        let count = try numberOfGlyphs(font)
        let ranges = try glyphRanges(font)
        guard let glyf = font.tables["glyf"] else { throw RedactionUnsupported("an embedded TrueType program has no glyph table") }
        var keep = requested.filter { $0 >= 0 && $0 < count }
        keep.insert(0)
        var queue = Array(keep)
        while let glyph = queue.popLast() {
            for component in components(glyf[ranges[glyph]]) where component < count && !keep.contains(component) {
                keep.insert(component)
                queue.append(component)
            }
        }

        // glyf and a long loca: removed glyphs are empty.
        var newGlyf: [UInt8] = []
        var loca: [UInt8] = []
        for glyph in 0..<count {
            put32(&loca, UInt32(newGlyf.count))
            guard keep.contains(glyph) else { continue }
            newGlyf.append(contentsOf: glyf[ranges[glyph]])
            while newGlyf.count % 4 != 0 { newGlyf.append(0) }
        }
        put32(&loca, UInt32(newGlyf.count))
        font.tables["glyf"] = newGlyf
        font.tables["loca"] = loca
        if var head = font.tables["head"] {
            head[50] = 0
            head[51] = 1
            font.tables["head"] = head
        }

        // hmtx: a removed glyph's advance and side bearing are zero (the last long entry keeps its
        // advance, which the glyphs after it share).
        if let hhea = font.tables["hhea"], hhea.count >= 36, var hmtx = font.tables["hmtx"] {
            let long = Int(u16(hhea, 34))
            for glyph in 0..<count where !keep.contains(glyph) {
                if glyph < long {
                    let offset = glyph * 4
                    guard offset + 4 <= hmtx.count else { continue }
                    if glyph < long - 1 { hmtx[offset] = 0; hmtx[offset + 1] = 0 }
                    hmtx[offset + 2] = 0; hmtx[offset + 3] = 0
                } else {
                    let offset = long * 4 + (glyph - long) * 2
                    guard offset + 2 <= hmtx.count else { continue }
                    hmtx[offset] = 0; hmtx[offset + 1] = 0
                }
            }
            font.tables["hmtx"] = hmtx
        }

        // cmap: every understood subtable with only the kept glyphs; post without names.
        font.tables["cmap"] = try rebuiltCharacterMaps(characterMaps(font), keep: keep)
        if let post = font.tables["post"], post.count >= 32 {
            var header = Array(post.prefix(32))
            header[0] = 0; header[1] = 3; header[2] = 0; header[3] = 0
            font.tables["post"] = header
        }
        font.tables = font.tables.filter { keptTables.contains($0.key) }
        return serialize(font)
    }

    /// Subtables (1,0) as format 6, and (0,x), (3,0), (3,1) as format 4, holding only mappings
    /// to kept glyphs in the Basic Multilingual Plane. Records whose rebuilt subtables are equal
    /// point at one copy of it, so records that shared a subtable still share one.
    static func rebuiltCharacterMaps(_ maps: [UInt32: [UInt32: Int]], keep: Set<Int>) throws -> [UInt8] {
        var records: [(key: UInt32, table: Int)] = []
        var tables: [[UInt8]] = []
        var known: [[UInt8]: Int] = [:]
        for key in maps.keys.sorted() {
            let platform = key >> 16, encoding = key & 0xFFFF
            let kept = (maps[key] ?? [:]).filter { keep.contains($0.value) && $0.value != 0 && $0.key <= 0xFFFF }
            var table: [UInt8] = []
            if platform == 1 && encoding == 0 {
                let codes = kept.keys.filter { $0 <= 0xFF }.sorted()
                let first = codes.first ?? 0, last = codes.last ?? 0
                put16(&table, 6)
                put16(&table, UInt16(10 + (codes.isEmpty ? 0 : (last - first + 1)) * 2))
                put16(&table, 0)
                put16(&table, UInt16(first))
                put16(&table, UInt16(codes.isEmpty ? 0 : last - first + 1))
                if !codes.isEmpty { for code in first...last { put16(&table, UInt16(kept[code] ?? 0)) } }
            } else if platform == 0 || platform == 3 {
                table = try format4(kept)
            } else {
                continue
            }
            if let index = known[table] {
                records.append((key, index))
            } else {
                known[table] = tables.count
                records.append((key, tables.count))
                tables.append(table)
            }
        }
        var offsets: [Int] = []
        var offset = 4 + records.count * 8
        for table in tables { offsets.append(offset); offset += table.count }
        var out: [UInt8] = []
        put16(&out, 0)
        put16(&out, UInt16(records.count))
        for record in records {
            put16(&out, UInt16(record.key >> 16))
            put16(&out, UInt16(record.key & 0xFFFF))
            put32(&out, UInt32(offsets[record.table]))
        }
        for table in tables { out.append(contentsOf: table) }
        return out
    }

    /// Segments one format 4 subtable can hold, its 0xFFFF end included: the table's length is
    /// 16 + 8 bytes a segment, in a 16-bit field.
    static let format4SegmentCeiling = (0xFFFF - 16) / 8

    private static func format4(_ map: [UInt32: Int]) throws -> [UInt8] {
        // One segment per run of consecutive codes with consecutive glyphs, then the 0xFFFF end.
        var segments: [(start: Int, end: Int, delta: Int)] = []
        for code in map.keys.sorted().map({ Int($0) }) {
            let glyph = map[UInt32(code)] ?? 0
            if var last = segments.last, last.end == code - 1, (code + last.delta) & 0xFFFF == glyph {
                last.end = code
                segments[segments.count - 1] = last
            } else {
                segments.append((code, code, (glyph - code) & 0xFFFF))
            }
        }
        segments.append((0xFFFF, 0xFFFF, 1))
        let count = segments.count
        // Kept glyphs reached from scattered codes — every code of a hostile table naming one
        // kept glyph, or a large CID font's text — need one segment each. UInt16(16 + count * 8)
        // trapped past this ceiling; the program is refused instead.
        guard count <= format4SegmentCeiling else {
            throw RedactionUnsupported("a reduced TrueType program's character map needs more segments than one table holds")
        }
        var table: [UInt8] = []
        put16(&table, 4)
        put16(&table, UInt16(16 + count * 8))
        put16(&table, 0)
        put16(&table, UInt16(count * 2))
        var power = 1, selector = 0
        while power * 2 <= count { power *= 2; selector += 1 }
        put16(&table, UInt16(power * 2))
        put16(&table, UInt16(selector))
        put16(&table, UInt16(count * 2 - power * 2))
        for segment in segments { put16(&table, UInt16(segment.end)) }
        put16(&table, 0)
        for segment in segments { put16(&table, UInt16(segment.start)) }
        for segment in segments { put16(&table, UInt16(segment.delta)) }
        for _ in segments { put16(&table, 0) }
        return table
    }

    static func serialize(_ font: Font) -> Data {
        var tables = font.tables
        if var head = tables["head"], head.count >= 12 {
            head[8] = 0; head[9] = 0; head[10] = 0; head[11] = 0
            tables["head"] = head
        }
        let tags = tables.keys.sorted()
        var power = 1, selector = 0
        while power * 2 <= tags.count { power *= 2; selector += 1 }
        var out: [UInt8] = []
        put32(&out, font.version == 0x4F54_544F ? font.version : 0x0001_0000)
        put16(&out, UInt16(tags.count))
        put16(&out, UInt16(power * 16))
        put16(&out, UInt16(selector))
        put16(&out, UInt16(tags.count * 16 - power * 16))
        var offset = 12 + tags.count * 16
        var headOffset: Int?
        for tag in tags {
            let data = tables[tag] ?? []
            out.append(contentsOf: Array(tag.utf8.prefix(4)) + Array(repeating: 0x20, count: max(0, 4 - tag.utf8.count)))
            put32(&out, checksum(data))
            put32(&out, UInt32(offset))
            put32(&out, UInt32(data.count))
            if tag == "head" { headOffset = offset }
            offset += (data.count + 3) / 4 * 4
        }
        for tag in tags {
            out.append(contentsOf: tables[tag] ?? [])
            while out.count % 4 != 0 { out.append(0) }
        }
        if let headOffset, headOffset + 12 <= out.count {
            let adjustment = 0xB1B0_AFBA &- checksum(out)
            out[headOffset + 8] = UInt8(adjustment >> 24)
            out[headOffset + 9] = UInt8(adjustment >> 16 & 0xFF)
            out[headOffset + 10] = UInt8(adjustment >> 8 & 0xFF)
            out[headOffset + 11] = UInt8(adjustment & 0xFF)
        }
        return Data(out)
    }

    private static func checksum(_ data: [UInt8]) -> UInt32 {
        var sum: UInt32 = 0
        var index = 0
        while index < data.count {
            var word: UInt32 = 0
            for offset in 0..<4 { word = word << 8 | UInt32(index + offset < data.count ? data[index + offset] : 0) }
            sum = sum &+ word
            index += 4
        }
        return sum
    }

    // MARK: - Bytes

    static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        guard offset + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    static func i16(_ bytes: [UInt8], _ offset: Int) -> Int16 { Int16(bitPattern: u16(bytes, offset)) }

    static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    static func put16(_ bytes: inout [UInt8], _ value: UInt16) {
        bytes.append(UInt8(value >> 8))
        bytes.append(UInt8(value & 0xFF))
    }

    static func put32(_ bytes: inout [UInt8], _ value: UInt32) {
        bytes.append(UInt8(value >> 24))
        bytes.append(UInt8(value >> 16 & 0xFF))
        bytes.append(UInt8(value >> 8 & 0xFF))
        bytes.append(UInt8(value & 0xFF))
    }
}
