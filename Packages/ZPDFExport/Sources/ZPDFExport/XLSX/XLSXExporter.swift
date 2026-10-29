import Foundation
import ZPDFXlsxWriter

public struct XLSXExportOptions: Hashable, Sendable {
    public var sheetName: String
    /// A second sheet with the project metadata, the filter, the sort and the grouping. `nil`
    /// omits it. Spec 15.8 asks for project metadata in the workbook; putting it on its own sheet
    /// keeps it out of the data range that the auto-filter covers.
    public var metadataSheetName: String?
    /// libxlsxwriter's constant-memory mode. Rows are flushed as they are written, so a
    /// 100 000-row export does not hold the sheet in RAM (QUALITY_BAR 4.7).
    public var constantMemory: Bool
    /// Above this many sheet rows the exporter switches to constant-memory mode by itself, even
    /// with ``constantMemory`` false (IM-062). QUALITY_BAR 4.7 asks for the XLSX export of a large
    /// takeoff in constant-memory mode, and the application exports with the default options,
    /// so the default has to be the one that scales. `nil` never switches automatically.
    ///
    /// The two modes write the same cells, values and formats; constant-memory mode stores each
    /// string inline in its cell instead of in the shared-string table, which every spreadsheet
    /// reads the same way.
    public var constantMemoryRowThreshold: Int?
    public var includeRawColumns: Bool
    public var includeUnitColumns: Bool
    public var includeGroupColumns: Bool
    public var includeSubtotalRows: Bool
    public var includeGrandTotalRows: Bool
    public var freezeHeaderRow: Bool
    public var autoFilter: Bool
    public var minimumColumnWidth: Double
    public var maximumColumnWidth: Double
    public var rawColumnSuffix: String
    public var unitColumnSuffix: String
    public var recordTypeColumnTitle: String
    public var headerBackground: XlsxColor
    public var headerFontColor: XlsxColor
    /// Number format for the full-precision raw columns. `General` would drop digits past 11
    /// characters; 15 significant digits is the numeric policy's own crossing point.
    public var rawNumberFormat: String
    /// Write every `Sum` subtotal and grand total as a live Excel `SUM` formula over the data rows
    /// it covers, instead of as a computed number (feature 34).
    ///
    /// **Off by default, and that default is the ordinary export.** This is an option beside
    /// the normal workbook, not a replacement for it: a recipient who
    /// wants numbers gets numbers. With `includeFormulas` false this exporter writes exactly the
    /// bytes it wrote before the option existed — `XLSXFormulaTests` asserts that no `<f>` element
    /// reaches the sheet in the default mode.
    public var includeFormulas: Bool
    /// NL-PLAT-07: make the workbook readable back. `nil` (the default) writes exactly the
    /// workbook this exporter always wrote.
    public var rowIdentity: XLSXRowIdentity?
    /// NL-QTY-13: one extra sheet per top-level group, each holding that group's rows and
    /// subtotals from the same projection, after the ledger sheet. Off by default.
    public var includeGroupSheets: Bool
    /// NL-QTY-09/13: the name of the sheet the projection's ``ExportProjection/summaryMatrix``
    /// is written to. A projection without a matrix writes no such sheet.
    public var summarySheetName: String

    public init(
        sheetName: String = "Ledger",
        metadataSheetName: String? = "Report",
        constantMemory: Bool = false,
        includeRawColumns: Bool = false,
        includeUnitColumns: Bool = true,
        includeGroupColumns: Bool = true,
        includeSubtotalRows: Bool = true,
        includeGrandTotalRows: Bool = true,
        freezeHeaderRow: Bool = true,
        autoFilter: Bool = true,
        minimumColumnWidth: Double = 9,
        maximumColumnWidth: Double = 48,
        rawColumnSuffix: String = " (raw)",
        unitColumnSuffix: String = " (unit)",
        recordTypeColumnTitle: String = "Record",
        headerBackground: XlsxColor = XlsxColor(rgb: 0x1F_2933),
        headerFontColor: XlsxColor = .white,
        rawNumberFormat: String = "0.###############",
        includeFormulas: Bool = false,
        constantMemoryRowThreshold: Int? = XLSXExportOptions.defaultConstantMemoryRowThreshold
    ) {
        self.sheetName = sheetName
        self.metadataSheetName = metadataSheetName
        self.constantMemory = constantMemory
        self.constantMemoryRowThreshold = constantMemoryRowThreshold
        self.includeRawColumns = includeRawColumns
        self.includeUnitColumns = includeUnitColumns
        self.includeGroupColumns = includeGroupColumns
        self.includeSubtotalRows = includeSubtotalRows
        self.includeGrandTotalRows = includeGrandTotalRows
        self.freezeHeaderRow = freezeHeaderRow
        self.autoFilter = autoFilter
        self.minimumColumnWidth = minimumColumnWidth
        self.maximumColumnWidth = maximumColumnWidth
        self.rawColumnSuffix = rawColumnSuffix
        self.unitColumnSuffix = unitColumnSuffix
        self.recordTypeColumnTitle = recordTypeColumnTitle
        self.headerBackground = headerBackground
        self.headerFontColor = headerFontColor
        self.rawNumberFormat = rawNumberFormat
        self.includeFormulas = includeFormulas
        self.rowIdentity = nil
        self.includeGroupSheets = false
        self.summarySheetName = ExportSummaryMatrix.defaultSheetName
    }

    /// 5 000 rows: well under a second of work either way, and the point past which holding the
    /// whole sheet in memory starts to cost more than it saves.
    public static let defaultConstantMemoryRowThreshold = 5_000

    /// Whether a sheet of `rows` rows is written in constant-memory mode.
    public func usesConstantMemory(forRowCount rows: Int) -> Bool {
        if constantMemory { return true }
        guard let threshold = constantMemoryRowThreshold else { return false }
        return rows > threshold
    }
}

/// What makes an exported workbook come back (NL-PLAT-07).
///
/// With this set, the ledger sheet gains a last, hidden **Row ID** column holding each data row's
/// `markupID` (blank on total rows), and the workbook gains a sheet recording the format, the
/// project, the export time and — column by column, by the exact header text — which columns may
/// be edited in a spreadsheet and brought back, and which are read-only. A measured quantity is
/// always read-only: a quantity comes from geometry, never from a cell.
public struct XLSXRowIdentity: Hashable, Sendable {
    public static let format = "zenit.ledger.roundtrip"
    public static let version = 1
    public static let rowIDHeader = "Row ID"
    public static let defaultSheetName = "Zenit"

