import Foundation

/// An embedded CFF program (`/FontFile3` `/Type1C`, `/CIDFontType0C`, or the `CFF ` table of an
/// OpenType program) reduced to the glyphs a redacted copy still draws (finding 19).
///
/// A removed glyph's charstring becomes a bare `endchar`; every subroutine no kept glyph calls
/// becomes a bare `return` (subroutines hold outline pieces shared between glyphs); the charset
/// names or CIDs only the kept glyphs; a custom built-in encoding maps only codes of kept
/// glyphs; strings only removed glyphs were named by are emptied. Glyph numbering is unchanged.
/// A charstring whose subroutine calls cannot be followed is a refusal.
enum RedactionCFF {

    // MARK: - Structures

    enum Operand: Equatable {
        case integer(Int)
        case real([UInt8])

        var intValue: Int? { if case let .integer(value) = self { return value } else { return nil } }
    }

    struct Entry {
        var op: Int
        var operands: [Operand]
    }

    static let charsetOp = 15, encodingOp = 16, charStringsOp = 17, privateOp = 18, subrsOp = 19
    static let rosOp = 1230, fdArrayOp = 1236, fdSelectOp = 1237, charstringTypeOp = 1206
    /// Operators whose operand is a string ID (they keep the strings they name).
    static let stringOps: Set<Int> = [0, 1, 2, 3, 4, 1200, 1221, 1222, 1238]

    struct Font {
        var header: [UInt8]
        var names: [[UInt8]]
        var top: [Entry]
        var strings: [[UInt8]]
        var globalSubrs: [[UInt8]]
        var charStrings: [[UInt8]]
        /// Glyph → SID (or CID in a CID-keyed font). `nil`: a predefined charset, kept as it is.
        var charset: [Int]?
        var predefinedCharset: Int
        /// Code → glyph of a custom built-in encoding; `nil`: predefined (0 standard, 1 expert).
        var encoding: [Int: Int]?
        var predefinedEncoding: Int
        var privateDict: [Entry]
        var localSubrs: [[UInt8]]
        var cidKeyed: Bool
        var fontDicts: [[Entry]]
        var fontPrivates: [[Entry]]
        var fontSubrs: [[[UInt8]]]
        var fdSelect: [Int]
    }

    // MARK: - Reading

    static func readIndex(_ bytes: [UInt8], at start: Int) throws -> (items: [[UInt8]], end: Int) {
        // Every caller's offset comes from a DICT operand, which CFF can encode as negative
        // (operators 28, 29 and 251–254): a negative start is refused, never indexed (S-064).
        guard start >= 0 else { throw RedactionUnsupported("a CFF program points before its start") }
        guard start + 2 <= bytes.count else { throw RedactionUnsupported("a CFF program is truncated") }
        let count = Int(bytes[start]) << 8 | Int(bytes[start + 1])
        if count == 0 { return ([], start + 2) }
        guard start + 3 <= bytes.count else { throw RedactionUnsupported("a CFF program is truncated") }
        let size = Int(bytes[start + 2])
        guard (1...4).contains(size), start + 3 + (count + 1) * size <= bytes.count else { throw RedactionUnsupported("a CFF index is malformed") }
        func offset(_ index: Int) -> Int {
            var value = 0
            for byte in bytes[(start + 3 + index * size)..<(start + 3 + (index + 1) * size)] { value = value << 8 | Int(byte) }
            return value
        }
        let base = start + 3 + (count + 1) * size - 1
        var items: [[UInt8]] = []
        items.reserveCapacity(count)
        for index in 0..<count {
            let a = base + offset(index), b = base + offset(index + 1)
            guard a <= b, b <= bytes.count, a > base else { throw RedactionUnsupported("a CFF index is malformed") }
            items.append(Array(bytes[a..<b]))
        }
        return (items, base + offset(count))
    }

