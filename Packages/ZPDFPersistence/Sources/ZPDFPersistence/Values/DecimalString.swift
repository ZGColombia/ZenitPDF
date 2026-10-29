import Foundation
import ZPDFSpreadsheet
import GRDB

/// A `Decimal` that travels through SQLite as a canonical decimal *string*.
///
/// Spec 8.2: every report value is stored as a decimal string in its SI base dimension.
/// The reason is arithmetic, not taste. SQLite's only numeric affinities are 64-bit
/// integer and IEEE 754 binary64; a quantity such as `12345678901234.5678` has 18
/// significant decimal digits and binary64 carries about 15.95, so a round trip through
/// `REAL` silently returns `12345678901234.568`. On a bill of quantities that is a
/// wrong number in a contract. `Decimal` carries 38 significant digits in base 10 and
/// `TEXT` carries them intact, so the value that comes out is the value that went in.
///
/// GRDB does not conform `Decimal` itself, and if it ever did the conformance would be
/// numeric. This wrapper exists so the storage decision is spelled out at every use
/// site: a column typed `DecimalString` cannot accidentally become a `Double`.
public struct DecimalString: Sendable, Hashable {

    /// The value. Never `Decimal.nan` — the initialisers refuse it.
    public let value: Decimal

    /// The canonical text form written to the database. Locale-independent, `.` separator.
    public let canonicalText: String

    // MARK: Creation

    /// Wraps a `Decimal`. Fails only for `NaN`.
    public init?(_ value: Decimal) {
        guard !value.isNaN else { return nil }
        guard let text = Self.canonicalString(for: value) else { return nil }
        self.value = value
        self.canonicalText = text
    }

    /// Parses a decimal string strictly.
    ///
    /// Strictly, because `Decimal(string:)` is a prefix parser: it happily reads `"12"`
    /// out of `"12 apples"` and returns `nil` only when the very first character is
    /// unusable. A database column that has been corrupted into `"1.5; DROP"` must be a
    /// typed error, not the number one and a half.
    public init?(text: String) {
        guard Self.isCanonicalGrammar(text) else { return nil }
        guard let parsed = Decimal(string: text, locale: Self.posix), !parsed.isNaN else { return nil }
        guard let canonical = Self.canonicalString(for: parsed) else { return nil }
        self.value = parsed
        self.canonicalText = canonical
    }

    /// Zero, the identity used when a measurement column is present but empty.
    ///
    /// Built through the private memberwise path rather than the failable initialiser so
    /// that the package's most-used constant needs no `!` and no optional at the call site.
    public static let zero = DecimalString(exactly: Decimal(0), text: "0")

    private init(exactly value: Decimal, text: String) {
        self.value = value
        self.canonicalText = text
    }

    // MARK: Grammar

    private static let posix = Locale(identifier: "en_US_POSIX")

    /// `[+-]? digits [ . digits ] [ (e|E) [+-]? digits ]`, at least one digit in the mantissa.
    ///
    /// The grammar is ``ZPDFSpreadsheet/StrictDecimal/isWellFormed(_:)`` (R-193): one strict
    /// whole-string literal for the database columns and the spreadsheet round trip alike.
    static func isCanonicalGrammar(_ text: String) -> Bool {
        StrictDecimal.isWellFormed(text)
    }

    /// Renders a `Decimal` with every significant digit it holds and no locale grouping.
    ///
    /// Plain digits whenever they fit the grammar's 96-byte cap; otherwise — a finite
    /// value with a large-magnitude exponent, which `NSDecimalString` spells out as a
    /// hundred zeros (BH-608) — the mantissa's digits with an explicit exponent, which
    /// the strict parser reads back to the identical `Decimal`.
    static func canonicalString(for value: Decimal) -> String? {
        var mutable = value
        let rendered = NSDecimalString(&mutable, posix)
        if isCanonicalGrammar(rendered) { return rendered }
        guard value.isFinite else { return nil }
        var digits = Decimal(sign: .plus, exponent: 0, significand: value.significand)
        let mantissa = NSDecimalString(&digits, posix)
        let exponential = "\(value.sign == .minus ? "-" : "")\(mantissa)e\(value.exponent)"
        guard isCanonicalGrammar(exponential),
              Decimal(string: exponential, locale: posix) == value
        else { return nil }
        return exponential
    }
}

// MARK: - Textual and Codable

extension DecimalString: CustomStringConvertible {
    public var description: String { canonicalText }
}

extension DecimalString: Codable {
    /// Encoded as a JSON *string*, for the same reason it is stored as SQL `TEXT`:
    /// `JSONEncoder` would otherwise route a `Decimal` through `Double`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let parsed = DecimalString(text: text) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Not a canonical decimal string: \(text)"
            )
        }
        self = parsed
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(canonicalText)
    }
}

// MARK: - Ordering and arithmetic

extension DecimalString: Comparable {
    public static func < (lhs: DecimalString, rhs: DecimalString) -> Bool {
        lhs.value < rhs.value
    }
}

extension DecimalString {
    /// Exact addition. Returns `nil` when the exact sum cannot be represented: on
    /// `Decimal` overflow, and when the sum would need more than `Decimal`'s 38
    /// significant digits (`NSDecimalAdd` reports that as `.lossOfPrecision`, and a sum
    /// with digits dropped is not exact) (BH-609).
    public func adding(_ other: DecimalString) -> DecimalString? {
        var result = Decimal()
        var left = value
        var right = other.value
        let status = NSDecimalAdd(&result, &left, &right, .plain)
        guard status == .noError else { return nil }
        return DecimalString(result)
    }
}

// MARK: - GRDB

extension DecimalString: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue { canonicalText.databaseValue }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> DecimalString? {
        // Only TEXT is accepted. A REAL in a decimal column means some other writer put
        // a lossy value there, and reading it as if it were fine would launder the loss.
        guard let text = String.fromDatabaseValue(dbValue) else { return nil }
        return DecimalString(text: text)
    }
}
