import SwiftUI

/// A unit-aware numeric field for measurements, coordinates and scale factors.
///
/// Three things make it different from a plain `TextField`:
/// tabular figures so a column of values never shifts width; a unit suffix that is part of the
/// field rather than a separate label; and an invalid state that shows a ring, a glyph and a
/// spoken value, never a red border on its own.
public struct ZPDFNumericField: View {
    @Binding private var value: Double?
    private let unit: String?
    private let accessibilityTitle: String
    private let placeholder: String
    private let isMixed: Bool
    private let fractionDigits: Int
    private let range: ClosedRange<Double>?
    private let onCommit: ((Double?) -> Void)?

    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var isFocused: Bool
    @State private var text: String = ""
    @State private var hasParseError = false
    /// The text the field last put on screen from a value, or last committed.
    ///
    /// The field displays a value rounded to ``fractionDigits`` while the stored number keeps
    /// full accuracy, so re-parsing what is on screen is a lossy round trip. Comparing against
    /// this is how the field knows whether the person actually typed something: tabbing past a
    /// depth of 0.2005 m used to re-commit the displayed "0.201" over it and fire `onCommit`
    /// for an edit nobody made. Finding CR-173.
    @State private var committedText: String = ""

    /// - Parameters:
    ///   - value: the edited number; `nil` means empty.
    ///   - unit: the unit suffix drawn inside the field, e.g. "mm" or "m²".
    ///   - accessibilityTitle: what VoiceOver calls this field.
    ///   - placeholder: shown when the field is empty.
    ///   - isMixed: `true` when a multi-selection disagrees; shows "Mixed" instead of a number.
    ///   - fractionDigits: how many decimals to display when not editing.
    ///   - range: optional valid range; a value outside it puts the field in the invalid state.
    ///   - onCommit: called when the user commits an edit.
    public init(
        value: Binding<Double?>,
        unit: String? = nil,
        accessibilityTitle: String,
        placeholder: String = "",
        isMixed: Bool = false,
        fractionDigits: Int = 2,
        range: ClosedRange<Double>? = nil,
        onCommit: ((Double?) -> Void)? = nil
    ) {
        self._value = value
        self.unit = unit
        self.accessibilityTitle = accessibilityTitle
        self.placeholder = placeholder
        self.isMixed = isMixed
        self.fractionDigits = fractionDigits
        self.range = range
        self.onCommit = onCommit
    }

    public var body: some View {
        HStack(spacing: ZPDFSpacing.xs) {
            TextField(displayPlaceholder, text: $text)
                .textFieldStyle(.plain)
                .zpdfFont(.monoNumeric)
                .foregroundStyle(isEnabled ? ZPDFColor.textPrimary : ZPDFColor.textSecondary)
                .multilineTextAlignment(.trailing)
                .focused($isFocused)
                .onSubmit(commit)
                .accessibilityLabel(accessibilityTitle)
                .accessibilityValue(Text(spokenValue))

            if !isValid {
                ZPDFGlyphView(.symbol(.warning), size: ZPDFSpacing.Control.iconSmall)
                    .foregroundStyle(ZPDFColor.danger)
            }

            if let unit, !unit.isEmpty {
                Text(unit)
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
                        .strokeBorder(borderColor, lineWidth: isValid ? ZPDFStroke.regular : ZPDFStroke.emphasis)
                }
        }
        .zpdfFocusRing(isFocused, cornerRadius: ZPDFRadius.small)
        .zpdfAnimation(.micro, value: isValid)
        .help(helpTag)
        .onAppear { syncFromValue() }
        .onChange(of: value) { _, _ in
            // BH-129: a binding that normalises what it is handed (rounds a page number,
            // clamps a count) changes `value` while the field still has focus. When the person
            // has not typed since the last commit, the field shows the model's value rather
            // than its own stale text; an edit in progress is still never overwritten.
            if Self.shouldResync(isFocused: isFocused, text: text, committedText: committedText) {
                syncFromValue()
            }
        }
        .onChange(of: isMixed) { _, _ in
            if !isFocused { syncFromValue() }
        }
        .onChange(of: isFocused) { _, focused in
            if focused {
                hasParseError = false
            } else {
                commit()
            }
        }
        .onChange(of: text) { _, _ in
            if isFocused { hasParseError = false }
        }
    }

    // MARK: - State

    private var displayPlaceholder: String {
        isMixed
            ? NSLocalizedString("Mixed", comment: "Numeric field placeholder when a multi-selection disagrees")
            : placeholder
    }

