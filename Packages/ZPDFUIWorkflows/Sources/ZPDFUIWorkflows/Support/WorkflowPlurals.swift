import Foundation
import ZPDFUIPresentation

/// The workflow sheets' count phrases, singular and plural (V-068).
///
/// Revision Compare, the symbol, room and sheet reviews, OCR, table import, batch apply and the
/// Tool Library used bare `%d` formats — "Add 1 Areas", "1 differences to review" — and "(s)"
/// workarounds — "1 cell(s) could not be read". Each phrase now goes through
/// ``LocalizedPlural``, keyed in `ZPDFUIPresentation`'s `Plurals.stringsdict`, with the English
/// one/other pair as the fallback a test bundle sees, as `LedgerPlurals` does for the ledger
/// (U-066). A sentence with two counts is built from single-count pieces, because a plural rule
/// takes one integer. `Iter5WorkflowsPluralTests.noBareCountFormatsRemain` keeps it that way.
enum WorkflowPlurals {

    /// "1 difference found, hidden by the change filter" / "4 differences found, all hidden by the change filter".
    static func differencesAllHidden(_ count: Int) -> String {
        LocalizedPlural.string(
            "%lld differences found, all hidden by the change filter", count: count,
            one: NSLocalizedString("%lld difference found, hidden by the change filter", comment: "Revision Compare header when the one detected difference is filtered out"),
            other: NSLocalizedString("%lld differences found, all hidden by the change filter", comment: "Revision Compare header when every detected difference is filtered out; the count")
        )
    }

    /// "1 difference to review" / "3 differences to review".
    static func differencesToReview(_ count: Int) -> String {
        LocalizedPlural.string(
            "%lld differences to review", count: count,
            one: NSLocalizedString("%lld difference to review", comment: "Revision Compare header: one candidate difference"),
            other: NSLocalizedString("%lld differences to review", comment: "Revision Compare header: candidate differences; the count")
        )
    }

    /// "Add 1 Area" / "Add 3 Areas" — the room review's confirm button.
    static func addAreas(_ count: Int) -> String {
        LocalizedPlural.string(
            "Add %lld Areas", count: count,
            one: NSLocalizedString("Add %lld Area", comment: "Accept one detected room as an area measurement"),
            other: NSLocalizedString("Add %lld Areas", comment: "Accept detected rooms as area measurements; the count")
        )
    }

    /// "1 room found" / "5 rooms found".
    static func roomsFound(_ count: Int) -> String {
        LocalizedPlural.string(
            "%lld rooms found", count: count,
            one: NSLocalizedString("%lld room found", comment: "Room detection review summary: one room found"),
            other: NSLocalizedString("%lld rooms found", comment: "Room detection review summary: rooms found; the count")
        )
    }

    /// "Add 1 Count" / "Add 6 Counts" — the symbol review's confirm button.
    static func addCounts(_ count: Int) -> String {
        LocalizedPlural.string(
            "Add %lld Counts", count: count,
            one: NSLocalizedString("Add %lld Count", comment: "Confirm the symbol review with one ticked place"),
            other: NSLocalizedString("Add %lld Counts", comment: "Confirm the symbol review; the number of ticked places")
        )
    }

    /// "Name 1 Sheet" / "Name 12 Sheets" — the sheet name review's confirm button.
    static func nameSheets(_ count: Int) -> String {
        LocalizedPlural.string(
            "Name %lld Sheets", count: count,
            one: NSLocalizedString("Name %lld Sheet", comment: "Accept the sheet name of one ticked sheet"),
            other: NSLocalizedString("Name %lld Sheets", comment: "Accept the sheet names; the number of ticked sheets")
        )
    }