    static func writeIndex(_ items: [[UInt8]]) -> [UInt8] {
        guard !items.isEmpty else { return [0, 0] }
        let total = items.reduce(0) { $0 + $1.count } + 1
        let size = total < 1 << 8 ? 1 : total < 1 << 16 ? 2 : total < 1 << 24 ? 3 : 4
        var out: [UInt8] = [UInt8(items.count >> 8), UInt8(items.count & 0xFF), UInt8(size)]
        var offset = 1
        func put(_ value: Int) { for shift in (0..<size).reversed() { out.append(UInt8((value >> (8 * shift)) & 0xFF)) } }
        put(offset)
        for item in items { offset += item.count; put(offset) }
        for item in items { out.append(contentsOf: item) }
        return out
    }

    static func readDict(_ bytes: [UInt8]) throws -> [Entry] {
        var entries: [Entry] = []
        var operands: [Operand] = []
        var index = 0
        while index < bytes.count {
            let b = bytes[index]
            switch b {
            case 0...21:
                var op = Int(b)
                index += 1
                if b == 12 {
                    guard index < bytes.count else { throw RedactionUnsupported("a CFF dictionary is truncated") }
                    op = 1200 + Int(bytes[index])
                    index += 1
                }
                entries.append(Entry(op: op, operands: operands))
                operands = []
            case 28:
                guard index + 3 <= bytes.count else { throw RedactionUnsupported("a CFF dictionary is truncated") }
                operands.append(.integer(Int(Int16(bitPattern: UInt16(bytes[index + 1]) << 8 | UInt16(bytes[index + 2])))))
                index += 3
            case 29:
                guard index + 5 <= bytes.count else { throw RedactionUnsupported("a CFF dictionary is truncated") }
                let value = Int32(bitPattern: UInt32(bytes[index + 1]) << 24 | UInt32(bytes[index + 2]) << 16 | UInt32(bytes[index + 3]) << 8 | UInt32(bytes[index + 4]))
                operands.append(.integer(Int(value)))
                index += 5
            case 30:
                var end = index + 1
                while end < bytes.count {
                    let byte = bytes[end]
                    end += 1
                    if byte & 0x0F == 0x0F || byte >> 4 == 0x0F { break }
                }
                operands.append(.real(Array(bytes[index..<end])))
                index = end
            case 32...246:
                operands.append(.integer(Int(b) - 139))
                index += 1
            case 247...250:
                guard index + 2 <= bytes.count else { throw RedactionUnsupported("a CFF dictionary is truncated") }
                operands.append(.integer((Int(b) - 247) * 256 + Int(bytes[index + 1]) + 108))
                index += 2
            case 251...254:
                guard index + 2 <= bytes.count else { throw RedactionUnsupported("a CFF dictionary is truncated") }
                operands.append(.integer(-(Int(b) - 251) * 256 - Int(bytes[index + 1]) - 108))
                index += 2
            default:
                throw RedactionUnsupported("a CFF dictionary has a reserved byte")
            }
        }
        return entries
    }

    /// A dictionary written back; offsets (and any operand of `fixed`) take five bytes so a
    /// layout can be computed before the offsets are known.
    static func writeDict(_ entries: [Entry], fixed: Set<Int>) -> [UInt8] {
        var out: [UInt8] = []
        for entry in entries {
            for operand in entry.operands {
                switch operand {
                case let .real(bytes):
                    out.append(contentsOf: bytes)
                case let .integer(value):
                    if fixed.contains(entry.op) {
                        let bits = UInt32(bitPattern: Int32(truncatingIfNeeded: value))
                        out.append(contentsOf: [29, UInt8(bits >> 24), UInt8(bits >> 16 & 0xFF), UInt8(bits >> 8 & 0xFF), UInt8(bits & 0xFF)])
                    } else if (-107...107).contains(value) {
                        out.append(UInt8(value + 139))
                    } else if (108...1131).contains(value) {
                        let v = value - 108
                        out.append(contentsOf: [UInt8(v / 256 + 247), UInt8(v % 256)])
                    } else if (-1131 ... -108).contains(value) {
                        let v = -value - 108
                        out.append(contentsOf: [UInt8(v / 256 + 251), UInt8(v % 256)])
                    } else if (-32768...32767).contains(value) {
                        let bits = UInt16(bitPattern: Int16(value))
                        out.append(contentsOf: [28, UInt8(bits >> 8), UInt8(bits & 0xFF)])
                    } else {
                        let bits = UInt32(bitPattern: Int32(truncatingIfNeeded: value))
                        out.append(contentsOf: [29, UInt8(bits >> 24), UInt8(bits >> 16 & 0xFF), UInt8(bits >> 8 & 0xFF), UInt8(bits & 0xFF)])
                    }
                }
            }
            if entry.op >= 1200 { out.append(contentsOf: [12, UInt8(entry.op - 1200)]) } else { out.append(UInt8(entry.op)) }
        }
        return out
    }

