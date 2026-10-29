import Foundation

/// What the text rewriter needs to know about one font: how a string splits into character
/// codes, how far each code advances, how tall its box is, and which text it stands for.
///
/// Widths come only from the font dictionary — `/Widths` for simple and Type 3 fonts, `/W` and
/// `/DW` for CID fonts — never from a guessed font program, because a glyph position computed
/// from the wrong width moves every glyph after it and the verifier would rightly refuse the
/// copy. A font whose widths cannot be read exactly is a ``RedactionUnsupported`` and its sheet
/// goes to the raster path.
struct RedactionFont {

    enum Kind: Equatable { case simple, type3, composite }

    struct Code: Hashable {
        var value: UInt32
        var length: Int
    }

    /// A box in text space for a font size of 1 (the advance runs along x from 0).
    struct GlyphBox: Equatable {
        var minX: Double
        var minY: Double
        var maxX: Double
        var maxY: Double
    }

    let kind: Kind
    let name: String
    private let firstChar: Int
    private let widths: [Double]
    private let missingWidth: Double
    /// CID fonts: explicit widths and ranges from `/W`, `/DW`.
    private let cidWidths: [UInt32: Double]
    private let cidWidthRanges: [(first: UInt32, last: UInt32, width: Double)]
    private let defaultWidth: Double
    private let codeMap: RedactionCMap?
    private let identityEncoding: Bool
    private let toUnicode: RedactionCMap?
    private let simpleUnicode: [Int: String]
    /// Type 3: glyph space → text space, and each code's box from `d1`.
    private let fontMatrix: (a: Double, d: Double, e: Double, f: Double)
    private let type3Boxes: [Int: GlyphBox]
    private let verticalExtent: (minY: Double, maxY: Double)
    /// The font's bounding box in text space for a font size of 1: the union of every glyph's
    /// ink, so no glyph draws outside `advance box ∪ fontBox` placed at its origin.
    private let fontBox: GlyphBox?

    // MARK: - Reading a font dictionary

