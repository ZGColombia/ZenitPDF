import Foundation
import CoreGraphics
import CoreText

/// Renders an ``ExportProjection`` as a paginated PDF report with Core Graphics.
///
/// # What is on the page
///
/// A cover block (project, document, revision, date, scale, units, plus the filter, sort and
/// grouping the numbers were produced under), then the table: grouped, with a heading per group,
/// a subtotal row per group, a grand total at the end, the column header repeated at the top of
/// every page, and a page number on every page. Optionally, an appendix of page images with the
/// markups drawn on them.
///
/// # Which columns are printed
///
/// The ones with something in them, plus the identity columns — see
/// ``printedColumns(table:options:)``. A `LedgerReport` carries every column the store defines,
/// and printing the forty of them so that thirty can be blank turns a three-row takeoff into a
/// seven-page report (live-test finding LT-18). The bands below cover the surviving columns only.
///
/// # A table wider than the page: **continuation bands**
///
/// Three strategies exist and only one of them is honest at 20 columns.
///
/// - *Shrink* the type until it fits. At 20 columns on A4 that is about 3.5 pt — unreadable, and
///   it fails silently: the report looks fine in a thumbnail and cannot be read on paper.
/// - *Wrap* cells onto multiple lines. Row heights stop being uniform, the eye loses the row, and
///   a 10 000-row report grows unpredictably.
/// - *Continue on a second band*, which is what this renderer does.
///
/// Columns are packed left to right into as many **bands** as the usable page width needs. Band 1
/// is printed for every row, then band 2 for every row, and so on. Each band repeats the table's
/// first column — the row's identity — so a reader can line band 2 up against band 1, and each
/// band's page header says `Columns 8-14 of 20 (band 2 of 3)`. A column too wide for a whole band
/// on its own is clipped to the band and its text is ellipsised, never silently truncated.
///
/// The trade-off, stated: a three-band report is three times as many pages. That is the price of
/// a wide table on a narrow page, and it is paid visibly rather than by shrinking the type to
/// something nobody can read.
///
/// # Memory
///
/// The renderer holds one flattened list of line descriptors — a group heading, a row, or a
/// subtotal — and draws straight into the `CGContext`, one page at a time. Nothing accumulates:
/// no per-page layout tree, no image of a page, no array of laid-out text. `CTLine`s are created
/// per cell and released at the end of the cell.
public struct PDFReportRenderer: Sendable {

    public init() {}

