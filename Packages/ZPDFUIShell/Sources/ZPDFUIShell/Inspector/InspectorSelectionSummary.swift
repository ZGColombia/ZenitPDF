import Foundation
import ZPDFDesignSystem
import ZPDFUILedger
import ZPDFUIPresentation

/// What the Inspector knows about the current selection.
///
/// A properties panel over several objects has exactly two honest answers per field: every
/// selected object agrees, or they do not. Guessing — showing the first object's value as if it
/// were everyone's — is how a user silently overwrites twenty markups they could not see.
public struct InspectorSelectionSummary: Sendable {

    /// The selected markups, in canvas order.
    public let markups: [MarkupSummary]

    /// Builds a summary.
    public init(markups: [MarkupSummary]) {
        self.markups = markups
    }

    /// How many markups are selected.
    public var count: Int { markups.count }
    /// Whether nothing is selected.
    public var isEmpty: Bool { markups.isEmpty }
    /// Whether exactly one markup is selected.
    public var isSingle: Bool { markups.count == 1 }
    /// Whether more than one markup is selected.
    public var isMultiple: Bool { markups.count > 1 }
    /// The only selected markup, when there is exactly one.
    public var single: MarkupSummary? { isSingle ? markups.first : nil }

    /// Whether any selected markup is locked — by its own lock or its layer's, which
    /// ``MarkupSummary/locked`` folds in (ADR-0032).
    ///
    /// The Inspector's one lock rule: the engine refuses every edit to a locked markup, so a
    /// control that edits the selection is off while this holds, and a mixed selection takes
    /// the strict reading — an edit that would land on nine of twelve is not offered (W-039).
    public var includesLockedMarkup: Bool { markups.contains(where: \.locked) }

    /// The value every selected markup shares, or `nil` when they disagree or nothing
    /// is selected.
    public func common<Value: Hashable>(_ keyPath: KeyPath<MarkupSummary, Value>) -> Value? {
        guard let first = markups.first?[keyPath: keyPath] else { return nil }
        return markups.allSatisfy { $0[keyPath: keyPath] == first } ? first : nil
    }

    /// The value every element of `values` shares, or `nil` when they disagree or there are
    /// none — ``common(_:)`` for a value derived from each markup rather than stored on it.
    public static func commonValue<Value: Hashable>(_ values: [Value]) -> Value? {
        guard let first = values.first else { return nil }
        return values.allSatisfy { $0 == first } ? first : nil
    }

    /// Whether the selection disagrees about a property.
    public func isMixed<Value: Hashable>(_ keyPath: KeyPath<MarkupSummary, Value>) -> Bool {
        guard markups.count > 1 else { return false }
        return common(keyPath) == nil
    }

    /// The shared value rendered for display, or an em dash when the selection disagrees.
    public func displayText<Value: Hashable>(
        _ keyPath: KeyPath<MarkupSummary, Value>,
        format: (Value) -> String
    ) -> String {
        guard let value = common(keyPath) else { return Self.mixedPlaceholder }
        return format(value)
    }

    /// What a field shows when the selection disagrees.
    public static let mixedPlaceholder = NSLocalizedString(
        "Multiple values",
        comment: "Inspector field text when the selected markups disagree"
    )

    /// The measurement fields every selected markup produces, deduplicated and ordered.
    ///
    /// Summing across mixed dimensions is not meaningful, so a field is listed only when every
    /// selected markup actually has it.
    public var sharedMeasurementFields: [MeasurementField] {
        guard let first = markups.first else { return [] }
        let firstFields = first.measurementFields.map(\.field)
        return firstFields.filter { field in
            markups.allSatisfy { markup in
                markup.measurementFields.contains { $0.field == field }
            }
        }
    }

    /// The display text for one measurement field across the selection.
    public func measurementText(_ field: MeasurementField) -> String {
        let texts = markups.compactMap { $0.field(field)?.displayTextWithUnit }
        guard let first = texts.first, texts.count == markups.count else {
            return Self.mixedPlaceholder
        }
        return texts.allSatisfy { $0 == first } ? first : Self.mixedPlaceholder
    }

    /// The fields whose values add up across markups — the ones a multi-selection total
    /// means something for. Slopes, angles, radii and diameters do not (IM-026).
    public static let additiveFields: Set<MeasurementField> = [
        .count, .planLength, .trueLength, .perimeter, .planArea, .netArea, .trueArea,
        .wallArea, .volume, .circumference, .arcLength
    ]

    /// How many times a markup counts in a total: its repeat count (feature 11), or once when it
    /// has none.
    ///
    /// The count on a summary is already the application's effective count — out-of-range and
    /// corrupt cells read as `nil` — so the only rule left is the ledger's: never fewer than
    /// once. Every additive field repeats with its markup in the ledger
    /// (`QuantityRepetition.multiplied`), so a total here multiplies exactly where a ledger
    /// subtotal does (W-040).
    public static func repetitions(_ markup: MarkupSummary) -> Int {
        max(1, markup.repeatCount ?? 1)
    }

