import Foundation

/// A recursive-descent reader for the PDF object syntax, over a byte buffer.
///
/// Bounded on purpose: every container is depth-limited, every loop is index-driven, and a
/// construct the parser does not recognise ends the parse rather than resynchronising. A reader
/// that guesses its way past damage is how a "successful" export ends up describing a different
/// drawing.
struct PDFObjectParser {

    /// Deep enough for any real page tree; shallow enough that a hostile file cannot recurse the
    /// stack. qpdf's own default is 200 and the bridge already uses it.
    static let maximumDepth = 64

    let bytes: [UInt8]
    var index: Int
    /// Resolves an indirect `/Length` (`n g R`) to the integer object `n` holds, when the caller
    /// has a document to look it up in. The parser alone has none, so a stream whose length is
    /// indirect takes the `endstream` search — which cannot tell a payload's own trailing CR from
    /// the CR of a CR-LF end-of-line marker. ``PDFDocumentScan`` re-reads those streams with this
    /// set once every object is known.
    var lengthResolver: ((Int) -> Int?)?

    init(bytes: [UInt8], index: Int = 0, lengthResolver: ((Int) -> Int?)? = nil) {
        self.bytes = bytes
        self.index = index
        self.lengthResolver = lengthResolver
    }

    private func resolvedIndirectLength(_ value: PDFObject?) -> Int? {
        guard let lengthResolver, let number = value?.referenceValue?.number else { return nil }
        return lengthResolver(number)
    }

    // MARK: - Scanning primitives

    mutating func skipWhitespaceAndComments() {
        while index < bytes.count {
            let byte = bytes[index]
            if PDFByte.isWhitespace(byte) {
                index += 1
            } else if byte == UInt8(ascii: "%") {
                while index < bytes.count, bytes[index] != 0x0A, bytes[index] != 0x0D {
                    index += 1
                }
            } else {
                return
            }
        }
    }

    /// Reads the next regular-character run without interpreting it, e.g. `obj`, `endstream`, `R`.
    mutating func readKeyword() -> String? {
        skipWhitespaceAndComments()
        let start = index
        while index < bytes.count, PDFByte.isRegular(bytes[index]) { index += 1 }
        guard index > start else { return nil }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }

    /// Whether the buffer spells `keyword` at `position`, bounded by a non-regular byte.
    func matches(_ keyword: String, at position: Int) -> Bool {
        let needle = Array(keyword.utf8)
        guard position >= 0, position + needle.count <= bytes.count else { return false }
        for (offset, byte) in needle.enumerated() where bytes[position + offset] != byte {
            return false
        }
        let after = position + needle.count
        return after == bytes.count || !PDFByte.isRegular(bytes[after])
    }

    // MARK: - Objects

    mutating func parseObject(depth: Int = 0) -> PDFObject? {
        guard depth <= Self.maximumDepth else { return nil }
        skipWhitespaceAndComments()
        guard index < bytes.count else { return nil }

        switch bytes[index] {
        case UInt8(ascii: "/"):
            return parseName()
        case UInt8(ascii: "("):
            return parseLiteralString()
        case UInt8(ascii: "<"):
            if index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "<") {
                return parseDictionaryOrStream(depth: depth)
            }
            return parseHexString()
        case UInt8(ascii: "["):
            return parseArray(depth: depth)
        case UInt8(ascii: "]"), UInt8(ascii: ">"), UInt8(ascii: ")"), UInt8(ascii: "}"):
            return nil
        default:
            break
        }

