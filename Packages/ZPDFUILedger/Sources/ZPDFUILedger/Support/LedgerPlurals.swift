import Foundation
import ZPDFUIPresentation

/// The ledger panels' count phrases, singular and plural (U-066).
///
/// Every one of these used a bare `%d` format, so the most common case — one row — read
/// "Price 1 Rows", "1 rows" and "1 selected measurements", in English and in Swedish. Each now
/// goes through ``LocalizedPlural``, keyed in `ZPDFUIPresentation`'s `Plurals.stringsdict` (en
/// and sv), with the English one/other pair as the fallback a test bundle sees.
///
/// This is the package's only home for a count phrase: no format in `ZPDFUILedger` pairs a
/// bare `%d` with a noun. A sentence with two counts — "Ledger, 412 rows, 3 groups" — is built
/// from single-count pieces ("Ledger, %1$@, %2$@" over ``rows(_:)`` and ``groups(_:)``), because
/// a `Plurals.stringsdict` rule takes one integer (U-066 re-fix).
enum LedgerPlurals {

    /// "1 row" / "3 rows".
    static func rows(_ count: Int) -> String {
        LocalizedPlural.string(
            "%lld rows", count: count,
            one: NSLocalizedString("%lld row", comment: "A number of ledger rows, singular"),
            other: NSLocalizedString("%lld rows", comment: "A number of ledger rows")
        )
    }

    /// "Price 1 Row" / "Price 3 Rows" — the Rate Library's apply button.
    static func priceRows(_ count: Int) -> String {
        LocalizedPlural.string(
            "Price %lld Rows", count: count,
            one: NSLocalizedString("Price %lld Row", comment: "Rate library: apply an item to the selected row"),
            other: NSLocalizedString("Price %lld Rows", comment: "Rate library: apply an item to the selected rows; the count")
        )
    }

    /// The Rate Library's confirmation after pricing rows.
    static func pricedRows(_ count: Int) -> String {
        LocalizedPlural.string(
            "Priced %lld rows. Undo takes it back.", count: count,
            one: NSLocalizedString("Priced %lld row. Undo takes it back.", comment: "Rate library: one row priced with an item"),
            other: NSLocalizedString("Priced %lld rows. Undo takes it back.", comment: "Rate library: rows priced with an item")
        )
    }

    /// The Rate Library's confirmation after updating rates.
    static func updatedRates(_ count: Int) -> String {
        LocalizedPlural.string(
            "Updated the rate on %lld rows. Undo takes it back.", count: count,
            one: NSLocalizedString("Updated the rate on %lld row. Undo takes it back.", comment: "Rate library: one rate updated"),
            other: NSLocalizedString("Updated the rate on %lld rows. Undo takes it back.", comment: "Rate library: rates updated")
        )
    }

    /// The Rate Library's heading over rows priced at an older rate.
    static func staleRates(_ count: Int) -> String {
        LocalizedPlural.string(
            "%lld rows are priced at an older rate", count: count,
            one: NSLocalizedString("%lld row is priced at an older rate", comment: "Rate library: one row has a stale rate"),
            other: NSLocalizedString("%lld rows are priced at an older rate", comment: "Rate library: how many rows have a stale rate")
        )
    }

    /// The Apply Assembly panel's subtitle.
    static func selectedMeasurements(_ count: Int) -> String {
        LocalizedPlural.string(
            "%lld selected measurements", count: count,
            one: NSLocalizedString("%lld selected measurement", comment: "Assembly panel subtitle: one row"),
            other: NSLocalizedString("%lld selected measurements", comment: "Assembly panel subtitle: how many rows")
        )
    }

    /// The recipe editor's note on rows a save brought up to date.
    static func measuredRowsUpdated(_ count: Int) -> String {
        LocalizedPlural.string(
            "%lld measured rows now use it; Undo takes them back.", count: count,
            one: NSLocalizedString("%lld measured row now uses it; Undo takes it back.", comment: "Assembly recipe editor: one row brought up to date by a save"),
            other: NSLocalizedString("%lld measured rows now use it; Undo takes them back.", comment: "Assembly recipe editor: rows brought up to date by a save")
        )
    }

    /// The recipe editor's note on locked rows a save left alone.
    static func lockedRowsKept(_ count: Int) -> String {
        LocalizedPlural.string(
            "%lld locked rows keep the old recipe.", count: count,
            one: NSLocalizedString("%lld locked row keeps the old recipe.", comment: "Assembly recipe editor: one locked row not brought up to date"),
            other: NSLocalizedString("%lld locked rows keep the old recipe.", comment: "Assembly recipe editor: locked rows not brought up to date")
        )
    }

    /// The Column Manager's summary of a choice column.
    static func options(_ count: Int) -> String {
        LocalizedPlural.string(
            "%lld options", count: count,
            one: NSLocalizedString("%lld option", comment: "Column Manager: one option in a choice column"),
            other: NSLocalizedString("%lld options", comment: "Column Manager: number of options in a choice column")
        )
    }

    // MARK: - Single-count pieces (U-066 re-fix)

    /// "1 markup" / "3 markups".
    static func markups(_ count: Int) -> String {
        LocalizedPlural.string(
            "%lld markups", count: count,
            one: NSLocalizedString("%lld markup", comment: "Count of markups, singular"),
            other: NSLocalizedString("%lld markups", comment: "Count of markups, plural")
        )
    }

