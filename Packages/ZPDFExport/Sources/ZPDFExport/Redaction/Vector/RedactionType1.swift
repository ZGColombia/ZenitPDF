import Foundation

/// An embedded Type 1 program (`/FontFile`) reduced to the glyphs a redacted copy still draws
/// (finding 19).
///
/// The private part is decrypted (eexec, key 55665), each removed glyph's charstring is replaced
/// by one that draws nothing (`0 0 hsbw endchar`), each subroutine no kept glyph calls by a bare
/// `return` (subroutines 0–3 serve flex and hint replacement and stay), and the private part is
/// encrypted again. A custom built-in encoding maps only the kept glyphs. A charstring whose
/// subroutine calls cannot be followed is a refusal.
enum RedactionType1 {

    struct Result {
        var bytes: [UInt8]
        var length1: Int
        var length2: Int
        var length3: Int
    }

    static let eexecKey: UInt16 = 55665
    static let charstringKey: UInt16 = 4330

    static func decrypt(_ bytes: [UInt8], key: UInt16) -> [UInt8] {
        var r = key
        return bytes.map { cipher in
            let plain = cipher ^ UInt8(r >> 8)
            r = (UInt16(cipher) &+ r) &* 52845 &+ 22719
            return plain
        }
    }

    static func encrypt(_ bytes: [UInt8], key: UInt16) -> [UInt8] {
        var r = key
        return bytes.map { plain in
            let cipher = plain ^ UInt8(r >> 8)
            r = (UInt16(cipher) &+ r) &* 52845 &+ 22719
            return cipher
        }
    }

    /// One binary entry of the private part: a subroutine or a charstring.
    struct Entry {
        var name: String
        var lengthRange: Range<Int>
        var dataRange: Range<Int>
    }

    static func prune(_ bytes: [UInt8], length1: Int, length2: Int, keepNames requested: Set<String>, keepCodes: Set<Int>) throws -> Result {
        // /Length1 and /Length2 come from the font dictionary: compared without adding them, so
        // Int.max cannot overflow the check (S-064).
        guard length1 > 0, length2 > 0, length1 <= bytes.count, length2 <= bytes.count - length1 else {
            throw RedactionUnsupported("a Type 1 program's lengths do not fit it")
        }
        var clear = Array(bytes[0..<length1])
        var encrypted = Array(bytes[length1..<(length1 + length2)])
        let trailer = Array(bytes[(length1 + length2)...])
        // A hex-written private part is decoded to binary; it is written back as binary.
        if encrypted.prefix(4).allSatisfy({ isHex($0) }) {
            encrypted = hexDecode(encrypted)
        }
        let plain = decrypt(encrypted, key: eexecKey)
        guard plain.count > 4 else { throw RedactionUnsupported("a Type 1 program's private part is empty") }
        let text = plain
        let lenIV = integer(after: "/lenIV", in: text) ?? 4
        // 4 is standard and a negative value means the charstrings are not encrypted. A program's
        // own `/lenIV 1000000000000` used to size the random prefix of every replacement
        // charstring: a terabyte allocation, and the process died (T-038).
        guard (-1...64).contains(lenIV) else { throw RedactionUnsupported("a Type 1 program's lenIV is out of range") }

        let subrs = try entries(in: text, section: "/Subrs", named: false)
        let charStrings = try entries(in: text, section: "/CharStrings", named: true)
        guard !charStrings.isEmpty else { throw RedactionUnsupported("a Type 1 program has no charstrings") }

        // Kept glyphs: the names asked for, the built-in encoding's names for the kept codes,
        // .notdef, and the accents and bases of kept accented glyphs (seac).
        let builtIn = builtInEncoding(clear)
        var keep = requested
        keep.insert(".notdef")
        for code in keepCodes { if let name = builtIn[code] ?? (builtIn.isEmpty ? RedactionGlyphTables.standard[code] : nil) { keep.insert(name) } }
        let subrData = subrs.map { Array(text[$0.dataRange]) }
        var usedSubrs: Set<Int> = [0, 1, 2, 3]
        var queue = Array(keep)
        var seen: Set<String> = []
        while let name = queue.popLast() {
            guard seen.insert(name).inserted, let entry = charStrings.first(where: { $0.name == name }) else { continue }
            var tracer = Tracer(subrs: subrData, lenIV: lenIV)
            guard tracer.run(Array(text[entry.dataRange])) else {
                throw RedactionUnsupported("a Type 1 glyph's subroutine calls cannot be followed")
            }
            usedSubrs.formUnion(tracer.usedSubrs)
            for code in tracer.accentCodes {
                if let component = RedactionGlyphTables.standard[code], !keep.contains(component) { keep.insert(component); queue.append(component) }
            }
        }

        // Rewrite the private part back to front so earlier ranges stay valid.
        var replacements: [(Entry, [UInt8])] = []
        for entry in charStrings where !keep.contains(entry.name) {
            replacements.append((entry, charstring([139, 139, 13, 14], lenIV: lenIV)))
        }
        for (index, entry) in subrs.enumerated() where !usedSubrs.contains(index) && !entry.dataRange.isEmpty {
            replacements.append((entry, charstring([11], lenIV: lenIV)))
        }
        var output = text
        for (entry, data) in replacements.sorted(by: { $0.0.dataRange.lowerBound > $1.0.dataRange.lowerBound }) {
            output.replaceSubrange(entry.dataRange, with: data)
            output.replaceSubrange(entry.lengthRange, with: Array(String(data.count).utf8))
        }

        // A custom built-in encoding keeps only the kept glyphs' codes.
        if !builtIn.isEmpty { clear = prunedEncoding(clear, keep: keep) }

        let newEncrypted = encrypt(output, key: eexecKey)
        return Result(bytes: clear + newEncrypted + trailer, length1: clear.count, length2: newEncrypted.count, length3: trailer.count)
    }