    public var projectID: String
    public var exportedAt: String
    /// Ledger column keys whose values a spreadsheet may change (text and money columns).
    public var editableColumnKeys: Set<String>
    public var sheetName: String
    /// NL-PLAT-09: when set, each data row's first text cell links to `revealLinkPrefix + markupID`
    /// (for example `zenitpdf://reveal?project=…&markup=`), so a click in the spreadsheet brings
    /// the markup forward in Zenit PDF. Sheets over Excel's 65 530 links per sheet get none.
    public var revealLinkPrefix: String?

    public init(projectID: String, exportedAt: String, editableColumnKeys: Set<String>, sheetName: String = XLSXRowIdentity.defaultSheetName,
                revealLinkPrefix: String? = nil) {
        self.projectID = projectID
        self.exportedAt = exportedAt
        self.editableColumnKeys = editableColumnKeys
        self.sheetName = sheetName
        self.revealLinkPrefix = revealLinkPrefix
    }
}

/// Writes an ``ExportProjection`` as a formatted XLSX workbook.
///
/// # Numbers are numbers
///
/// Every quantity cell holds a real numeric value carrying a number format. Never a string that
/// looks like a number: a string cell cannot be summed, sorted, filtered or charted, and a
/// takeoff whose quantities arrive in Excel as text is a takeoff the estimator has to retype.
///
/// The value written is ``ExportNumber/convertedRaw`` — exact, in the column's display unit, and
/// **unrounded** — with the column's number format applied, which is what QUALITY_BAR A32
/// requires: the cell holds full precision and the *rendered* string equals the on-screen string.
/// `XLSXExporterTests` asserts exactly that, by reproducing Excel's own display rounding (a
/// double is displayed via its 15-significant-digit decimal form, so `1.005` shows as `1.01`
/// under `0.00`, not the `1.00` a naive `%.2f` on the binary value would give).
///
/// # One thing a workbook cannot carry
///
/// A number-format code's `.` and `,` are placeholders that Excel replaces with the *host's*
/// separators. There is no per-cell decimal separator in the file format. So a projection made
/// with ``ExportNumberLocale/svSE`` produces the right digits in CSV, JSON and PDF, and in XLSX
/// produces the right *digits* with the separators of whatever machine opens it. That is a
/// property of XLSX, not a defect here, and it is why the cross-format digit-for-digit test runs
/// the XLSX leg under a locale whose separators are the format code's own.
public struct XLSXExporter: Sendable {

    public init() {}

    public func export(
        _ projection: ExportProjection,
        to url: URL,
        options: XLSXExportOptions = XLSXExportOptions()
    ) throws {
        let layout = Layout(table: projection.table, options: options)
        let rowsNeeded = layout.estimatedRowCount
        guard rowsNeeded <= XlsxLimits.maximumRows else {
            throw ExportError.rowLimitExceeded(rows: rowsNeeded, limit: XlsxLimits.maximumRows)
        }

        let metadata = projection.table.metadata
        let properties = XlsxDocumentProperties(
            title: metadata.title.isEmpty ? "Quantity Ledger" : metadata.title,
            subject: metadata.document.projectName,
            author: metadata.document.preparedBy ?? "Zenit PDF",
            company: metadata.document.projectName,
            category: "Quantity takeoff",
            comments: metadata.document.notes,
            status: metadata.document.revision
        )

        do {
            try XlsxWriter.write(
                to: url,
                options: XlsxWorkbookOptions(
                    constantMemory: options.usesConstantMemory(forRowCount: rowsNeeded)
                ),
                properties: properties
            ) { workbook in
                // Every fixed name is claimed before any group label, so a group called "Report"
                // or "Zenit" is the one renamed — it used to claim the name first, and the
                // metadata or round-trip sheet then failed the whole export as a duplicate
                // (R-104). The round-trip sheet is claimed first of all: its reader finds it by
                // name.
                var names = SheetNames()
                let identityName = options.rowIdentity.map { names.claim($0.sheetName) }
                let ledgerName = names.claim(options.sheetName)
                let summaryName = projection.summaryMatrix.map { _ in names.claim(options.summarySheetName) }
                let metadataName = options.metadataSheetName.map { names.claim($0) }
                let table = projection.table
                try writeLedgerSheet(
                    projection, layout: layout, options: options, workbook: workbook,
                    content: SheetContent(
                        name: ledgerName, groups: table.groups, rows: table.rows,
                        grandTotals: options.includeGrandTotalRows ? table.grandTotals : [],
                        carriesLinks: true
                    )
                )
                if let matrix = projection.summaryMatrix, let summaryName {
                    try writeSummarySheet(matrix, name: summaryName, options: options, workbook: workbook)
                }
                if options.includeGroupSheets {
                    for group in table.groups {
                        try writeLedgerSheet(
                            projection, layout: layout, options: options, workbook: workbook,
                            content: SheetContent(
                                name: names.claim(group.label), groups: [group], rows: [],
                                grandTotals: [], carriesLinks: false
                            )
                        )
                    }
                }
                if let metadataName {
                    try writeMetadataSheet(projection, name: metadataName, workbook: workbook)
                }
                if let identity = options.rowIdentity, let identityName {
                    try writeRowIdentitySheet(identity, name: identityName, layout: layout, workbook: workbook)
                }
            }
        } catch let error as XlsxError {
            throw ExportError.xlsx(error)
        }
    }

    // MARK: - The ledger sheet

    /// What one ledger-shaped sheet holds: the whole table on the ledger sheet, one top-level
    /// group on a group sheet (NL-QTY-13).
    struct SheetContent {
        let name: String
        let groups: [ExportGroup]
        let rows: [ExportRow]
        let grandTotals: [ExportTotalRow]
        /// Reveal links and the round trip read the ledger sheet only.
        let carriesLinks: Bool

        /// Rows the auto-filter covers: header excluded, data and subtotals included.
        func filterLastRow(includeSubtotals: Bool) -> Int {
            var count = rows.count
            func visit(_ group: ExportGroup) {
                count += group.rows.count + (includeSubtotals ? group.subtotals.count : 0)
                group.subgroups.forEach(visit)
            }
            groups.forEach(visit)
            return count
        }
    }

