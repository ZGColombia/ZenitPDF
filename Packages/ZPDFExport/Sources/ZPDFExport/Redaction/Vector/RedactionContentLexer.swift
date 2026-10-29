import Foundation

/// Why the vector rewriter handed a sheet to the raster path instead. Every case is a sentence
/// in the report; none is ever swallowed (NL-PDF-14 phase 2, ADR-0033).
struct RedactionUnsupported: Error, Equatable, CustomStringConvertible {
    let reason: String
    init(_ reason: String) { self.reason = reason }
    var description: String { reason }
}

/// One operator of a content stream with its operands, as ISO 32000-1 §7.8.2 defines it.
struct RedactionOperation: Equatable {
    var operands: [PDFObject]
    var name: String
    /// `BI … ID … EI`: the image dictionary (keys exactly as written, abbreviations included)
    /// and the raw payload.
    var inlineImage: RedactionInlineImage?

    init(_ name: String, _ operands: [PDFObject] = [], inlineImage: RedactionInlineImage? = nil) {
        self.name = name
        self.operands = operands
        self.inlineImage = inlineImage
    }
}

struct RedactionInlineImage: Equatable {
    var dictionary: [String: PDFObject]
    var data: Data
}

/// Reads a content stream into operations and writes operations back.
///
/// The reader shares ``PDFObjectParser`` with the rest of the object layer for operands, so a
/// string, name or number reads the same in a content stream as in a dictionary. Comments are
/// dropped — a comment is not drawn, and a comment on a redacted sheet is exactly the kind of
/// place a stray copy of the secret could survive. Anything the reader cannot place is a
/// ``RedactionUnsupported``: a sheet the rewriter does not fully understand is never written
/// as vector.
enum RedactionContentLexer {

    /// A content stream longer than this is refused rather than parsed; the raster path takes it.
    static let maximumOperations = 4_000_000

    static func parse(_ data: Data) throws -> [RedactionOperation] {
        let bytes = [UInt8](data)
        var parser = PDFObjectParser(bytes: bytes)
        var operations: [RedactionOperation] = []
        var operands: [PDFObject] = []
        while true {
            parser.skipWhitespaceAndComments()
            guard parser.index < bytes.count else { break }
            let byte = bytes[parser.index]
            if startsOperand(byte) || parser.matches("true", at: parser.index)
                || parser.matches("false", at: parser.index) || parser.matches("null", at: parser.index) {
                let before = parser.index
                guard let operand = parser.parseObject() else {
                    throw RedactionUnsupported("a content stream has an operand that cannot be read (byte \(before))")
                }
                operands.append(operand)
                if operands.count > 100_000 { throw RedactionUnsupported("a content stream has an operator with too many operands") }
                continue
            }
            guard let keyword = parser.readKeyword() else {
                throw RedactionUnsupported("a content stream has a byte that is neither operand nor operator (byte \(parser.index))")
            }
            if keyword == "BI" {
                let image = try readInlineImage(bytes, parser: &parser)
                operations.append(RedactionOperation("BI", [], inlineImage: image))
                operands.removeAll()
            } else {
                operations.append(RedactionOperation(keyword, operands))
                operands.removeAll(keepingCapacity: true)
            }
            if operations.count > maximumOperations {
                throw RedactionUnsupported("a content stream has more than \(maximumOperations) operators")
            }
        }
        return operations
    }

    private static func startsOperand(_ byte: UInt8) -> Bool {
        PDFByte.isDigit(byte) || byte == UInt8(ascii: "+") || byte == UInt8(ascii: "-") || byte == UInt8(ascii: ".")
            || byte == UInt8(ascii: "/") || byte == UInt8(ascii: "(") || byte == UInt8(ascii: "<") || byte == UInt8(ascii: "[")
    }

    /// `BI` has been read; reads the key–value pairs, `ID`, the payload and `EI`.
    private static func readInlineImage(_ bytes: [UInt8], parser: inout PDFObjectParser) throws -> RedactionInlineImage {
        var dictionary: [String: PDFObject] = [:]
        while true {
            parser.skipWhitespaceAndComments()
            guard parser.index < bytes.count else { throw RedactionUnsupported("an inline image never reaches ID") }
            if parser.matches("ID", at: parser.index) {
                parser.index += 2
                break
            }
            guard case let .name(key)? = parser.parseObject(), let value = parser.parseObject() else {
                throw RedactionUnsupported("an inline image dictionary cannot be read")
            }
            dictionary[key] = value
            if dictionary.count > 64 { throw RedactionUnsupported("an inline image dictionary is malformed") }
        }
        // Exactly one white-space byte separates ID from the data (§8.9.7).
        if parser.index < bytes.count, PDFByte.isWhitespace(bytes[parser.index]) { parser.index += 1 }
        let start = parser.index

        // Unfiltered data has a length the dictionary states; use it rather than searching for
        // `EI`, which can occur inside binary samples.
        if RedactionInlineImageKeys.filters(dictionary).isEmpty,
           let expected = RedactionInlineImageKeys.unfilteredLength(dictionary),
           expected <= bytes.count - start {
            var probe = PDFObjectParser(bytes: bytes, index: start + expected)
            probe.skipWhitespaceAndComments()
            if probe.matches("EI", at: probe.index) {
                parser.index = probe.index + 2
                return RedactionInlineImage(dictionary: dictionary, data: Data(bytes[start..<(start + expected)]))
            }
        }
        var index = start
        while index + 1 < bytes.count {
            if bytes[index] == UInt8(ascii: "E"), bytes[index + 1] == UInt8(ascii: "I"),
               index > start, PDFByte.isWhitespace(bytes[index - 1]),
               index + 2 >= bytes.count || !PDFByte.isRegular(bytes[index + 2]) {
                var end = index - 1
                // Drop the white space that precedes EI; it is a separator, not data.
                if end > start, bytes[end - 1] == 0x0D, bytes[end] == 0x0A { end -= 1 }
                parser.index = index + 2
                return RedactionInlineImage(dictionary: dictionary, data: Data(bytes[start..<max(start, end)]))
            }
            index += 1
        }
        throw RedactionUnsupported("an inline image has no EI")
    }

