import Foundation
import os
import ZPDFDesignSystem
import ZPDFUIPresentation

/// How many fraction digits an exported or displayed ledger value keeps.
///
/// `exact` is the only value that never loses information; every other case rounds and
/// therefore has to be announced to the user before an export runs.
public enum LedgerRounding: Int, Codable, Hashable, Sendable, CaseIterable, Identifiable {

    /// Keep the stored decimal exactly as it is.
    case exact = -1
    /// Round to whole units.
    case integer = 0
    /// Round to one fraction digit.
    case oneDigit = 1
    /// Round to two fraction digits.
    case twoDigits = 2
    /// Round to three fraction digits.
    case threeDigits = 3
    /// Round to four fraction digits.
    case fourDigits = 4

    /// Stable identity.
    public var id: Int { rawValue }

    /// Number of fraction digits, or `nil` when the value is kept exact.
    public var fractionDigits: Int? { self == .exact ? nil : rawValue }

    /// A localized name for the rounding picker.
    public var displayName: String {
        switch self {
        case .exact:
            return NSLocalizedString("Exact (no rounding)", comment: "Ledger export rounding option")
        case .integer:
            return NSLocalizedString("Whole numbers", comment: "Ledger export rounding option")
        case .oneDigit:
            return NSLocalizedString("1 decimal", comment: "Ledger export rounding option")
        case .twoDigits:
            return NSLocalizedString("2 decimals", comment: "Ledger export rounding option")
        case .threeDigits:
            return NSLocalizedString("3 decimals", comment: "Ledger export rounding option")
        case .fourDigits:
            return NSLocalizedString("4 decimals", comment: "Ledger export rounding option")
        }
    }
}

/// Which display unit each dimension is converted into on export.
///
/// The ledger stores SI base units. A policy only changes the presented magnitude and the
/// unit symbol; it never changes the dimension, so a policy can never make two
/// incompatible columns look summable.
public struct LedgerUnitPolicy: Codable, Hashable, Sendable {

    /// Unit used for length columns.
    public var length: LengthUnit
    /// Unit used for area columns.
    public var area: AreaUnit
    /// Unit used for volume columns.
    public var volume: VolumeUnit
    /// Unit used for angle columns.
    public var angle: AngleDisplayUnit

    /// Creates a unit policy.
    public init(
        length: LengthUnit = .metre,
        area: AreaUnit = .squareMetre,
        volume: VolumeUnit = .cubicMetre,
        angle: AngleDisplayUnit = .degrees
    ) {
        self.length = length
        self.area = area
        self.volume = volume
        self.angle = angle
    }

    /// The SI base policy: metres, square metres, cubic metres, degrees.
    public static let metric = LedgerUnitPolicy()

    /// Converts a quantity into the policy's unit.
    ///
    /// - Returns: The magnitude in the chosen unit and the unit symbol to print beside it.
    ///   Counts, ratios and currencies are returned unchanged.
    public func convert(_ quantity: DecimalQuantity) -> (value: Decimal, symbol: String) {
        let dimension = quantity.dimension
        if let code = dimension.currencyCode { return (quantity.value, code) }
        if dimension.angle {
            return (angle.fromRadians(quantity.value), angle.symbol)
        }
        switch dimension.lengthPower {
        case 1:
            return ((try? quantity.converted(to: length)) ?? quantity.value, length.symbol)
        case 2:
            return ((try? quantity.converted(to: area)) ?? quantity.value, area.symbol)
        case 3:
            return ((try? quantity.converted(to: volume)) ?? quantity.value, volume.symbol)
        default:
            return (quantity.value, "")
        }
    }
}

/// Locale-aware decimal formatting and rounding for the ledger and its exports.
///
/// Nothing here mutates stored data: rounding is a presentation decision.
///
/// Rendering is hermetic (IM-012, IM-096): no `NumberFormatter` is allocated per call and the
/// user's live regional settings are read only through the pinned ``LedgerNumberStyle`` for a
/// locale, so a cell, a group header, the totals footer and an export of the same `Decimal`
/// agree digit for digit. Rounding happens exactly once, half away from zero, through
/// ``rounded(_:fractionDigits:)``; the renderer never rounds again (no double rounding and
/// no ICU half-even step, BH-241).
public enum LedgerNumberFormatting {

    /// Renders an **already rounded** decimal: `fractionDigits == nil` writes every digit the
    /// value has; `grouping == false` suppresses the grouping separator.
    public typealias Renderer = @Sendable (
        _ value: Decimal,
        _ fractionDigits: Int?,
        _ locale: Locale,
        _ grouping: Bool
    ) -> String