    static func value(_ entries: [Entry], _ op: Int) -> [Operand]? { entries.first { $0.op == op }?.operands }

    static func parse(_ bytes: [UInt8]) throws -> Font {
        guard bytes.count >= 4, bytes[0] == 1 else { throw RedactionUnsupported("an embedded CFF program is not version 1") }
        let headerSize = Int(bytes[2])
        guard headerSize >= 4, headerSize <= bytes.count else { throw RedactionUnsupported("a CFF header is malformed") }
        let (names, afterNames) = try readIndex(bytes, at: headerSize)
        let (tops, afterTops) = try readIndex(bytes, at: afterNames)
        guard tops.count == 1 else { throw RedactionUnsupported("a CFF program holds more than one font") }
        let (strings, afterStrings) = try readIndex(bytes, at: afterTops)
        let (globalSubrs, _) = try readIndex(bytes, at: afterStrings)
        let top = try readDict(tops[0])
        if let type = value(top, charstringTypeOp)?.first?.intValue, type != 2 { throw RedactionUnsupported("a CFF program uses Type 1 charstrings") }
        guard let charStringsOffset = value(top, charStringsOp)?.first?.intValue else { throw RedactionUnsupported("a CFF program has no charstrings") }
        let (charStrings, _) = try readIndex(bytes, at: charStringsOffset)
        let count = charStrings.count
        let cidKeyed = value(top, rosOp) != nil

        // Charset.
        var charset: [Int]?
        let charsetOffset = value(top, charsetOp)?.first?.intValue ?? 0
        if charsetOffset > 2 {
            guard charsetOffset < bytes.count else { throw RedactionUnsupported("a CFF charset lies outside the program") }
            var ids = [0]
            var cursor = charsetOffset + 1
            switch bytes[charsetOffset] {
            case 0:
                while ids.count < count {
                    guard cursor + 2 <= bytes.count else { throw RedactionUnsupported("a CFF charset is truncated") }
                    ids.append(Int(bytes[cursor]) << 8 | Int(bytes[cursor + 1]))
                    cursor += 2
                }
            case 1, 2:
                let wide = bytes[charsetOffset] == 2
                while ids.count < count {
                    guard cursor + (wide ? 4 : 3) <= bytes.count else { throw RedactionUnsupported("a CFF charset is truncated") }
                    let first = Int(bytes[cursor]) << 8 | Int(bytes[cursor + 1])
                    let left = wide ? Int(bytes[cursor + 2]) << 8 | Int(bytes[cursor + 3]) : Int(bytes[cursor + 2])
                    cursor += wide ? 4 : 3
                    for offset in 0...left where ids.count < count { ids.append(first + offset) }
                }
            default:
                throw RedactionUnsupported("a CFF charset has an unknown format")
            }
            charset = ids
        }

        // Built-in encoding (not in CID-keyed fonts).
        var encoding: [Int: Int]?
        let encodingOffset = value(top, encodingOp)?.first?.intValue ?? 0
        if !cidKeyed, encodingOffset > 1 {
            guard encodingOffset + 2 <= bytes.count else { throw RedactionUnsupported("a CFF encoding lies outside the program") }
            var map: [Int: Int] = [:]
            let format = bytes[encodingOffset] & 0x7F
            var cursor = encodingOffset + 1
            if format == 0 {
                let codes = Int(bytes[cursor])
                cursor += 1
                for glyph in 1...max(1, codes) where codes > 0 {
                    guard cursor < bytes.count else { break }
                    map[Int(bytes[cursor])] = glyph
                    cursor += 1
                }
            } else if format == 1 {
                let ranges = Int(bytes[cursor])
                cursor += 1
                var glyph = 1
                for _ in 0..<ranges {
                    guard cursor + 2 <= bytes.count else { break }
                    let first = Int(bytes[cursor]), left = Int(bytes[cursor + 1])
                    cursor += 2
                    for code in first...(first + left) { map[code] = glyph; glyph += 1 }
                }
            } else {
                throw RedactionUnsupported("a CFF encoding has an unknown format")
            }
            if bytes[encodingOffset] & 0x80 != 0, cursor < bytes.count {
                let supplements = Int(bytes[cursor])
                cursor += 1
                for _ in 0..<supplements {
                    guard cursor + 3 <= bytes.count else { break }
                    let code = Int(bytes[cursor]), sid = Int(bytes[cursor + 1]) << 8 | Int(bytes[cursor + 2])
                    cursor += 3
                    if let glyph = charset?.firstIndex(of: sid) { map[code] = glyph }
                }
            }
            encoding = map
        }

        func privateOf(_ dict: [Entry]) throws -> ([Entry], [[UInt8]]) {
            guard let operands = value(dict, privateOp), operands.count == 2, let size = operands[0].intValue, let offset = operands[1].intValue else { return ([], []) }
            guard size >= 0, offset >= 0, offset + size <= bytes.count else { throw RedactionUnsupported("a CFF private dictionary lies outside the program") }
            let entries = try readDict(Array(bytes[offset..<(offset + size)]))
            var subrs: [[UInt8]] = []
            if let relative = value(entries, subrsOp)?.first?.intValue { subrs = try readIndex(bytes, at: offset + relative).items }
            return (entries, subrs)
        }

        var font = Font(
            header: Array(bytes[0..<headerSize]), names: names, top: top, strings: strings, globalSubrs: globalSubrs,
            charStrings: charStrings, charset: charset, predefinedCharset: charsetOffset <= 2 ? charsetOffset : -1,
            encoding: encoding, predefinedEncoding: encodingOffset <= 1 ? encodingOffset : -1,
            privateDict: [], localSubrs: [], cidKeyed: cidKeyed, fontDicts: [], fontPrivates: [], fontSubrs: [], fdSelect: []
        )
        if cidKeyed {
            guard let arrayOffset = value(top, fdArrayOp)?.first?.intValue, let selectOffset = value(top, fdSelectOp)?.first?.intValue,
                  selectOffset >= 0, selectOffset < bytes.count else { throw RedactionUnsupported("a CID-keyed CFF program has no font dictionaries") }
            for dict in try readIndex(bytes, at: arrayOffset).items {
                let entries = try readDict(dict)
                let (privateDict, subrs) = try privateOf(entries)
                font.fontDicts.append(entries)
                font.fontPrivates.append(privateDict)
                font.fontSubrs.append(subrs)
            }
            var select: [Int] = []
            var cursor = selectOffset + 1
            switch bytes[selectOffset] {
            case 0:
                guard cursor + count <= bytes.count else { throw RedactionUnsupported("a CFF font selector is truncated") }
                select = bytes[cursor..<(cursor + count)].map { Int($0) }
            case 3:
                guard cursor + 2 <= bytes.count else { throw RedactionUnsupported("a CFF font selector is truncated") }
                let ranges = Int(bytes[cursor]) << 8 | Int(bytes[cursor + 1])
                cursor += 2
                select = Array(repeating: 0, count: count)
                for range in 0..<ranges {
                    let base = cursor + range * 3
                    guard base + 5 <= bytes.count else { throw RedactionUnsupported("a CFF font selector is truncated") }
                    let first = Int(bytes[base]) << 8 | Int(bytes[base + 1]), fd = Int(bytes[base + 2])
                    let next = Int(bytes[base + 3]) << 8 | Int(bytes[base + 4])
                    // A range that starts at or past the glyph count, or ends before it starts,
                    // selects no glyph (S-064: `first..<upper` with first > upper traps).
                    let upper = min(next, count)
                    guard first < upper else { continue }
                    for glyph in first..<upper { select[glyph] = fd }
                }
            default:
                throw RedactionUnsupported("a CFF font selector has an unknown format")
            }
            font.fdSelect = select
        } else {
            (font.privateDict, font.localSubrs) = try privateOf(top)
        }
        return font
    }

