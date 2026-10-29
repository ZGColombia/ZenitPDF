import Foundation
import ZPDFContracts
import ZPDFQuantityLedger
import ZPDFUIPresentation

/// Feature 11 — *measure once, applies to every storey* — as a **reserved custom column**.
///
/// ### Why a column and not a field on the record
///
/// A repetition count is a claim about a measurement: *this flat repeats on six sheets.* The
/// obvious home is `MarkupRecord`, and it is the wrong one. `MarkupRecord` is a frozen contract;
/// adding a field to it needs an ADR with migration evidence, and every consumer of the record —
/// undo, save, export, compare — would have to learn what a repeat count is before a single row
/// could show one.
///
/// A custom ledger column needs none of that. `customValues` already round-trips through the
/// archive, already appears in the ledger, already exports, and already writes an audit entry on
/// every change, because `.editCustomValue` is an ordinary undoable command. So the multiplier
/// arrives **visible by construction**, which is the invariant this column exists for: *the
/// multiplier is on the row, in the export, and in the audit entry, or a total is inflated
/// with nothing on screen saying why.*
///
/// ### What "reserved" means
///
/// The column is a custom column with a fixed key that Zenit ships rather than the user creating.
/// Its `ColumnID` is derived, not generated, by the same mechanism the built-in columns use, so
/// the same drawing carries the same repeat column on every machine and in every process — a
/// generated `UUID()` here would mean a project saved on one Mac had a `Repeat ×` column that a
/// second Mac read as an unrelated user column.
///
/// ### What this type deliberately does not do
///
/// It does not multiply anything into a ledger total. The aggregation core
/// (`ZPDFQuantityLedger`) folds a column's cells with no notion of another column scaling them,
/// and teaching it one is a change to the aggregation package, which owns
/// `Σ subtotal == grandTotal` and is not this seam's to edit. ``repeatedTotal(value:count:)`` is
/// the arithmetic, stated once and tested, for whoever wires the totals.
public enum RepetitionColumn: Sendable {

    // MARK: - Identity

    /// Namespace for the columns Zenit reserves but models as custom ones.
    ///
    /// Separate from ``ZPDFQuantityLedger/LedgerIdentifiers/standardColumnNamespace`` because
    /// these are *not* `StandardLedgerColumn` cases — that enum is frozen — and sharing a
    /// namespace with it would invite a future collision between a reserved key and a built-in
    /// one.
    public static let namespace = "zenit.pdf/ledger/reserved-column/v1"

    /// The reserved name, under the `custom.` prefix that
    /// ``ZPDFUIPresentation/LedgerColumnID/isCustom`` recognises.
    public static let name = "zenit.repeat"

    /// The column's stable key: what a formula, a saved layout and an export all address it by.
    ///
    /// Matches ``presentationID`` by construction — `LedgerBridge` builds a presentation column
    /// id as `LedgerColumnID(definition.key)`, so the two must agree or the ledger would draw a
    /// column the presenter could not find.
    public static let key = "custom.\(name)"

    /// The column's identity in the domain: what `record.customValues` is keyed by.
    public static let columnID = ColumnID(
        LedgerIdentifiers.deterministicUUID(namespace: namespace, name: name)
    )

    /// The column's identity in the presentation tier.
    public static let presentationID = LedgerColumnID.custom(name)

    /// The header a person reads.
    ///
    /// The multiplication sign is part of the title so a cell reading `6` reads as *six times*
    /// rather than as six of something. `UX_COPY_STANDARD` case, no invented vocabulary.
    public static var title: String {
        NSLocalizedString(
            "Repeat ×",
            comment: "Quantity Ledger column: how many times a measurement repeats"
        )
    }

    /// The count a markup has when the column is absent.
    ///
    /// Absent means *once*, never *zero*. A default of zero would let an unset column erase a
    /// measurement from a total.
    public static let defaultCount = 1

