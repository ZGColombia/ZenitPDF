import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

/// The known-length entry for calibration.
///
/// A metric unit gets a plain numeric entry. An imperial unit accepts what an estimator actually
/// types off a drawing — `12' 6 1/2"`, `6 1/2`, `12 ft 6 in` — and echoes back the parsed value
/// rounded to the chosen fraction. The echo is display only: the value handed back up is the
/// exact parsed number, never the rounded one.
///
/// The field owns its text for both kinds of unit and publishes it through ``pendingText`` on
/// every keystroke. That is what lets a single click on Apply commit the calibration: the sheet
/// validates the text the field is showing rather than the last value it wrote back, so the
/// first click is no longer spent committing the field (live finding LT-5).
public struct CalibrationLengthField: View {

    @Binding private var length: Double?
    @Binding private var pendingText: String
    private let unit: LengthUnit?
    private let precision: ImperialPrecision
    private let title: String
    private let isInvalid: Bool

    @FocusState private var isFocused: Bool
    /// Everything the field decides, as one pure value (see ``CalibrationLengthEntry``).
    @State private var entry = CalibrationLengthEntry()
    private let requestsFocus: Bool

    /// The range a calibration length has to fall in.
    ///
    /// Far wider than any drawing needs. It exists to keep a mistyped exponent out of the
    /// scale, not to second-guess an estimator who is measuring a site plan. The validator
    /// blocks on it too, so it is not only the field's warning glyph (BH-249).
    public static var allowedRange: ClosedRange<Double> { CalibrationValidator.allowedLengthRange }

    /// Decimals shown when the field is not being edited. The stored value keeps full accuracy.
    nonisolated static let metricFractionDigits = 4