    private func writeLedgerSheet(
        _ projection: ExportProjection,
        layout: Layout,
        options: XLSXExportOptions,
        workbook: XlsxWorkbook,
        content: SheetContent
    ) throws {
        let sheet = try workbook.addWorksheet(name: content.name)
        let table = projection.table
        // NL-QTY-13: formula columns whose operands are all exported, as cell formulas.
        let rowFormulas: [Int: XLSXRowFormula] = options.includeFormulas ? layout.rowFormulas : [:]

        let header = try workbook.format(XlsxFormatSpec(
            bold: true,
            fontColor: options.headerFontColor,
            backgroundColor: options.headerBackground,
            alignment: .left,
            textWrap: true,
            bottomBorder: .thin
        ))
        let textFormat = try workbook.format(XlsxFormatSpec())
        let quotedText = try workbook.format(XlsxFormatSpec(quotePrefix: true))
        let dateFormat = try workbook.format(
            XlsxFormatSpec(numberFormat: "yyyy\\-mm\\-dd\\Thh:mm:ss\\Z")
        )
        let rawFormat = try workbook.format(XlsxFormatSpec(numberFormat: options.rawNumberFormat))
        // The raw column of a bold total row keeps the raw number format. It used to borrow
        // column 0's bold format, so the exact sum in a subtotal's raw cell was shown at that
        // column's digit count — or as General, when column 0 was text (CR-69).
        let rawBold = try workbook.format(
            XlsxFormatSpec(bold: true, numberFormat: options.rawNumberFormat, topBorder: .thin)
        )

        // One format per distinct number-format code, plain and bold, made the first time a cell
        // asks for it. The code is the cell's own (``ExportNumber/numberFormatCode``), not its
        // column's: a Count total on a three-place length column is the integer 12, and a
        // currency column with no declared precision holds 125.5 on one row and 12.3456 on the
        // next. Formatting every cell with the column's code showed `12.000`, `126` and `12`
        // where the CSV and the PDF printed `12`, `125.5` and `12.3456` (BH-139, BH-140, BH-141,
        // BH-149, BH-150). A format is workbook state, not sheet state, so adding one while rows
        // stream is safe in constant-memory mode; the cache keeps the count to the handful of
        // codes a ledger actually uses.
        var numeric: [String: XlsxFormatHandle] = [:]
        var numericBold: [String: XlsxFormatHandle] = [:]
        func numberFormat(_ code: String, bold: Bool) throws -> XlsxFormatHandle {
            if bold {
                if let cached = numericBold[code] { return cached }
                let made = try workbook.format(
                    XlsxFormatSpec(bold: true, numberFormat: code, topBorder: .thin)
                )
                numericBold[code] = made
                return made
            }
            if let cached = numeric[code] { return cached }
            let made = try workbook.format(XlsxFormatSpec(numberFormat: code))
            numeric[code] = made
            return made
        }
        // The column codes first, in column order, so a workbook's format table starts the way
        // it always did and the common case never creates a format mid-stream.
        for column in table.columns {
            guard let code = column.numberFormatCode else { continue }
            _ = try numberFormat(code, bold: false)
            _ = try numberFormat(code, bold: true)
        }
        let boldText = try workbook.format(XlsxFormatSpec(bold: true, topBorder: .thin))

        // Column widths first: in constant-memory mode the sheet is streamed, so anything that
        // is not a cell has to be declared before the rows start flowing.
        for (index, width) in layout.columnWidths.enumerated() {
            try sheet.setColumnWidth(first: index, last: index, width: width)
        }
        if let rowIDColumn = layout.rowIDColumn {
            // Hidden (width 0): the identity is for the way back, not for reading.
            try sheet.setColumnWidth(first: rowIDColumn, last: rowIDColumn, width: 0)
        }
        if options.freezeHeaderRow { try sheet.freezePanes(row: 1, column: 0) }
        // Before the rows, not after: in constant-memory mode libxlsxwriter refuses any
        // reference to a row it has already flushed, and the auto-filter references row 0.
        let filterLastRow = content.filterLastRow(includeSubtotals: options.includeSubtotalRows)
        if options.autoFilter, !layout.header.isEmpty, filterLastRow >= 1 {
            // The filter covers the header, the data and the subtotals, and deliberately **not**
            // the grand total rows: an auto-filter that hides rows while a total row stays
            // visible is how a user ends up reading a total that does not match what is on
            // screen.
            try sheet.autofilter(
                firstRow: 0,
                firstColumn: 0,
                lastRow: filterLastRow,
                lastColumn: layout.header.count - 1
            )
        }

        for (index, title) in layout.header.enumerated() {
            try sheet.writeString(row: 0, column: index, Self.cellText(title), format: header)
        }

        var cursor = 1
        /// Sheet rows that hold data, in write order. Only ever appended to, so the ranges a
        /// total sums are always rows that have already been written — which is what
        /// constant-memory mode requires and what keeps a total from summing another total.
        var dataRows: [Int] = []

        // Only when links are asked for: a workbook without them keeps exactly its old styles.
        let revealPrefix = (content.carriesLinks && layout.table.allRows().count <= 65_530)
            ? options.rowIdentity?.revealLinkPrefix : nil
        let linkFormat = revealPrefix == nil ? nil : try workbook.format(XlsxFormatSpec(fontColor: XlsxColor(rgb: 0x1F_4E_A8)))

        /// The cell formula for a data row's formula column, or `nil` when that cell is a number.
        func rowFormula(sheetColumn: Int, row: ExportRow?) -> String? {
            guard let row, let ledgerIndex = layout.ledgerColumnAtSheet[sheetColumn],
                  let formula = rowFormulas[ledgerIndex],
                  Self.holdsSIValue(row, ledgerIndex),
                  formula.operandColumns.allSatisfy({ Self.holdsSIValue(row, $0) })
            else { return nil }
            return formula.render(row: cursor + 1) { layout.sheetColumnForLedger[$0] }
        }

        func writeRow(
            _ fields: [Field], bold: Bool, sum: [Int]? = nil, outline: Int = 0, link: String? = nil,
            source: ExportRow? = nil
        ) throws {
            // IM-063: grouped rows carry their outline level, so the sheet's own outline buttons
            // collapse a group to its subtotal. Set before the row's cells — the order
            // constant-memory mode needs — and only for a grouped row, so a flat workbook is the
            // bytes it always was.
            if outline > 0 {
                try sheet.setRowOptions(cursor, level: UInt8(clamping: outline))
            }
            for (index, field) in fields.enumerated() {
                switch field {
                case .blank:
                    if bold { try sheet.writeBlank(row: cursor, column: index, format: boldText) }
                case .text(let value) where link != nil && index == layout.linkColumn && !value.isEmpty:
                    try sheet.writeURL(row: cursor, column: index, url: link!, text: Self.cellText(value), format: linkFormat)
                case .text(let value):
                    let format = bold ? boldText : (XLSXTextTable.needsFormulaGuard(value) ? quotedText : textFormat)
                    try sheet.writeString(
                        row: cursor, column: index, Self.cellText(value), format: format
                    )
                case .number(let value, let code):
                    let format = try numberFormat(code, bold: bold)
                    let number = NSDecimalNumber(decimal: value).doubleValue
                    if let sum, !layout.mixedUnitSheetColumns.contains(index),
                       let formula = Self.sumFormula(column: index, rows: sum) {
                        // The cached result is the ledger's own total, so the workbook is right
                        // before anything recalculates and stays right after it does.
                        try sheet.writeFormula(
                            row: cursor, column: index, formula, result: number, format: format
                        )
                    } else if let formula = rowFormula(sheetColumn: index, row: source) {
                        // NL-QTY-13: the engine's own result is the cached value.
                        try sheet.writeFormula(
                            row: cursor, column: index, formula, result: number, format: format
                        )
                    } else {
                        try sheet.writeNumber(row: cursor, column: index, number, format: format)
                    }
                case .rawNumber(let value):
                    let format = bold ? rawBold : rawFormat
                    let number = NSDecimalNumber(decimal: value).doubleValue
                    if let sum, let formula = Self.sumFormula(column: index, rows: sum) {
                        try sheet.writeFormula(
                            row: cursor, column: index, formula, result: number, format: format
                        )
                    } else {
                        try sheet.writeNumber(row: cursor, column: index, number, format: format)
                    }
                case .date(let value):
                    try sheet.writeDate(row: cursor, column: index, value, format: dateFormat)
                case .boolean(let flag):
                    try sheet.writeBoolean(
                        row: cursor, column: index, flag, format: bold ? boldText : textFormat
                    )
                }
            }
            cursor += 1
        }

        /// The rows a total may sum, or `nil` when this total is written as a plain number.
        ///
        /// Only `Sum` becomes a formula. `Count`, `Average`, `Min`, `Max`, `Distinct` and
        /// `WeightedTotal` are aggregates the ledger defines and Excel does not define the same
        /// way — a `WeightedTotal` written as `SUM` would be a wrong number that recalculates
        /// itself into looking authoritative.
        func sumRows(_ function: String, _ rows: [Int]) -> [Int]? {
            guard options.includeFormulas, function == "Sum", !rows.isEmpty else { return nil }
            return rows
        }

        if content.groups.isEmpty {
            for row in content.rows {
                dataRows.append(cursor)
                try writeRow(
                    layout.fields(row: row), bold: false, link: revealPrefix.map { $0 + row.markupID }, source: row
                )
            }
        } else {
            /// - Returns: the sheet rows of every data row in this group and its descendants.
            func visit(_ group: ExportGroup) throws -> [Int] {
                var owned: [Int] = []
                for row in group.rows {
                    owned.append(cursor)
                    dataRows.append(cursor)
                    try writeRow(
                        layout.fields(row: row), bold: false,
                        outline: Self.outlineLevel(groupDepth: group.depth, isSubtotal: false),
                        link: revealPrefix.map { $0 + row.markupID },
                        source: row
                    )
                }
                for subgroup in group.subgroups { owned.append(contentsOf: try visit(subgroup)) }
                guard options.includeSubtotalRows else { return owned }
                for subtotal in group.subtotals {
                    try writeRow(
                        layout.fields(total: subtotal, kind: "Subtotal", group: group),
                        bold: true,
                        sum: sumRows(subtotal.function, owned),
                        outline: Self.outlineLevel(groupDepth: group.depth, isSubtotal: true)
                    )
                }
                return owned
            }
            for group in content.groups { _ = try visit(group) }
        }

        if options.includeGrandTotalRows {
            for total in content.grandTotals {
                try writeRow(
                    layout.fields(total: total, kind: "Total", group: nil),
                    bold: true,
                    sum: sumRows(total.function, dataRows)
                )
            }
        }
    }