    // MARK: - Names

    static func string(_ font: Font, sid: Int) -> String? {
        if sid < RedactionGlyphTables.cffStandardStrings.count { return RedactionGlyphTables.cffStandardStrings[sid] }
        let index = sid - RedactionGlyphTables.cffStandardStrings.count
        return index < font.strings.count ? String(decoding: font.strings[index], as: UTF8.self) : nil
    }

    // MARK: - Pruning

    static func prune(_ bytes: [UInt8], simpleCodes codes: Set<Int>, names: [Int: String]) throws -> [UInt8] {
        let font = try parse(bytes)
        guard !font.cidKeyed else { return try prune(bytes, cids: Set(codes.map { UInt32($0) })) }
        var byName: [String: Int] = [:]
        if let charset = font.charset {
            for (glyph, sid) in charset.enumerated() { if let name = string(font, sid: sid), byName[name] == nil { byName[name] = glyph } }
        } else if font.predefinedCharset == 0 {
            // ISOAdobe: glyph n is SID n.
            for glyph in 0..<font.charStrings.count { if let name = string(font, sid: glyph) { byName[name] = glyph } }
        }
        var keep: Set<Int> = [0]
        for code in codes {
            if let name = names[code], let glyph = byName[name] { keep.insert(glyph) }
            if let glyph = font.encoding?[code] { keep.insert(glyph) }
            if font.encoding == nil, let name = RedactionGlyphTables.standard[code], let glyph = byName[name] { keep.insert(glyph) }
        }
        return try prune(font, keep: keep)
    }