    init(dictionary: [String: PDFObject], resolve: (PDFObject?) -> PDFObject?) throws {
        let subtype = resolve(dictionary["Subtype"])?.nameValue ?? ""
        name = resolve(dictionary["BaseFont"])?.nameValue ?? subtype
        switch subtype {
        case "Type1", "MMType1", "TrueType":
            kind = .simple
        case "Type3":
            kind = .type3
        case "Type0":
            kind = .composite
        default:
            throw RedactionUnsupported("a font of type “\(subtype.isEmpty ? "unknown" : subtype)” cannot be measured")
        }

        var firstChar = 0, widths: [Double] = [], missingWidth = 0.0
        var cidWidths: [UInt32: Double] = [:], cidRanges: [(UInt32, UInt32, Double)] = [], defaultWidth = 1000.0
        var codeMap: RedactionCMap?, identity = false
        var matrix = (a: 0.001, d: 0.001, e: 0.0, f: 0.0)
        var type3Boxes: [Int: GlyphBox] = [:]
        var descriptor: [String: PDFObject]?

        switch kind {
        case .simple, .type3:
            firstChar = resolve(dictionary["FirstChar"])?.integerValue ?? 0
            // A simple font's codes are single bytes. `/FirstChar Int.min` used to reach
            // `Int(code) - firstChar` in width(_:) and trap on the first glyph measured; a value
            // out of range is refused like a /W CID past UInt32 (S-063, T-037).
            guard (0...0xFFFF).contains(firstChar) else {
                throw RedactionUnsupported("the font \(name)'s /FirstChar is out of range")
            }
            guard let array = resolve(dictionary["Widths"])?.arrayValue, !array.isEmpty else {
                throw RedactionUnsupported("the font \(name) has no width table (a standard font without /Widths)")
            }
            widths = array.map { resolve($0)?.doubleValue ?? 0 }
            descriptor = resolve(dictionary["FontDescriptor"])?.dictionaryValue
            missingWidth = resolve(descriptor?["MissingWidth"])?.doubleValue ?? 0
            if kind == .type3 {
                guard let values = resolve(dictionary["FontMatrix"])?.arrayValue?.compactMap({ resolve($0)?.doubleValue }), values.count == 6 else {
                    throw RedactionUnsupported("the Type 3 font \(name) has no readable FontMatrix")
                }
                guard abs(values[1]) < 1e-12, abs(values[2]) < 1e-12, abs(values[0]) > 1e-12 else {
                    throw RedactionUnsupported("the Type 3 font \(name) is rotated or skewed by its FontMatrix")
                }
                matrix = (values[0], values[3], values[4], values[5])
                type3Boxes = try Self.type3GlyphBoxes(dictionary, matrix: matrix, resolve: resolve)
            }
        case .composite:
            guard let descendants = resolve(dictionary["DescendantFonts"])?.arrayValue,
                  let cidFont = resolve(descendants.first)?.dictionaryValue else {
                throw RedactionUnsupported("the composite font \(name) has no descendant font")
            }
            let cidSubtype = resolve(cidFont["Subtype"])?.nameValue ?? ""
            guard cidSubtype == "CIDFontType0" || cidSubtype == "CIDFontType2" else {
                throw RedactionUnsupported("the composite font \(name) has a descendant of type “\(cidSubtype)”")
            }
            descriptor = resolve(cidFont["FontDescriptor"])?.dictionaryValue
            defaultWidth = resolve(cidFont["DW"])?.doubleValue ?? 1000
            if let array = resolve(cidFont["W"])?.arrayValue {
                (cidWidths, cidRanges) = try Self.readW(array, resolve: resolve)
            }
            switch resolve(dictionary["Encoding"]) {
            case .name("Identity-H")?:
                identity = true
            case let .name(other)?:
                throw RedactionUnsupported(other.hasSuffix("-V")
                    ? "the font \(name) writes vertically (\(other))"
                    : "the font \(name) uses the predefined CMap \(other), which is not embedded")
            case let .stream(streamDictionary, data)?:
                let decoded = try RedactionStreamFilters.decode(dictionary: streamDictionary, data: data).data
                let map = try RedactionCMap(decoded)
                if map.writingMode == 1 || resolve(streamDictionary["WMode"])?.integerValue == 1 {
                    throw RedactionUnsupported("the font \(name) writes vertically")
                }
                guard !map.usesOtherCMap, resolve(streamDictionary["UseCMap"]) == nil else {
                    throw RedactionUnsupported("the font \(name)'s CMap builds on another CMap")
                }
                guard !map.codeSpace.isEmpty else { throw RedactionUnsupported("the font \(name)'s CMap has no code space") }
                codeMap = map
            default:
                throw RedactionUnsupported("the composite font \(name) has no encoding")
            }
        }

        var toUnicode: RedactionCMap?
        if case let .stream(streamDictionary, data)? = resolve(dictionary["ToUnicode"]),
           let decoded = try? RedactionStreamFilters.decode(dictionary: streamDictionary, data: data).data {
            toUnicode = try? RedactionCMap(decoded)
        }

        // Vertical extent: ascent and descent where the descriptor gives sane ones, the font
        // box otherwise, and a full em as the last resort — never less than the glyph can be.
        var minY = -0.25, maxY = 1.0
        var fontBox: GlyphBox?
        let boxSource = kind == .type3 ? resolve(dictionary["FontBBox"]) : resolve(descriptor?["FontBBox"])
        if let values = boxSource?.arrayValue?.compactMap({ resolve($0)?.doubleValue }), values.count == 4,
           values[2] > values[0], values[3] > values[1] {
            let scaleX = kind == .type3 ? matrix.a : 0.001, scaleY = kind == .type3 ? matrix.d : 0.001
            let offsetX = kind == .type3 ? matrix.e : 0, offsetY = kind == .type3 ? matrix.f : 0
            let xs = [values[0] * scaleX + offsetX, values[2] * scaleX + offsetX], ys = [values[1] * scaleY + offsetY, values[3] * scaleY + offsetY]
            fontBox = GlyphBox(minX: xs.min()!, minY: ys.min()!, maxX: xs.max()!, maxY: ys.max()!)
        }
        if kind == .type3 {
            if let box = resolve(dictionary["FontBBox"])?.arrayValue?.compactMap({ resolve($0)?.doubleValue }), box.count == 4,
               box[3] > box[1] {
                minY = min(box[1], box[3]) * matrix.d + matrix.f
                maxY = max(box[1], box[3]) * matrix.d + matrix.f
                if minY > maxY { swap(&minY, &maxY) }
            }
        } else if let descriptor {
            let ascent = resolve(descriptor["Ascent"])?.doubleValue ?? 0
            let descent = resolve(descriptor["Descent"])?.doubleValue ?? 0
            let box = resolve(descriptor["FontBBox"])?.arrayValue?.compactMap { resolve($0)?.doubleValue }
            if ascent > descent, ascent > 0 {
                minY = min(descent, 0) / 1000
                maxY = ascent / 1000
            } else if let box, box.count == 4, box[3] > box[1] {
                minY = min(box[1], 0) / 1000
                maxY = box[3] / 1000
            }
        }

        self.firstChar = firstChar
        self.widths = widths
        self.missingWidth = missingWidth
        self.cidWidths = cidWidths
        self.cidWidthRanges = cidRanges
        self.defaultWidth = defaultWidth
        self.codeMap = codeMap
        self.identityEncoding = identity
        self.toUnicode = toUnicode
        self.fontMatrix = matrix
        self.type3Boxes = type3Boxes
        self.verticalExtent = (minY, maxY)
        self.fontBox = fontBox
        self.simpleUnicode = kind == .composite ? [:] : Self.simpleEncoding(dictionary, resolve: resolve)
    }