    /// Whether a row's cell in `column` is a number whose display value is its SI value — the
    /// only kind a spreadsheet formula computes the same way the engine does (NL-QTY-13).
    static func holdsSIValue(_ row: ExportRow, _ column: Int) -> Bool {
        guard column < row.cells.count, let number = row.cells[column].number else { return false }
        return number.raw == number.convertedRaw
    }

    // MARK: - Sheet names

    /// Sheet names the way a spreadsheet accepts them: at most 31 code points, none of
    /// `[ ] : * ? / \`, not blank, not `History`, and unique ignoring case (NL-QTY-13 — a group
    /// label is user text).
    struct SheetNames {
        private var taken: Set<String> = []

        /// The longest sheet name, in Unicode code points — what libxlsxwriter's
        /// `workbook_validate_sheet_name` counts (`lxw_utf8_strlen`), not Swift characters.
        static let maximumCodePoints = 31

        /// `name` shortened by whole characters from its end until it has at most `limit` code
        /// points, so a decomposed accent or an emoji sequence is dropped whole, never split.
        static func fitted(_ name: String, to limit: Int) -> String {
            var name = name
            while name.unicodeScalars.count > limit { name.removeLast() }
            return name
        }

        static func sanitised(_ proposed: String) -> String {
            // Cut to 31 code points first, then strip every apostrophe at either end: a
            // spreadsheet refuses a name that starts or ends with one, and stripping one before
            // cutting left "''x" and a cut that ended on one (R-104). Counting characters let a
            // 31-character, 32-code-point name through to the writer, which refused it and failed
            // the whole export (it1r R-104).
            var name = fitted(String(proposed.map { "[]:*?/\\".contains($0) ? "_" : $0 })
                .trimmingCharacters(in: .whitespacesAndNewlines), to: maximumCodePoints)
            while name.hasPrefix("'") || name.hasSuffix("'") || name.first?.isWhitespace == true || name.last?.isWhitespace == true {
                if name.hasPrefix("'") || name.first?.isWhitespace == true { name.removeFirst() } else { name.removeLast() }
            }
            if name.isEmpty || name.caseInsensitiveCompare("History") == .orderedSame { name = "Sheet" }
            return name
        }

