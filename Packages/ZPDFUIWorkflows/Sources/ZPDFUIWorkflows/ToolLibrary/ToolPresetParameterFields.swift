import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

/// A text field that edits an optional stored length, typed in a display unit.
///
/// The whole reason this is a type and not a `TextField` with a formatter is the unit. A preset
/// stores metres and the estimator types feet, so every keystroke crosses a conversion — and a
/// conversion done in two places is a conversion that eventually disagrees with itself. Both
/// directions are here, both go through `Decimal`, and neither goes near a `Double`: a depth
/// typed as `0.2` has to store as exactly two tenths of a metre or the ledger will show back a
/// number the estimator did not type.
///
/// An empty field means *no value*, not zero. That distinction is load-bearing: a Volume with no
/// depth is a tool waiting for one, and a Volume with a depth of zero is a tool that will
/// cheerfully report a volume of nothing.
struct ToolPresetLengthField: View {

    @Binding var quantity: DecimalQuantity?
    /// Set while the typed text does not read as a number; the stored value is left alone and
    /// the typed text stays in the box (IM-036).
    @Binding var isUnparsed: Bool
    let unit: LengthUnit
    let accessibilityLabel: String
    /// The shared rule's message for this field, or `nil` when the value is fine.
    var issue: String?

    @State private var text: String = ""
    /// Which strings in ``text`` the field wrote itself, and so must not parse back.
    @State private var echo = EchoState()

    /// The rule for telling a rendering apart from a keystroke.
    ///
    /// Rendering is rounded and parsing is not, so a rendering fed straight back through the
    /// parser is a lossy round trip. Without this, switching the unit picker back and forth
    /// would grind the stored depth down a few digits at a time. The rendered string is
    /// remembered here and skipped when it comes back through `onChange`.
    ///
    /// It is `nil`, not `""`, after a keystroke. It used to be reset to the empty string, so
    /// typing `0.25` and then selecting all and deleting produced a change to `""` that equalled
    /// the remembered `""` — the guard swallowed it and the draft kept 0.25 m behind a blank
    /// field. Finding BH-056. A `nil` matches no text, so every keystroke after the first
    /// parses, including the one that empties the field.
    struct EchoState: Equatable {
        /// The last string the field wrote, or `nil` once the person has typed.
        var rendered: String? = ""

        /// Records that the field rendered `value` itself.
        mutating func didRender(_ value: String) {
            rendered = value
        }

        /// Whether `newValue` came from the keyboard and must be parsed into the quantity.
        /// Every call that answers `true` also forgets the rendering.
        mutating func shouldParse(_ newValue: String) -> Bool {
            guard newValue != rendered else { return false }
            rendered = nil
            return true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .zpdfFont(.control)
                .accessibilityLabel(Text(accessibilityLabel))
                .accessibilityHint(Text(issue ?? ""))
                .onAppear { render(unit) }
                .onChange(of: text) { _, newValue in
                    guard echo.shouldParse(newValue) else { return }
                    switch Self.reading(newValue, unit: unit) {
                    case .empty:
                        quantity = nil
                        isUnparsed = false
                    case let .value(parsed):
                        quantity = parsed
                        isUnparsed = false
                    case .unparsed:
                        // Keep the text and the stored value; say what is wrong instead of
                        // silently deleting the depth. Finding IM-036.
                        isUnparsed = true
                    }
                }
                .onChange(of: unit) { _, newUnit in
                    // The stored value did not change; the unit it is read in did. Re-rendering the
                    // field is what keeps "2.7 m" from silently becoming "2.7 ft".
                    render(newUnit)
                }
            if let issue { ToolPresetFieldIssue(message: issue) }
        }
    }

    private func render(_ unit: LengthUnit) {
        let value = Self.text(from: quantity, unit: unit)
        echo.didRender(value)
        text = value
        isUnparsed = false
    }

    /// What a keystroke's text means for the stored value.
    enum Reading: Equatable {
        /// The field is empty: no value.
        case empty
        /// The text reads as this length, in metres.
        case value(DecimalQuantity)
        /// The text is not a number; the stored value must be left alone.
        case unparsed
    }