    static func readW(_ array: [PDFObject], resolve: (PDFObject?) -> PDFObject?) throws
        -> ([UInt32: Double], [(UInt32, UInt32, Double)]) {
        var explicit: [UInt32: Double] = [:]
        var ranges: [(UInt32, UInt32, Double)] = []
        var index = 0
        let items = array.map { resolve($0) ?? .null }
        while index < items.count {
            guard let first = items[index].integerValue, first >= 0 else { throw RedactionUnsupported("a font's /W array is malformed") }
            guard index + 1 < items.count else { break }
            // A CID is a UInt32; a value past it is refused, never converted with a trap (S-063).
            if let list = items[index + 1].arrayValue {
                for (offset, value) in list.enumerated() {
                    let (sum, overflow) = first.addingReportingOverflow(offset)
                    guard !overflow, let cid = UInt32(exactly: sum) else {
                        throw RedactionUnsupported("a font's /W array names a CID past 4294967295")
                    }
                    explicit[cid] = resolve(value)?.doubleValue ?? 0
                }
                index += 2
            } else {
                guard index + 2 < items.count, let last = items[index + 1].integerValue, let width = items[index + 2].doubleValue,
                      last >= first else { throw RedactionUnsupported("a font's /W array is malformed") }
                guard let low = UInt32(exactly: first), let high = UInt32(exactly: last) else {
                    throw RedactionUnsupported("a font's /W array names a CID past 4294967295")
                }
                ranges.append((low, high, width))
                index += 3
            }
        }
        return (explicit, ranges)
    }

    /// Each Type 3 glyph's box from the `d1` operator of its glyph procedure, in text space.
    private static func type3GlyphBoxes(
        _ dictionary: [String: PDFObject],
        matrix: (a: Double, d: Double, e: Double, f: Double),
        resolve: (PDFObject?) -> PDFObject?
    ) throws -> [Int: GlyphBox] {
        guard let procs = resolve(dictionary["CharProcs"])?.dictionaryValue else { return [:] }
        let names = differences(resolve(dictionary["Encoding"])?.dictionaryValue, resolve: resolve)
        var boxes: [Int: GlyphBox] = [:]
        for (code, glyph) in names {
            guard case let .stream(streamDictionary, data)? = resolve(procs[glyph]),
                  let decoded = try? RedactionStreamFilters.decode(dictionary: streamDictionary, data: data).data,
                  let operations = try? RedactionContentLexer.parse(decoded.prefix(4096)),
                  let first = operations.first(where: { $0.name == "d1" || $0.name == "d0" }),
                  first.name == "d1", first.operands.count == 6
            else { continue }
            let values = first.operands.compactMap(\.doubleValue)
            guard values.count == 6 else { continue }
            var box = GlyphBox(
                minX: min(values[2], values[4]) * matrix.a + matrix.e, minY: min(values[3], values[5]) * matrix.d + matrix.f,
                maxX: max(values[2], values[4]) * matrix.a + matrix.e, maxY: max(values[3], values[5]) * matrix.d + matrix.f
            )
            if box.minX > box.maxX { swap(&box.minX, &box.maxX) }
            if box.minY > box.maxY { swap(&box.minY, &box.maxY) }
            boxes[code] = box
        }
        return boxes
    }

