import Foundation

/// The rules for the values a person types for an assembly's inputs (V-067).
///
/// Two places take the same recipe parameters — Apply Assembly in the Quantity Ledger and the
/// Assembly row of the Tool Library's preset editor — and each used to carry its own copy of the
/// unit label, the length conversion and the "which free parameters are still empty" check. The
/// copies had already drifted once (U-064: one read a length as metres, the other in the
/// project's unit). They are written once, here, and both models call them.
///
/// Parsing the typed text is the caller's `parse`, because this package has no dependencies;
/// both callers pass the one Zenit number reading, `ZPDFDecimalParser` with exponents (the
/// ledger through `LedgerNumberParsing`, a pass-through to it).
extension LedgerAssemblySummary.Input {

    /// The unit a value for this input is typed in, for the label after its field: the display
    /// length unit for a length, m² and m³ for an area and a volume, nothing for a number.
    public func unitLabel(lengthUnit: LengthUnit) -> String {
        Self.unitLabel(for: dimension, lengthUnit: lengthUnit)
    }

    /// ``unitLabel(lengthUnit:)`` for a dimension.
    public static func unitLabel(for dimension: QuantityDimension, lengthUnit: LengthUnit) -> String {
        switch dimension.lengthPower {
        case 1: lengthUnit.symbol
        case 2: "m²"
        case 3: "m³"
        default: ""
        }
    }

    /// A typed number as the quantity it means, in SI base units: a length typed in
    /// `lengthUnit`, an area or a volume in m² or m³, anything else as it is.
    public func quantity(typed value: Decimal, lengthUnit: LengthUnit) -> DecimalQuantity {
        let factor = dimension.lengthPower == 1 ? lengthUnit.metresPerUnit : 1
        return DecimalQuantity(value: value * factor, dimension: dimension)
    }

    /// The text typed for this input, trimmed.
    func typedText(in texts: [String: String]) -> String {
        (texts[name] ?? "").trimmingCharacters(in: .whitespaces)
    }

    /// The free parameters among `inputs` with nothing typed — every one is needed.
    public static func missingParameters(_ inputs: [Self], texts: [String: String]) -> [String] {
        inputs.filter { $0.isFreeParameter && $0.typedText(in: texts).isEmpty }.map(\.name)
    }

    /// The inputs whose typed text is not a number.
    public static func unreadableInputs(
        _ inputs: [Self],
        texts: [String: String],
        parse: (String) -> Decimal?
    ) -> [String] {
        inputs.compactMap { input in
            let text = input.typedText(in: texts)
            return !text.isEmpty && parse(text) == nil ? input.name : nil
        }
    }

    /// Every typed value as its quantity, by input name. Empty and unreadable fields are left
    /// out: an optional input a measurement can supply stays unset.
    public static func quantities(
        _ inputs: [Self],
        texts: [String: String],
        lengthUnit: LengthUnit,
        parse: (String) -> Decimal?
    ) -> [String: DecimalQuantity] {
        var values: [String: DecimalQuantity] = [:]
        for input in inputs {
            let text = input.typedText(in: texts)
            guard !text.isEmpty, let value = parse(text) else { continue }
            values[input.name] = input.quantity(typed: value, lengthUnit: lengthUnit)
        }
        return values
    }
}
