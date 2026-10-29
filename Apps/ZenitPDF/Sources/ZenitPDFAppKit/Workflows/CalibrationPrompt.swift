import AppKit
import Foundation
import ZPDFAppCore
import ZPDFContracts
import ZPDFDesignSystem
import ZPDFUIPresentation

/// Asks for the real-world length of the two points the user just clicked.
///
/// A sheet with a number and a unit, and nothing else. The two points are already on screen in the
/// calibration colour, so the question the dialog has to ask is exactly one question.
///
/// The value is parsed into `Decimal` by ``parse(_:unit:)`` — a whole-string, locale-independent
/// grammar — never through `Double(_:)` or a prefix parser: a scale is the multiplier under
/// every quantity in the project, `12,5` has to mean twelve and a half on any Mac, and text
/// the grammar does not understand is refused rather than read as its leading number.
@MainActor
public enum CalibrationPrompt {

    /// A known length and the unit it was given in.
    public struct Entry: Sendable {
        public let length: Decimal
        public let unit: Domain.Length
    }

    /// The units offered, in the order the popup lists them.
    static let units: [(unit: Domain.Length, title: String)] = [
        (.metre, NSLocalizedString("m", comment: "Unit symbol: metre")),
        (.millimetre, NSLocalizedString("mm", comment: "Unit symbol: millimetre")),
        (.centimetre, NSLocalizedString("cm", comment: "Unit symbol: centimetre")),
        (.foot, NSLocalizedString("ft", comment: "Unit symbol: foot")),
        (.inch, NSLocalizedString("in", comment: "Unit symbol: inch"))
    ]

    /// The stable names of these dialogues, for `ZenitModalPresenter.didRequest(_:)`.
    public static let modalIdentifier = "calibration.knownLength"
    public static let parseFailureModalIdentifier = "calibration.unusableLength"

    /// Runs the sheet modally and returns what the user entered, or `nil` if they cancelled.
    ///
    /// - Parameter defaultUnit: the unit the popup starts on — the project's length unit, so
    ///   an imperial takeoff does not calibrate "24" as 24 metres on a Return (BH-376).
    public static func ask(
        in window: NSWindow,
        defaultUnit: Domain.Length = .metre,
        title: String? = nil,
        message: String? = nil,
        confirmTitle: String? = nil,
        identifier: String = modalIdentifier
    ) -> Entry? {
        let alert = NSAlert()
        alert.messageText = title ?? NSLocalizedString(
            "How long is that line in the real building?",
            comment: "Calibration prompt title"
        )
        alert.informativeText = message ?? NSLocalizedString(
            "Every quantity in this drawing is computed from this length, so use a dimension the drawing states rather than one you estimate.",
            comment: "Calibration prompt message"
        )
        alert.addButton(withTitle: confirmTitle ?? NSLocalizedString("Set Scale", comment: "Calibration prompt button"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Calibration prompt button"))

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        field.placeholderString = NSLocalizedString("Length", comment: "Calibration field placeholder")
        field.alignment = .right
        // Return in the field presses Set Scale directly. Without this, Return only ended
        // editing, and the first Set Scale click was likewise spent committing the field
        // editor — the button had to be clicked twice (LT-5, 2026-08-29).
        if let setScale = alert.buttons.first {
            field.target = setScale
            field.action = #selector(NSButton.performClick(_:))
        }
        let popup = NSPopUpButton(frame: NSRect(x: 128, y: 0, width: 82, height: 24), pullsDown: false)
        popup.addItems(withTitles: units.map(\.title))
        popup.selectItem(at: units.firstIndex { $0.unit == defaultUnit } ?? 0)
        popup.setAccessibilityLabel(NSLocalizedString(
            "Unit", comment: "Accessibility label for the calibration unit popup"
        ))
        field.setAccessibilityLabel(NSLocalizedString(
            "Known length", comment: "Accessibility label for the calibration length field"
        ))

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 210, height: 24))
        accessory.addSubview(field)
        accessory.addSubview(popup)
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = field

        // No user, no scale. A calibration invented by a headless process is the wrong
        // number under every quantity in the project.
        guard ZenitModalPresenter.runAlert(
            alert,
            identifier: identifier,
            answerWithoutAUser: .dismissed
        ) == .button(0) else { return nil }

        // The field editor's live text, not the cell: `stringValue` lags while editing is
        // still open, which is the other half of the double-click defect (LT-5).
        let text = field.currentEditor()?.string ?? field.stringValue
        let selectedUnit = units[max(0, min(units.count - 1, popup.indexOfSelectedItem))].unit
        let parsedEntry = parse(text, unit: selectedUnit)
        let parsed = parsedEntry?.length
        guard let parsed, parsed > 0 else {
            let failure = NSAlert()
            failure.alertStyle = .warning
            failure.messageText = NSLocalizedString(
                "That is not a length Zenit PDF can use.",
                comment: "Calibration parse failure title"
            )
            failure.informativeText = NSLocalizedString(
                "Enter a positive number, for example 5, 5.5 or 5,5 — or feet and inches such as 10' 6\".",
                comment: "Calibration parse failure message"
            )
            ZenitModalPresenter.runAlert(
                failure,
                identifier: parseFailureModalIdentifier,
                answerWithoutAUser: .dismissed
            )
            return nil
        }
        return Entry(length: parsed, unit: parsedEntry?.unit ?? selectedUnit)
    }