    /// `/Differences` as code → glyph name.
    ///
    /// Only single-byte codes (0…255) exist in a simple or Type 3 font. A number outside that
    /// range is skipped together with the names that follow it, and a run stops at 255:
    /// `[9223372036854775807 /a]` used to trap on `code += 1` (T-037).
    static func differences(_ encoding: [String: PDFObject]?, resolve: (PDFObject?) -> PDFObject?) -> [Int: String] {
        guard let array = resolve(encoding?["Differences"])?.arrayValue else { return [:] }
        var out: [Int: String] = [:]
        var code: Int? = 0
        for item in array {
            if let number = resolve(item)?.integerValue {
                code = (0...255).contains(number) ? number : nil
            } else if let glyph = resolve(item)?.nameValue {
                guard let current = code else { continue }
                out[current] = glyph
                code = current < 255 ? current + 1 : nil
            }
        }
        return out
    }

    private static func simpleEncoding(_ dictionary: [String: PDFObject], resolve: (PDFObject?) -> PDFObject?) -> [Int: String] {
        var out: [Int: String] = [:]
        let encoding = resolve(dictionary["Encoding"])
        let base = encoding?.nameValue ?? resolve(encoding?.dictionaryValue?["BaseEncoding"])?.nameValue
        if base != nil || encoding == nil {
            for code in 32...126 { out[code] = String(UnicodeScalar(UInt8(code))) }
            if base == "StandardEncoding" { out[0x27] = "\u{2019}"; out[0x60] = "\u{2018}" }
        }
        for (code, glyph) in differences(encoding?.dictionaryValue, resolve: resolve) {
            if let text = RedactionGlyphNames.unicode(for: glyph) { out[code] = text } else { out.removeValue(forKey: code) }
        }
        return out
    }

    // MARK: - Using it

    /// Splits a string operand into character codes.
    func codes(_ bytes: [UInt8]) throws -> [Code] {
        switch kind {
        case .simple, .type3:
            return bytes.map { Code(value: UInt32($0), length: 1) }
        case .composite:
            if identityEncoding {
                guard bytes.count % 2 == 0 else { throw RedactionUnsupported("a string in the font \(name) has an odd number of bytes") }
                return stride(from: 0, to: bytes.count, by: 2).map { Code(value: UInt32(bytes[$0]) << 8 | UInt32(bytes[$0 + 1]), length: 2) }
            }
            guard let codeMap else { throw RedactionUnsupported("the font \(name) has no code space") }
            var out: [Code] = []
            var index = 0
            while index < bytes.count {
                guard let length = codeMap.codeLength(bytes, at: index) else {
                    throw RedactionUnsupported("a string does not fit the code space of the font \(name)")
                }
                var value: UInt32 = 0
                for byte in bytes[index..<(index + length)] { value = value << 8 | UInt32(byte) }
                out.append(Code(value: value, length: length))
                index += length
            }
            return out
        }
    }

    /// Horizontal advance in text space for a font size of 1, before spacing and scaling.
    func width(_ code: Code) -> Double {
        switch kind {
        case .simple:
            let index = Int(code.value) - firstChar
            return (index >= 0 && index < widths.count ? widths[index] : missingWidth) / 1000
        case .type3:
            let index = Int(code.value) - firstChar
            return (index >= 0 && index < widths.count ? widths[index] : 0) * fontMatrix.a
        case .composite:
            let cid = identityEncoding ? code.value : (codeMap?.cid(for: code) ?? 0)
            if let explicit = cidWidths[cid] { return explicit / 1000 }
            if let range = cidWidthRanges.first(where: { $0.first <= cid && cid <= $0.last }) { return range.width / 1000 }
            return defaultWidth / 1000
        }
    }

    /// The glyph's box in text space for a font size of 1.
    func box(_ code: Code) -> GlyphBox {
        let advance = width(code)
        var box = GlyphBox(minX: min(0, advance), minY: verticalExtent.minY, maxX: max(0, advance), maxY: verticalExtent.maxY)
        if kind == .type3, let ink = type3Boxes[Int(code.value)] {
            box.minX = min(box.minX, ink.minX)
            box.maxX = max(box.maxX, ink.maxX)
            box.minY = min(box.minY, ink.minY)
            box.maxY = max(box.maxY, ink.maxY)
        }
        return box
    }