    /// The most fraction digits an ``LedgerRounding/exact`` display writes. A value converted
    /// into an imperial unit can carry 30+ digits; beyond this cap the display rounds, half away
    /// from zero, and says nothing more than the stored value already does.
    public static let maximumExactFractionDigits = 10

    private static let rendererOverride = OSAllocatedUnfairLock<Renderer?>(initialState: nil)

    /// Replaces the renderer every ledger string goes through.
    ///
    /// The composition root installs the core formatter here so the screen and every export
    /// share one implementation (QUALITY_BAR A25/A29). `nil` restores the built-in hermetic
    /// renderer, which follows the same rules.
    public static func setRenderer(_ renderer: Renderer?) {
        rendererOverride.withLock { $0 = renderer }
    }

    /// The built-in renderer: ``LedgerNumberStyle/forLocale(_:)``.
    public static let builtInRenderer: Renderer = { value, digits, locale, grouping in
        let style = LedgerNumberStyle.forLocale(locale)
        return (grouping ? style : style.withoutGrouping).string(value, fractionDigits: digits)
    }

    static func render(_ value: Decimal, fractionDigits: Int?, locale: Locale, grouping: Bool) -> String {
        let override = rendererOverride.withLock { $0 }
        return (override ?? builtInRenderer)(value, fractionDigits, locale, grouping)
    }

    /// Rounds a decimal half away from zero to a number of fraction digits.
    ///
    /// The single rounding entry point of the package (IM-079): a result that rounds to zero
    /// is returned as plain zero, never a signed zero that renders as "-0.00".
    public static func rounded(_ value: Decimal, fractionDigits: Int) -> Decimal {
        var input = value
        var output = Decimal()
        NSDecimalRound(&output, &input, fractionDigits, .plain)
        return output.isZero ? Decimal.zero : output
    }

    /// Formats a decimal for display, grouping thousands in the given locale.
    ///
    /// The value is rounded half away from zero to `fractionDigits` first, then rendered.
    public static func string(
        _ value: Decimal,
        fractionDigits: Int,
        locale: Locale = .autoupdatingCurrent,
        grouping: Bool = true
    ) -> String {
        let digits = max(0, fractionDigits)
        return render(rounded(value, fractionDigits: digits), fractionDigits: digits, locale: locale, grouping: grouping)
    }

    /// The number of fraction digits the ledger shows for a dimension by default.
    ///
    /// A ratio is not a count (BH-736): a waste factor of 1.05 or a slope of 0.75 needs its
    /// fraction, so ratios get two digits where a count gets none.
    public static func defaultFractionDigits(for dimension: QuantityDimension?) -> Int {
        guard let dimension else { return 2 }
        if dimension.currencyCode != nil { return 2 }
        if dimension.angle { return 1 }
        if dimension.ratio { return 2 }
        switch dimension.lengthPower {
        case 0: return 0
        case 1: return 3
        case 2: return 2
        default: return 3
        }
    }

    /// The number of fraction digits a value actually carries (trailing zeros ignored).
    static func significantFractionDigits(of value: Decimal) -> Int {
        let plain = value.description
        guard let dot = plain.firstIndex(of: ".") else { return 0 }
        let fraction = plain[plain.index(after: dot)...]
        var count = fraction.count
        for character in fraction.reversed() {
            guard character == "0" else { break }
            count -= 1
        }
        return count
    }

    /// Formats an ``LedgerRounding/exact`` value: every digit it has (up to
    /// ``maximumExactFractionDigits``), padded to the dimension's default so a column still
    /// lines up. `.exact` never discards a digit the stored value carries (BH-241, BH-736).
    public static func exactString(
        _ value: Decimal,
        minimumFractionDigits: Int,
        locale: Locale = .autoupdatingCurrent,
        grouping: Bool = true
    ) -> String {
        let own = min(significantFractionDigits(of: value), maximumExactFractionDigits)
        let digits = max(max(0, minimumFractionDigits), own)
        return string(value, fractionDigits: digits, locale: locale, grouping: grouping)
    }

    /// Formats a quantity with its unit symbol, the way a totals row prints it.
    public static func display(
        _ quantity: DecimalQuantity,
        policy: LedgerUnitPolicy = .metric,
        rounding: LedgerRounding = .exact,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let parts = displayParts(quantity, policy: policy, rounding: rounding, locale: locale)
        return parts.unitSymbol.isEmpty ? parts.numberText : "\(parts.numberText) \(parts.unitSymbol)"
    }

    /// The most fraction digits a count shows: the cap the application's quantity formatter
    /// puts on a dimensionless cell (`QuantityFormatter.countDecimalPlaces`), so a count
    /// heading and the count cells under it write the same digits.
    public static let countMaximumFractionDigits = 6