    public func render(
        _ projection: ExportProjection,
        to url: URL,
        options: PDFReportOptions = PDFReportOptions(),
        appendix: [PDFReportAppendixPage] = [],
        auditAppendix: PDFReportAuditAppendix? = nil
    ) throws -> PDFReportResult {
        let table = projection.table
        var mediaBox = CGRect(
            x: 0, y: 0, width: options.pageSize.width, height: options.pageSize.height
        )
        let info: [CFString: Any] = [
            kCGPDFContextTitle: table.metadata.title.isEmpty ? "Quantity Ledger" : table.metadata.title,
            kCGPDFContextCreator: "Zenit PDF",
            kCGPDFContextAuthor: table.metadata.document.preparedBy ?? "Zenit PDF",
            // L-46: the contract, grammar and number-locale versions are the file's provenance,
            // not the reader's business: they live in the document information, off the cover.
            kCGPDFContextKeywords: Self.provenanceKeywords(table.metadata)
        ]
        guard let context = CGContext(
            url as CFURL, mediaBox: &mediaBox, info as CFDictionary
        ) else {
            throw ExportError.pdfContextUnavailable(path: url.path(percentEncoded: false))
        }

        let body = CTFontCreateWithName(options.fontName as CFString, options.bodyFontSize, nil)
        let bold = CTFontCreateWithName(options.boldFontName as CFString, options.bodyFontSize, nil)
        let title = CTFontCreateWithName(options.boldFontName as CFString, options.titleFontSize, nil)
        let subtitle = CTFontCreateWithName(options.fontName as CFString, options.bodyFontSize + 3, nil)

        var painter = Painter(
            context: context,
            mediaBox: mediaBox,
            options: options,
            body: body,
            bold: bold,
            title: title,
            subtitle: subtitle
        )

        // One answer for the widths and the painter, so a heading measured without its unit is
        // drawn without it (T-042).
        let mixedUnitColumns = table.mixedUnitColumns()
        painter.mixedUnitColumns = mixedUnitColumns
        let widths = Self.columnWidths(
            table: table, options: options, font: bold, bodyFont: body, mixedUnitColumns: mixedUnitColumns
        )
        let usable = options.pageSize.width - options.margins.left - options.margins.right
        // LT-18: the bands cover the columns the report prints, not every column the ledger
        // defines. A column dropped here costs no band, no page and no heading.
        let printed = Self.printedColumns(table: table, options: options)
        let bands = try Self.bands(
            widths: widths, usable: usable, options: options, columns: printed
        )
        let lines = Self.flatten(table: table, options: options)

        if options.includeCoverPage { painter.drawCover(table) }

        for (index, band) in bands.enumerated() {
            painter.drawTableBand(
                band,
                bandIndex: index,
                bandCount: bands.count,
                widths: widths,
                table: table,
                printedColumnCount: printed.count,
                lines: lines
            )
        }

        if let matrix = projection.summaryMatrix { painter.drawSummaryMatrix(matrix) }
        for page in appendix { painter.drawAppendixPage(page) }
        if let auditAppendix { painter.drawAuditAppendix(auditAppendix) }

        painter.finish()
        context.closePDF()

        var result = PDFReportResult(
            pageCount: painter.pageCount,
            bandCount: bands.count,
            drawnText: painter.drawnText,
            printedColumnCount: printed.count,
            drawnLabels: painter.drawnLabels,
            drawnMarks: painter.drawnMarks,
            rightMarginOverrun: painter.rightMarginOverrun
        )
        result.drewLogo = painter.drewLogo
        result.drawnCompanyLines = painter.drawnCompanyLines
        result.drawnMatrixText = painter.drawnMatrixText
        result.matrixPageCount = painter.matrixPageCount
        return result
    }

    // MARK: - Total-line labels

    /// The label a subtotal line carries in its identity column: `Sum: Concrete`.
    static func subtotalLabel(function: String, groupLabel: String) -> String {
        "\(function): \(groupLabel)"
    }

    /// The label a grand-total line carries in its identity column: `Sum (all rows)`.
    static func grandTotalLabel(function: String) -> String {
        "\(function) (all rows)"
    }

    /// What the identity cell of a total line reads: the label, followed by the cell's own
    /// aggregate when the column has one.
    ///
    /// The label used to be drawn only when that cell was blank, and the identity column of a
    /// *Count* line is never blank — it holds the count — so every Count line on every report
    /// lost its "Count: Concrete" and a reader could not tell it from the Sum line above it
    /// (CR-61). The label names the line; the cell's number follows it.
    static func totalCellText(label: String, cellText: String) -> String {
        cellText.isEmpty ? label : "\(label)  \(cellText)"
    }

    // MARK: - Column geometry

    /// A column band: the indices of the columns on it, in order. ``identityColumn`` is repeated
    /// in every band after the first.
    ///
    /// The indices are into ``ExportTable/columns``, so a band still lines up with a row's cells
    /// after ``printedColumns(table:options:)`` has dropped the empty ones. The *ordinals* are
    /// positions among the printed columns, because that is what the page header counts: a
    /// caption reading "Columns 8-14 of 20" over a report that prints twelve columns would be
    /// counting something the reader cannot see.
    struct Band: Hashable {
        var columns: [Int]
        var firstOriginalColumn: Int
        var lastOriginalColumn: Int
        /// 1-based position of ``firstOriginalColumn`` among the printed columns.
        var firstPrintedOrdinal: Int
        /// 1-based position of ``lastOriginalColumn`` among the printed columns.
        var lastPrintedOrdinal: Int
        /// The first printed column — the row's identity, repeated on every continuation band.
        var identityColumn: Int
    }

