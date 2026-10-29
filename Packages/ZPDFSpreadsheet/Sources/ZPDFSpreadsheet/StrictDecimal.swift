import Foundation

/// One strict, whole-string decimal literal grammar for everything that turns typed or stored
/// text into an amount (R-193).
///
/// `Decimal(string:)` is a prefix parser: it reads `1.25` out of `"1.250.00"`, `12` out of
/// `"12-5"`, `1000` out of `"1e3e3"` and `5` out of `"5e"`. A character-set filter in front of
/// it lets every one of those through, which is how a mistyped Unit Cost cell used to import as
/// a different amount. This grammar is checked first, over the whole string, and only a literal
/// that passes reaches `Decimal(string:)`.
///
/// It lives in this dependency-free package so the spreadsheet round trip and the persistence
/// layer's `DecimalString` — which the application's apply step reads through — share one
/// implementation.
public enum StrictDecimal {

    private static let posix = Locale(identifier: "en_US_POSIX")

    /// `[+-]? digits [ . digits ] [ (e|E) [+-]? digits ]`, at least one digit in the mantissa,
    /// at most four in the exponent, at most 96 bytes. No whitespace, no grouping separators.
    ///
    /// Hand-written rather than a regular expression: the persistence layer runs it once per
    /// decimal column per row, roughly two million times for a 100 000-row ledger.
    public static func isWellFormed(_ text: String) -> Bool {
        // A decimal literal long enough to matter is still tiny; anything past this is
        // hostile input, not a quantity.
        guard !text.isEmpty, text.utf8.count <= 96 else { return false }
        let bytes = text.utf8
        var index = bytes.startIndex
        let end = bytes.endIndex

        func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }

        if bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") {
            index = bytes.index(after: index)
        }
        var mantissaDigits = 0
        while index < end, isDigit(bytes[index]) {
            mantissaDigits += 1
            index = bytes.index(after: index)
        }
        if index < end, bytes[index] == UInt8(ascii: ".") {
            index = bytes.index(after: index)
            while index < end, isDigit(bytes[index]) {
                mantissaDigits += 1
                index = bytes.index(after: index)
            }
        }
        guard mantissaDigits > 0 else { return false }
        if index < end, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
            index = bytes.index(after: index)
            if index < end, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") {
                index = bytes.index(after: index)
            }
            var exponentDigits = 0
            while index < end, isDigit(bytes[index]) {
                exponentDigits += 1
                index = bytes.index(after: index)
            }
            guard exponentDigits > 0, exponentDigits <= 4 else { return false }
        }
        return index == end
    }

    /// The exact decimal a well-formed literal names, or `nil` for anything else — never the
    /// value of a prefix.
    public static func parse(_ text: String) -> Decimal? {
        guard isWellFormed(text),
              let value = Decimal(string: text, locale: posix),
              !value.isNaN
        else { return nil }
        return value
    }
}