    /// Where the glyph's ink can be: its box, grown by the font box (the union of all glyphs'
    /// ink) when the font has one, and by a full em each way when it has none.
    func inkEnvelope(_ code: Code) -> GlyphBox {
        var envelope = box(code)
        if kind == .type3, type3Boxes[Int(code.value)] != nil { return envelope }
        let ink = fontBox ?? GlyphBox(minX: -1, minY: -1, maxX: 2, maxY: 2)
        envelope.minX = min(envelope.minX, ink.minX)
        envelope.maxX = max(envelope.maxX, ink.maxX)
        envelope.minY = min(envelope.minY, ink.minY)
        envelope.maxY = max(envelope.maxY, ink.maxY)
        return envelope
    }

    /// Word spacing applies to the single-byte code 32 only (§9.3.3).
    func takesWordSpacing(_ code: Code) -> Bool {
        code.length == 1 && code.value == 32
    }

    /// The text a code stands for, when the font says.
    func unicode(_ code: Code) -> String? {
        if let toUnicode, let text = toUnicode.unicode(for: code) { return text }
        switch kind {
        case .simple, .type3: return simpleUnicode[Int(code.value)]
        case .composite: return nil
        }
    }
}

/// How a font's strings split into codes, read without its widths — enough to learn which codes
/// a sheet still draws in a font that lost glyphs under a box (a standard font without a width
/// table included).
struct RedactionCodeSplitter {
    private enum Kind { case single, identity, map(RedactionCMap) }
    private let kind: Kind

    init(dictionary: [String: PDFObject], resolve: (PDFObject?) -> PDFObject?) throws {
        guard resolve(dictionary["Subtype"])?.nameValue == "Type0" else {
            kind = .single
            return
        }
        switch resolve(dictionary["Encoding"]) {
        case .name("Identity-H")?, .name("Identity-V")?:
            kind = .identity
        case let .stream(streamDictionary, data)?:
            let map = try RedactionCMap(try RedactionStreamFilters.decode(dictionary: streamDictionary, data: data).data)
            guard !map.codeSpace.isEmpty else { throw RedactionUnsupported("a font's CMap has no code space") }
            kind = .map(map)
        default:
            throw RedactionUnsupported("a composite font's codes cannot be read")
        }
    }

    func codes(_ bytes: [UInt8]) throws -> [RedactionFont.Code] {
        switch kind {
        case .single:
            return bytes.map { RedactionFont.Code(value: UInt32($0), length: 1) }
        case .identity:
            guard bytes.count % 2 == 0 else { throw RedactionUnsupported("a string has an odd number of bytes") }
            return stride(from: 0, to: bytes.count, by: 2).map { RedactionFont.Code(value: UInt32(bytes[$0]) << 8 | UInt32(bytes[$0 + 1]), length: 2) }
        case let .map(map):
            var out: [RedactionFont.Code] = []
            var index = 0
            while index < bytes.count {
                guard let length = map.codeLength(bytes, at: index) else { throw RedactionUnsupported("a string does not fit a font's code space") }
                var value: UInt32 = 0
                for byte in bytes[index..<(index + length)] { value = value << 8 | UInt32(byte) }
                out.append(RedactionFont.Code(value: value, length: length))
                index += length
            }
            return out
        }
    }
}

/// A CMap read from a stream: its code space, CID mappings, Unicode mappings and writing mode.
struct RedactionCMap {
    struct Range {
        var low: [UInt8]
        var high: [UInt8]
    }
    private(set) var codeSpace: [Range] = []
    private(set) var cidRanges: [(low: UInt32, high: UInt32, length: Int, cid: UInt32)] = []
    private(set) var unicodeSingles: [UInt64: String] = [:]
    private(set) var unicodeRanges: [(low: UInt32, high: UInt32, length: Int, start: [UInt8]?, list: [String]?)] = []
    private(set) var writingMode = 0
    private(set) var usesOtherCMap = false