        mutating func claim(_ proposed: String) -> String {
            let base = Self.sanitised(proposed)
            var name = base
            var suffix = 2
            while taken.contains(name.lowercased()) {
                let tail = " (\(suffix))"
                name = Self.fitted(base, to: Self.maximumCodePoints - tail.unicodeScalars.count) + tail
                suffix += 1
            }
            taken.insert(name.lowercased())
            return name
        }
    }

    // MARK: - The summary sheet (NL-QTY-09)

    /// One block per quantity column: a heading line, a header (corner, column titles, Total),
    /// one line per row group and a Total line, then a blank line. Every number is the
    /// projector's; with live formulas on, each row total and column total is a `SUM` over the
    /// cells beside it whose cached result is the ledger's own total — equal by construction,
    /// because every cell is a sum over disjoint rows.
    private func writeSummarySheet(
        _ matrix: ExportSummaryMatrix,
        name: String,
        options: XLSXExportOptions,
        workbook: XlsxWorkbook
    ) throws {
        let sheet = try workbook.addWorksheet(name: name)
        let header = try workbook.format(XlsxFormatSpec(
            bold: true, fontColor: options.headerFontColor, backgroundColor: options.headerBackground,
            alignment: .left, textWrap: true, bottomBorder: .thin
        ))
        let title = try workbook.format(XlsxFormatSpec(bold: true))
        let boldText = try workbook.format(XlsxFormatSpec(bold: true, topBorder: .thin))
        var plain: [String: XlsxFormatHandle] = [:]
        var bold: [String: XlsxFormatHandle] = [:]
        func format(_ code: String, isBold: Bool) throws -> XlsxFormatHandle {
            if isBold {
                if let cached = bold[code] { return cached }
                let made = try workbook.format(XlsxFormatSpec(bold: true, numberFormat: code, topBorder: .thin))
                bold[code] = made
                return made
            }
            if let cached = plain[code] { return cached }
            let made = try workbook.format(XlsxFormatSpec(numberFormat: code))
            plain[code] = made
            return made
        }
        let widest = ([matrix.rowAxisTitle] + matrix.rowTitles).map(\.count).max() ?? 10
        try sheet.setColumnWidth(first: 0, last: 0, width: min(max(Double(widest) + 3, 14), 48))
        if !matrix.columnTitles.isEmpty {
            let across = (matrix.columnTitles.map(\.count).max() ?? 8) + 3
            try sheet.setColumnWidth(
                first: 1, last: matrix.columnTitles.count + 1, width: min(max(Double(across), 12), 36)
            )
        }
        let totalColumn = matrix.columnTitles.count + 1
        var row = 0
        func write(_ cell: ExportCell, at column: Int, isBold: Bool, sum: String? = nil) throws {
            switch cell {
            case .number(let number):
                let value = NSDecimalNumber(decimal: number.convertedRaw).doubleValue
                let handle = try format(number.numberFormatCode, isBold: isBold)
                if options.includeFormulas, let sum {
                    try sheet.writeFormula(row: row, column: column, sum, result: value, format: handle)
                } else {
                    try sheet.writeNumber(row: row, column: column, value, format: handle)
                }
            case .blank:
                if isBold { try sheet.writeBlank(row: row, column: column, format: boldText) }
            default:
                try sheet.writeString(row: row, column: column, Self.cellText(cell.text), format: isBold ? boldText : nil)
            }
        }
        /// `SUM` over sheet cells, only when every one of them is a number — a refusal among them
        /// means the total is a refusal too, and it is written as one.
        func sum(_ cells: [ExportCell], _ range: String) -> String? {
            cells.allSatisfy({ $0.number != nil || $0 == .blank }) && cells.contains(where: { $0.number != nil })
                ? "SUM(\(range))" : nil
        }
        let lastLetter = Self.columnReference(max(1, matrix.columnTitles.count))
        for block in matrix.blocks {
            try sheet.writeString(row: row, column: 0, Self.cellText(block.heading), format: title)
            row += 1
            try sheet.writeString(row: row, column: 0, Self.cellText(matrix.rowAxisTitle + " \\ " + matrix.columnAxisTitle), format: header)
            for (index, text) in matrix.columnTitles.enumerated() {
                try sheet.writeString(row: row, column: index + 1, Self.cellText(text), format: header)
            }
            try sheet.writeString(row: row, column: totalColumn, ExportSummaryMatrix.totalTitle, format: header)
            row += 1
            let firstDataRow = row
            for (index, text) in matrix.rowTitles.enumerated() {
                try sheet.writeString(row: row, column: 0, Self.cellText(text))
                for (column, cell) in block.cells[index].enumerated() {
                    try write(cell, at: column + 1, isBold: false)
                }
                let range = "B\(row + 1):\(lastLetter)\(row + 1)"
                try write(block.rowTotals[index], at: totalColumn, isBold: true, sum: matrix.columnTitles.isEmpty ? nil : sum(block.cells[index], range))
                row += 1
            }
            try sheet.writeString(row: row, column: 0, ExportSummaryMatrix.totalTitle, format: boldText)
            for (column, cell) in block.columnTotals.enumerated() {
                let letter = Self.columnReference(column + 1)
                let range = "\(letter)\(firstDataRow + 1):\(letter)\(row)"
                let down = block.cells.map { $0[column] }
                try write(cell, at: column + 1, isBold: true, sum: matrix.rowTitles.isEmpty ? nil : sum(down, range))
            }
            let totalLetter = Self.columnReference(totalColumn)
            try write(
                block.grandTotal, at: totalColumn, isBold: true,
                sum: matrix.rowTitles.isEmpty ? nil
                    : sum(block.rowTotals, "\(totalLetter)\(firstDataRow + 1):\(totalLetter)\(row)")
            )
            row += 2
        }
    }

    // MARK: - Text cells

    /// Excel's limit on the characters in one cell; libxlsxwriter refuses a longer string.
    static let maximumCellCharacters = 32_767

    /// `text`, cut to what one cell can hold, ending in an ellipsis when it was cut.
    ///
    /// libxlsxwriter counts Unicode scalars. A pasted specification in a Notes cell used to
    /// fail the whole workbook with ``ExportError/xlsx(_:)`` while the CSV of the same
    /// projection wrote fine (BH-536); one over-long cell now loses its tail, visibly, and the
    /// ledger is exported. The CSV and the JSON keep the full text.
    static func cellText(_ text: String) -> String {
        guard text.unicodeScalars.count > maximumCellCharacters else { return text }
        let budget = maximumCellCharacters - 1
        var kept = ""
        var used = 0
        for character in text {
            let size = character.unicodeScalars.count
            if used + size > budget { break }
            kept.append(character)
            used += size
        }
        return kept + "\u{2026}"
    }