    static func prune(_ bytes: [UInt8], cids: Set<UInt32>) throws -> [UInt8] {
        let font = try parse(bytes)
        var keep: Set<Int> = [0]
        if font.cidKeyed, let charset = font.charset {
            for (glyph, cid) in charset.enumerated() where cids.contains(UInt32(cid)) { keep.insert(glyph) }
        } else {
            keep.formUnion(cids.map { Int($0) })
        }
        return try prune(font, keep: keep)
    }

    static func prune(_ original: Font, keep: Set<Int>) throws -> [UInt8] {
        var font = original
        let count = font.charStrings.count
        var usedGlobal: Set<Int> = []
        var usedLocal: [Int: Set<Int>] = [:]
        for glyph in keep where glyph < count {
            let fd = font.cidKeyed ? (glyph < font.fdSelect.count ? font.fdSelect[glyph] : 0) : -1
            let local = fd >= 0 ? (fd < font.fontSubrs.count ? font.fontSubrs[fd] : []) : font.localSubrs
            var tracer = Tracer(global: font.globalSubrs, local: local)
            guard tracer.run(font.charStrings[glyph]) else {
                throw RedactionUnsupported("a CFF glyph's subroutine calls cannot be followed")
            }
            usedGlobal.formUnion(tracer.usedGlobal)
            usedLocal[fd, default: []].formUnion(tracer.usedLocal)
        }
        for glyph in 0..<count where !keep.contains(glyph) { font.charStrings[glyph] = [14] }
        for index in font.globalSubrs.indices where !usedGlobal.contains(index) { font.globalSubrs[index] = [11] }
        if font.cidKeyed {
            for fd in font.fontSubrs.indices {
                for index in font.fontSubrs[fd].indices where !(usedLocal[fd]?.contains(index) ?? false) { font.fontSubrs[fd][index] = [11] }
            }
        } else {
            for index in font.localSubrs.indices where !(usedLocal[-1]?.contains(index) ?? false) { font.localSubrs[index] = [11] }
        }
        if var charset = font.charset {
            let removedSIDs = Set((0..<min(count, charset.count)).filter { !keep.contains($0) }.map { charset[$0] })
            for glyph in 0..<min(count, charset.count) where !keep.contains(glyph) { charset[glyph] = 0 }
            font.charset = charset
            if !font.cidKeyed {
                // Strings only removed glyphs were named by.
                var named: Set<Int> = Set(charset)
                for entry in font.top + font.privateDict where stringOps.contains(entry.op) { for operand in entry.operands { if let sid = operand.intValue { named.insert(sid) } } }
                for sid in removedSIDs where !named.contains(sid) {
                    let index = sid - RedactionGlyphTables.cffStandardStrings.count
                    if index >= 0, index < font.strings.count { font.strings[index] = [] }
                }
            }
        }
        if var encoding = font.encoding {
            encoding = encoding.filter { keep.contains($0.value) }
            font.encoding = encoding
        }
        return serialize(font)
    }