    /// - Parameter mixedUnitColumns: ``ExportTable/mixedUnitColumns()``, when the caller has it;
    ///   `nil` works it out.
    static func columnWidths(
        table: ExportTable,
        options: PDFReportOptions,
        font header: CTFont,
        bodyFont: CTFont,
        mixedUnitColumns: Set<Int>? = nil
    ) -> [Double] {
        let mixed = mixedUnitColumns ?? table.mixedUnitColumns()
        var widths = table.columns.enumerated().map { index, column -> Double in
            let text = column.heading(sharesUnit: !mixed.contains(index))
            return TextMeasure.width(text, font: header) + options.columnPadding * 2
        }
        // A bounded sample: enough to size a column honestly, cheap enough not to be a second
        // pass over 100 000 rows.
        for row in table.allRows().prefix(400) {
            for (index, cell) in row.cells.enumerated() where index < widths.count {
                widths[index] = max(
                    widths[index],
                    // The printed string, not the projection's: a date column sized for
                    // "2026-08-29T14:55:25Z" would be half again too wide for "29 Aug 2026",
                    // and a number in a column of mixed units carries its unit (T-042).
                    TextMeasure.width(cell.printedText(inMixedUnitColumn: mixed.contains(index)), font: bodyFont)
                        + options.columnPadding * 2
                )
            }
        }
        // CR-60: subtotal and grand-total lines are printed in bold and hold the widest string
        // a column ever carries — a refusal token such as `#MIXED_UNITS[m|m²]` — but were never
        // measured, so the one string that says "this total is not a number" was the one the
        // report ellipsised. Totals are few; every one of them is measured, label included.
        let identity = options.dropsEmptyColumns
            ? printedColumns(table: table, options: options).first
            : table.columns.indices.first
        var totalLines: [(cells: [ExportCell], label: String)] = []
        func collect(_ group: ExportGroup) {
            if options.includeGroupSubtotals {
                for subtotal in group.subtotals {
                    totalLines.append((
                        table.printedCells(of: subtotal),
                        subtotalLabel(function: subtotal.function, groupLabel: group.printedLabel)
                    ))
                }
            }
            for subgroup in group.subgroups { collect(subgroup) }
        }
        for group in table.groups { collect(group) }
        if options.includeGrandTotals {
            for total in table.grandTotals {
                totalLines.append((table.printedCells(of: total), grandTotalLabel(function: total.function)))
            }
        }
        for line in totalLines.prefix(2_000) {
            for (index, cell) in line.cells.enumerated() where index < widths.count {
                var text = cell.printedText(inMixedUnitColumn: mixed.contains(index))
                if index == identity { text = totalCellText(label: line.label, cellText: text) }
                widths[index] = max(
                    widths[index],
                    TextMeasure.width(text, font: header) + options.columnPadding * 2
                )
            }
        }
        return widths.map { min(max($0, options.minimumColumnWidth), options.maximumColumnWidth) }
    }