    private static func charstring(_ commands: [UInt8], lenIV: Int) -> [UInt8] {
        guard lenIV >= 0 else { return commands }
        return encrypt(Array(repeating: 0, count: lenIV) + commands, key: charstringKey)
    }

    // MARK: - Reading the private part

    private static func isHex(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte) || PDFByte.isWhitespace(byte)
    }

    private static func hexDecode(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var high: UInt8?
        for byte in bytes {
            let value: UInt8
            switch byte {
            case 0x30...0x39: value = byte - 0x30
            case 0x41...0x46: value = byte - 0x41 + 10
            case 0x61...0x66: value = byte - 0x61 + 10
            default: continue
            }
            if let h = high { out.append(h << 4 | value); high = nil } else { high = value }
        }
        return out
    }

    private static func token(_ bytes: [UInt8], at start: Int) -> (String, Int)? {
        var index = start
        while index < bytes.count, PDFByte.isWhitespace(bytes[index]) { index += 1 }
        guard index < bytes.count else { return nil }
        let begin = index
        if bytes[index] == UInt8(ascii: "/") { index += 1 }
        while index < bytes.count, !PDFByte.isWhitespace(bytes[index]),
              bytes[index] != UInt8(ascii: "/") || index == begin { index += 1 }
        return (String(decoding: bytes[begin..<index], as: UTF8.self), index)
    }

    private static func integer(after key: String, in bytes: [UInt8]) -> Int? {
        guard let found = PDFObjectParser.find(Array(key.utf8), in: bytes, from: 0), let (value, _) = token(bytes, at: found + key.utf8.count) else { return nil }
        return Int(value)
    }

    /// The entries after `section`: `dup i n RD <n bytes> NP` for subroutines, `/name n RD <n
    /// bytes> ND` for charstrings (RD, NP, ND under any of their usual spellings). Subroutines
    /// are returned by index, missing ones empty.
    private static func entries(in bytes: [UInt8], section: String, named: Bool) throws -> [Entry] {
        guard let found = PDFObjectParser.find(Array(section.utf8), in: bytes, from: 0) else { return [] }
        var cursor = found + section.utf8.count
        var out: [Entry] = []
        var steps = 0
        func binary(after lengthToken: Int, length: Int) throws -> (Int, Int)? {
            guard let (_, afterRD) = token(bytes, at: lengthToken) else { return nil }
            let dataStart = afterRD + 1
            // Compared without adding: `/a 9223372036854775807 RD` overflowed `dataStart + length`
            // and trapped (T-038).
            guard length >= 0, length <= bytes.count - dataStart else { throw RedactionUnsupported("a Type 1 charstring runs past the program") }
            return (dataStart, dataStart + length)
        }
        while let (word, after) = token(bytes, at: cursor), steps < 200_000 {
            steps += 1
            if named {
                if word == "end" { break }
                guard word.hasPrefix("/"), word.count > 1,
                      let (lengthText, afterLength) = token(bytes, at: after), let length = Int(lengthText),
                      let (start, end) = try binary(after: afterLength, length: length) else {
                    cursor = after
                    continue
                }
                out.append(Entry(name: String(word.dropFirst()), lengthRange: lengthRangeStart(bytes, after)..<afterLength, dataRange: start..<end))
                cursor = end
            } else {
                if word == "dup",
                   let (indexText, afterIndex) = token(bytes, at: after), let position = Int(indexText), position >= 0, position < 65_536,
                   let (lengthText, afterLength) = token(bytes, at: afterIndex), let length = Int(lengthText),
                   let (start, end) = try binary(after: afterLength, length: length) {
                    while out.count <= position { out.append(Entry(name: "", lengthRange: 0..<0, dataRange: 0..<0)) }
                    out[position] = Entry(name: "\(position)", lengthRange: lengthRangeStart(bytes, afterIndex)..<afterLength, dataRange: start..<end)
                    cursor = end
                    continue
                }
                if !out.isEmpty, !["NP", "|", "noaccess", "put"].contains(word) { break }
                cursor = after
            }
        }
        return out
    }

    private static func lengthRangeStart(_ bytes: [UInt8], _ start: Int) -> Int {
        var index = start
        while index < bytes.count, PDFByte.isWhitespace(bytes[index]) { index += 1 }
        return index
    }

    /// A custom built-in encoding in the clear part: `dup <code> /<name> put`. Empty for
    /// StandardEncoding.
    static func builtInEncoding(_ clear: [UInt8]) -> [Int: String] {
        guard PDFObjectParser.find(Array("/Encoding".utf8), in: clear, from: 0) != nil,
              PDFObjectParser.find(Array("StandardEncoding".utf8), in: clear, from: 0) == nil else { return [:] }
        var out: [Int: String] = [:]
        var cursor = 0
        while let found = PDFObjectParser.find(Array("dup".utf8), in: clear, from: cursor) {
            cursor = found + 3
            guard let (code, afterCode) = token(clear, at: cursor), let value = Int(code),
                  let (name, afterName) = token(clear, at: afterCode), name.hasPrefix("/"),
                  let (put, _) = token(clear, at: afterName), put == "put" else { continue }
            out[value] = String(name.dropFirst())
        }
        return out
    }

    private static func prunedEncoding(_ clear: [UInt8], keep: Set<String>) -> [UInt8] {
        var out = clear
        var cursor = out.count
        while let found = PDFObjectParser.findLast(Array("dup".utf8), in: Array(out[0..<cursor])) {
            cursor = found
            guard let (code, afterCode) = token(out, at: found + 3), Int(code) != nil,
                  let (name, afterName) = token(out, at: afterCode), name.hasPrefix("/"),
                  let (put, afterPut) = token(out, at: afterName), put == "put" else { continue }
            if !keep.contains(String(name.dropFirst())) { out.replaceSubrange(found..<afterPut, with: []) }
        }
        return out
    }

    // MARK: - Following subroutine calls

    /// A Type 1 charstring interpreter that tracks only what it must to follow `callsubr`: the
    /// numbers it pushed, what `callothersubr` hands back through `pop` (hint replacement's
    /// subroutine number), and the codes `seac` composes from.
    struct Tracer {
        let subrs: [[UInt8]]
        let lenIV: Int
        var usedSubrs: Set<Int> = []
        var accentCodes: [Int] = []
        private var stack: [Double?] = []
        private var postScript: [Double?] = []
        private var ended = false
        private var steps = 0

        init(subrs: [[UInt8]], lenIV: Int) {
            self.subrs = subrs
            self.lenIV = lenIV
        }

        private func plain(_ bytes: [UInt8]) -> [UInt8] {
            guard lenIV >= 0 else { return bytes }
            return Array(RedactionType1.decrypt(bytes, key: RedactionType1.charstringKey).dropFirst(lenIV))
        }

        mutating func run(_ encrypted: [UInt8]) -> Bool {
            execute(plain(encrypted), depth: 0)
        }

        private mutating func execute(_ bytes: [UInt8], depth: Int) -> Bool {
            guard depth <= 10 else { return false }
            var index = 0
            while index < bytes.count, !ended {
                steps += 1
                guard steps < 1_000_000 else { return false }
                let b = bytes[index]
                switch b {
                case 32...246:
                    stack.append(Double(Int(b) - 139)); index += 1
                case 247...250:
                    guard index + 2 <= bytes.count else { return false }
                    stack.append(Double((Int(b) - 247) * 256 + Int(bytes[index + 1]) + 108)); index += 2
                case 251...254:
                    guard index + 2 <= bytes.count else { return false }
                    stack.append(Double(-(Int(b) - 251) * 256 - Int(bytes[index + 1]) - 108)); index += 2
                case 255:
                    guard index + 5 <= bytes.count else { return false }
                    let bits = Int32(bitPattern: UInt32(bytes[index + 1]) << 24 | UInt32(bytes[index + 2]) << 16 | UInt32(bytes[index + 3]) << 8 | UInt32(bytes[index + 4]))
                    stack.append(Double(bits)); index += 5
                case 10:
                    guard let top = stack.popLast(), let number = top, number == number.rounded(), number >= 0, Int(number) < subrs.count else { return false }
                    usedSubrs.insert(Int(number))
                    guard execute(plain(subrs[Int(number)]), depth: depth + 1) else { return false }
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
                    switch op {
                    case 6: // seac: asb adx ady bchar achar
                        let achar = stack.popLast() ?? nil, bchar = stack.popLast() ?? nil
                        for code in [bchar, achar] { if let code { accentCodes.append(Int(code)) } }
                        ended = true
                        return true
                    case 16: // callothersubr: args… n othersubr#
                        let other = stack.popLast() ?? nil
                        // The argument count is a number the charstring pushed, and its arguments
                        // are on the stack. A count of 2^31 − 1 used to run two billion O(n)
                        // inserts — a hang, then no memory — that the step guard never saw (T-038).
                        guard let top = stack.popLast(), let number = top, number == number.rounded(),
                              number >= 0, number <= Double(stack.count) else { return false }
                        let count = Int(number)
                        let arguments = Array(stack.suffix(count))
                        stack.removeLast(count)
                        switch other.map({ Int($0) }) {
                        case 3?: postScript = arguments.isEmpty ? [nil] : [arguments[0]]
                        case 0?: postScript = [nil, nil]
                        default: postScript = arguments
                        }
                    case 17: // pop
                        stack.append(postScript.popLast() ?? nil)
                    case 12: // div
                        _ = stack.popLast(); _ = stack.popLast(); stack.append(nil)
                    case 33: // setcurrentpoint
                        stack = []
                    default: // dotsection, vstem3, hstem3, sbw
                        stack = []
                    }
                default:
                    stack = []
                    index += 1
                }
            }
            return true
        }
    }
}
