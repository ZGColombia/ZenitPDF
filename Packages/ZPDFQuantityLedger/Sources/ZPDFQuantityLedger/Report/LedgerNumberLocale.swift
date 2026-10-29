import Foundation

/// How a rounded `Decimal` becomes digits on a page.
///
/// This is the *only* place in the aggregation and export layers that knows what a decimal
/// separator is (IM-012: moved here from ZPDFExport, which keeps `ExportNumberLocale` as an alias),
/// and it is set once, on the projection, not per format. That is deliberate: a Swedish CSV and the PDF
/// report printed beside it must agree digit for digit (QUALITY_BAR A29, A33), and they cannot
/// if each exporter carries its own idea of a separator.
///
/// `Foundation.NumberFormatter` is not used. It formats through `Double` for some paths, it
/// changes behaviour with the ICU version, and it reads the user's regional settings — all three
/// are ways for two runs of the same export to differ. Rendering is done here from the
/// `Decimal`'s own decimal digits, so it is exact, hermetic and reproducible.
public struct LedgerNumberLocale: Hashable, Sendable {
    /// A tag written into the export metadata so a reader knows what produced the digits.
    public let identifier: String
    public let decimalSeparator: String
    /// `nil` disables digit grouping. Grouping is off by default because a grouping separator
    /// that happens to equal a CSV delimiter is a corrupt file.
    public let groupingSeparator: String?
    /// Digits per group, counting from the decimal separator leftwards.
    public let groupingSize: Int
    public let minusSign: String
    /// The ten digit characters, index 0...9. Latin by default; a non-Latin-digit locale
    /// (QUALITY_BAR A33) supplies its own.
    public let digits: [Character]

    public init(
        identifier: String,
        decimalSeparator: String,
        groupingSeparator: String? = nil,
        groupingSize: Int = 3,
        minusSign: String = "-",
        digits: [Character] = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"]
    ) {
        self.identifier = identifier
        self.decimalSeparator = decimalSeparator
        self.groupingSeparator = groupingSeparator
        self.groupingSize = max(1, groupingSize)
        self.minusSign = minusSign
        self.digits = digits.count == 10
            ? digits
            : ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"]
    }

    /// Period decimal separator, no grouping, Latin digits. The default, and what the JSON
    /// interchange always uses for its raw values regardless of the display locale.
    public static let invariant = LedgerNumberLocale(identifier: "invariant", decimalSeparator: ".")

    /// Period decimal separator, comma grouping.
    public static let enUS = LedgerNumberLocale(
        identifier: "en-US",
        decimalSeparator: ".",
        groupingSeparator: ","
    )

    /// Comma decimal separator, non-breaking-space grouping. The locale a Swedish Excel expects,
    /// paired with ``CSVExportOptions/excelSwedish`` which switches the delimiter to a semicolon.
    public static let svSE = LedgerNumberLocale(
        identifier: "sv-SE",
        decimalSeparator: ",",
        groupingSeparator: "\u{00A0}",
        minusSign: "\u{2212}"
    )

    /// Arabic-Indic digits with the Arabic decimal and thousands separators — the non-Latin-digit
    /// locale QUALITY_BAR A33 requires the golden set to cover.
    public static let arEG = LedgerNumberLocale(
        identifier: "ar-EG",
        decimalSeparator: "\u{066B}",
        groupingSeparator: "\u{066C}",
        minusSign: "\u{061C}-",
        digits: ["\u{0660}", "\u{0661}", "\u{0662}", "\u{0663}", "\u{0664}",
                 "\u{0665}", "\u{0666}", "\u{0667}", "\u{0668}", "\u{0669}"]
    )

    // MARK: - From a Locale (IM-012)

    private static let latinDigits: [Character] = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"]