    /// "1 needs a look before it is accepted." / "2 need a look before they are accepted."
    static func needALook(_ count: Int) -> String {
        LocalizedPlural.string(
            "%lld need a look before they are accepted.", count: count,
            one: NSLocalizedString("%lld needs a look before it is accepted.", comment: "Sheet name review summary: one flagged sheet"),
            other: NSLocalizedString("%lld need a look before they are accepted.", comment: "Sheet name review summary: flagged sheets; the count")
        )
    }

    /// "1 near miss shown" / "2 near misses shown".
    static func nearMissesShown(_ count: Int) -> String {
        LocalizedPlural.string(
            "%lld near misses shown", count: count,
            one: NSLocalizedString("%lld near miss shown", comment: "Symbol review summary: one near miss"),
            other: NSLocalizedString("%lld near misses shown", comment: "Symbol review summary: near misses; the count")
        )
    }

    /// "1 other shape did not resemble the symbol." / "212 other shapes did not resemble the symbol."
    static func otherShapes(_ count: Int) -> String {
        LocalizedPlural.string(
            "%lld other shapes did not resemble the symbol.", count: count,
            one: NSLocalizedString("%lld other shape did not resemble the symbol.", comment: "Symbol review summary: one other shape"),
            other: NSLocalizedString("%lld other shapes did not resemble the symbol.", comment: "Symbol review summary: other shapes; the count")
        )
    }

    /// "1 place matches more than one type" / "3 places match more than one type".
    static func contestedPlaces(_ count: Int) -> String {
        LocalizedPlural.string(
            "%lld places match more than one type", count: count,
            one: NSLocalizedString("%lld place matches more than one type", comment: "Symbol review summary: one contested place"),
            other: NSLocalizedString("%lld places match more than one type", comment: "Symbol review summary: contested places; the count")
        )
    }

    /// "1 still needs a pick." / "2 still need a pick."
    static func stillNeedAPick(_ count: Int) -> String {
        LocalizedPlural.string(
            "%lld still need a pick.", count: count,
            one: NSLocalizedString("%lld still needs a pick.", comment: "Symbol review summary: one unresolved contested place"),
            other: NSLocalizedString("%lld still need a pick.", comment: "Symbol review summary: unresolved contested places; the count")
        )
    }

    /// "1 symbol" / "6 symbols".
    static func symbols(_ count: Int) -> String {
        LocalizedPlural.string(
            "%lld symbols", count: count,
            one: NSLocalizedString("%lld symbol", comment: "A number of symbols, singular"),
            other: NSLocalizedString("%lld symbols", comment: "A number of symbols")
        )
    }

    /// "1 tag" / "6 tags".
    static func tags(_ count: Int) -> String {
        LocalizedPlural.string(
            "%lld tags", count: count,
            one: NSLocalizedString("%lld tag", comment: "A number of printed tags, singular"),
            other: NSLocalizedString("%lld tags", comment: "A number of printed tags")
        )
    }

    /// "1 tag with no symbol beside it is marked on the sheet." / "2 tags with no symbol beside them are marked on the sheet."
    static func orphanTags(_ count: Int) -> String {
        LocalizedPlural.string(
            "%lld tags with no symbol beside them are marked on the sheet.", count: count,
            one: NSLocalizedString("%lld tag with no symbol beside it is marked on the sheet.", comment: "Symbol review summary: one tag with no symbol"),
            other: NSLocalizedString("%lld tags with no symbol beside them are marked on the sheet.", comment: "Symbol review summary: tags with no symbol; the count")
        )
    }

    /// "1 word" / "240 words" — an OCR result's recognised words.
    static func words(_ count: Int) -> String {
        LocalizedPlural.string(
            "%lld words", count: count,
            one: NSLocalizedString("%lld word", comment: "OCR result: one recognised word"),
            other: NSLocalizedString("%lld words", comment: "OCR result: recognised word count")
        )
    }