    /// The number and the unit of a displayed quantity as separate strings (IM-098), so a
    /// cell that needs only one of them never has to split a formatted string on whitespace.
    ///
    /// `rounding` is the session's display precision, and it applies to measured quantities
    /// only (T-048). A count keeps the digits it has, as its cells do: at three-digit
    /// precision a Count heading of 151 read "151,000" in sv_SE, a hundred and fifty-one
    /// thousand. Money is printed at its currency's minor digits, as its cells are
    /// (``LedgerMoneyFormatting``): 767.125 SEK read "767.125" at `.exact`, "767.1250" at four
    /// digits and "767" at whole numbers against "767,13 kr" in the cell. Both round half away
    /// from zero, the one display rule. The table's group headings, its totals and the summary
    /// chips all come through here, so they cannot disagree with each other.
    public static func displayParts(
        _ quantity: DecimalQuantity,
        policy: LedgerUnitPolicy = .metric,
        rounding: LedgerRounding = .exact,
        locale: Locale = .autoupdatingCurrent
    ) -> LedgerDisplayParts {
        let converted = policy.convert(quantity)
        let dimension = quantity.dimension
        let isCount = dimension.lengthPower == 0 && !dimension.angle && !dimension.ratio
            && dimension.currencyCode == nil
        let text: String
        if let code = dimension.currencyCode {
            text = string(
                converted.value,
                fractionDigits: LedgerMoneyFormatting.fractionDigits(currencyCode: code),
                locale: locale
            )
        } else if isCount {
            let digits = min(significantFractionDigits(of: converted.value), countMaximumFractionDigits)
            text = string(converted.value, fractionDigits: digits, locale: locale)
        } else if let digits = rounding.fractionDigits {
            text = string(converted.value, fractionDigits: digits, locale: locale)
        } else {
            text = exactString(
                converted.value,
                minimumFractionDigits: defaultFractionDigits(for: quantity.dimension),
                locale: locale
            )
        }
        return LedgerDisplayParts(numberText: text, unitSymbol: converted.symbol)
    }
}

/// A formatted quantity split into its number and its unit symbol.
public struct LedgerDisplayParts: Hashable, Sendable {
    /// The formatted magnitude, for example `1,234.50`.
    public let numberText: String
    /// The unit symbol, empty for counts and ratios.
    public let unitSymbol: String

    /// Creates display parts.
    public init(numberText: String, unitSymbol: String) {
        self.numberText = numberText
        self.unitSymbol = unitSymbol
    }
}

/// How a rounded `Decimal` becomes characters: separators, minus sign and digit glyphs.
///
/// Rendered from the `Decimal`'s own digits — never through `Double`, ICU or the live regional
/// settings — so the same value gives the same string on every run. The rules match the export
/// layer's number locale: no rounding here, a value that is zero is written without a sign,
/// grouping counts from the decimal separator leftwards.
public struct LedgerNumberStyle: Hashable, Sendable {

    /// The decimal separator.
    public let decimalSeparator: String
    /// The grouping separator, or `nil` for no grouping.
    public let groupingSeparator: String?
    /// Digits per group.
    public let groupingSize: Int
    /// The minus sign written before a negative value.
    public let minusSign: String
    /// The ten digit glyphs, index 0...9.
    public let digits: [Character]

    private static let latinDigits: [Character] = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"]

    /// Creates a number style.
    public init(
        decimalSeparator: String,
        groupingSeparator: String? = nil,
        groupingSize: Int = 3,
        minusSign: String = "-",
        digits: [Character] = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"]
    ) {
        self.decimalSeparator = decimalSeparator
        self.groupingSeparator = groupingSeparator
        self.groupingSize = max(1, groupingSize)
        self.minusSign = minusSign
        self.digits = digits.count == 10 ? digits : Self.latinDigits
    }

    /// Period separator, no grouping, ASCII digits and minus.
    public static let invariant = LedgerNumberStyle(decimalSeparator: ".")

    /// The same style with grouping switched off.
    public var withoutGrouping: LedgerNumberStyle {
        LedgerNumberStyle(
            decimalSeparator: decimalSeparator,
            groupingSeparator: nil,
            groupingSize: groupingSize,
            minusSign: minusSign,
            digits: digits
        )
    }

    private static let cache = OSAllocatedUnfairLock<[String: LedgerNumberStyle]>(initialState: [:])