    /// The sum of an additive field over the selection, in SI, each markup counted as many times
    /// as it repeats — the number the ledger's subtotal for the same rows holds — or `nil` when
    /// the field is not additive or a markup lacks it.
    ///
    /// W-040: the sum used to read each markup's value once, so a 12 m² room marked ×6 plus a
    /// 10 m² room totalled 22 m² here and 82 m² in the ledger. `Decimal` × an integer count is
    /// exact, as the ledger's own multiplication is.
    public func summedQuantity(_ field: MeasurementField) -> DecimalQuantity? {
        guard Self.additiveFields.contains(field), !markups.isEmpty else { return nil }
        var repeated: [DecimalQuantity] = []
        repeated.reserveCapacity(markups.count)
        for markup in markups {
            guard let quantity = markup.field(field)?.quantity else { return nil }
            repeated.append(DecimalQuantity(
                value: quantity.value * Decimal(Self.repetitions(markup)),
                dimension: quantity.dimension
            ))
        }
        return try? DecimalQuantity.sum(repeated, in: field.dimension)
    }

    /// The sum of an additive field over every selected markup, formatted in the unit and at
    /// the precision the markups display — or `nil` when the field is not additive, a markup
    /// lacks it, or the markups do not share one decimal display unit.
    ///
    /// Summed as `Decimal` in SI (the stored quantities) and rounded only here, at display
    /// (IM-026, house rule: `Decimal` for aggregates), through ``summedQuantity(_:)``, so a
    /// repeated markup counts as often as its ledger row does (W-040).
    public func measurementTotalText(_ field: MeasurementField, locale: Locale = .current) -> String? {
        guard Self.additiveFields.contains(field), !markups.isEmpty else { return nil }
        let summaries = markups.compactMap { $0.field(field) }
        guard summaries.count == markups.count, let first = summaries.first else { return nil }
        let symbol = first.displayUnitSymbol
        guard summaries.allSatisfy({ $0.displayUnitSymbol == symbol }) else { return nil }
        guard let total = summedQuantity(field) else { return nil }
        let converted: Decimal
        switch field.dimension {
        case .length:
            guard let unit = LengthUnit(rawValue: symbol), let value = try? total.converted(to: unit) else { return nil }
            converted = value
        case .area:
            guard let unit = AreaUnit(rawValue: symbol), let value = try? total.converted(to: unit) else { return nil }
            converted = value
        case .volume:
            guard let unit = VolumeUnit(rawValue: symbol), let value = try? total.converted(to: unit) else { return nil }
            converted = value
        case .count:
            converted = total.value
        default:
            return nil
        }
        // The precision is the one the markups are shown at, read in the document's number
        // locale; a display text that is not a plain decimal (feet and inches) has no digit
        // count to copy, so no total. Several markups shown at different precisions (a
        // per-markup display override, NL-MEASURE-10) total at the finest of them.
        let readings = summaries.map { InspectorDisplayedNumber.read($0.displayText, locale: locale) }
        guard let reading = readings.first ?? nil, readings.allSatisfy({ $0 != nil }) else { return nil }
        let digits = readings.compactMap { $0?.fractionDigits }.max() ?? reading.fractionDigits
        let mark = readings.lazy.compactMap { $0?.decimalMark }.first ?? reading.decimalMark
        let number = InspectorDisplayedNumber(decimalMark: mark, fractionDigits: digits)
            .render(converted, locale: locale)
        return symbol.isEmpty ? number : "\(number) \(symbol)"
    }

    /// The header the Inspector shows above the sections.
    public var headerTitle: String {
        switch count {
        case 0:
            return NSLocalizedString("No selection", comment: "Inspector header with nothing selected")
        case 1:
            return markups[0].subject
        default:
            return LocalizedPlural.string(
                "%lld markups selected",
                count: count,
                one: NSLocalizedString("%lld markup selected", comment: "Inspector header with one markup selected"),
                other: NSLocalizedString("%lld markups selected", comment: "Inspector header with several markups selected")
            )
        }
    }

    /// The header's second line: the kind, or how many kinds are mixed together.
    public var headerSubtitle: String? {
        guard !isEmpty else { return nil }
        if let kind = common(\.kind) { return kind.displayName }
        let kinds = Set(markups.map(\.kind)).count
        let format = NSLocalizedString(
            "%d different markup types",
            comment: "Inspector subtitle when the selection mixes markup types"
        )
        return String(format: format, kinds)
    }