    /// The table import refusal for recognised lines that carry no page position.
    static func linesWithoutPositions(_ count: Int) -> String {
        LocalizedPlural.string(
            "%lld recognised lines in this region carry no page positions, so they cannot be placed in a grid. Run text recognition again on this page.", count: count,
            one: NSLocalizedString("%lld recognised line in this region carries no page position, so it cannot be placed in a grid. Run text recognition again on this page.", comment: "Table import refusal detail: one line without a position"),
            other: NSLocalizedString("%lld recognised lines in this region carry no page positions, so they cannot be placed in a grid. Run text recognition again on this page.", comment: "Table import refusal detail: text without positions; the line count")
        )
    }

    /// "1 interior rule line" / "3 interior rule lines".
    static func interiorRuleLines(_ count: Int) -> String {
        LocalizedPlural.string(
            "%lld interior rule lines", count: count,
            one: NSLocalizedString("%lld interior rule line", comment: "Table import refusal detail: one rule line"),
            other: NSLocalizedString("%lld interior rule lines", comment: "Table import refusal detail: rule lines; the count")
        )
    }

    /// "1 text alignment cluster" / "2 text alignment clusters".
    static func alignmentClusters(_ count: Int) -> String {
        LocalizedPlural.string(
            "%lld text alignment clusters", count: count,
            one: NSLocalizedString("%lld text alignment cluster", comment: "Table import refusal detail: one alignment cluster"),
            other: NSLocalizedString("%lld text alignment clusters", comment: "Table import refusal detail: alignment clusters; the count")
        )
    }

    /// The table import note on cells that could not be read.
    static func unreadCells(_ count: Int) -> String {
        LocalizedPlural.string(
            "%lld cells could not be read. They stay empty — nothing is filled in for you.", count: count,
            one: NSLocalizedString("%lld cell could not be read. It stays empty — nothing is filled in for you.", comment: "Table import review: one unread cell"),
            other: NSLocalizedString("%lld cells could not be read. They stay empty — nothing is filled in for you.", comment: "Table import review: unread cell count")
        )
    }

    /// The table import warning on cells in number columns that do not read as numbers.
    static func cellsFailingNumberClaim(_ count: Int) -> String {
        LocalizedPlural.string(
            "%lld cells in number columns do not read as numbers. They keep their text exactly as read — never a zero.", count: count,
            one: NSLocalizedString("%lld cell in a number column does not read as a number. It keeps its text exactly as read — never a zero.", comment: "Table import review: one cell failing the number claim"),
            other: NSLocalizedString("%lld cells in number columns do not read as numbers. They keep their text exactly as read — never a zero.", comment: "Table import review: cells failing the number claim; the count")
        )
    }

    /// "Add 1 Read Row" / "Add 14 Read Rows" — the table import's confirm button.
    static func addReadRows(_ count: Int) -> String {
        LocalizedPlural.string(
            "Add %lld Read Rows", count: count,
            one: NSLocalizedString("Add %lld Read Row", comment: "Confirm the table import of one row"),
            other: NSLocalizedString("Add %lld Read Rows", comment: "Confirm the table import; the number of rows")
        )
    }

    /// "Import 1 Tool" / "Import 5 Tools" — the undo action name of a tool set import.
    static func importTools(_ count: Int) -> String {
        LocalizedPlural.string(
            "Import %lld Tools", count: count,
            one: NSLocalizedString("Import %lld Tool", comment: "Undo action name: a tool set import of one tool"),
            other: NSLocalizedString("Import %lld Tools", comment: "Undo action name: a tool set import; the number of tools")
        )
    }

    /// "1 tool" / "5 tools".
    static func tools(_ count: Int) -> String {
        LocalizedPlural.string(
            "%lld tools", count: count,
            one: NSLocalizedString("%lld tool", comment: "A number of tools, singular"),
            other: NSLocalizedString("%lld tools", comment: "A number of tools")
        )
    }