    /// The smallest count the column accepts. Half a repetition is not a thing, and a count of
    /// zero is a deletion wearing a number's clothes.
    public static let minimumCount = 1

    /// The largest count the column accepts. Far beyond any building — a tower of a thousand
    /// storeys is ten times taller than any built — and far inside `Int`, so the conversion
    /// from the stored `Decimal` is exact on every Mac. Above `Int64` the conversion used to be
    /// unspecified: a saturated multiplier on one architecture, "once" on another (BH-437).
    /// Read from the presentation layer's ``MarkupSummary/maximumRepeatCount`` so the Inspector's
    /// Repeat stepper stops at the same bound (X-021).
    public static let maximumCount = MarkupSummary.maximumRepeatCount

    // MARK: - The column

    /// The column definition, ready to be added to a project's column set.
    ///
    /// A dimensionless number column: the value is a multiplicity, not a quantity, so it
    /// carries `.ratio` and consequently is *not* summed into a grand total —
    /// `LedgerBridge.aggregate(for:)` refuses a dimensionless non-count column, and a column of
    /// repeat counts added together would be a number that means nothing (QUALITY_BAR A14).
    ///
    /// - Parameter order: where the column sits in the layout. Defaults to the far right, after
    ///   the built-ins, because it qualifies a row rather than being one of its measurements.
    public static func definition(order: Int = LedgerColumnID.standardColumns.count) -> LedgerColumnDefinition {
        LedgerColumnDefinition(
            id: columnID,
            key: key,
            title: title,
            kind: .number,
            standard: nil,
            dimension: .ratio,
            precision: .decimalPlaces(0),
            isEditable: true,
            isVisible: true,
            order: order
        )
    }

    // MARK: - Reading

    /// How many times this markup repeats, or `nil` when nobody has said.
    ///
    /// `nil` rather than `1` so a caller can tell "not set" from "set to one" — the difference
    /// between a row that says nothing about repetition and a row that deliberately says once.
    /// ``count(of:)`` is the one that answers the arithmetic question.
    ///
    /// A stored value below the minimum, or one that is not a plain number, reads as `nil`: a
    /// `Repeat ×` of `0` or `-3` is corrupt data, and honouring it would zero or negate a
    /// quantity. Fractions are floored rather than rounded, because a "repeat" that is 2.9 is
    /// two complete repetitions and a mistake, and rounding it up would invent a storey.
    public static func repeatCount(of record: MarkupRecord) -> Int? {
        guard case .number(let quantity)? = record.customValues[columnID] else { return nil }
        return effectiveCount(of: quantity)
    }

    /// The multiplier a stored cell quantity stands for, or `nil` when it stands for none.
    ///
    /// The range is checked in `Decimal`, before any conversion, so an out-of-range value reads
    /// as `nil` on every machine (BH-437). The ledger cell renders this same number, so the
    /// cell, the badge, the Inspector and the totals cannot disagree about a stored 2.9 or 0
    /// (BH-104, BH-105) — and the write path refuses both in the first place
    /// (``validatedCellValue(_:)``).
    public static func effectiveCount(of quantity: ZPDFContracts.DecimalQuantity) -> Int? {
        guard quantity.dimension == .ratio || quantity.dimension == .count else { return nil }
        let value = quantity.value
        guard value.isFinite, !value.isNaN,
              value >= Decimal(minimumCount), value < Decimal(maximumCount + 1) else { return nil }
        var source = value
        var floored = Decimal()
        NSDecimalRound(&floored, &source, 0, .down)
        return (floored as NSDecimalNumber).intValue
    }