    /// The popup unit that matches a display length unit.
    public static func promptUnit(for display: ZPDFUIPresentation.LengthUnit) -> Domain.Length {
        switch display {
        case .millimetre: return .millimetre
        case .centimetre: return .centimetre
        case .inch: return .inch
        case .foot: return .foot
        default: return .metre
        }
    }

    /// Parses a known length. Pure, for BH-077/BH-078's regression tests.
    ///
    /// - A plain number is read by `ZPDFDecimalParser`: whole string, one decimal mark (`.` or
    ///   `,`), spaces as grouping, never the Mac's locale. `NumberFormatter` in en_US read
    ///   `12,5` as 125 and in de_DE read `5.5` as 55 — a 10x scale (BH-077).
    /// - Feet and inches (`10'6"`, `10' - 6 1/2"`, `10 ft 6 in`) and a mixed fraction
    ///   (`3 1/2`) are read exactly; feet-and-inches comes back in inches.
    /// - Anything else is `nil`. The old `Decimal(string:)` fallback read the leading number
    ///   and dropped the rest: `10'6"` became 10, `3 1/2` became 3 (BH-078).
    public static func parse(_ raw: String, unit: Domain.Length) -> Entry? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let value = ZPDFDecimalParser.decimal(text) {
            return value > 0 ? Entry(length: value, unit: unit) : nil
        }
        if let inches = feetAndInches(text) {
            return inches > 0 ? Entry(length: inches, unit: .inch) : nil
        }
        if let value = mixedNumber(text) {
            return value > 0 ? Entry(length: value, unit: unit) : nil
        }
        return nil
    }

    /// `3 1/2`, `1/2`, `3-1/2` → a Decimal, or `nil`.
    static func mixedNumber(_ text: String) -> Decimal? {
        let pattern = #"^\s*(?:([0-9]+(?:[.,][0-9]+)?)\s*[- ]\s*)?([0-9]+)\s*/\s*([0-9]+)\s*$"#
        guard let match = text.firstMatch(of: try! Regex(pattern)) else {
            return nil
        }
        let whole = match.output[1].substring.flatMap { ZPDFDecimalParser.decimal(String($0)) } ?? 0
        guard let numeratorText = match.output[2].substring,
              let denominatorText = match.output[3].substring,
              let numerator = Decimal(string: String(numeratorText)),
              let denominator = Decimal(string: String(denominatorText)),
              denominator != 0 else { return nil }
        return whole + numerator / denominator
    }

    /// `10'6"`, `10' - 6 1/2"`, `10 ft 6 in`, `10'` → inches, or `nil`.
    static func feetAndInches(_ text: String) -> Decimal? {
        let normalised = text
            .replacingOccurrences(of: "\u{2032}", with: "'")
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2033}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "''", with: "\"")
        let pattern = #"^\s*([0-9]+(?:[.,][0-9]+)?)\s*(?:'|ft\.?|feet|foot)\s*(?:-?\s*(.*?)\s*(?:"|in\.?|inch|inches)?)?\s*$"#
        guard let match = normalised.firstMatch(of: try! Regex(pattern).ignoresCase()),
              let feetText = match.output[1].substring,
              let feet = ZPDFDecimalParser.decimal(String(feetText)) else { return nil }
        var inches: Decimal = 0
        if let rest = match.output[2].substring, !rest.trimmingCharacters(in: .whitespaces).isEmpty {
            let inchText = String(rest).trimmingCharacters(in: .whitespaces)
            guard let value = ZPDFDecimalParser.decimal(inchText) ?? mixedNumber(inchText) else { return nil }
            inches = value
        }
        return feet * 12 + inches
    }
}