    /// Reads the typed text. Empty and unparseable are different answers: the first clears the
    /// value, the second keeps it and raises an issue.
    static func reading(_ text: String, unit: LengthUnit) -> Reading {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .empty }
        guard let parsed = quantity(from: text, unit: unit) else { return .unparsed }
        return .value(parsed)
    }

    /// Decimals shown in the field. Six is a micrometre in metres and a third of one in feet —
    /// finer than any takeoff, and short enough to read.
    static let displayFractionDigits = 6

    /// The stored quantity as a string in `unit`, or empty when there is none.
    ///
    /// Rounded at the display boundary, which is the house rule and also the difference between
    /// a usable field and the one this replaced: a 0.2 m depth read in feet is
    /// 0.65616797900262467191601049868766404, and that is what the editor put in the box for
    /// somebody to read a number off. Finding CR-183. The stored `Decimal` is untouched; only
    /// this string is rounded, and ``rendered`` keeps the rounding from travelling back into it.
    static func text(from quantity: DecimalQuantity?, unit: LengthUnit) -> String {
        guard let quantity, quantity.dimension == .length else { return "" }
        let perUnit = unit.metresPerUnit
        var rounded = Decimal()
        var raw = quantity.value / perUnit
        NSDecimalRound(&rounded, &raw, displayFractionDigits, .plain)
        return "\(rounded)"
    }

    /// The typed string as a stored quantity in metres, or `nil` when the field is empty or
    /// unparseable.
    ///
    /// Reads through the one grammar every Zenit field shares (CR-184), so `2,7` and `2.7` are
    /// the same depth whichever estimator is at the keyboard, `1 200` is twelve hundred rather
    /// than a parse failure, and `1,200.50` is refused rather than read as one of two numbers a
    /// thousand apart.
    static func quantity(from text: String, unit: LengthUnit) -> DecimalQuantity? {
        guard let value = ZPDFDecimalParser.decimal(text, allowingExponent: true) else { return nil }
        return DecimalQuantity(value: value * unit.metresPerUnit, dimension: .length)
    }
}

/// A text field that edits an optional bare number — a slope percentage, an azimuth in degrees.
///
/// Separate from ``ToolPresetLengthField`` because these two carry no unit and must not be
/// converted. A slope of 50 is 50 % whether the estimator works in metres or in feet, and
/// running it through a length conversion is exactly the kind of quiet wrongness the product
/// exists to avoid.
struct ToolPresetNumberField: View {

    @Binding var value: Double?
    /// Set while the typed text does not read as a number (IM-036).
    @Binding var isUnparsed: Bool
    let accessibilityLabel: String
    /// The shared rule's message for this field, or `nil` when the value is fine.
    var issue: String?

    @State private var text: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .zpdfFont(.control)
                .accessibilityLabel(Text(accessibilityLabel))
                .accessibilityHint(Text(issue ?? ""))
                .onAppear { text = value.map { Self.text(from: $0) } ?? "" }
                .onChange(of: text) { _, newValue in
                    if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        value = nil
                        isUnparsed = false
                    } else if let parsed = Self.number(from: newValue) {
                        value = parsed
                        isUnparsed = false
                    } else {
                        isUnparsed = true
                    }
                }
            if let issue { ToolPresetFieldIssue(message: issue) }
        }
    }

    /// A stored number as a field string, without a trailing `.0` on a whole number.
    static func text(from value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15
            ? String(Int(value))
            : String(value)
    }

    /// The typed string as a number, or `nil` when the field is empty or unparseable.
    ///
    /// Reads through the one grammar every Zenit field shares (CR-184). The old reading turned
    /// every comma into a point before parsing, so `1,234` here was one point two three four
    /// while the numeric field two rows up read the same text as one thousand two hundred and
    /// thirty-four.
    static func number(from text: String) -> Double? {
        ZPDFDecimalParser.double(text, allowingExponent: true)
    }
}

/// The message under a preset parameter field that holds something the shared rule refuses.
/// An icon and words, never colour alone.
struct ToolPresetFieldIssue: View {
    let message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: ZPDFSpacing.xs) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(ZPDFColor.danger)
                .accessibilityHidden(true)
            Text(message)
                .zpdfText(.caption, .danger)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