    /// The pinned style for a locale, cached by identifier.
    ///
    /// Separators come from the locale once and are normalised: any space-like grouping
    /// separator (ICU's narrow no-break space U+202F, a plain space) becomes U+00A0, and a
    /// language whose typographic minus is U+2212 (Swedish, Norwegian, Finnish) gets it, so
    /// two ICU versions cannot produce two different strings for one value.
    public static func forLocale(_ locale: Locale) -> LedgerNumberStyle {
        let key = locale.identifier
        if let cached = cache.withLock({ $0[key] }) { return cached }
        let style = makeStyle(for: locale)
        cache.withLock { $0[key] = style }
        return style
    }

    private static func makeStyle(for locale: Locale) -> LedgerNumberStyle {
        let language = locale.language.languageCode?.identifier ?? ""
        let decimal = locale.decimalSeparator ?? "."
        var grouping = locale.groupingSeparator ?? ","
        if grouping.isEmpty || grouping == decimal {
            grouping = decimal == "," ? "\u{00A0}" : ","
        }
        if grouping.unicodeScalars.allSatisfy({ $0.properties.isWhitespace }) {
            grouping = "\u{00A0}"
        }
        let unicodeMinusLanguages: Set<String> = ["sv", "nb", "nn", "no", "fi"]
        let minus = unicodeMinusLanguages.contains(language) ? "\u{2212}" : "-"
        var glyphs = latinDigits
        if locale.numberingSystem.identifier == "arab" {
            glyphs = ["\u{0660}", "\u{0661}", "\u{0662}", "\u{0663}", "\u{0664}",
                      "\u{0665}", "\u{0666}", "\u{0667}", "\u{0668}", "\u{0669}"]
        }
        return LedgerNumberStyle(
            decimalSeparator: decimal,
            groupingSeparator: grouping,
            minusSign: minus,
            digits: glyphs
        )
    }

    /// Renders an already rounded decimal at a fixed number of fraction digits, or every digit
    /// it has when `fractionDigits` is `nil`. Padding and cutting are exact for a value that was
    /// rounded to that many places; nothing here rounds.
    public func string(_ value: Decimal, fractionDigits: Int?) -> String {
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
        if let fractionDigits {
            let wanted = max(0, fractionDigits)
            if fractionPart.count > wanted {
                fractionPart = String(fractionPart.prefix(wanted))
            } else {
                fractionPart += String(repeating: "0", count: wanted - fractionPart.count)
            }
        }
        var output = grouped(integerPart)
        if !fractionPart.isEmpty {
            output += decimalSeparator + translate(fractionPart)
        }
        let isZero = integerPart.allSatisfy { $0 == "0" } && fractionPart.allSatisfy { $0 == "0" }
        if negative, !isZero { output = minusSign + output }
        return output
    }

    private func translate(_ asciiDigits: String) -> String {
        guard digits != Self.latinDigits else { return asciiDigits }
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

/// Reading a number the user typed.
///
/// A field shows its value with the locale's decimal separator (``editingString(_:locale:)``)
/// and reads it back with ``decimal(from:allowingExponent:)``, which is Zenit's one grammar for a
/// typed number, ``ZPDFDecimalParser``: spaces group digits, a single comma or a single period is
/// the decimal mark, and anything ambiguous or not entirely a number is refused.
public enum LedgerNumberParsing {

    /// The text an editable numeric field shows: locale decimal separator, no grouping,
    /// every digit the value has, ASCII digits and minus.
    public static func editingString(_ value: Decimal, locale: Locale = .autoupdatingCurrent) -> String {
        let separator = locale.decimalSeparator ?? "."
        let plain = LedgerNumberStyle.invariant.string(value.isZero ? Decimal.zero : value, fractionDigits: nil)
        return separator == "." ? plain : plain.replacingOccurrences(of: ".", with: separator)
    }

    /// Parses a typed number with ``ZPDFDecimalParser``, the reading every Zenit field uses, so
    /// the same text is the same number in the preset editor, Apply Assembly, a cell, Bulk Edit
    /// and the filter. Returns `nil` for anything that is not entirely a number (including an
    /// empty field).
    ///
    /// The ledger used to read typed text in its own, locale-dependent way, which dropped the
    /// locale's grouping separator wherever it stood: under en-US "0,6" was 6 and "45,50" was
    /// 4550, under de-DE "45.50" was 4550 — a silent ×10 or ×100 in a recipe parameter, a unit
    /// cost or a bulk edit, while the preset editor beside it read 0.6 and 45.5 (S-076). Grouping
    /// is now spaces only, and a text with both marks ("1,234.5") is refused, not guessed.
    ///
    /// - Parameter allowingExponent: Whether `1e5` is a number. Off for ledger cells and
    ///   filters, on where the preset editor accepts one (assembly parameters).
    public static func decimal(from text: String, allowingExponent: Bool = false) -> Decimal? {
        ZPDFDecimalParser.decimal(text, allowingExponent: allowingExponent)
    }
}