    /// - Parameter columns: the columns to band, as indices into `widths`, in print order.
    ///   `nil` bands every column — which is what a caller with no ``ExportTable`` in hand, such
    ///   as a geometry test, means.
    static func bands(
        widths: [Double],
        usable: Double,
        options: PDFReportOptions,
        columns printed: [Int]? = nil
    ) throws -> [Band] {
        let printed = printed ?? Array(widths.indices)
        guard !printed.isEmpty else {
            return [Band(
                columns: [], firstOriginalColumn: 0, lastOriginalColumn: 0,
                firstPrintedOrdinal: 0, lastPrintedOrdinal: 0, identityColumn: 0
            )]
        }
        guard usable >= options.minimumColumnWidth else {
            throw ExportError.pageTooSmallForTable(usableWidth: usable)
        }
        // A single column wider than the page is clipped to the page rather than refused: the
        // alternative is an export that fails because someone typed a long comment.
        let clamped = widths.map { min($0, usable) }
        let identity = printed[0]

        var bands: [Band] = []
        var slot = 0
        while slot < printed.count {
            var columns: [Int] = []
            var used = 0.0
            // Every band after the first repeats the identity column, so the reader can line the
            // continuation up against the first band. It is dropped only when the identity plus
            // one data column would not fit at all.
            if !bands.isEmpty, slot != 0, clamped[identity] + clamped[printed[slot]] <= usable {
                columns.append(identity)
                used = clamped[identity]
            }
            let firstSlot = slot
            var lastSlot = slot
            while slot < printed.count {
                let width = clamped[printed[slot]]
                if !columns.isEmpty, used + width > usable { break }
                columns.append(printed[slot])
                used += width
                lastSlot = slot
                slot += 1
            }
            bands.append(Band(
                columns: columns,
                firstOriginalColumn: printed[firstSlot],
                lastOriginalColumn: printed[lastSlot],
                firstPrintedOrdinal: firstSlot + 1,
                lastPrintedOrdinal: lastSlot + 1,
                identityColumn: identity
            ))
        }
        return bands
    }

    // MARK: - Line flattening

    /// One printable line of the table. Building this once, as a flat list, is what keeps the
    /// renderer from recursing over the group tree on every page and from holding a layout.
    enum Line {
        case groupHeading(label: String, depth: Int, rowCount: Int)
        case row(ExportRow)
        case subtotal(label: String, depth: Int, function: String, cells: [ExportCell])
        case grandTotal(function: String, cells: [ExportCell])
    }

    /// The machine provenance the report carries in its document information rather than on
    /// its cover (L-46): `Ledger contract v1; Formula grammar v1; Number locale sv_SE`.
    static func provenanceKeywords(_ metadata: ExportMetadata) -> String {
        "Ledger contract v\(metadata.ledgerContractVersion); Formula grammar v\(metadata.formulaGrammarVersion); "
            + "Number locale \(metadata.numberLocaleIdentifier)"
    }

    static func flatten(table: ExportTable, options: PDFReportOptions) -> [Line] {
        var lines: [Line] = []
        lines.reserveCapacity(table.metadata.rowCount + 16)
        func visit(_ group: ExportGroup) {
            if options.includeGroupHeadings {
                // The printed label: a date group is headed by its day spelled as a person reads
                // it, not by the ISO date the parsed formats carry (BH-532, C-10).
                lines.append(.groupHeading(
                    label: group.printedLabel, depth: group.depth, rowCount: group.rowCount
                ))
            }
            for row in group.rows { lines.append(.row(row)) }
            for subgroup in group.subgroups { visit(subgroup) }
            guard options.includeGroupSubtotals else { return }
            for subtotal in group.subtotals {
                lines.append(.subtotal(
                    label: group.printedLabel,
                    depth: group.depth,
                    function: subtotal.function,
                    cells: table.printedCells(of: subtotal)
                ))
            }
        }
        if table.groups.isEmpty {
            for row in table.rows { lines.append(.row(row)) }
        } else {
            for group in table.groups { visit(group) }
        }
        if options.includeGrandTotals {
            for total in table.grandTotals {
                lines.append(.grandTotal(function: total.function, cells: table.printedCells(of: total)))
            }
        }
        return lines
    }
}

/// Text measurement, kept in one place so the layout and the drawing agree.
enum TextMeasure {
    static func width(_ text: String, font: CTFont) -> Double {
        guard !text.isEmpty else { return 0 }
        let attributed = NSAttributedString(
            string: text,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        return CTLineGetTypographicBounds(line, nil, nil, nil)
    }
}