        if matches("true", at: index) { index += 4; return .boolean(true) }
        if matches("false", at: index) { index += 5; return .boolean(false) }
        if matches("null", at: index) { index += 4; return .null }
        return parseNumberOrReference()
    }

    private mutating func parseName() -> PDFObject? {
        index += 1  // the solidus
        var out: [UInt8] = []
        while index < bytes.count, PDFByte.isRegular(bytes[index]) {
            let byte = bytes[index]
            if byte == UInt8(ascii: "#"), index + 2 < bytes.count,
               let high = Self.hexValue(bytes[index + 1]),
               let low = Self.hexValue(bytes[index + 2]) {
                out.append(high << 4 | low)
                index += 3
                continue
            }
            out.append(byte)
            index += 1
        }
        return .name(String(decoding: out, as: UTF8.self))
    }

    private mutating func parseLiteralString() -> PDFObject? {
        index += 1
        var out: [UInt8] = []
        var depth = 1
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if byte == UInt8(ascii: "\\") {
                guard index < bytes.count else { break }
                let escaped = bytes[index]
                index += 1
                switch escaped {
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case 0x0A: break
                case 0x0D:
                    if index < bytes.count, bytes[index] == 0x0A { index += 1 }
                case UInt8(ascii: "0")...UInt8(ascii: "7"):
                    var value = Int(escaped - UInt8(ascii: "0"))
                    var digits = 1
                    while digits < 3, index < bytes.count,
                          bytes[index] >= UInt8(ascii: "0"), bytes[index] <= UInt8(ascii: "7") {
                        value = value * 8 + Int(bytes[index] - UInt8(ascii: "0"))
                        index += 1
                        digits += 1
                    }
                    out.append(UInt8(value & 0xFF))
                default:
                    out.append(escaped)
                }
                continue
            }
            if byte == UInt8(ascii: "(") { depth += 1 }
            if byte == UInt8(ascii: ")") {
                depth -= 1
                if depth == 0 { return .string(out) }
            }
            out.append(byte)
        }
        return .string(out)
    }

    private mutating func parseHexString() -> PDFObject? {
        index += 1
        var out: [UInt8] = []
        var high: UInt8?
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if byte == UInt8(ascii: ">") { break }
            guard let value = Self.hexValue(byte) else { continue }
            if let pending = high {
                out.append(pending << 4 | value)
                high = nil
            } else {
                high = value
            }
        }
        if let pending = high { out.append(pending << 4) }
        return .hexString(out)
    }

    private mutating func parseArray(depth: Int) -> PDFObject? {
        index += 1
        var values: [PDFObject] = []
        while true {
            skipWhitespaceAndComments()
            guard index < bytes.count else { return .array(values) }
            if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(values) }
            guard let value = parseObject(depth: depth + 1) else { return .array(values) }
            values.append(value)
            // A container that never terminates is a hostile file, not a big drawing.
            if values.count > 200_000 { return .array(values) }
        }
    }

    private mutating func parseDictionaryOrStream(depth: Int) -> PDFObject? {
        index += 2
        var entries: [String: PDFObject] = [:]
        while true {
            skipWhitespaceAndComments()
            guard index < bytes.count else { return .dictionary(entries) }
            if bytes[index] == UInt8(ascii: ">") {
                index += 1
                if index < bytes.count, bytes[index] == UInt8(ascii: ">") { index += 1 }
                break
            }
            guard bytes[index] == UInt8(ascii: "/"),
                  case let .name(key)? = parseName(),
                  let value = parseObject(depth: depth + 1)
            else { return .dictionary(entries) }
            entries[key] = value
            if entries.count > 100_000 { return .dictionary(entries) }
        }

        // `stream` may follow, and if it does the payload is raw bytes rather than syntax.
        let afterDictionary = index
        skipWhitespaceAndComments()
        guard matches("stream", at: index) else {
            index = afterDictionary
            return .dictionary(entries)
        }
        index += 6
        if index < bytes.count, bytes[index] == 0x0D { index += 1 }
        if index < bytes.count, bytes[index] == 0x0A { index += 1 }
        let start = index

        // The declared length is used only when it lands on `endstream`. A wrong `/Length` is one
        // of the most common defects in files produced by plotters, and trusting it truncates the
        // page. An indirect `/Length` is not resolvable here — this parser has no document — so
        // both cases fall through to the search.
        // `declared <= bytes.count - start` rather than `start + declared <= bytes.count`: a
        // hostile `/Length 9223372036854775807` must fall through to the search, not overflow.
        if let declared = entries["Length"]?.integerValue ?? resolvedIndirectLength(entries["Length"]),
           declared >= 0, declared <= bytes.count - start {
            var probe = PDFObjectParser(bytes: bytes, index: start + declared)
            probe.skipWhitespaceAndComments()
            if probe.matches("endstream", at: probe.index) {
                index = probe.index + 9
                return .stream(
                    dictionary: entries,
                    data: Data(bytes[start..<(start + declared)])
                )
            }
        }
        guard let end = Self.find(Array("endstream".utf8), in: bytes, from: start) else {
            return nil
        }
        // No usable length: strip one end-of-line marker (LF, CR-LF or CR), as ISO 32000-1
        // §7.3.8.1 describes it. A payload that itself ends in CR is indistinguishable from a
        // CR-LF marker here, which is why a resolvable indirect `/Length` is resolved first.
        var payloadEnd = end
        if payloadEnd > start, bytes[payloadEnd - 1] == 0x0A {
            payloadEnd -= 1
            if payloadEnd > start, bytes[payloadEnd - 1] == 0x0D { payloadEnd -= 1 }
        } else if payloadEnd > start, bytes[payloadEnd - 1] == 0x0D {
            payloadEnd -= 1
        }
        index = end + 9
        return .stream(dictionary: entries, data: Data(bytes[start..<payloadEnd]))
    }

    private mutating func parseNumberOrReference() -> PDFObject? {
        let start = index
        var sawDigit = false
        var sawPoint = false
        if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") {
            index += 1
        }
        while index < bytes.count {
            let byte = bytes[index]
            if PDFByte.isDigit(byte) { sawDigit = true; index += 1; continue }
            if byte == UInt8(ascii: ".") , !sawPoint { sawPoint = true; index += 1; continue }
            if byte == UInt8(ascii: "-") || byte == UInt8(ascii: "+") { index += 1; continue }
            break
        }
        guard sawDigit || sawPoint else {
            // Not a number at all: step over one byte so a caller's loop still terminates.
            index = start + 1
            return nil
        }
        let text = String(decoding: bytes[start..<index], as: UTF8.self)
        if sawPoint {
            return .real(Double(text) ?? 0)
        }
        guard let value = Int(text) else { return .real(Double(text) ?? 0) }

        // `n g R` — only an unsigned integer pair can open a reference.
        guard value >= 0 else { return .integer(value) }
        let afterFirst = index
        var probe = PDFObjectParser(bytes: bytes, index: index)
        probe.skipWhitespaceAndComments()
        let generationStart = probe.index
        while probe.index < bytes.count, PDFByte.isDigit(bytes[probe.index]) { probe.index += 1 }
        guard probe.index > generationStart,
              let generation = Int(String(decoding: bytes[generationStart..<probe.index], as: UTF8.self))
        else {
            index = afterFirst
            return .integer(value)
        }
        probe.skipWhitespaceAndComments()
        guard probe.matches("R", at: probe.index) else {
            index = afterFirst
            return .integer(value)
        }
        index = probe.index + 1
        return .reference(number: value, generation: generation)
    }

    // MARK: - Helpers

    static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
        default: nil
        }
    }

    static func find(_ needle: [UInt8], in haystack: [UInt8], from start: Int) -> Int? {
        guard !needle.isEmpty, start >= 0, needle.count <= haystack.count else { return nil }
        let last = haystack.count - needle.count
        guard start <= last else { return nil }
        var position = start
        while position <= last {
            if haystack[position] == needle[0] {
                var matched = true
                for offset in 1..<needle.count where haystack[position + offset] != needle[offset] {
                    matched = false
                    break
                }
                if matched { return position }
            }
            position += 1
        }
        return nil
    }

    static func findLast(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, needle.count <= haystack.count else { return nil }
        var position = haystack.count - needle.count
        while position >= 0 {
            var matched = true
            for offset in 0..<needle.count where haystack[position + offset] != needle[offset] {
                matched = false
                break
            }
            if matched { return position }
            position -= 1
        }
        return nil
    }
}