    // MARK: - Writing

    static func serialize(_ font: Font) -> [UInt8] {
        let fixed: Set<Int> = [charsetOp, encodingOp, charStringsOp, privateOp, fdArrayOp, fdSelectOp, subrsOp]
        let count = font.charStrings.count

        // Sections after the four leading indices, in order; their offsets fill the top dict.
        var charsetBytes: [UInt8] = []
        if let charset = font.charset {
            charsetBytes = [0]
            for glyph in 1..<max(1, min(count, charset.count)) {
                let id = min(max(charset[glyph], 0), 0xFFFF)
                charsetBytes += [UInt8(id >> 8), UInt8(id & 0xFF)]
            }
        }
        var encodingBytes: [UInt8] = []
        if let encoding = font.encoding {
            // Format 0 with no sequential codes and one supplement (code, glyph's SID) per kept
            // code: the kept glyphs need not be the first ones, which format 0 alone would need.
            let pairs = encoding.sorted { $0.key < $1.key }.compactMap { code, glyph -> (Int, Int)? in
                guard (0...255).contains(code), let sid = font.charset.flatMap({ glyph < $0.count ? $0[glyph] : nil }) ?? (font.predefinedCharset == 0 ? glyph : nil),
                      sid > 0, sid <= 0xFFFF else { return nil }
                return (code, sid)
            }.prefix(255)
            encodingBytes = [0x80, 0, UInt8(pairs.count)]
            for (code, sid) in pairs { encodingBytes += [UInt8(code), UInt8(sid >> 8), UInt8(sid & 0xFF)] }
        }
        let charStringsBytes = writeIndex(font.charStrings)
        var fdSelectBytes: [UInt8] = []
        if font.cidKeyed { fdSelectBytes = [0] + (0..<count).map { UInt8($0 < font.fdSelect.count ? font.fdSelect[$0] & 0xFF : 0) } }

        func privateBytes(_ entries: [Entry], subrs: [[UInt8]]) -> [UInt8] {
            var dict = entries.filter { $0.op != subrsOp }
            if !subrs.isEmpty { dict.append(Entry(op: subrsOp, operands: [.integer(0)])) }
            let size = writeDict(dict, fixed: fixed).count
            if !subrs.isEmpty { dict[dict.count - 1].operands = [.integer(size)] }
            return writeDict(dict, fixed: fixed) + (subrs.isEmpty ? [] : writeIndex(subrs))
        }
        func privateSize(_ entries: [Entry], subrs: [[UInt8]]) -> Int {
            var dict = entries.filter { $0.op != subrsOp }
            if !subrs.isEmpty { dict.append(Entry(op: subrsOp, operands: [.integer(0)])) }
            return writeDict(dict, fixed: fixed).count
        }

        func topDict(charset: Int, encoding: Int, charStrings: Int, privateSize: Int, privateOffset: Int, fdArray: Int, fdSelect: Int) -> [UInt8] {
            var entries = font.top.filter { ![charsetOp, encodingOp, charStringsOp, privateOp, fdArrayOp, fdSelectOp].contains($0.op) }
            entries.append(Entry(op: charsetOp, operands: [.integer(font.charset == nil ? font.predefinedCharset : charset)]))
            if !font.cidKeyed { entries.append(Entry(op: encodingOp, operands: [.integer(font.encoding == nil ? max(0, font.predefinedEncoding) : encoding)])) }
            entries.append(Entry(op: charStringsOp, operands: [.integer(charStrings)]))
            if font.cidKeyed {
                entries.append(Entry(op: fdArrayOp, operands: [.integer(fdArray)]))
                entries.append(Entry(op: fdSelectOp, operands: [.integer(fdSelect)]))
            } else {
                entries.append(Entry(op: privateOp, operands: [.integer(privateSize), .integer(privateOffset)]))
            }
            // ROS must come first in a CID-keyed top dictionary.
            if let ros = entries.firstIndex(where: { $0.op == rosOp }), ros != 0 { entries.insert(entries.remove(at: ros), at: 0) }
            return writeDict(entries, fixed: fixed)
        }

        let head = font.header + writeIndex(font.names)
        let tail = writeIndex(font.strings) + writeIndex(font.globalSubrs)
        let topSize = writeIndex([topDict(charset: 0, encoding: 0, charStrings: 0, privateSize: 0, privateOffset: 0, fdArray: 0, fdSelect: 0)]).count
        var cursor = head.count + topSize + tail.count
        let charsetOffset = cursor; cursor += charsetBytes.count
        let encodingOffset = cursor; cursor += encodingBytes.count
        let charStringsOffset = cursor; cursor += charStringsBytes.count
        let fdSelectOffset = cursor; cursor += fdSelectBytes.count
        var body: [UInt8] = charsetBytes + encodingBytes + charStringsBytes + fdSelectBytes
        var privateOffset = 0, privateLength = 0, fdArrayOffset = 0
        if font.cidKeyed {
            // Font dicts point at their private dicts, which follow the FDArray index.
            let dictSizes = font.fontDicts.map { entries -> Int in
                var dict = entries.filter { $0.op != privateOp }
                dict.append(Entry(op: privateOp, operands: [.integer(0), .integer(0)]))
                return writeDict(dict, fixed: fixed).count
            }
            let arraySize = writeIndex(dictSizes.map { Array(repeating: UInt8(0), count: $0) }).count
            fdArrayOffset = cursor
            var privateCursor = cursor + arraySize
            var dicts: [[UInt8]] = []
            var privates: [UInt8] = []
            for (index, entries) in font.fontDicts.enumerated() {
                let privateEntries = index < font.fontPrivates.count ? font.fontPrivates[index] : []
                let subrs = index < font.fontSubrs.count ? font.fontSubrs[index] : []
                let block = privateBytes(privateEntries, subrs: subrs)
                var dict = entries.filter { $0.op != privateOp }
                dict.append(Entry(op: privateOp, operands: [.integer(privateSize(privateEntries, subrs: subrs)), .integer(privateCursor)]))
                dicts.append(writeDict(dict, fixed: fixed))
                privates += block
                privateCursor += block.count
            }
            body += writeIndex(dicts) + privates
        } else {
            privateOffset = cursor
            privateLength = privateSize(font.privateDict, subrs: font.localSubrs)
            body += privateBytes(font.privateDict, subrs: font.localSubrs)
        }
        let top = topDict(charset: charsetOffset, encoding: encodingOffset, charStrings: charStringsOffset, privateSize: privateLength,
                          privateOffset: privateOffset, fdArray: fdArrayOffset, fdSelect: fdSelectOffset)
        return head + writeIndex([top]) + tail + body
    }