    private var parsed: Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return Self.parse(trimmed)
    }

    private var isValid: Bool {
        guard isEnabled else { return true }
        if hasParseError { return false }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }
        guard let parsed else { return false }
        guard let range else { return true }
        return range.contains(parsed)
    }

    private var borderColor: Color {
        isValid ? ZPDFColor.border : ZPDFColor.danger
    }

    private var spokenValue: String {
        if isMixed {
            return NSLocalizedString("Mixed value", comment: "Accessibility label for a mixed multi-selection value")
        }
        var spoken = text.isEmpty
            ? NSLocalizedString("Empty", comment: "Accessibility value: the field has no value")
            : text
        if let unit, !unit.isEmpty { spoken += " \(unit)" }
        if !isValid {
            spoken += ", " + invalidReason
        }
        return spoken
    }

    private var invalidReason: String {
        if let range, let parsed, !range.contains(parsed) {
            return String(
                format: NSLocalizedString("outside the allowed range %@ to %@", comment: "Accessibility: value is out of range"),
                Self.formatBound(range.lowerBound, fractionDigits: fractionDigits),
                Self.formatBound(range.upperBound, fractionDigits: fractionDigits)
            )
        }
        return NSLocalizedString("not a valid number", comment: "Accessibility: value cannot be parsed")
    }

    private var helpTag: String {
        guard let range else { return accessibilityTitle }
        return String(
            format: NSLocalizedString("%@ (%@ to %@)", comment: "Help tag: field name and allowed range"),
            accessibilityTitle,
            Self.formatBound(range.lowerBound, fractionDigits: fractionDigits),
            Self.formatBound(range.upperBound, fractionDigits: fractionDigits)
        )
    }

    // MARK: - Editing

    private func syncFromValue() {
        hasParseError = false
        guard !isMixed, let value else {
            text = ""
            committedText = ""
            return
        }
        text = Self.formatBound(value, fractionDigits: fractionDigits)
        committedText = text
    }

    private func commit() {
        switch Self.commitOutcome(text: text, committedText: committedText, range: range) {
        case .unchanged:
            hasParseError = false
        case .invalid:
            hasParseError = true
        case .cleared:
            hasParseError = false
            committedText = ""
            value = nil
            onCommit?(nil)
        case let .value(clamped):
            hasParseError = false
            value = clamped
            // BH-129 / BH-130: show what the binding actually stored, not what was handed to
            // it. A setter that rounds (Bulk Scale's first page) or clamps reads back a
            // different number, and displaying the pre-normalisation value is how the field
            // said "2" while the sheet applied page 3.
            text = Self.committedDisplayText(
                clamped: clamped, readBack: value, fractionDigits: fractionDigits
            )
            committedText = text
            onCommit?(clamped)
        }
    }

    /// Whether an external change of `value` should replace the field's text.
    ///
    /// Always when unfocused; while focused only when the text is still what the field itself
    /// last put there, so a normalising binding is reflected but a half-typed edit is kept.
    static func shouldResync(isFocused: Bool, text: String, committedText: String) -> Bool {
        guard isFocused else { return true }
        return text.trimmingCharacters(in: .whitespaces) == committedText
    }

    /// The text shown after a commit: the binding's read-back value when it has one.
    static func committedDisplayText(clamped: Double, readBack: Double?, fractionDigits: Int) -> String {
        formatBound(readBack ?? clamped, fractionDigits: fractionDigits)
    }

    /// What committing a given text should do.
    ///
    /// Pure and static so the rule can be asserted without putting a field on anybody's
    /// screen, and so the blur path and the Return path can never come to different answers.
    enum CommitOutcome: Equatable {
        /// The text is what the field itself last put there: not an edit, so nothing happens.
        case unchanged
        /// The text is not a finite number. The field shows the invalid state and keeps it.
        case invalid
        /// The field was emptied, which means *no value* rather than zero.
        case cleared
        /// A new value, already clamped into range.
        case value(Double)
    }

    static func commitOutcome(
        text: String,
        committedText: String,
        range: ClosedRange<Double>?
    ) -> CommitOutcome {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        // A blur is not an edit. Without this the field re-parses its own rounded display on
        // the way out — truncating the stored number and announcing a change nobody made — and
        // an untouched empty or Mixed field clears the selection on every tab through it.
        guard trimmed != committedText else { return .unchanged }
        guard !trimmed.isEmpty else { return .cleared }
        guard let parsed = parse(trimmed) else { return .invalid }
        // `parsed` is finite by construction — the shared parser refuses anything else — so
        // this clamp is a clamp rather than the NaN passthrough `min(max(nan, lo), hi)` is.
        guard let range else { return .value(parsed) }
        return .value(min(max(parsed, range.lowerBound), range.upperBound))
    }

    // MARK: - Number handling

    /// Parses a number through the one grammar every Zenit field shares.
    ///
    /// This used to be a locale `NumberFormatter`, then a POSIX one, then a bare
    /// `Double(string)` fallback — and that last line is what let `nan` and `inf` into the
    /// field. From there `min(max(nan, lo), hi)` returns `nan` rather than clamping, and a
    /// caller that turns the value into an `Int` traps. Finding CR-166; the shared parser
    /// refuses anything that is not a finite number, so there is nothing left to clamp.
    static func parse(_ string: String) -> Double? {
        ZPDFDecimalParser.double(string, allowingExponent: true)
    }

    /// The display text for `value` at `fractionDigits` decimals, in the user's decimal mark.
    ///
    /// BH-019: the text must be something ``parse(_:)`` reads back. A plain locale formatter
    /// emits U+2212 for a negative on sv/fi/nb/et Macs and native digits plus bidi marks on
    /// Arabic and Persian ones; the field then showed its own stored value as invalid. The
    /// formatter keeps the locale's decimal mark but uses Latin digits and an ASCII minus.
    ///
    /// BH-130: ties round away from zero, the way every caller rounds (`Double.rounded()`),
    /// rather than `NumberFormatter`'s default half-even.
    static func format(_ value: Double, fractionDigits: Int, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        var components = Locale.Components(locale: locale)
        components.numberingSystem = Locale.NumberingSystem("latn")
        formatter.locale = Locale(components: components)
        formatter.minusSign = "-"
        formatter.plusSign = "+"
        formatter.roundingMode = .halfUp
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = max(0, fractionDigits)
        formatter.usesGroupingSeparator = false
        let text = formatter.string(from: NSNumber(value: value)) ?? String(value)
        return String(text.filter { !ZPDFDecimalParser.ignoredMarks.contains($0) })
    }

    /// ``format(_:fractionDigits:locale:)``, widened until a non-zero value no longer reads
    /// as zero.
    ///
    /// BH-501 / BH-130: a Depth range of `0.0001...10000` at three decimals printed its floor
    /// as "0", so the help read "Depth (0 to 10000)" and typing 0 committed 0.0001 while the
    /// field showed "0". A bound, or a clamped value, is shown with as many extra decimals as
    /// it takes (up to ten) to be truthful.
    static func formatBound(_ value: Double, fractionDigits: Int, locale: Locale = .current) -> String {
        var digits = max(0, fractionDigits)
        var text = format(value, fractionDigits: digits, locale: locale)
        while value != 0, digits < 10, parse(text) == 0 {
            digits += 1
            text = format(value, fractionDigits: digits, locale: locale)
        }
        return text
    }
}