    // MARK: - Writing

    static func serialize(_ operations: [RedactionOperation]) -> Data {
        var out = Data()
        out.reserveCapacity(operations.count * 12)
        for operation in operations {
            if let image = operation.inlineImage {
                out.append(contentsOf: Array("BI".utf8))
                for key in image.dictionary.keys.sorted() {
                    guard let value = image.dictionary[key] else { continue }
                    out.append(contentsOf: Array(" /".utf8))
                    out.append(contentsOf: PDFObject.escapedName(key))
                    out.append(UInt8(ascii: " "))
                    out.append(value.serialized)
                }
                out.append(contentsOf: Array(" ID ".utf8))
                out.append(image.data)
                out.append(contentsOf: Array("\nEI\n".utf8))
                continue
            }
            for operand in operation.operands {
                out.append(operand.serialized)
                out.append(UInt8(ascii: " "))
            }
            out.append(contentsOf: Array(operation.name.utf8))
            out.append(0x0A)
        }
        return out
    }
}

/// The abbreviations an inline image may use (§8.9.7, Table 93 and 94).
enum RedactionInlineImageKeys {
    static let expansions: [String: String] = [
        "BPC": "BitsPerComponent", "CS": "ColorSpace", "D": "Decode", "DP": "DecodeParms",
        "F": "Filter", "H": "Height", "IM": "ImageMask", "I": "Interpolate", "W": "Width", "L": "Length"
    ]
    static let filterExpansions: [String: String] = [
        "AHx": "ASCIIHexDecode", "A85": "ASCII85Decode", "LZW": "LZWDecode", "Fl": "FlateDecode",
        "RL": "RunLengthDecode", "CCF": "CCITTFaxDecode", "DCT": "DCTDecode"
    ]
    static let colorSpaceExpansions: [String: String] = [
        "G": "DeviceGray", "RGB": "DeviceRGB", "CMYK": "DeviceCMYK", "I": "Indexed"
    ]

    /// The dictionary with every abbreviated key, filter name and colour-space name spelled out.
    static func expanded(_ dictionary: [String: PDFObject]) -> [String: PDFObject] {
        var out: [String: PDFObject] = [:]
        for (key, value) in dictionary {
            let full = expansions[key] ?? key
            switch full {
            case "Filter":
                if case let .name(name) = value {
                    out[full] = .name(filterExpansions[name] ?? name)
                } else if case let .array(names) = value {
                    out[full] = .array(names.map { $0.nameValue.map { .name(filterExpansions[$0] ?? $0) } ?? $0 })
                } else {
                    out[full] = value
                }
            case "ColorSpace":
                if case let .name(name) = value {
                    out[full] = .name(colorSpaceExpansions[name] ?? name)
                } else if case let .array(items) = value, case let .name(first)? = items.first {
                    var copy = items
                    copy[0] = .name(colorSpaceExpansions[first] ?? first)
                    // An inline Indexed base may be abbreviated as well.
                    if copy.count > 1, case let .name(base) = copy[1] { copy[1] = .name(colorSpaceExpansions[base] ?? base) }
                    out[full] = .array(copy)
                } else {
                    out[full] = value
                }
            default:
                out[full] = value
            }
        }
        return out
    }

    static func filters(_ dictionary: [String: PDFObject]) -> [String] {
        switch dictionary["F"] ?? dictionary["Filter"] {
        case let .name(value)?: [value]
        case let .array(values)?: values.compactMap(\.nameValue)
        default: []
        }
    }

    /// Bytes of unfiltered sample data the dictionary describes, or `nil` when it cannot say
    /// (an unknown colour space named through the resources).
    static func unfilteredLength(_ dictionary: [String: PDFObject]) -> Int? {
        let full = expanded(dictionary)
        guard let width = full["Width"]?.integerValue, let height = full["Height"]?.integerValue,
              width > 0, height > 0, width < 1 << 16, height < 1 << 16 else { return nil }
        let isMask = full["ImageMask"] == .boolean(true)
        let bits = isMask ? 1 : (full["BitsPerComponent"]?.integerValue ?? 8)
        // §8.9.5.1 allows 1, 2, 4, 8 and (PDF 1.5) 16 bits per component. Anything else is not a
        // length the dictionary can state: a negative or huge value would make the product below
        // negative or overflow (S-061). With these bits, width and height below 2^16 and at most
        // four components, the largest product is under 2^38, so the arithmetic cannot overflow.
        guard [1, 2, 4, 8, 16].contains(bits) else { return nil }
        let components: Int
        if isMask {
            components = 1
        } else {
            switch full["ColorSpace"] {
            case .name("DeviceGray")?, .name("CalGray")?: components = 1
            case .name("DeviceRGB")?, .name("CalRGB")?: components = 3
            case .name("DeviceCMYK")?: components = 4
            case let .array(items)? where items.first?.nameValue == "Indexed": components = 1
            default: return nil
            }
        }
        let length = (width * components * bits + 7) / 8 * height
        return length > 0 ? length : nil
    }
}
