import Foundation

/// A JSON value with a **declared** key order.
///
/// `JSONEncoder` writes dictionary keys in whatever order the hash gives, or alphabetically with
/// `.sortedKeys`. Neither is the order a person reading the file wants, and the first is not even
/// stable across runs. The interchange format promises a stable byte sequence for a given
/// projection, so the object type here is an array of pairs and the writer emits them as given.
///
/// It also has no `Double` case. That is the point of the format: a decimal that travels as a
/// JSON number is at the mercy of whatever the reader parses numbers into, and most readers
/// parse them into binary floating point. Every quantity in a `.zpdfjson` file is a string.
indirect enum JSONValue: Hashable, Sendable {
    case string(String)
    /// An integer. Safe as a JSON number: counts and versions, never measurements.
    case integer(Int)
    case boolean(Bool)
    case null
    case array([JSONValue])
    case object([(key: String, value: JSONValue)])

    static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.string(let a), .string(let b)): a == b
        case (.integer(let a), .integer(let b)): a == b
        case (.boolean(let a), .boolean(let b)): a == b
        case (.null, .null): true
        case (.array(let a), .array(let b)): a == b
        case (.object(let a), .object(let b)):
            a.count == b.count && zip(a, b).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        default: false
        }
    }

    func hash(into hasher: inout Hasher) {
        switch self {
        case .string(let value): hasher.combine(0); hasher.combine(value)
        case .integer(let value): hasher.combine(1); hasher.combine(value)
        case .boolean(let value): hasher.combine(2); hasher.combine(value)
        case .null: hasher.combine(3)
        case .array(let values): hasher.combine(4); hasher.combine(values)
        case .object(let pairs):
            hasher.combine(5)
            for pair in pairs { hasher.combine(pair.key); hasher.combine(pair.value) }
        }
    }

    subscript(key: String) -> JSONValue? {
        guard case .object(let pairs) = self else { return nil }
        return pairs.first { $0.key == key }?.value
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var integerValue: Int? {
        if case .integer(let value) = self { return value }
        return nil
    }

    var booleanValue: Bool? {
        if case .boolean(let value) = self { return value }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let values) = self { return values }
        return nil
    }
}

enum JSONWriter {

    /// Pretty-printed with two-space indentation, LF line endings, and keys in declared order.
    static func data(_ value: JSONValue) -> Data {
        var output = ""
        write(value, indent: 0, into: &output)
        output += "\n"
        return Data(output.utf8)
    }

    private static func write(_ value: JSONValue, indent: Int, into output: inout String) {
        let pad = String(repeating: "  ", count: indent)
        let innerPad = String(repeating: "  ", count: indent + 1)
        switch value {
        case .string(let text):
            output += escape(text)
        case .integer(let number):
            output += String(number)
        case .boolean(let flag):
            output += flag ? "true" : "false"
        case .null:
            output += "null"
        case .array(let values):
            guard !values.isEmpty else { output += "[]"; return }
            output += "[\n"
            for (index, element) in values.enumerated() {
                output += innerPad
                write(element, indent: indent + 1, into: &output)
                output += index == values.count - 1 ? "\n" : ",\n"
            }
            output += pad + "]"
        case .object(let pairs):
            guard !pairs.isEmpty else { output += "{}"; return }
            output += "{\n"
            for (index, pair) in pairs.enumerated() {
                output += innerPad + escape(pair.key) + ": "
                write(pair.value, indent: indent + 1, into: &output)
                output += index == pairs.count - 1 ? "\n" : ",\n"
            }
            output += pad + "}"
        }
    }

    /// RFC 8259 §7 string escaping. Non-ASCII is emitted as UTF-8, not as `\u` escapes: the file
    /// is declared UTF-8 and a `m²` that reads as `m²` in a text editor is worth more than
    /// ASCII-safety nobody needs.
    static func escape(_ text: String) -> String {
        var output = "\""
        output.reserveCapacity(text.count + 2)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            default:
                if scalar.value < 0x20 {
                    output += String(format: "\\u%04x", scalar.value)
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        return output + "\""
    }
}

enum JSONReader {

    /// Parses with `JSONSerialization` and rebuilds the ordered representation.
    ///
    /// Key order is lost by `JSONSerialization`, so it is restored from the schema: the importer
    /// reads named keys and re-emits them in the writer's declared order. Round-trip byte
    /// equality therefore proves the *schema* is stable, which is the property that matters, and
    /// does not depend on a dictionary's iteration order, which is the property that never holds.
    /// The deepest structure the converter will walk.
    ///
    /// `JSONSerialization` will happily hand back an array nested ten thousand deep, and
    /// ``convert(_:depth:)`` is recursive, so an untrusted file could recurse this process off
    /// the end of its stack — a crash rather than a refusal. The limit is far above any real
    /// interchange document (the writer's own deepest path is five) and far below the stack.
    static let maximumDepth = 128

    static func value(from data: Data) throws -> JSONValue {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw ExportError.malformedInterchange(error.localizedDescription)
        }
        return try convert(object, depth: 0)
    }

    private static func convert(_ object: Any, depth: Int) throws -> JSONValue {
        guard depth <= maximumDepth else {
            throw ExportError.malformedInterchange("JSON nested deeper than \(maximumDepth)")
        }
        switch object {
        case let text as String:
            return .string(text)
        case let number as NSNumber:
            // `JSONSerialization` hands booleans back as `__NSCFBoolean`, which bridges to `Int`
            // *and* to `Bool`. Testing `as? Bool` first would turn `"schemaVersion": 1` into
            // `true`, so the CoreFoundation type is the only reliable discriminator.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .boolean(number.boolValue) }
            // The format has no `Double` case on purpose, and `intValue` truncates: a hostile
            // `"schemaVersion": 1.9` would be read as 1, and `1e400` as something arbitrary.
            // A non-integral JSON number is not part of this format, so it is refused rather
            // than rounded into one.
            //
            // `Int(exactly:)` is the range check: `Double(Int.max)` rounds up to 2^63, so a bound
            // written as `value <= Double(Int.max)` let 9223372036854775808 through to
            // `intValue`, whose answer for it is undefined — Int.max on one machine, Int.min on
            // another, so one file validated here and was refused there (BH-510).
            let value = number.doubleValue
            guard value.isFinite, let integer = Int(exactly: value) else {
                throw ExportError.malformedInterchange(
                    "\(number) is not an integer; every quantity in this format is a string"
                )
            }
            return .integer(integer)
        case let array as [Any]:
            return .array(try array.map { try convert($0, depth: depth + 1) })
        case let dictionary as [String: Any]:
            // Sorted, so the intermediate representation is at least deterministic. The importer
            // never depends on this order; it reads by key.
            return .object(try dictionary.keys.sorted().map {
                ($0, try convert(dictionary[$0] as Any, depth: depth + 1))
            })
        case is NSNull:
            return .null
        default:
            throw ExportError.malformedInterchange("unsupported JSON value \(type(of: object))")
        }
    }
}