    /// "1 markup selected" / "3 markups selected" — the bulk-edit panel's subtitle.
    static func markupsSelected(_ count: Int) -> String {
        LocalizedPlural.string(
            "%lld markups selected", count: count,
            one: NSLocalizedString("%lld markup selected", comment: "Bulk edit subtitle: one selected markup"),
            other: NSLocalizedString("%lld markups selected", comment: "Bulk edit subtitle: number of selected markups")
        )
    }

    /// "1 group" / "3 groups".
    static func groups(_ count: Int) -> String {
        LocalizedPlural.string(
            "%lld groups", count: count,
            one: NSLocalizedString("%lld group", comment: "A number of ledger groups, singular"),
            other: NSLocalizedString("%lld groups", comment: "A number of ledger groups")
        )
    }

    /// "1 rule" / "3 rules" — the rules switched on in a filter group.
    static func rules(_ count: Int) -> String {
        LocalizedPlural.string(
            "%lld rules", count: count,
            one: NSLocalizedString("%lld rule", comment: "A number of ledger filter rules, singular"),
            other: NSLocalizedString("%lld rules", comment: "A number of ledger filter rules")
        )
    }

    /// "1 changed field" / "3 changed fields" — a bulk edit's staged fields.
    static func changedFields(_ count: Int) -> String {
        LocalizedPlural.string(
            "%lld changed fields", count: count,
            one: NSLocalizedString("%lld changed field", comment: "Bulk edit: one field the edit changes"),
            other: NSLocalizedString("%lld changed fields", comment: "Bulk edit: number of fields the edit changes")
        )
    }

    /// "1 item imported" / "3 items imported" — the Rate Library's import outcome.
    static func itemsImported(_ count: Int) -> String {
        LocalizedPlural.string(
            "%lld items imported", count: count,
            one: NSLocalizedString("%lld item imported", comment: "Rate library: one item imported from a pasted list"),
            other: NSLocalizedString("%lld items imported", comment: "Rate library: number of items imported from a pasted list")
        )
    }

    /// "1 line not read" / "3 lines not read" — the pasted lines the import could not read.
    static func linesNotRead(_ count: Int) -> String {
        LocalizedPlural.string(
            "%lld lines not read", count: count,
            one: NSLocalizedString("%lld line not read", comment: "Rate library: one pasted line the import could not read"),
            other: NSLocalizedString("%lld lines not read", comment: "Rate library: number of pasted lines the import could not read")
        )
    }

    /// "of 1 row matches" / "of 12 rows match" — the total half of the filter's match count;
    /// the noun and the verb agree with the total.
    static func ofRowsMatch(_ total: Int) -> String {
        LocalizedPlural.string(
            "of %lld rows match", count: total,
            one: NSLocalizedString("of %lld row matches", comment: "Ledger filter match count, after the matching count: the total, one row"),
            other: NSLocalizedString("of %lld rows match", comment: "Ledger filter match count, after the matching count: the total rows")
        )
    }

    // MARK: - Sentences over the pieces

    /// "Ledger, 1 row" / "Ledger, 412 rows, 3 groups" — the head of the ledger's spoken summary;
    /// the groups are named only when there are any.
    static func ledgerSummary(rows rowCount: Int, groups groupCount: Int) -> String {
        guard groupCount > 0 else {
            return String(format: NSLocalizedString(
                "Ledger, %1$@",
                comment: "VoiceOver summary of the Quantity Ledger: the row count as '5 rows'"
            ), rows(rowCount))
        }
        return String(format: NSLocalizedString(
            "Ledger, %1$@, %2$@",
            comment: "VoiceOver summary of the Quantity Ledger: the row count as '5 rows', the group count as '3 groups'"
        ), rows(rowCount), groups(groupCount))
    }

    /// "Label: 1 markup" — one line of the bulk edit's per-field summary.
    static func markupsPerField(_ columnTitle: String, count: Int) -> String {
        String(format: NSLocalizedString(
            "%1$@: %2$@",
            comment: "Bulk edit per-field summary: column title, the markup count as '3 markups'"
        ), columnTitle, markups(count))
    }

    /// "Applies 1 changed field to 1 markup." — the bulk edit's confirmation above Apply.
    static func bulkEditApplies(fields fieldCount: Int, markups markupCount: Int) -> String {
        String(format: NSLocalizedString(
            "Applies %1$@ to %2$@.",
            comment: "Bulk edit confirmation: the field count as '2 changed fields', the markup count as '5 markups'"
        ), changedFields(fieldCount), markups(markupCount))
    }

    /// "Match all group, 1 rule" — a filter group's VoiceOver label.
    static func filterGroupLabel(_ conjunctionName: String, ruleCount: Int) -> String {
        String(format: NSLocalizedString(
            "%1$@ group, %2$@",
            comment: "Accessibility label of a filter group: conjunction name, the rule count as '2 rules'"
        ), conjunctionName, rules(ruleCount))
    }

    /// "1 item imported, 0 lines not read." — the Rate Library's import outcome.
    static func importOutcome(imported: Int, rejected: Int) -> String {
        String(format: NSLocalizedString(
            "%1$@, %2$@.",
            comment: "Rate library import outcome: '3 items imported', '1 line not read'"
        ), itemsImported(imported), linesNotRead(rejected))
    }

    /// "1 of 1 row matches" / "3 of 12 rows match" — the filter panel's live match count.
    static func rowsMatch(_ matching: Int, of total: Int) -> String {
        String.localizedStringWithFormat(NSLocalizedString(
            "%1$lld %2$@",
            comment: "Ledger filter live match count: the matching rows, then the total as 'of 12 rows match'"
        ), matching, ofRowsMatch(total))
    }
}