    // MARK: - Following subroutine calls

    /// A Type 2 charstring interpreter that only tracks what it must to follow `callsubr` and
    /// `callgsubr`: the operand stack (numbers it pushed itself), the stem count `hintmask`
    /// needs to skip its mask bytes, and the subroutines reached.
    struct Tracer {
        let global: [[UInt8]]
        let local: [[UInt8]]
        var usedGlobal: Set<Int> = []
        var usedLocal: Set<Int> = []
        private var stack: [Double?] = []
        private var stems = 0
        private var ended = false
        private var steps = 0

        init(global: [[UInt8]], local: [[UInt8]]) {
            self.global = global
            self.local = local
        }

        static func bias(_ count: Int) -> Int { count < 1240 ? 107 : count < 33900 ? 1131 : 32768 }

        /// `false` when a call cannot be followed (a computed subroutine number, a bad index).
        mutating func run(_ bytes: [UInt8]) -> Bool {
            stack = []
            stems = 0
            ended = false
            return execute(bytes, depth: 0)
        }

        private mutating func execute(_ bytes: [UInt8], depth: Int) -> Bool {
            guard depth <= 10 else { return false }
            var index = 0
            while index < bytes.count, !ended {
                steps += 1
                guard steps < 1_000_000 else { return false }
                let b = bytes[index]
                switch b {
                case 28:
                    guard index + 3 <= bytes.count else { return false }
                    stack.append(Double(Int16(bitPattern: UInt16(bytes[index + 1]) << 8 | UInt16(bytes[index + 2]))))
                    index += 3
                case 32...246:
                    stack.append(Double(Int(b) - 139))
                    index += 1
                case 247...250:
                    guard index + 2 <= bytes.count else { return false }
                    stack.append(Double((Int(b) - 247) * 256 + Int(bytes[index + 1]) + 108))
                    index += 2
                case 251...254:
                    guard index + 2 <= bytes.count else { return false }
                    stack.append(Double(-(Int(b) - 251) * 256 - Int(bytes[index + 1]) - 108))
                    index += 2
                case 255:
                    guard index + 5 <= bytes.count else { return false }
                    let bits = Int32(bitPattern: UInt32(bytes[index + 1]) << 24 | UInt32(bytes[index + 2]) << 16 | UInt32(bytes[index + 3]) << 8 | UInt32(bytes[index + 4]))
                    stack.append(Double(bits) / 65536)
                    index += 5
                case 1, 3, 18, 23:
                    stems += stack.count / 2
                    stack = []
                    index += 1
                case 19, 20:
                    stems += stack.count / 2
                    stack = []
                    index += 1 + (stems + 7) / 8
                case 10, 29:
                    let isGlobal = b == 29
                    guard let top = stack.popLast(), let number = top, number == number.rounded() else { return false }
                    let subrs = isGlobal ? global : local
                    let subr = Int(number) + Self.bias(subrs.count)
                    guard subr >= 0, subr < subrs.count else { return false }
                    if isGlobal { usedGlobal.insert(subr) } else { usedLocal.insert(subr) }
                    guard execute(subrs[subr], depth: depth + 1) else { return false }
                    index += 1
                case 11:
                    return true
                case 14:
                    ended = true
                    return true
                case 12:
                    guard index + 1 < bytes.count else { return false }
                    let op = bytes[index + 1]
                    index += 2
                    applyEscape(op)
                default:
                    // Path construction and other operators clear the stack.
                    stack = []
                    index += 1
                }
            }
            return true
        }

        /// The stack effect of a two-byte operator; a value it computes is unknown (`nil`).
        private mutating func applyEscape(_ op: UInt8) {
            func pop(_ count: Int) { for _ in 0..<count { _ = stack.popLast() } }
            switch op {
            case 3, 4, 10, 11, 12, 15, 24: pop(2); stack.append(nil)      // and or add sub div eq mul
            case 5, 9, 14, 21, 26, 29: pop(1); stack.append(nil)          // not abs neg get sqrt index
            case 18: pop(1)                                               // drop
            case 20: pop(2)                                               // put
            case 22: pop(4); stack.append(nil)                            // ifelse
            case 23: stack.append(nil)                                    // random
            case 27: stack.append(stack.last ?? nil)                      // dup
            case 28: if stack.count >= 2 { stack.swapAt(stack.count - 1, stack.count - 2) }  // exch
            case 30:                                                      // roll
                let shift = stack.popLast() ?? nil, count = stack.popLast() ?? nil
                _ = shift
                let n = count.map { Int($0) } ?? stack.count
                for position in max(0, stack.count - max(0, n))..<stack.count { stack[position] = nil }
            default: stack = []                                           // flex operators and the rest
            }
        }
    }
}