#if DEBUG
struct ZPDFNumericField_Previews: PreviewProvider {
    private struct Demo: View {
        @State private var length: Double? = 4218.75
        @State private var invalid: Double? = 0
        @State private var empty: Double?

        var body: some View {
            ZPDFPreviewPanel("Numeric fields") {
                VStack(alignment: .leading, spacing: ZPDFSpacing.m) {
                    ZPDFNumericField(
                        value: $length,
                        unit: NSLocalizedString("mm", comment: "Preview unit"),
                        accessibilityTitle: NSLocalizedString("Length", comment: "Preview label")
                    )
                    ZPDFNumericField(
                        value: $invalid,
                        unit: NSLocalizedString("m", comment: "Preview unit"),
                        accessibilityTitle: NSLocalizedString("Depth", comment: "Preview label"),
                        range: 0.01...50
                    )
                    ZPDFNumericField(
                        value: $empty,
                        unit: NSLocalizedString("m²", comment: "Preview unit"),
                        accessibilityTitle: NSLocalizedString("Area", comment: "Preview label"),
                        isMixed: true
                    )
                    ZPDFNumericField(
                        value: .constant(1.0),
                        unit: NSLocalizedString("mm", comment: "Preview unit"),
                        accessibilityTitle: NSLocalizedString("Disabled", comment: "Preview label")
                    )
                    .disabled(true)
                }
            }
        }
    }

    static var previews: some View {
        ZPDFAppearancePair { Demo() }
            .previewDisplayName("ZPDFNumericField - dark and light")
    }
}
#endif
