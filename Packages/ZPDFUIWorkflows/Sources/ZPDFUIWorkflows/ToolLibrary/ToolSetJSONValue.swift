import Foundation

/// A parsed JSON tree, with no `Any` in sight.
///
/// The Tool Library reads imported `.zpdftools` files through this type rather than straight
/// into `Codable` structs, for two reasons. It lets the import-safety review report *unknown*
/// fields instead of silently dropping them, and it guarantees the file is only ever treated as
/// inert data: there is no case in this enum that can hold behaviour, so nothing an imported
/// file says can be executed.
public indirect enum ToolSetJSONValue: Hashable, Sendable, Decodable {

    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([ToolSetJSONValue])
    case object([String: ToolSetJSONValue])

    /// Decodes one JSON value.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([ToolSetJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: ToolSetJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Value is not valid JSON."
            )
        }
    }

    /// Parses a whole document. Throws when the bytes are not JSON.
    ///
    /// Foundation's parser refuses a number it cannot hold as a finite `Double` — `1e400` —
    /// and one such number used to reject the whole file as "not valid JSON", although the
    /// validator's contract is that an absurd number costs that one field. Finding BH-855. When
    /// the first parse fails, every number literal outside a string that does not fit a finite
    /// `Double` is re-written as a string and the parse is tried once more; the validator then
    /// reports that field as "not a number" and describes the rest of the file. Bytes that
    /// still do not parse are refused with the original error.
    public static func parse(_ data: Data) throws -> ToolSetJSONValue {
        do {
            return try JSONDecoder().decode(ToolSetJSONValue.self, from: data)
        } catch {
            guard let rescued = quotingUnrepresentableNumbers(in: data) else { throw error }
            guard let value = try? JSONDecoder().decode(ToolSetJSONValue.self, from: rescued) else {
                throw error
            }
            return value
        }
    }

    /// `data` with every number literal that is not a finite `Double` wrapped in quotes, or
    /// `nil` when there is none. String state is tracked, escapes included, so text inside a
    /// string is never touched. Linear in the size of the file.
    static func quotingUnrepresentableNumbers(in data: Data) -> Data? {
        let bytes = [UInt8](data)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count + 16)
        var changed = false
        var inString = false
        var escaped = false
        var index = 0
        let quote = UInt8(ascii: "\""), backslash = UInt8(ascii: "\\"), minus = UInt8(ascii: "-")
        func isNumberByte(_ byte: UInt8) -> Bool {
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || byte == minus || byte == UInt8(ascii: "+") || byte == UInt8(ascii: ".")
                || byte == UInt8(ascii: "e") || byte == UInt8(ascii: "E")
        }
        while index < bytes.count {
            let byte = bytes[index]
            if inString {
                output.append(byte)
                if escaped {
                    escaped = false
                } else if byte == backslash {
                    escaped = true
                } else if byte == quote {
                    inString = false
                }
                index += 1
                continue
            }
            if byte == quote {
                inString = true
                output.append(byte)
                index += 1
                continue
            }
            if byte == minus || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) {
                var end = index
                while end < bytes.count, isNumberByte(bytes[end]) { end += 1 }
                let token = bytes[index..<end]
                let text = String(decoding: token, as: UTF8.self)
                if let value = Double(text), !value.isFinite {
                    output.append(quote)
                    output.append(contentsOf: token)
                    output.append(quote)
                    changed = true
                } else {
                    output.append(contentsOf: token)
                }
                index = end
                continue
            }
            output.append(byte)
            index += 1
        }
        return changed ? Data(output) : nil
    }

    /// The string, or `nil` when this is not a string.
    public var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    /// The number as an `Int`, or `nil` when this is not a whole number.
    public var intValue: Int? {
        guard case let .number(value) = self, value.rounded() == value else { return nil }
        // `Double(Int.max)` rounds up to exactly 2^63, so a bound check written as
        // `value <= Double(Int.max)` let 2^63 through and `Int(value)` trapped on it — a file
        // declaring `"schemaVersion": 9223372036854775807` crashed the validator that exists to
        // survive hostile files. `Int(exactly:)` answers `nil` for anything the type cannot hold.
        // Finding BH-057.
        return Int(exactly: value)
    }

    /// The number, or `nil` when this is not a number.
    public var doubleValue: Double? {
        if case let .number(value) = self { return value }
        return nil
    }

    /// The array, or `nil` when this is not an array.
    public var arrayValue: [ToolSetJSONValue]? {
        if case let .array(value) = self { return value }
        return nil
    }

    /// The object, or `nil` when this is not an object.
    public var objectValue: [String: ToolSetJSONValue]? {
        if case let .object(value) = self { return value }
        return nil
    }

    /// Reads a member of an object, or `nil` when this is not an object or has no such member.
    public subscript(key: String) -> ToolSetJSONValue? {
        guard case let .object(members) = self else { return nil }
        let value = members[key]
        if case .null = value { return nil }
        return value
    }
}
