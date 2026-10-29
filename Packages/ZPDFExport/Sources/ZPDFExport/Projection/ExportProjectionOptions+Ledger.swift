import Foundation
import ZPDFQuantityLedger

extension ExportProjectionOptions {

    /// The options every Quantity Ledger export of the whole takeoff is projected with — the
    /// application's File ▸ Export… and the `zenit` command-line tool alike (NL-PLAT-13), so the
    /// two cannot drift apart: the same document context, dates in the zone the ledger shows
    /// them in, and numbers with the precision the screen uses.
    ///
    /// - Parameter presentation: the ledger's own words and numbers — its column titles, each
    ///   row's Unit, its number locale and its filter in words (L-46). The application passes
    ///   what its ledger shows; the default keeps the report's keys and the invariant locale.
    public static func ledgerExport(
        documentName: String,
        scaleDescription: String?,
        preparedBy: String,
        screenDecimalPlaces: Int,
        rowTraces: [String: ExportRowTrace] = [:],
        timeZone: TimeZone = .current,
        staleScaleRowIDs: Set<String> = [],
        presentation: LedgerExportPresentation = LedgerExportPresentation()
    ) -> ExportProjectionOptions {
        var options = ExportProjectionOptions(
            numberLocale: presentation.numberLocale,
            document: ExportDocumentContext(
                documentName: documentName,
                scaleDescription: scaleDescription,
                preparedBy: preparedBy
            ),
            rowTraces: rowTraces,
            humanDateTimeZone: timeZone,
            screenNotation: ExportScreenNotation(decimalPlaces: screenDecimalPlaces),
            staleScaleRowIDs: staleScaleRowIDs
        )
        options.columnTitles = presentation.columnTitles
        options.rowUnitTexts = presentation.rowUnitTexts
        options.rowTypeTexts = presentation.rowTypeTexts
        options.groupLabels = presentation.groupLabels
        options.filterSummary = presentation.filterSummary
        return options
    }

    /// The ledger report's title for an export of `documentName`.
    public static func ledgerReportTitle(documentName: String) -> String {
        documentName + " — " + NSLocalizedString("Quantity Ledger", comment: "PDF report title suffix")
    }
}

/// What the ledger on screen shows that the ledger package does not know (L-46): the words its
/// columns are titled with, what its Unit column reads on each row, the number locale its cells
/// are written in, and its filter in words. Handed to ``ExportProjectionOptions/ledgerExport``
/// so the workbook, the printed report, the export profiles and the interchange JSON read as
/// the ledger and its CSV do.
public struct LedgerExportPresentation: Hashable, Sendable {
    /// Column titles by column key. See ``ExportProjectionOptions/columnTitles``.
    public var columnTitles: [String: String]
    /// The Unit column's text by markup UUID string. See ``ExportProjectionOptions/rowUnitTexts``.
    public var rowUnitTexts: [String: String]
    /// The Type column's text by markup UUID string. See ``ExportProjectionOptions/rowTypeTexts``.
    public var rowTypeTexts: [String: String]
    /// Group headings the ledger words differently from the stored key — a Type group keyed on
    /// `t:rectangleArea` reads "Rectangle Area" — by group token. See
    /// ``ExportProjectionOptions/groupLabels``.
    public var groupLabels: [String: String]
    /// The locale the numbers are written in.
    public var numberLocale: ExportNumberLocale
    /// The filter in words. See ``ExportProjectionOptions/filterSummary``.
    public var filterSummary: String?

    public init(
        columnTitles: [String: String] = [:],
        rowUnitTexts: [String: String] = [:],
        rowTypeTexts: [String: String] = [:],
        groupLabels: [String: String] = [:],
        numberLocale: ExportNumberLocale = .invariant,
        filterSummary: String? = nil
    ) {
        self.columnTitles = columnTitles
        self.rowUnitTexts = rowUnitTexts
        self.rowTypeTexts = rowTypeTexts
        self.groupLabels = groupLabels
        self.numberLocale = numberLocale
        self.filterSummary = filterSummary
    }
}