    /// - Parameters:
    ///   - length: the entered length, expressed in `unit`.
    ///   - unit: the chosen unit, or `nil` when the unit itself is invalid.
    ///   - precision: fraction precision used for the imperial echo.
    ///   - title: the accessibility label and help tag.
    ///   - isInvalid: draw the invalid state because the validator rejected the value.
    ///   - pendingText: receives what the field is holding but has not committed. Defaults to a
    ///     constant so a preview can render the field without a sheet around it.
    ///   - requestsFocus: when this turns `true` the field takes keyboard focus, so the sheet
    ///     can move the person straight to the length once the second point lands (IM-102).
    public init(
        length: Binding<Double?>,
        unit: LengthUnit?,
        precision: ImperialPrecision = .sixteenth,
        title: String,
        isInvalid: Bool = false,
        pendingText: Binding<String> = .constant(""),
        requestsFocus: Bool = false
    ) {
        self._length = length
        self._pendingText = pendingText
        self.unit = unit
        self.precision = precision
        self.title = title
        self.isInvalid = isInvalid
        self.requestsFocus = requestsFocus
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.xs) {
            entryField

            // IM-017: the reason is on screen, next to the field, with an example of what to
            // type — not only in the VoiceOver value while sighted users get a red glyph.
            if let message = entry.errorMessage(unit: unit) {
                HStack(alignment: .firstTextBaseline, spacing: ZPDFSpacing.xs) {
                    ZPDFGlyphView(.symbol(.warning), size: ZPDFSpacing.Control.iconSmall)
                        .foregroundStyle(ZPDFColor.danger)
                        .accessibilityHidden(true)
                    Text(message)
                        .zpdfText(.caption, .danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }

            if let echo = CalibrationLengthEntry.roundingEcho(length: length, unit: unit, precision: precision) {
                Text(echo)
                    .zpdfText(.caption, .textSecondary)
                    .accessibilityLabel(
                        Text(
                            String(
                                format: NSLocalizedString(
                                    "Rounded for display: %@",
                                    comment: "Accessibility label for the imperial rounding echo"
                                ),
                                echo
                            )
                        )
                    )
            }
        }
        .disabled(unit == nil)
    }

    // MARK: Entry

    private var entryField: some View {
        HStack(spacing: ZPDFSpacing.xs) {
            TextField(placeholder, text: $entry.text)
                .textFieldStyle(.plain)
                .zpdfFont(.monoNumeric)
                .foregroundStyle(unit == nil ? ZPDFColor.textSecondary : ZPDFColor.textPrimary)
                .multilineTextAlignment(.trailing)
                .focused($isFocused)
                .onSubmit { update { $0.commit(unit: unit, precision: precision) } }
                .accessibilityLabel(title)
                .accessibilityValue(Text(spokenValue))

            if showsInvalidGlyph {
                ZPDFGlyphView(.symbol(.warning), size: ZPDFSpacing.Control.iconSmall)
                    .foregroundStyle(ZPDFColor.danger)
            }

            if let unit {
                Text(unit.symbol)
                    .zpdfText(.caption, .textSecondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, ZPDFSpacing.s)
        .frame(minHeight: ZPDFSpacing.Control.inspectorControl)
        .background {
            RoundedRectangle(cornerRadius: ZPDFRadius.small, style: .continuous)
                .fill(ZPDFColor.elevated)
                .overlay {
                    RoundedRectangle(cornerRadius: ZPDFRadius.small, style: .continuous)
                        .strokeBorder(
                            showsInvalidGlyph ? ZPDFColor.danger : ZPDFColor.border,
                            lineWidth: showsInvalidGlyph ? ZPDFStroke.emphasis : ZPDFStroke.regular
                        )
                }
        }
        .zpdfFocusRing(isFocused, cornerRadius: ZPDFRadius.small)
        .help(title)
        .onChange(of: isFocused) { _, focused in
            update { entry in
                if focused {
                    entry.beginEditing()
                } else {
                    entry.commit(unit: unit, precision: precision)
                }
            }
        }
        .onChange(of: entry.text) { _, _ in
            // Publishing on every keystroke is the point: the sheet has to be able to see an
            // uncommitted length, because the click that would commit it is the same click
            // that has to apply it. The field's own echo is not a keystroke (BH-046).
            let focused = isFocused
            update { $0.textDidChange(isFocused: focused) }
        }
        .onChange(of: length) { _, newValue in
            guard newValue != entry.length else { return }
            let focused = isFocused
            update { $0.lengthDidChange(to: newValue, isFocused: focused, unit: unit, precision: precision) }
        }
        .onChange(of: unit) { _, _ in
            if !isFocused { update { $0.sync(unit: unit, precision: precision) } }
        }
        .onChange(of: precision) { _, _ in
            if !isFocused { update { $0.sync(unit: unit, precision: precision) } }
        }
        .onChange(of: requestsFocus) { _, requested in
            if requested { isFocused = true }
        }
        .onAppear {
            update { entry in
                entry.length = length
                entry.sync(unit: unit, precision: precision)
            }
            if requestsFocus { isFocused = true }
        }
    }

    /// Runs one step of the entry and hands what changed to the bindings.
    private func update(_ step: (inout CalibrationLengthEntry) -> Void) {
        var next = entry
        step(&next)
        entry = next
        if pendingText != next.pendingText { pendingText = next.pendingText }
        if length != next.length { length = next.length }
    }

    // MARK: State

    private var placeholder: String {
        guard let unit, unit == .foot || unit == .inch else {
            return NSLocalizedString("Length", comment: "Placeholder for the known length field")
        }
        return NSLocalizedString("12' 6 1/2\"", comment: "Placeholder showing the accepted imperial format")
    }

    private var showsInvalidGlyph: Bool { entry.hasParseError || entry.hasRangeError || isInvalid }

    private var spokenValue: String {
        if let message = entry.errorMessage(unit: unit) { return message }
        guard !entry.text.isEmpty else {
            return NSLocalizedString("Empty", comment: "Accessibility value for an empty field")
        }
        guard let unit else { return entry.text }
        return entry.text + " " + unit.symbol
    }

    // MARK: Editing

    /// What committing a given text should do.
    ///
    /// Pure and static so the rule can be asserted without a sheet on anybody's screen.
    ///
    /// The case that matters is ``outOfRange``. This used to clamp instead: a typed `0` became
    /// `allowedRange.lowerBound`, one millionth, which then rendered back as "0" at four
    /// decimals. The field said zero, the draft held a positive number, and the validator's
    /// `nonPositiveLength` block — the one thing standing between a typo and a scale a million
    /// times too small — could never fire. Finding CR-164.
    enum CommitOutcome: Equatable {
        /// The field is empty. There is no length.
        case cleared
        /// The text is not a length at all.
        case unusable
        /// A real number, outside what a calibration may use. Carried through unchanged.
        case outOfRange(Double)
        /// A usable length, exactly as typed.
        case accepted(Double)
    }

    static func commitOutcome(text: String, unit: LengthUnit?) -> CommitOutcome {
        switch CalibrationPendingLength.reading(text, unit: unit) {
        case .none:
            return .cleared
        case .unusable:
            return .unusable
        case let .length(value):
            guard value.isFinite else { return .unusable }
            return allowedRange.contains(value) ? .accepted(value) : .outOfRange(value)
        }
    }

    /// The idle rendering of a decimal length: the user's decimal separator, no grouping,
    /// ASCII digits.
    ///
    /// ASCII digits because the text is read back through ``ZPDFDecimalParser``, whose grammar
    /// is ASCII. Rendering in `Locale.current` gave Eastern Arabic digits under `ar_SA` and
    /// Persian digits under `fa_IR`; the next focus-and-blur re-read the field's own echo as
    /// "not a length" and blocked Apply until the person retyped a number they had already
    /// entered (BH-743). Only the decimal mark is taken from the locale, and only when it is
    /// one of the two marks the grammar accepts.
    nonisolated static func metricString(_ value: Double, locale: Locale = .current) -> String {
        guard value.isFinite else { return String(value) }
        let posix = value.formatted(
            .number
                .precision(.fractionLength(0...metricFractionDigits))
                .grouping(.never)
                .locale(Locale(identifier: "en_US_POSIX"))
        )
        guard locale.decimalSeparator == "," else { return posix }
        return posix.replacingOccurrences(of: ".", with: ",")
    }
}

/// The decisions behind ``CalibrationLengthField``, as one pure value.
///
/// Pulled out of the view so the whole sequence — type, press Return, the field rewriting its
/// own text, blur, click back in — can be driven in a test with no field on anybody's screen.
struct CalibrationLengthEntry: Equatable {

    /// What the field shows.
    var text: String = ""
    /// What the sheet should fold into the draft: the typed, uncommitted text, or empty.
    var pendingText: String = ""
    /// The exact committed length, in the field's unit.
    var length: Double?
    var hasParseError = false
    /// The entry is a number, but not one a calibration may use. A separate state from a parse
    /// error because it needs a different sentence: the person typed a length, just not this one.
    var hasRangeError = false
    /// The text the entry last wrote into the field itself, rendered from ``length``.
    ///
    /// The echo is rounded for display. Reading it back as if the person had typed it is how
    /// the exact length used to be replaced by its rounding: on Return the rewrite was
    /// published as pending text and Apply committed `12' 7"` for a typed `12' 6 1/2"`
    /// (BH-046); on a later focus-and-blur `2.1235` overwrote a stored `2.123456` (BH-248).
    private(set) var echo: String?

    /// The field gained focus.
    mutating func beginEditing() {
        hasParseError = false
        hasRangeError = false
    }

    /// The field's text changed, by typing or by the entry rewriting it.
    mutating func textDidChange(isFocused: Bool) {
        guard isFocused else { return }
        if let echo, text == echo {
            // The field's own rendering of the committed length: nothing is pending.
            pendingText = ""
            return
        }
        // The person has typed over the echo. From here the text is theirs, even if they end
        // up typing the very string the echo showed.
        echo = nil
        hasParseError = false
        hasRangeError = false
        pendingText = text
    }

    /// Return was pressed or focus left: write the text back into ``length``, or refuse it.
    ///
    /// Unusable text keeps publishing itself through ``pendingText``, so the sheet blocks on
    /// what the person is looking at rather than falling back to a value the field has stopped
    /// showing. That fallback is how a calibration would silently commit the wrong number.
    mutating func commit(unit: LengthUnit?, precision: ImperialPrecision) {
        if let echo, text == echo, length != nil {
            // Unchanged since the entry rendered it: keep the exact value behind the rounding.
            pendingText = ""
            hasParseError = false
            return
        }
        switch CalibrationLengthField.commitOutcome(text: text, unit: unit) {
        case .cleared:
            hasParseError = false
            hasRangeError = false
            pendingText = ""
            text = ""
            echo = nil
            length = nil
        case .unusable:
            hasParseError = true
            hasRangeError = false
            pendingText = text
        case let .outOfRange(value):
            // Out of range, but still exactly what was typed. The number goes through so the
            // validator sees a zero as a zero and blocks; the field keeps the person's own text
            // and shows the invalid state rather than a rounded lie.
            hasRangeError = true
            hasParseError = false
            pendingText = text
            echo = text
            length = value
        case let .accepted(value):
            hasParseError = false
            hasRangeError = false
            pendingText = ""
            length = value
            render(value, unit: unit, precision: precision)
        }
    }

    /// The bound length changed from outside the field.
    mutating func lengthDidChange(
        to newValue: Double?,
        isFocused: Bool,
        unit: LengthUnit?,
        precision: ImperialPrecision
    ) {
        length = newValue
        if !isFocused { sync(unit: unit, precision: precision) }
    }

    /// Re-renders the field from ``length``.
    mutating func sync(unit: LengthUnit?, precision: ImperialPrecision) {
        hasParseError = false
        pendingText = ""
        guard let length else {
            hasRangeError = false
            text = ""
            echo = nil
            return
        }
        // A committed length that is out of range stays flagged; syncing used to clear the
        // warning the moment focus left the field (BH-249).
        hasRangeError = !CalibrationLengthField.allowedRange.contains(length)
        render(length, unit: unit, precision: precision)
    }

    private mutating func render(_ value: Double, unit: LengthUnit?, precision: ImperialPrecision) {
        let rendered = Self.displayText(value, unit: unit, precision: precision)
        text = rendered
        echo = rendered
    }

    /// The field's idle rendering of `value` in `unit`.
    ///
    /// Feet and inches render as `12' 6 1/2"`. Every other unit, yards and miles included,
    /// renders as a decimal in that unit: rendering yards through the inch formatter showed
    /// `180" yd` for five yards (BH-742).
    static func displayText(
        _ value: Double,
        unit: LengthUnit?,
        precision: ImperialPrecision,
        locale: Locale = .current
    ) -> String {
        guard let unit else { return "" }
        guard unit == .foot || unit == .inch else {
            return CalibrationLengthField.metricString(value, locale: locale)
        }
        let metresPerUnit = NSDecimalNumber(decimal: unit.metresPerUnit).doubleValue
        return ImperialLengthFormatter.string(
            metres: value * metresPerUnit,
            precision: precision,
            showsFeet: unit == .foot
        )
    }

    /// The sentence under the field that explains what is wrong, or `nil`.
    func errorMessage(unit: LengthUnit?) -> String? {
        if hasRangeError {
            return NSLocalizedString(
                "Outside the range a calibration can use. Type a positive length.",
                comment: "Calibration length is a number but out of range"
            )
        }
        guard hasParseError else { return nil }
        guard let unit, unit == .foot || unit == .inch else {
            return String(
                format: NSLocalizedString(
                    "“%@” is not a length. Type a number, for example 5.5.",
                    comment: "Calibration length cannot be read; the argument is the typed text"
                ),
                text
            )
        }
        return String(
            format: NSLocalizedString(
                "“%@” is not a length. Type feet and inches, for example 12' 6 1/2\".",
                comment: "Imperial calibration length cannot be read; the argument is the typed text"
            ),
            text
        )
    }

    /// The rounding note under a feet-and-inches entry, or `nil` for every other unit.
    static func roundingEcho(length: Double?, unit: LengthUnit?, precision: ImperialPrecision) -> String? {
        guard let unit, unit == .foot || unit == .inch, let length, length > 0, length.isFinite else {
            return nil
        }
        let rounded = displayText(length, unit: unit, precision: precision)
        return String(
            format: NSLocalizedString(
                "Shown as %1$@ at %2$@ precision. The stored value keeps full accuracy.",
                comment: "Echo under the imperial entry: rounded string, fraction precision"
            ),
            rounded,
            precision.displayName
        )
    }
}