    /// "1 category" / "3 categories".
    static func categories(_ count: Int) -> String {
        LocalizedPlural.string(
            "%lld categories", count: count,
            one: NSLocalizedString("%lld category", comment: "A number of tool categories, singular"),
            other: NSLocalizedString("%lld categories", comment: "A number of tool categories")
        )
    }

    /// "1 image" / "2 images".
    static func images(_ count: Int) -> String {
        LocalizedPlural.string(
            "%lld images", count: count,
            one: NSLocalizedString("%lld image", comment: "A number of embedded images, singular"),
            other: NSLocalizedString("%lld images", comment: "A number of embedded images")
        )
    }

    /// The import review's note on tools the file describes that will not be added.
    static func droppedTools(_ count: Int) -> String {
        LocalizedPlural.string(
            "%lld of the tools described in the file will not be added. The reasons are listed below.", count: count,
            one: NSLocalizedString("%lld of the tools described in the file will not be added. The reason is listed below.", comment: "Import review: one preset was dropped"),
            other: NSLocalizedString("%lld of the tools described in the file will not be added. The reasons are listed below.", comment: "Import review: some presets were dropped; the count")
        )
    }

    /// The import finding for a tool with more custom column values than the limit.
    static func tooManyCustomValues(_ count: Int) -> String {
        LocalizedPlural.string(
            "This tool sets more than %lld custom column values. The extra ones were left out.", count: count,
            one: NSLocalizedString("This tool sets more than %lld custom column value. The extra ones were left out.", comment: "Import finding: too many custom defaults; a limit of one"),
            other: NSLocalizedString("This tool sets more than %lld custom column values. The extra ones were left out.", comment: "Import finding: too many custom defaults; the limit")
        )
    }

    /// The import finding for a file with more pictures than the limit.
    static func tooManyPictures(_ count: Int) -> String {
        LocalizedPlural.string(
            "This file carries more than %lld pictures. The extra ones were left out; the tools themselves were kept.", count: count,
            one: NSLocalizedString("This file carries more than %lld picture. The extra ones were left out; the tools themselves were kept.", comment: "Import finding: too many embedded images; a limit of one"),
            other: NSLocalizedString("This file carries more than %lld pictures. The extra ones were left out; the tools themselves were kept.", comment: "Import finding: too many embedded images; the limit")
        )
    }

    /// "1 matching point" / "3 matching points".
    static func matchingPoints(_ count: Int) -> String {
        LocalizedPlural.string(
            "%lld matching points", count: count,
            one: NSLocalizedString("%lld matching point", comment: "Revision alignment: one point pair"),
            other: NSLocalizedString("%lld matching points", comment: "Revision alignment: point pairs; the count")
        )
    }

    /// "1 revision" / "3 revisions".
    static func revisions(_ count: Int) -> String {
        LocalizedPlural.string(
            "%lld revisions", count: count,
            one: NSLocalizedString("%lld revision", comment: "A number of revisions, singular"),
            other: NSLocalizedString("%lld revisions", comment: "A number of revisions")
        )
    }

    /// "1 page" / "40 pages".
    static func pages(_ count: Int) -> String {
        LocalizedPlural.string(
            "%lld pages", count: count,
            one: NSLocalizedString("%lld page", comment: "A number of pages, singular"),
            other: NSLocalizedString("%lld pages", comment: "A number of pages")
        )
    }

    /// "1 point" / "4 points".
    static func points(_ count: Int) -> String {
        LocalizedPlural.string(
            "%lld points", count: count,
            one: NSLocalizedString("%lld point", comment: "A number of points, singular"),
            other: NSLocalizedString("%lld points", comment: "A number of points")
        )
    }

    /// "1 sheet" / "12 sheets".
    static func sheets(_ count: Int) -> String {
        LocalizedPlural.string(
            "%lld sheets", count: count,
            one: NSLocalizedString("%lld sheet", comment: "A number of sheets, singular"),
            other: NSLocalizedString("%lld sheets", comment: "A number of sheets")
        )
    }
}