    init(_ data: Data) throws {
        let bytes = [UInt8](data.prefix(8 * 1024 * 1024))
        var parser = PDFObjectParser(bytes: bytes)
        var stack: [PDFObject] = []
        var guardCount = 0
        while true {
            guardCount += 1
            if guardCount > 4_000_000 { break }
            parser.skipWhitespaceAndComments()
            guard parser.index < bytes.count else { break }
            let byte = bytes[parser.index]
            if byte == UInt8(ascii: "/") || byte == UInt8(ascii: "<") || byte == UInt8(ascii: "[") || byte == UInt8(ascii: "(")
                || PDFByte.isDigit(byte) || byte == UInt8(ascii: "-") {
                if byte == UInt8(ascii: "<"), parser.index + 1 < bytes.count, bytes[parser.index + 1] == UInt8(ascii: "<") {
                    // A dictionary (CIDSystemInfo); read and drop it.
                    _ = parser.parseObject()
                    continue
                }
                guard let object = parser.parseObject() else { parser.index += 1; continue }
                stack.append(object)
                if stack.count > 100_000 { stack.removeFirst(50_000) }
                continue
            }
            guard let keyword = parser.readKeyword() else { parser.index += 1; continue }
            switch keyword {
            case "endcodespacerange":
                var index = 0
                while index + 1 < stack.count {
                    if let low = Self.bytes(stack[index]), let high = Self.bytes(stack[index + 1]), low.count == high.count, !low.isEmpty, low.count <= 4 {
                        codeSpace.append(Range(low: low, high: high))
                    }
                    index += 2
                }
            case "endcidrange":
                var index = 0
                while index + 2 < stack.count {
                    // A CID past UInt32 is skipped, never converted with a trap (S-063).
                    if let low = Self.bytes(stack[index]), let high = Self.bytes(stack[index + 1]),
                       let cid = stack[index + 2].integerValue.flatMap({ UInt32(exactly: $0) }),
                       low.count == high.count, low.count <= 4 {
                        cidRanges.append((Self.value(low), Self.value(high), low.count, cid))
                    }
                    index += 3
                }
            case "endcidchar":
                var index = 0
                while index + 1 < stack.count {
                    if let code = Self.bytes(stack[index]), let cid = stack[index + 1].integerValue.flatMap({ UInt32(exactly: $0) }),
                       code.count <= 4 {
                        cidRanges.append((Self.value(code), Self.value(code), code.count, cid))
                    }
                    index += 2
                }
            case "endbfchar":
                var index = 0
                while index + 1 < stack.count {
                    if let code = Self.bytes(stack[index]), code.count <= 4, let text = Self.text(stack[index + 1]) {
                        unicodeSingles[Self.key(Self.value(code), code.count)] = text
                    }
                    index += 2
                }
            case "endbfrange":
                var index = 0
                while index + 2 < stack.count {
                    if let low = Self.bytes(stack[index]), let high = Self.bytes(stack[index + 1]), low.count == high.count, low.count <= 4 {
                        if let start = Self.bytes(stack[index + 2]) {
                            unicodeRanges.append((Self.value(low), Self.value(high), low.count, start, nil))
                        } else if let list = stack[index + 2].arrayValue {
                            unicodeRanges.append((Self.value(low), Self.value(high), low.count, nil, list.map { Self.text($0) ?? "" }))
                        }
                    }
                    index += 3
                }
            case "def":
                if stack.count >= 2, stack[stack.count - 2] == .name("WMode"), let mode = stack.last?.integerValue { writingMode = mode }
            case "usecmap":
                usesOtherCMap = true
            default:
                break
            }
            if keyword.hasPrefix("end") || keyword == "def" || keyword.hasPrefix("begin") { stack.removeAll(keepingCapacity: true) }
        }
    }

    private static func bytes(_ object: PDFObject) -> [UInt8]? {
        switch object {
        case let .hexString(value), let .string(value): value
        default: nil
        }
    }

    private static func value(_ bytes: [UInt8]) -> UInt32 { bytes.reduce(0) { $0 << 8 | UInt32($1) } }
    private static func key(_ value: UInt32, _ length: Int) -> UInt64 { UInt64(length) << 32 | UInt64(value) }

    private static func text(_ object: PDFObject) -> String? {
        guard let bytes = bytes(object), !bytes.isEmpty else { return nil }
        return utf16(bytes)
    }