    /// The pinned number locale for a Foundation `Locale`, read once and normalised so two ICU
    /// versions cannot produce two different strings for one value.
    ///
    /// The rules are the screen's (`LedgerNumberStyle.forLocale` in ZPDFUILedger) exactly, so a
    /// cell on screen and the same cell in an export are the same characters:
    /// - decimal separator from the locale (`.` when it has none);
    /// - grouping separator from the locale; an empty one, or one equal to the decimal
    ///   separator, becomes U+00A0 after a comma decimal and `,` otherwise; any whitespace
    ///   grouping separator (ICU's U+202F, a plain space) becomes U+00A0;
    /// - minus sign U+2212 for Swedish, Norwegian and Finnish, `-` otherwise;
    /// - Arabic-Indic digits when the locale's numbering system is `arab`.
    ///
    /// - Parameter grouping: `false` returns the locale without a grouping separator — the
    ///   default for machine-read exports, where a separator can collide with a delimiter.
    public static func forLocale(_ locale: Locale, grouping: Bool = true) -> LedgerNumberLocale {
        let language = locale.language.languageCode?.identifier ?? ""
        let decimal = locale.decimalSeparator ?? "."
        var separator = locale.groupingSeparator ?? ","
        if separator.isEmpty || separator == decimal {
            separator = decimal == "," ? "\u{00A0}" : ","
        }
        if separator.unicodeScalars.allSatisfy({ $0.properties.isWhitespace }) {
            separator = "\u{00A0}"
        }
        let unicodeMinusLanguages: Set<String> = ["sv", "nb", "nn", "no", "fi"]
        var glyphs = latinDigits
        if locale.numberingSystem.identifier == "arab" {
            glyphs = ["\u{0660}", "\u{0661}", "\u{0662}", "\u{0663}", "\u{0664}",
                      "\u{0665}", "\u{0666}", "\u{0667}", "\u{0668}", "\u{0669}"]
        }
        return LedgerNumberLocale(
            identifier: locale.identifier,
            decimalSeparator: decimal,
            groupingSeparator: grouping ? separator : nil,
            minusSign: unicodeMinusLanguages.contains(language) ? "\u{2212}" : "-",
            digits: glyphs
        )
    }

    /// Renders an **already-rounded** `Decimal` at a fixed number of decimal places.
    ///
    /// - Parameter decimalPlaces: `nil` renders every digit the value actually has, which is what
    ///   a column with no declared precision means.
    ///
    /// The input must already have been through ``LedgerValueFormatting/displayDecimal(_:)``.
    /// Nothing here rounds — padding a shorter fraction with zeros and cutting a longer one are
    /// both exact, because a value rounded to *n* places has at most *n* fractional digits. That
    /// is what makes double rounding structurally impossible rather than merely avoided
    /// (QUALITY_BAR A30, A31).
    public func string(_ value: Decimal, decimalPlaces: Int?) -> String {
        // `Decimal.description` is plain positional notation with a `.` separator, no grouping
        // and no exponent, for every value `Decimal` can hold. It is the exact digit string.
        var plain = value.description
        var negative = false
        if plain.hasPrefix("-") {
            negative = true
            plain.removeFirst()
        }
        var integerPart = plain
        var fractionPart = ""
        if let dot = plain.firstIndex(of: ".") {
            integerPart = String(plain[plain.startIndex..<dot])
            fractionPart = String(plain[plain.index(after: dot)...])
        }
        if let decimalPlaces {
            if fractionPart.count > decimalPlaces {
                fractionPart = String(fractionPart.prefix(decimalPlaces))
            } else {
                fractionPart += String(repeating: "0", count: decimalPlaces - fractionPart.count)
            }
        }
        var output = grouped(integerPart)
        if !fractionPart.isEmpty {
            output += decimalSeparator + translate(fractionPart)
        }
        // "-0.00" is a rounding artefact, never a measurement, and it reads as a mistake on a
        // printed page. A value that rounded to zero is written without a sign.
        let isZero = integerPart.allSatisfy { $0 == "0" } && fractionPart.allSatisfy { $0 == "0" }
        if negative, !isZero { output = minusSign + output }
        return output
    }

    private func translate(_ asciiDigits: String) -> String {
        guard digits != ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"] else { return asciiDigits }
        var output = ""
        output.reserveCapacity(asciiDigits.count)
        for character in asciiDigits {
            if let value = character.wholeNumberValue, (0...9).contains(value) {
                output.append(digits[value])
            } else {
                output.append(character)
            }
        }
        return output
    }

    private func grouped(_ integerDigits: String) -> String {
        let translated = translate(integerDigits)
        guard let groupingSeparator, translated.count > groupingSize else { return translated }
        var characters = Array(translated)
        var chunks: [String] = []
        while characters.count > groupingSize {
            chunks.insert(String(characters.suffix(groupingSize)), at: 0)
            characters.removeLast(groupingSize)
        }
        chunks.insert(String(characters), at: 0)
        return chunks.joined(separator: groupingSeparator)
    }
}