    // MARK: - Outline levels (IM-063)

    /// The Excel outline level of a sheet row, so a grouped workbook collapses to its subtotals
    /// with the sheet's own outline buttons: a data row sits one level below its group's
    /// subtotal (group depth + 1), a subtotal at its group's depth, and the header, a flat
    /// table's rows and the grand totals at level 0 — the layout a spreadsheet's own subtotal
    /// command produces. Summary rows are below the rows they summarise, which is how this
    /// exporter writes them.
    ///
    /// Excel allows levels 0-7; a deeper grouping is clamped at 7 rather than refused.
    ///
    /// - Parameters:
    ///   - groupDepth: the depth of the group the row belongs to (0 for a top-level group), or
    ///     `nil` for a row outside every group — the header, a flat table's rows, a grand total.
    ///   - isSubtotal: whether the row is that group's subtotal.
    ///
    /// Written through `XlsxWorksheet.setRowOptions` in `writeRow` (IM-063).
    static func outlineLevel(groupDepth: Int?, isSubtotal: Bool) -> Int {
        guard let groupDepth else { return 0 }
        return min(7, max(0, groupDepth) + (isSubtotal ? 0 : 1))
    }

    // MARK: - Formulas

    /// `SUM(C2:C7)`, or `SUM(C2:C4,C6:C9)` when the rows a group owns are not contiguous.
    ///
    /// They are not contiguous whenever a group has subgroups: the parent's own rows are written
    /// first, then each subgroup's rows *and that subgroup's subtotal row*, and a range spanning
    /// all of it would sum the subtotals too and double every figure it touched. So the rows are
    /// collapsed into runs and only the data rows are ever referenced.
    static func sumFormula(column: Int, rows: [Int]) -> String? {
        guard !rows.isEmpty else { return nil }
        let letter = columnReference(column)
        let sorted = rows.sorted()
        var ranges: [String] = []
        var start = sorted[0]
        var previous = sorted[0]
        func flush() {
            // Excel rows are 1-based; the sheet rows here are 0-based.
            ranges.append(
                start == previous
                    ? "\(letter)\(start + 1)"
                    : "\(letter)\(start + 1):\(letter)\(previous + 1)"
            )
        }
        for row in sorted.dropFirst() {
            if row == previous + 1 {
                previous = row
                continue
            }
            flush()
            start = row
            previous = row
        }
        flush()
        return nestedSum(ranges)
    }

    /// Excel's limit on the arguments of one function call.
    static let maximumFunctionArguments = 255
    /// Excel's limit on the length of a formula, in characters.
    static let maximumFormulaLength = 8_192

    /// `SUM(r1,...,rn)`, nested as `SUM(SUM(r1,...,r255),SUM(...))` when there are more runs
    /// than one call may take, or `nil` when even the nested formula is longer than Excel
    /// accepts — the cell is then written as the ledger's number, which is right without a
    /// formula. A grouped ledger with more than 255 subtotalled groups gives the grand total
    /// one run per group, and a flat `SUM` of 300 arguments opened with a repair prompt that
    /// stripped the formula and left the total cell empty (BH-537, BH-538).
    static func nestedSum(_ arguments: [String]) -> String? {
        var level = arguments
        while level.count > maximumFunctionArguments {
            level = stride(from: 0, to: level.count, by: maximumFunctionArguments).map { start in
                let chunk = level[start..<min(start + maximumFunctionArguments, level.count)]
                return "SUM(" + chunk.joined(separator: ",") + ")"
            }
        }
        let formula = "SUM(" + level.joined(separator: ",") + ")"
        return formula.count <= maximumFormulaLength ? formula : nil
    }

    /// A zero-based column index as its spreadsheet letters: 0 is `A`, 26 is `AA`.
    static func columnReference(_ index: Int) -> String {
        var remaining = index
        var letters = ""
        repeat {
            let digit = remaining % 26
            letters = String(UnicodeScalar(UInt8(65 + digit))) + letters
            remaining = remaining / 26 - 1
        } while remaining >= 0
        return letters
    }

    // MARK: - The metadata sheet

    private func writeMetadataSheet(
        _ projection: ExportProjection,
        name: String,
        workbook: XlsxWorkbook
    ) throws {
        let sheet = try workbook.addWorksheet(name: name)
        let key = try workbook.format(XlsxFormatSpec(bold: true, alignment: .left))
        let value = try workbook.format(XlsxFormatSpec(alignment: .left, textWrap: true))
        try sheet.setColumnWidth(first: 0, last: 0, width: 28)
        try sheet.setColumnWidth(first: 1, last: 1, width: 72)

        let metadata = projection.table.metadata
        var entries: [(String, String)] = [
            ("Report", metadata.title),
            ("Generated at", metadata.generatedAt.iso8601),
            ("Project", metadata.document.projectName ?? ""),
            ("Document", metadata.document.documentName ?? ""),
            ("Revision", metadata.document.revision ?? ""),
            ("Scale", metadata.document.scaleDescription ?? ""),
            ("Units", metadata.document.unitsDescription ?? ""),
            ("Prepared by", metadata.document.preparedBy ?? ""),
            ("Notes", metadata.document.notes ?? ""),
            ("Number locale", metadata.numberLocaleIdentifier),
            // The metadata sheet keeps the audit spellings — keys, the sort grammar, the filter
            // grammar — beside the contract versions: it is the file's provenance (L-46 keeps
            // these off the report's cover and out of the ledger sheet's headers, not out of here).
            ("Grouping", metadata.groupingColumnKeys.joined(separator: " > ")),
            ("Sort", metadata.sortDescription.joined(separator: ", ")),
            ("Filter", metadata.filterDescription),
            ("Filter rules not applied", metadata.unappliedFilterRules.joined(separator: "; ")),
            ("Rows exported", String(metadata.rowCount)),
            ("Rows before filter", String(metadata.totalRowCountBeforeFilter)),
            ("Ledger contract version", String(metadata.ledgerContractVersion)),
            ("Formula grammar version", String(metadata.formulaGrammarVersion)),
            ("libxlsxwriter", XlsxWriter.libraryVersion)
        ]
        // K-04: values kept under an older scale are said beside the scale, and only then.
        if let notice = metadata.staleScaleNotice, let scale = entries.firstIndex(where: { $0.0 == "Scale" }) {
            entries.insert(("Scale notice", notice), at: scale + 1)
        }
        // A formula column's aggregation semantics travel into every export's metadata
        // (QUALITY_BAR A24).
        for column in projection.table.columns where column.aggregationSemantics != nil {
            entries.append((
                "Formula: \(column.title)",
                "\(column.formulaCanonicalText ?? "")  [\(column.aggregationSemantics ?? "")]"
            ))
        }
        for (index, entry) in entries.enumerated() {
            try sheet.writeString(row: index, column: 0, Self.cellText(entry.0), format: key)
            try sheet.writeString(row: index, column: 1, Self.cellText(entry.1), format: value)
        }
    }

