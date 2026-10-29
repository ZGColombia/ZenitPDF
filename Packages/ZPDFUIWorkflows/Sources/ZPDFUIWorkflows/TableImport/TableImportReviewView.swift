import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

/// The review panel a selected schedule becomes before it becomes rows (feature 31).
///
/// Everything on this panel exists so the person can check the engine's reading against the
/// drawing before anything is imported: the grid exactly as it was read, unread cells marked
/// in words, text the OCR read but could not file, and — on every row leader — the ⌐ marker
/// that will follow these rows into the Quantity Ledger, because a row read off a schedule
/// is a different claim than a measurement (ADR-0012) and the person should see that claim
/// **before** accepting, not discover it after.
///
/// A refusal renders as a full-panel state with the reason in plain words. There is no
/// empty grid pretending success, and no import button to press.
public struct TableImportReviewView: View {

    @Bindable private var model: TableImportReviewModel

    /// Creates the panel over its model.
    public init(model: TableImportReviewModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.m) {
            switch model.content {
            case .table:
                header
                readRowLegend
                subjectPicker
                ScrollView([.horizontal, .vertical]) {
                    if model.usesLazyRows {
                        lazyGrid
                            .padding(.bottom, ZPDFSpacing.m)
                    } else {
                        grid
                            .padding(.bottom, ZPDFSpacing.m)
                    }
                }
                if model.flaggedCellCount > 0 { numberClaimNote }
                if let table = model.table, !table.unplacedTexts.isEmpty {
                    unplacedSection(table.unplacedTexts)
                }
            case .refusal(let refusal):
                refusalPanel(refusal)
            }
            footer
        }
        .padding(ZPDFSpacing.l)
        .frame(minWidth: 520, minHeight: 360)
        .background(ZPDFColor.background)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(NSLocalizedString(
            "Review the table read from the drawing before importing",
            comment: "Accessibility label for the table import review panel"
        )))
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.xs) {
            Text(NSLocalizedString(
                "Review the table before importing",
                comment: "Title of the table import review panel"
            ))
            .zpdfText(.windowTitle, .textPrimary)

            if let table = model.table {
                Text(table.columnOrigin.displayText)
                    .zpdfText(.caption, .textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if table.unreadCellCount > 0 {
                    Text(WorkflowPlurals.unreadCells(table.unreadCellCount))
                    .zpdfText(.caption, .textSecondary)
                }
            }
        }
    }

    /// The standing legend: what the ⌐ on every row means. Words, not colour.
    private var readRowLegend: some View {
        HStack(alignment: .firstTextBaseline, spacing: ZPDFSpacing.s) {
            Text(TableImportReviewModel.readRowGlyph)
                .zpdfText(.body.withWeight(.semibold), .textPrimary)
                .accessibilityHidden(true)
            Text(TableImportReviewModel.readRowLegendText)
            .zpdfText(.caption, .textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    /// Which column groups the imported rows in the Quantity Ledger. Starts on the first column
    /// that is mostly text — usually the schedule's mark column (IM-153).
    private var subjectPicker: some View {
        Picker(selection: $model.subjectColumnIndex) {
            ForEach(model.columns) { column in
                Text(model.finalTitle(forColumn: column.index)).tag(column.index)
            }
        } label: {
            Text(NSLocalizedString(
                "Group rows by",
                comment: "Label for the table import picker choosing the subject (grouping) column"
            ))
        }
        .frame(maxWidth: 320)
        .accessibilityHint(Text(NSLocalizedString(
            "The column whose text becomes each row's subject in the Quantity Ledger.",
            comment: "Accessibility hint for the table import subject column picker"
        )))
    }

    // MARK: - Grid

    /// The same grid for a long schedule, built row by row as it scrolls into view (IM-231).
    ///
    /// `Grid` is not lazy: every cell of every row, each with its accessibility element, was
    /// built before the first frame. Past ``TableImportReviewModel/defaultLazyRowThreshold`` rows the
    /// panel uses a lazy stack with fixed column widths and a pinned header row instead.
    private var lazyGrid: some View {
        LazyVStack(alignment: .leading, spacing: ZPDFSpacing.xs, pinnedViews: [.sectionHeaders]) {
            Section {
                ForEach(model.rows.indices, id: \.self) { rowIndex in
                    HStack(alignment: .top, spacing: ZPDFSpacing.m) {
                        rowLeader(rowIndex)
                            .frame(width: TableImportReviewModel.leaderColumnWidth, alignment: .leading)
                        ForEach(model.columns) { column in
                            cellView(rowIndex: rowIndex, columnIndex: column.index)
                                .frame(width: model.columnWidth(forColumn: column.index), alignment: .leading)
                        }
                    }
                }
            } header: {
                VStack(alignment: .leading, spacing: ZPDFSpacing.xs) {
                    HStack(alignment: .top, spacing: ZPDFSpacing.m) {
                        Text(TableImportReviewModel.readRowGlyph)
                            .zpdfText(.caption, .textSecondary)
                            .frame(width: TableImportReviewModel.leaderColumnWidth, alignment: .leading)
                            .accessibilityLabel(Text(NSLocalizedString(
                                "Read row marker column",
                                comment: "Accessibility label for the marker column header in the table import grid"
                            )))
                        ForEach(model.columns) { column in
                            columnHeader(column)
                                .frame(width: model.columnWidth(forColumn: column.index), alignment: .leading)
                        }
                    }
                    ZPDFHairlineDivider()
                }
                .background(ZPDFColor.background)
            }
        }
    }

    private var grid: some View {
        Grid(alignment: .topLeading, horizontalSpacing: ZPDFSpacing.m, verticalSpacing: ZPDFSpacing.xs) {
            GridRow {
                // The leader column's header: the marker, explained by the legend above.
                Text(TableImportReviewModel.readRowGlyph)
                    .zpdfText(.caption, .textSecondary)
                    .accessibilityLabel(Text(NSLocalizedString(
                        "Read row marker column",
                        comment: "Accessibility label for the marker column header in the table import grid"
                    )))
                ForEach(model.columns) { column in
                    columnHeader(column)
                }
            }
            ZPDFHairlineDivider()
                .gridCellUnsizedAxes(.horizontal)
                .gridCellColumns(model.columns.count + 1)
            ForEach(model.rows.indices, id: \.self) { rowIndex in
                GridRow {
                    rowLeader(rowIndex)
                    ForEach(model.columns) { column in
                        cellView(rowIndex: rowIndex, columnIndex: column.index)
                    }
                }
            }
        }
    }

    private func columnHeader(_ column: TableImportReviewTable.Column) -> some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.xs) {
            TextField("", text: $model.columnTitles[column.index])
                // Escape must leave the sheet even while a column title has focus — the
                // field otherwise consumes the key as "abort editing" and the person is
                // one Escape short of out (RT-10, 2026-08-31). The edited title is kept:
                // cancelling the SHEET is not cancelling the keystroke.
                .onExitCommand { model.cancel() }
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 96)
                .accessibilityLabel(Text(String(
                    format: NSLocalizedString(
                        "Name of column %d",
                        comment: "Accessibility label for a table import column name field. %d is the 1-based column position"
                    ),
                    column.index + 1
                )))
            Text(column.headerWasPrinted
                ? NSLocalizedString(
                    "printed on the drawing",
                    comment: "Table import review: the column header came from the sheet"
                )
                : NSLocalizedString(
                    "no printed header",
                    comment: "Table import review: the column had no header on the sheet"
                ))
                .zpdfText(.caption, .textSecondary)
            Picker(selection: $model.columnKinds[column.index]) {
                ForEach(TableImportColumnKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            } label: {
                Text(NSLocalizedString(
                    "Column type",
                    comment: "Label for the table import column type picker"
                ))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 140)
            .accessibilityLabel(Text(String(
                format: NSLocalizedString(
                    "Type of column %d",
                    comment: "Accessibility label for a table import column type picker. %d is the 1-based column position"
                ),
                column.index + 1
            )))
        }
    }

    private func rowLeader(_ rowIndex: Int) -> some View {
        Text(TableImportReviewModel.readRowGlyph)
            .zpdfText(.body.withWeight(.semibold), .textPrimary)
            .accessibilityLabel(Text(String(
                format: NSLocalizedString(
                    "Row %d. %@",
                    comment: "Accessibility label for a table import row leader: 1-based row number, then the read-row explanation"
                ),
                rowIndex + 1,
                TableImportReviewModel.readRowAccessibilityText
            )))
    }

    @ViewBuilder
    private func cellView(rowIndex: Int, columnIndex: Int) -> some View {
        // A ragged row — one the engine produced with fewer cells than there are columns —
        // used to take the whole panel down here with an index-out-of-range trap. It now reads
        // as what it is: a cell that is not there. Finding CR-192.
        if let cell = model.cell(row: rowIndex, column: columnIndex) {
            populatedCellView(cell, rowIndex: rowIndex, columnIndex: columnIndex)
        } else {
            Text(NSLocalizedString(
                "— no cell —",
                comment: "Placeholder shown where a table import row is short of a column"
            ))
            .zpdfText(.caption, .textSecondary)
            .italic()
            .accessibilityLabel(Text(NSLocalizedString(
                "No cell. This row is short of this column, so nothing was read here.",
                comment: "Accessibility label for a table import row that is short of a column"
            )))
        }
    }

    @ViewBuilder
    private func populatedCellView(
        _ cell: TableImportReviewTable.Cell,
        rowIndex: Int,
        columnIndex: Int
    ) -> some View {
        if cell.isUnread {
            // The unread marker is text, deliberately — an empty cell and a tinted empty
            // cell both read as "nothing here", and this one means "the OCR failed here".
            Text(NSLocalizedString(
                "— unread —",
                comment: "Placeholder shown in a table import cell the OCR could not read"
            ))
            .zpdfText(.caption, .textSecondary)
            .italic()
            .accessibilityLabel(Text(NSLocalizedString(
                "Unread cell. Nothing was recognised here and nothing is filled in.",
                comment: "Accessibility label for an unread table import cell"
            )))
        } else if model.isCellFlagged(row: rowIndex, column: columnIndex) {
            HStack(spacing: ZPDFSpacing.xs) {
                Text(cell.text).zpdfText(.control, .textPrimary)
                Text(NSLocalizedString(
                    "not a number",
                    comment: "Marker beside a table import cell that fails its column's number type"
                ))
                .zpdfText(.caption, .textSecondary)
                .italic()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(String(
                format: NSLocalizedString(
                    "%@. Not a number — it stays as text.",
                    comment: "Accessibility label for a flagged table import cell. %@ is the cell text"
                ),
                cell.text
            )))
        } else {
            Text(cell.text).zpdfText(.control, .textPrimary)
        }
    }

    /// The standing consequence of a failed number claim, in words: kept, as text.
    private var numberClaimNote: some View {
        ZPDFInlineWarning(
            severity: .warning,
            message: WorkflowPlurals.cellsFailingNumberClaim(model.flaggedCellCount)
        )
    }

    // MARK: - Unplaced text

    private func unplacedSection(_ texts: [String]) -> some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.xs) {
            Text(NSLocalizedString(
                "Read, but not placed in any cell",
                comment: "Table import review: heading over text that could not be filed into the grid"
            ))
            .zpdfText(.caption.withWeight(.semibold), .textPrimary)
            Text(NSLocalizedString(
                "These lines were recognised inside the selection but carry no usable position. They will not be imported.",
                comment: "Table import review: explanation of unplaced text"
            ))
            .zpdfText(.caption, .textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            ForEach(texts, id: \.self) { text in
                Text(text).zpdfText(.code, .textSecondary)
            }
        }
    }

    // MARK: - Refusal

    private func refusalPanel(_ refusal: TableImportReviewRefusal) -> some View {
        VStack {
            Spacer(minLength: 0)
            ZPDFEmptyState(
                glyph: .symbol(.info),
                title: refusal.displayTitle,
                message: refusal.displayMessage
            )
            .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: ZPDFSpacing.s) {
            Spacer(minLength: 0)
            Button(
                NSLocalizedString("Cancel", comment: "Close the table import review without importing"),
                action: { model.cancel() }
            )
            .keyboardShortcut(.cancelAction)
            if model.table != nil {
                Button(
                    WorkflowPlurals.addReadRows(model.rows.count),
                    action: { model.accept() }
                )
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canAccept)
            }
        }
    }
}
