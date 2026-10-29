import Foundation

/// One value from a PDF file's object layer, and the bytes it serialises back to.
///
/// # Why the export layer owns a PDF object model at all
///
/// ADR-0013 asks for an artefact whose **underlying drawing is byte-for-byte the file the
/// estimator opened**, with the markups added as optional content. There is exactly one way to
/// add anything to a PDF without rewriting it: an *incremental update* — the original bytes,
/// then the objects that supersede a handful of the old ones, then a new cross-reference section.
/// Core Graphics cannot write one (it only authors whole documents), and the qpdf bridge cannot
/// either (its entry points all write a rebuilt copy). So the object layer lives here, small and
/// bounded, and its output is appended to bytes it never touches.
///
/// # What this is not
///
/// Not a PDF reader for the application to open drawings with — `ZPDFPDFKitBridge` and
/// `CGPDFDocument` do that. This model reads three things out of a source file (the catalog, the
/// page dictionaries, and the object streams they may hide in) and writes six kinds of object
/// back. Anything it cannot parse is a refusal with a sentence, never a guess: see
/// ``ExportError/layeredSourceUnreadable(_:)``.
indirect enum PDFObject: Hashable, Sendable {
    case null
    case boolean(Bool)
    case integer(Int)
    case real(Double)
    /// A literal string, already unescaped.
    case string([UInt8])
    case hexString([UInt8])
    /// A name, without the leading solidus and with `#xx` escapes already resolved.
    case name(String)
    case array([PDFObject])
    case dictionary([String: PDFObject])
    /// An indirect reference, `n g R`.
    case reference(number: Int, generation: Int)
    /// A stream. `data` is the **raw, still-encoded** payload exactly as it appeared in the file,
    /// so copying a stream from one document to another cannot re-encode it.
    case stream(dictionary: [String: PDFObject], data: Data)

    // MARK: - Accessors

    var dictionaryValue: [String: PDFObject]? {
        switch self {
        case let .dictionary(value): value
        case let .stream(dictionary, _): dictionary
        default: nil
        }
    }

    var arrayValue: [PDFObject]? {
        if case let .array(value) = self { return value }
        return nil
    }

    var nameValue: String? {
        if case let .name(value) = self { return value }
        return nil
    }

    /// The value as an `Int`, or `nil` when it is not a number or does not fit one.
    ///
    /// A digit run too long for `Int` is parsed as a `.real` (e.g. `1e20` for twenty nines), and
    /// `Int(1e20)` is a trap, not a refusal — so the conversion is `Int(exactly:)` on the
    /// truncated value, and a damaged `startxref`, `/Length`, `/N` or `/First` reads as absent.
    var integerValue: Int? {
        switch self {
        case let .integer(value): value
        case let .real(value) where value.isFinite: Int(exactly: value.rounded(.towardZero))
        default: nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case let .integer(value): Double(value)
        case let .real(value): value
        default: nil
        }
    }

    var referenceValue: (number: Int, generation: Int)? {
        if case let .reference(number, generation) = self { return (number, generation) }
        return nil
    }

    // MARK: - Serialisation

    /// The bytes this value is written as. Dictionary keys are emitted in sorted order so that
    /// two exports of the same project produce the same file.
    var serialized: Data {
        var out = Data()
        append(into: &out)
        return out
    }

    private func append(into out: inout Data) {
        switch self {
        case .null:
            out.append(contentsOf: Array("null".utf8))
        case let .boolean(value):
            out.append(contentsOf: Array((value ? "true" : "false").utf8))
        case let .integer(value):
            out.append(contentsOf: Array(String(value).utf8))
        case let .real(value):
            out.append(contentsOf: Array(Self.format(value).utf8))
        case let .string(bytes):
            out.append(UInt8(ascii: "("))
            for byte in bytes {
                switch byte {
                case UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "\\"):
                    out.append(UInt8(ascii: "\\"))
                    out.append(byte)
                case 0x0A:
                    out.append(contentsOf: Array("\\n".utf8))
                case 0x0D:
                    out.append(contentsOf: Array("\\r".utf8))
                default:
                    out.append(byte)
                }
            }
            out.append(UInt8(ascii: ")"))
        case let .hexString(bytes):
            out.append(UInt8(ascii: "<"))
            out.append(contentsOf: Array(bytes.map { String(format: "%02X", $0) }.joined().utf8))
            out.append(UInt8(ascii: ">"))
        case let .name(value):
            out.append(UInt8(ascii: "/"))
            out.append(contentsOf: Self.escapedName(value))
        case let .array(values):
            out.append(UInt8(ascii: "["))
            for (index, value) in values.enumerated() {
                if index > 0 { out.append(UInt8(ascii: " ")) }
                value.append(into: &out)
            }
            out.append(UInt8(ascii: "]"))
        case let .dictionary(entries):
            appendDictionary(entries, into: &out)
        case let .reference(number, generation):
            out.append(contentsOf: Array("\(number) \(generation) R".utf8))
        case let .stream(dictionary, data):
            var entries = dictionary
            entries["Length"] = .integer(data.count)
            appendDictionary(entries, into: &out)
            out.append(contentsOf: Array("\nstream\n".utf8))
            out.append(data)
            out.append(contentsOf: Array("\nendstream".utf8))
        }
    }

    private func appendDictionary(_ entries: [String: PDFObject], into out: inout Data) {
        out.append(contentsOf: Array("<<".utf8))
        for key in entries.keys.sorted() {
            guard let value = entries[key] else { continue }
            out.append(UInt8(ascii: "/"))
            out.append(contentsOf: Self.escapedName(key))
            out.append(UInt8(ascii: " "))
            value.append(into: &out)
        }
        out.append(contentsOf: Array(">>".utf8))
    }

    /// A name's bytes, with everything outside the regular character set written as `#xx`.
    static func escapedName(_ value: String) -> [UInt8] {
        var out: [UInt8] = []
        for byte in Array(value.utf8) {
            if PDFByte.isRegular(byte), byte != UInt8(ascii: "#") {
                out.append(byte)
            } else {
                out.append(UInt8(ascii: "#"))
                out.append(contentsOf: Array(String(format: "%02X", byte).utf8))
            }
        }
        return out
    }

    /// Fixed-notation, trailing zeros trimmed. PDF has no exponent syntax, so `1e-05` written
    /// into a content stream is a syntax error that a reader silently drops.
    static func format(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        if value == value.rounded(), abs(value) < 1e15 { return String(Int(value)) }
        var text = String(format: "%.6f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text.isEmpty ? "0" : text
    }
}

/// The character classes of the PDF lexical syntax (ISO 32000-1 §7.2).
enum PDFByte {
    static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x00 || byte == 0x09 || byte == 0x0A || byte == 0x0C || byte == 0x0D
            || byte == 0x20
    }

    static func isDelimiter(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "<"), UInt8(ascii: ">"),
             UInt8(ascii: "["), UInt8(ascii: "]"), UInt8(ascii: "{"), UInt8(ascii: "}"),
             UInt8(ascii: "/"), UInt8(ascii: "%"):
            true
        default:
            false
        }
    }

    static func isRegular(_ byte: UInt8) -> Bool {
        byte > 0x20 && byte < 0x7F && !isDelimiter(byte)
    }

    static func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }
}