    // MARK: - Layout

    enum Field {
        case blank
        case text(String)
        /// A display-unit value with the number-format code that renders it as its text reads —
        /// the cell's own code, which is not always its column's (BH-141, BH-150).
        case number(Decimal, formatCode: String)
        case rawNumber(Decimal)
        case date(Date)
        case boolean(Bool)
    }

    // MARK: - The round-trip sheet (NL-PLAT-07)

    /// Key/value rows, then one row per ledger column: header text, ledger key, and whether a
    /// spreadsheet may change it. The reader matches columns by the header text written here.
    private func writeRowIdentitySheet(_ identity: XLSXRowIdentity, name: String, layout: Layout, workbook: XlsxWorkbook) throws {
        let sheet = try workbook.addWorksheet(name: name)
        let bold = try workbook.format(XlsxFormatSpec(bold: true))
        var row = 0
        func pair(_ key: String, _ value: String) throws {
            try sheet.writeString(row: row, column: 0, key, format: bold)
            try sheet.writeString(row: row, column: 1, Self.cellText(value))
            row += 1
        }
        try pair("Format", XLSXRowIdentity.format)
        try pair("Version", String(XLSXRowIdentity.version))
        try pair("Project", identity.projectID)
        try pair("Exported", identity.exportedAt)
        try pair("Sheet", layout.options.sheetName)
        try pair("Row ID column", XLSXRowIdentity.rowIDHeader)
        row += 1
        try sheet.writeString(row: row, column: 0, "Column", format: bold)
        try sheet.writeString(row: row, column: 1, "Key", format: bold)
        try sheet.writeString(row: row, column: 2, "Brought back", format: bold)
        row += 1
        for (index, column) in layout.table.columns.enumerated() {
            // The same text the ledger sheet's header carries: the reader matches on it.
            let header = layout.valueHeader(column, at: index)
            try sheet.writeString(row: row, column: 0, Self.cellText(header))
            try sheet.writeString(row: row, column: 1, column.key)
            let editable = identity.editableColumnKeys.contains(column.key)
            try sheet.writeString(row: row, column: 2, editable ? "editable" : "read-only")
            row += 1
        }
    }

    struct Layout {
        let table: ExportTable
        let options: XLSXExportOptions
        let header: [String]
        let columnWidths: [Double]
        let hasRecordTypeColumn: Bool
        let groupLevelCount: Int
        /// The provenance column (ADR-0012 rule 4), appended after every existing column so a
        /// reader built against the old sheet keeps reading the old cells at the old letters.
        /// Present exactly when the table carries a derived or read row; a pure-measured
        /// workbook is the workbook this exporter always wrote. Not an option: the moment the
        /// three claims can mix, the labels are there by construction.
        let hasProvenanceColumn: Bool
        /// The scale-status column (K-04), after the provenance column, present only when some
        /// row holds a value kept under an older scale.
        let hasScaleStatusColumn: Bool
        let labelsByToken: [String: String]
        /// The hidden Row ID column's index, when ``XLSXExportOptions/rowIdentity`` is set.
        let rowIDColumn: Int?
        /// The sheet column of the first text column: where a row's reveal link goes (NL-PLAT-09).
        let linkColumn: Int?
        let estimatedRowCount: Int
        /// The sheet column of each exported ledger column, and back (NL-QTY-13).
        let sheetColumnForLedger: [Int]
        let ledgerColumnAtSheet: [Int: Int]
        /// Formula columns that translate into a cell formula, by ledger column index.
        let rowFormulas: [Int: XLSXRowFormula]
        /// Numeric columns, by ledger index, where some row is shown in units of its own
        /// (NL-MEASURE-10, ADR-0035 §1.3): a markup with a display override puts, say, feet in a
        /// metre column. Their header names no unit — each row's unit column does — and no
        /// total over them is a live `SUM`, which would add feet to metres the moment the sheet
        /// recalculates. Empty for every workbook without an override, which is unchanged.
        let mixedUnitColumns: Set<Int>
        /// ``mixedUnitColumns`` as sheet columns.
        let mixedUnitSheetColumns: Set<Int>

        /// A value column's header: the title and its unit, or the title alone when the column
        /// has no unit or its rows do not share one.
        func valueHeader(_ column: ExportColumn, at index: Int) -> String {
            Self.valueHeader(column, sharesUnit: !mixedUnitColumns.contains(index))
        }

        static func valueHeader(_ column: ExportColumn, sharesUnit: Bool) -> String {
            column.heading(sharesUnit: sharesUnit)
        }