    static func utf16(_ bytes: [UInt8]) -> String {
        var units: [UInt16] = []
        var index = 0
        while index + 1 < bytes.count {
            units.append(UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1]))
            index += 2
        }
        if bytes.count % 2 == 1 { units.append(UInt16(bytes[bytes.count - 1])) }
        return String(decoding: units, as: UTF16.self)
    }

    /// How many bytes the code at `index` takes, by the code-space ranges (§9.7.6.2).
    func codeLength(_ bytes: [UInt8], at index: Int) -> Int? {
        for length in 1...4 where index + length <= bytes.count {
            let candidate = Array(bytes[index..<(index + length)])
            for range in codeSpace where range.low.count == length {
                var inside = true
                for position in 0..<length where candidate[position] < range.low[position] || candidate[position] > range.high[position] {
                    inside = false
                    break
                }
                if inside { return length }
            }
        }
        return nil
    }

    func cid(for code: RedactionFont.Code) -> UInt32? {
        for range in cidRanges.reversed() where range.length == code.length && range.low <= code.value && code.value <= range.high {
            // `<0000> <FFFF> 4294967295` would carry the CID past UInt32 for every code but the first.
            let (cid, overflow) = range.cid.addingReportingOverflow(code.value - range.low)
            return overflow ? nil : cid
        }
        return nil
    }

    func unicode(for code: RedactionFont.Code) -> String? {
        if let single = unicodeSingles[Self.key(code.value, code.length)] { return single }
        for range in unicodeRanges where range.length == code.length && range.low <= code.value && code.value <= range.high {
            let offset = Int(code.value - range.low)
            if let list = range.list { return offset < list.count ? list[offset] : nil }
            guard var start = range.start, !start.isEmpty else { return nil }
            var carry = offset
            var position = start.count - 1
            while carry > 0, position >= 0 {
                let sum = Int(start[position]) + carry
                start[position] = UInt8(sum & 0xFF)
                carry = sum >> 8
                position -= 1
            }
            return Self.utf16(start)
        }
        return nil
    }
}

/// Glyph names to text for the names a drawing's simple fonts actually use (a subset of the
/// Adobe Glyph List, plus the `uniXXXX` and `uXXXX` forms).
enum RedactionGlyphNames {
    private static let table: [String: String] = [
        "space": " ", "exclam": "!", "quotedbl": "\"", "numbersign": "#", "dollar": "$", "percent": "%",
        "ampersand": "&", "quotesingle": "'", "quoteright": "\u{2019}", "quoteleft": "\u{2018}", "parenleft": "(",
        "parenright": ")", "asterisk": "*", "plus": "+", "comma": ",", "hyphen": "-", "minus": "\u{2212}",
        "period": ".", "slash": "/", "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5",
        "six": "6", "seven": "7", "eight": "8", "nine": "9", "colon": ":", "semicolon": ";", "less": "<",
        "equal": "=", "greater": ">", "question": "?", "at": "@", "bracketleft": "[", "backslash": "\\",
        "bracketright": "]", "asciicircum": "^", "underscore": "_", "grave": "`", "braceleft": "{", "bar": "|",
        "braceright": "}", "asciitilde": "~", "endash": "\u{2013}", "emdash": "\u{2014}", "bullet": "\u{2022}",
        "degree": "\u{00B0}", "multiply": "\u{00D7}", "plusminus": "\u{00B1}", "adieresis": "\u{00E4}",
        "odieresis": "\u{00F6}", "aring": "\u{00E5}", "Adieresis": "\u{00C4}", "Odieresis": "\u{00D6}",
        "Aring": "\u{00C5}", "eacute": "\u{00E9}", "Eacute": "\u{00C9}", "udieresis": "\u{00FC}",
        "Udieresis": "\u{00DC}", "section": "\u{00A7}", "copyright": "\u{00A9}", "registered": "\u{00AE}",
        "mu": "\u{00B5}", "twosuperior": "\u{00B2}", "threesuperior": "\u{00B3}", "diameter": "\u{2300}"
    ]

    static func unicode(for name: String) -> String? {
        if let known = table[name] { return known }
        if name.count == 1, let scalar = name.unicodeScalars.first, scalar.isASCII, CharacterSet.letters.contains(scalar) { return name }
        if name.hasPrefix("uni"), name.count >= 7, let value = UInt32(name.dropFirst(3).prefix(4), radix: 16), let scalar = UnicodeScalar(value) {
            return String(scalar)
        }
        if name.hasPrefix("u"), (5...7).contains(name.count), let value = UInt32(name.dropFirst(), radix: 16), let scalar = UnicodeScalar(value) {
            return String(scalar)
        }
        if let dot = name.firstIndex(of: "."), dot != name.startIndex { return unicode(for: String(name[..<dot])) }
        return nil
    }
}