    /// A value a person asked to store in the column, or `nil` when the column must refuse it.
    ///
    /// Only a whole number from ``minimumCount`` to ``maximumCount``, or clearing the cell. A
    /// bulk edit wrote any number straight through — 2.9, 0, 1e19 — and the row then showed one
    /// multiplier while its total used another (BH-104, BH-105, BH-437).
    public static func validatedCellValue(_ value: ZPDFContracts.LedgerCellValue) -> ZPDFContracts.LedgerCellValue? {
        switch value {
        case .empty:
            return value
        case .number(let quantity):
            // The number is judged, not the dimension: a mismatched tag stays visible to the
            // column set's own validation rather than being rewritten here.
            let value = quantity.value
            guard value.isFinite, !value.isNaN,
                  value >= Decimal(minimumCount), value <= Decimal(maximumCount) else { return nil }
            var source = value
            var whole = Decimal()
            NSDecimalRound(&whole, &source, 0, .down)
            return whole == value ? .number(quantity) : nil
        default:
            return nil
        }
    }

    /// The multiplier to apply, which is `1` for a markup that has not been given one.
    public static func count(of record: MarkupRecord) -> Int {
        repeatCount(of: record) ?? defaultCount
    }

    /// Whether this markup carries a multiplier worth showing — anything above once.
    ///
    /// A `×1` badge on every row is noise that teaches people to stop reading badges, which is
    /// how the one row that says `×6` gets missed.
    public static func isRepeated(_ record: MarkupRecord) -> Bool {
        count(of: record) > defaultCount
    }

    // MARK: - Writing

    /// The cell value for a count, clamped to at least one.
    ///
    /// Clamping rather than throwing: this is the value a bulk edit or a preset writes, and the
    /// worst outcome of a clamp is a row that says `×1`. The worst outcome of accepting `0` is a
    /// measurement that silently leaves the total.
    public static func cellValue(count: Int) -> ZPDFContracts.LedgerCellValue {
        .number(ZPDFContracts.DecimalQuantity(value: Decimal(max(minimumCount, count)), dimension: .ratio))
    }

    /// The command that sets a markup's repeat count.
    ///
    /// Deliberately just `.editCustomValue`: no new command case, no new undo semantics, and
    /// the audit trail records it the same way it records any other cell edit — which is what
    /// keeps the multiplier *in the audit entry*.
    public static func edit(markupID: MarkupID, count: Int) -> DocumentCommand {
        .editCustomValue(id: markupID, column: columnID, value: cellValue(count: count))
    }

    // MARK: - Arithmetic

    /// One row's quantity, repeated.
    ///
    /// `Decimal` in and `Decimal` out: repetition is an aggregate operation and the house rule
    /// is that aggregates never touch binary floating point. Multiplying by an integer count is
    /// exact in `Decimal`, so six repetitions of a value equal the sum of six copies of it,
    /// bit for bit — which is what lets a subtotal and a repeated row agree.
    ///
    /// A count below one is clamped to one rather than allowed to shrink the value, for the
    /// same reason ``cellValue(count:)`` clamps.
    public static func repeatedTotal(value: Decimal, count: Int) -> Decimal {
        value * Decimal(max(minimumCount, count))
    }

    /// The same arithmetic over a dimensioned quantity, keeping the dimension untouched.
    ///
    /// Repetition scales the magnitude and never the unit: six of a 12 m² floor is 72 m², not
    /// 72 m⁶.
    public static func repeatedTotal(value: ZPDFContracts.DecimalQuantity, count: Int) -> ZPDFContracts.DecimalQuantity {
        ZPDFContracts.DecimalQuantity(
            value: repeatedTotal(value: value.value, count: count),
            dimension: value.dimension
        )
    }

    /// The badge text for a count — `"×6"` — or `nil` for a row that repeats once.
    ///
    /// Formatted through `NumberFormatter` so the digits are the reader's, not the process's.
    public static func badgeText(count: Int) -> String? {
        guard count > defaultCount else { return nil }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        let digits = formatter.string(from: NSNumber(value: count)) ?? "\(count)"
        let format = NSLocalizedString(
            "×%@",
            comment: "Repetition badge on a ledger row and a markup: the multiplication sign and the count"
        )
        return String(format: format, digits)
    }
}