    /// What the Inspector header shows under its title (IM-119).
    ///
    /// The markup's type was never on screen: `headerSubtitle` existed and nothing read it,
    /// and a single markup with an empty subject left the line blank. One markup reads
    /// "subject · type" (the type alone when there is no subject); several read
    /// "3 markups selected · Length" or "… · 2 different markup types".
    public var headerLine: String? {
        guard !isEmpty, let subtitle = headerSubtitle else { return nil }
        let title = isSingle
            ? markups[0].subject.trimmingCharacters(in: .whitespacesAndNewlines)
            : headerTitle
        guard !title.isEmpty else { return subtitle }
        return String(
            format: NSLocalizedString(
                "%1$@ · %2$@", comment: "Inspector header line: subject or selection count, then markup type"
            ),
            title, subtitle
        )
    }
}

/// A number as a markup row displays it, read in the document's number locale (R-070).
///
/// The rows are rendered by the ledger's one number formatter — `LedgerNumberFormatting`, which
/// the application points at the aggregation layer's `LedgerNumberLocale` — with the locale's
/// grouping separator on. The Inspector used to infer the format by taking the last "." or ","
/// as the decimal mark, so a grouping separator read as one: in English "1,234.57" was refused
/// (no Total row at all) and "12,345" at no decimals was read as three decimals. Here the
/// locale says which mark is the decimal separator and which is grouping, and a total renders
/// through the same formatter as the rows, grouping included.
struct InspectorDisplayedNumber: Hashable, Sendable {

    /// The decimal mark the text uses, or `nil` for a whole number.
    let decimalMark: String?
    /// How many digits follow the decimal mark.
    let fractionDigits: Int

    /// Reads a displayed number, or `nil` when the text is not a plain decimal — feet and
    /// inches, a fraction, a word.
    static func read(_ text: String, locale: Locale) -> InspectorDisplayedNumber? {
        let style = LedgerNumberStyle.forLocale(locale)
        var body = text.trimmingCharacters(in: .whitespaces)
        if let first = body.first, first == "-" || first == "\u{2212}" || first == "+" { body.removeFirst() }
        if body.hasPrefix(style.minusSign) { body.removeFirst(style.minusSign.count) }
        guard let firstCharacter = body.first, firstCharacter.isNumber else { return nil }
        let spaces: Set<Character> = [" ", "\u{00A0}", "\u{202F}"]
        let grouping = style.groupingSeparator.flatMap(\.first)
        let decimal = style.decimalSeparator
        // The locale's own decimal separator, when the text carries it, is the mark.
        if body.contains(decimal) {
            let parts = body.components(separatedBy: decimal)
            guard parts.count == 2, !parts[1].isEmpty, parts[1].allSatisfy(\.isNumber),
                  parts[0].allSatisfy({ $0.isNumber || $0 == grouping || spaces.contains($0) })
            else { return nil }
            return InspectorDisplayedNumber(decimalMark: decimal, fractionDigits: parts[1].count)
        }
        // Otherwise the last "." or "," between digits: the locale's grouping separator when it
        // closes a full group, the decimal mark of another locale's text when it does not.
        guard body.allSatisfy({ $0.isNumber || $0 == "." || $0 == "," || $0 == grouping || spaces.contains($0) }) else {
            return nil
        }
        guard let markIndex = body.lastIndex(where: { $0 == "." || $0 == "," }) else {
            return InspectorDisplayedNumber(decimalMark: nil, fractionDigits: 0)
        }
        let tail = body[body.index(after: markIndex)...]
        guard !tail.isEmpty, tail.allSatisfy(\.isNumber) else { return nil }
        if body[markIndex] == grouping, tail.count == style.groupingSize {
            return InspectorDisplayedNumber(decimalMark: nil, fractionDigits: 0)
        }
        let head = body[..<markIndex]
        guard !head.contains(body[markIndex]) else { return nil }
        return InspectorDisplayedNumber(decimalMark: String(body[markIndex]), fractionDigits: tail.count)
    }

    /// Renders `value` the way the text was rendered: rounded once, half away from zero, at the
    /// same digit count, through the ledger's formatter in `locale` with grouping — or, for a
    /// text whose decimal mark is not the locale's, with that mark and no grouping.
    func render(_ value: Decimal, locale: Locale) -> String {
        let style = LedgerNumberStyle.forLocale(locale)
        guard let decimalMark, decimalMark != style.decimalSeparator else {
            return LedgerNumberFormatting.string(value, fractionDigits: fractionDigits, locale: locale, grouping: true)
        }
        let borrowed = LedgerNumberStyle(
            decimalSeparator: decimalMark, groupingSeparator: nil, minusSign: style.minusSign, digits: style.digits
        )
        return borrowed.string(
            LedgerNumberFormatting.rounded(value, fractionDigits: fractionDigits), fractionDigits: fractionDigits
        )
    }
}