        init(table: ExportTable, options: XLSXExportOptions) {
            self.table = table
            self.options = options
            self.hasRecordTypeColumn = options.includeSubtotalRows || options.includeGrandTotalRows
            self.groupLevelCount = options.includeGroupColumns
                ? table.metadata.groupingColumnKeys.count
                : 0

            var header: [String] = []
            if hasRecordTypeColumn { header.append(options.recordTypeColumnTitle) }
            // L-46: the grouping column named as the ledger titles it — "Group: Subject".
            for title in table.metadata.groupingColumnTitles.prefix(groupLevelCount) {
                header.append("Group: \(title)")
            }
            self.hasProvenanceColumn = table.carriesProvenanceLabels
            self.hasScaleStatusColumn = table.carriesScaleStatus
            // The one answer the printed report and the export profiles read too (T-042).
            let mixedUnitColumns = table.mixedUnitColumns()
            self.mixedUnitColumns = mixedUnitColumns
            var firstText: Int?
            var sheetColumnForLedger: [Int] = []
            for (index, column) in table.columns.enumerated() {
                sheetColumnForLedger.append(header.count)
                if firstText == nil, column.kind == .text { firstText = header.count }
                header.append(Self.valueHeader(column, sharesUnit: !mixedUnitColumns.contains(index)))
                if options.includeRawColumns, column.isNumeric {
                    header.append(column.title + options.rawColumnSuffix)
                }
                if options.includeUnitColumns, column.isNumeric {
                    header.append(column.title + options.unitColumnSuffix)
                }
            }
            self.linkColumn = firstText
            self.sheetColumnForLedger = sheetColumnForLedger
            self.mixedUnitSheetColumns = Set(mixedUnitColumns.map { sheetColumnForLedger[$0] })
            self.ledgerColumnAtSheet = Dictionary(
                sheetColumnForLedger.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first }
            )
            var rowFormulas: [Int: XLSXRowFormula] = [:]
            if options.includeFormulas {
                for (index, column) in table.columns.enumerated() {
                    guard column.kind == .formula, let text = column.formulaCanonicalText,
                          let formula = XLSXRowFormula.translate(text, columns: table.columns),
                          !formula.operandColumns.contains(index)
                    else { continue }
                    rowFormulas[index] = formula
                }
            }
            self.rowFormulas = rowFormulas
            if hasProvenanceColumn { header.append(ExportRow.provenanceColumnTitle) }
            if hasScaleStatusColumn { header.append(ExportRow.scaleStatusColumnTitle) }
            // NL-PLAT-07: the identity column goes last, after every existing column, so the
            // cells a reader already knows stay at their letters.
            if options.rowIdentity != nil {
                self.rowIDColumn = header.count
                header.append(XLSXRowIdentity.rowIDHeader)
            } else {
                self.rowIDColumn = nil
            }
            self.header = header

            var labels: [String: String] = [:]
            var subtotalRows = 0
            func collect(_ groups: [ExportGroup]) {
                for group in groups {
                    labels[group.token] = group.label
                    subtotalRows += group.subtotals.count
                    collect(group.subgroups)
                }
            }
            collect(table.groups)
            self.labelsByToken = labels
            // The header, the data and subtotal rows, then the grand totals. The auto-filter's
            // own range is `SheetContent.filterLastRow(includeSubtotals:)`, the one count (V-057).
            let dataAndSubtotals = table.metadata.rowCount + (options.includeSubtotalRows ? subtotalRows : 0)
            self.estimatedRowCount = 1 + dataAndSubtotals
                + (options.includeGrandTotalRows ? table.grandTotals.count : 0)

            // Width from the widest string that will actually be in the column, capped. One pass
            // over the header plus a bounded sample of rows: a full scan of 100 000 rows to size
            // a column is not worth the seconds it costs, and the cap makes it moot anyway.
            var widths = header.map { Double($0.count) + 3 }
            let sample = table.allRows().prefix(2_000)
            for row in sample {
                var index = hasRecordTypeColumn ? 1 : 0
                index += groupLevelCount
                for (columnIndex, column) in table.columns.enumerated() where index < widths.count {
                    let cell = columnIndex < row.cells.count ? row.cells[columnIndex] : .blank
                    widths[index] = max(widths[index], Double(cell.text.count) + 2)
                    index += 1
                    if options.includeRawColumns, column.isNumeric {
                        if index < widths.count {
                            widths[index] = max(
                                widths[index],
                                Double((cell.number?.invariantRawText.count ?? 0) + 2)
                            )
                        }
                        index += 1
                    }
                    if options.includeUnitColumns, column.isNumeric { index += 1 }
                }
            }
            self.columnWidths = widths.map {
                min(max($0, options.minimumColumnWidth), options.maximumColumnWidth)
            }
        }

        func fields(row: ExportRow) -> [Field] {
            var fields: [Field] = []
            fields.reserveCapacity(header.count)
            if hasRecordTypeColumn { fields.append(.text("Row")) }
            for level in 0..<groupLevelCount {
                fields.append(
                    level < row.groupPath.count
                        ? .text(labelsByToken[row.groupPath[level]] ?? row.groupPath[level])
                        : .blank
                )
            }
            for (index, column) in table.columns.enumerated() {
                append(index < row.cells.count ? row.cells[index] : .blank,
                       column: column, to: &fields)
            }
            // A string cell, deliberately: "measured" is a claim, not a quantity, and a reader
            // filtering the sheet filters it by the word.
            if hasProvenanceColumn { fields.append(.text(row.provenance)) }
            if hasScaleStatusColumn { fields.append(row.keptUnderOlderScale ? .text(row.scaleStatusText) : .blank) }
            if rowIDColumn != nil { fields.append(.text(row.markupID)) }
            return fields
        }

        func fields(total: ExportTotalRow, kind: String, group: ExportGroup?) -> [Field] {
            var fields: [Field] = []
            fields.reserveCapacity(header.count)
            if hasRecordTypeColumn { fields.append(.text("\(kind): \(total.function)")) }
            for level in 0..<groupLevelCount {
                if let group, level < group.path.count {
                    fields.append(.text(labelsByToken[group.path[level]] ?? group.path[level]))
                } else if group == nil, level == 0 {
                    fields.append(.text(table.metadata.title))
                } else {
                    fields.append(.blank)
                }
            }
            // L-46: a counting line says nothing under a column of words.
            let cells = table.printedCells(of: total)
            for (index, column) in table.columns.enumerated() {
                append(index < cells.count ? cells[index] : .blank,
                       column: column, to: &fields)
            }
            // An aggregate of rows whose claims may differ has no provenance of its own.
            if hasProvenanceColumn { fields.append(.blank) }
            if hasScaleStatusColumn { fields.append(.blank) }
            if rowIDColumn != nil { fields.append(.blank) }
            return fields
        }

        private func append(
            _ cell: ExportCell,
            column: ExportColumn,
            to fields: inout [Field]
        ) {
            switch cell {
            case .blank: fields.append(.blank)
            case .text(let text): fields.append(.text(text))
            case .boolean(let flag): fields.append(.boolean(flag))
            case .date(let value): fields.append(.date(value.date))
            case .refusal(let token): fields.append(.text(token))
            case .number(let number):
                fields.append(.number(number.convertedRaw, formatCode: number.numberFormatCode))
            }
            guard column.isNumeric else { return }
            if options.includeRawColumns {
                if let number = cell.number {
                    fields.append(.rawNumber(number.raw))
                } else {
                    fields.append(cell.isRefusal ? .text(cell.text) : .blank)
                }
            }
            if options.includeUnitColumns {
                fields.append(.text(cell.number?.unitSymbol ?? (cell.isRefusal ? "" : column.unitSymbol)))
            }
        }
    }
}
