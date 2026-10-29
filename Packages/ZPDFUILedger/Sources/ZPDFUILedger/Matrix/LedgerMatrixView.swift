import AppKit
import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

/// The summary matrix's state (NL-QTY-09): which grouping runs down, which across, and the
/// matrix the presenter built for them.
@MainActor
@Observable
public final class LedgerMatrixModel {

    /// The grouping down the side and the grouping across the top, as one pair.
    public struct Axes: Hashable, Sendable {
        public let rows: LedgerColumnID
        public let columns: LedgerColumnID
        public init(rows: LedgerColumnID, columns: LedgerColumnID) {
            self.rows = rows
            self.columns = columns
        }
    }

    /// One grouping choice.
    public struct Option: Identifiable, Hashable, Sendable {
        public let column: LedgerColumnID
        public let title: String
        public var id: LedgerColumnID { column }
        public init(column: LedgerColumnID, title: String) {
            self.column = column
            self.title = title
        }
    }

    /// The groupings on offer.
    public let options: [Option]
    /// The grouping down the side.
    public var rowColumn: LedgerColumnID
    /// The grouping across the top.
    public var columnColumn: LedgerColumnID
    /// The matrix for the current choice, once built. While a new choice is being built this is
    /// still the previous matrix; ``matrixAxes`` says which choice it was built for.
    public private(set) var matrix: LedgerMatrix?
    /// The groupings ``matrix`` was built for (W-064). The corner heading and the copied table
    /// are read from these, not from the pickers, so they always describe the numbers beside them.
    public private(set) var matrixAxes: Axes?
    /// Why the matrix could not be built, in words, when it could not.
    public private(set) var failure: String?
    /// The underlying error's own text — for the help tag, never the sentence on screen.
    public private(set) var failureDetail: String?

    @ObservationIgnored private let presenter: any LedgerMatrixProviding
    /// Counts builds, so a build that a newer one has overtaken drops its result (V-063).
    @ObservationIgnored private var generation = 0

    public init(presenter: any LedgerMatrixProviding, options: [Option], rows: LedgerColumnID, columns: LedgerColumnID) {
        self.presenter = presenter
        self.options = options
        self.rowColumn = rows
        self.columnColumn = columns
    }

    /// Builds the matrix for the current choice.
    ///
    /// V-063: `.task(id:)` cancels the build a new choice replaces, but the result used to be
    /// assigned after the await all the same. A cancelled or overtaken build now leaves the
    /// matrix to the build that replaced it.
    public func rebuild() async {
        generation += 1
        let current = generation
        let axes = Axes(rows: rowColumn, columns: columnColumn)
        do {
            let built = try await presenter.matrix(rows: axes.rows, columns: axes.columns)
            guard !Task.isCancelled, current == generation else { return }
            matrix = built
            matrixAxes = axes
            failure = nil
            failureDetail = nil
        } catch {
            guard !Task.isCancelled, current == generation else { return }
            // U-065: the error's own text is an internal diagnostic in English ("ledger rebuild
            // failed: no document"); the panel says what happened in the interface's words and
            // keeps the detail for the help tag.
            matrix = nil
            matrixAxes = nil
            failure = NSLocalizedString(
                "The summary matrix could not be built. Close it and try again.",
                comment: "Summary matrix: the totals could not be computed"
            )
            failureDetail = String(describing: error)
        }
    }

    /// The heading of the corner cell: "Subject \\ Page".
    ///
    /// W-064: named for the groupings the shown matrix was built for. It used to follow the
    /// pickers, so after swapping Subject \\ Page to Page \\ Subject the corner read
    /// "Page \\ Subject" over rows that were still subjects until the new build landed — and Copy
    /// as Table pasted that mismatched heading. Before the first build it names the pickers.
    public var cornerTitle: String {
        let axes = matrixAxes ?? Axes(rows: rowColumn, columns: columnColumn)
        let down = options.first { $0.column == axes.rows }?.title ?? axes.rows.rawValue
        let across = options.first { $0.column == axes.columns }?.title ?? axes.columns.rawValue
        return "\(down) \\ \(across)"
    }

    /// The matrix as tab-separated text.
    public var tabularText: String? {
        matrix?.tabularText(
            cornerTitle: cornerTitle,
            totalTitle: NSLocalizedString("Total", comment: "Summary matrix: the total row and column")
        )
    }

    /// Puts the matrix on a pasteboard for a spreadsheet paste.
    @discardableResult
    public func copy(to pasteboard: NSPasteboard) -> Bool {
        guard let text = tabularText else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}

/// The summary matrix view: pick what runs down and across, read the totals, copy the table.
public struct LedgerMatrixView: View {

    @Bindable private var model: LedgerMatrixModel
    private let pasteboard: NSPasteboard
    private let onDone: () -> Void

    public init(model: LedgerMatrixModel, pasteboard: NSPasteboard = .general, onDone: @escaping () -> Void) {
        self.model = model
        self.pasteboard = pasteboard
        self.onDone = onDone
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZPDFPanelHeader(
                title: NSLocalizedString("Summary Matrix", comment: "Title of the summary matrix"),
                subtitle: NSLocalizedString(
                    "Totals of the rows the ledger shows, by one grouping down and another across.",
                    comment: "Summary matrix subtitle"
                ),
                count: model.matrix?.rowTitles.count ?? 0
            )
            HStack(spacing: ZPDFSpacing.m) {
                picker(NSLocalizedString("Down", comment: "Summary matrix: grouping down the side"), selection: $model.rowColumn)
                picker(NSLocalizedString("Across", comment: "Summary matrix: grouping across the top"), selection: $model.columnColumn)
                Spacer()
            }
            .padding(ZPDFSpacing.m)
            ZPDFHairlineDivider()
            if let matrix = model.matrix {
                ScrollView([.horizontal, .vertical]) {
                    grid(matrix).padding(ZPDFSpacing.m)
                }
            } else if let failure = model.failure {
                ZPDFInlineWarning(message: failure)
                    .help(model.failureDetail ?? "")
                    .padding(ZPDFSpacing.m)
            } else {
                Text(NSLocalizedString("Building…", comment: "Summary matrix: being computed"))
                    .zpdfText(.caption, .textSecondary)
                    .padding(ZPDFSpacing.m)
            }
            Spacer(minLength: 0)
            ZPDFHairlineDivider()
            HStack {
                Spacer()
                Button(NSLocalizedString("Copy as Table", comment: "Summary matrix: copy for a spreadsheet")) {
                    model.copy(to: pasteboard)
                }
                .disabled(model.matrix == nil)
                Button(NSLocalizedString("Done", comment: "Column Manager: close")) { onDone() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(ZPDFSpacing.l)
        }
        .frame(minWidth: 560, minHeight: 380)
        .background(ZPDFColor.surface)
        .task(id: "\(model.rowColumn.rawValue)|\(model.columnColumn.rawValue)") { await model.rebuild() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(NSLocalizedString("Summary Matrix", comment: "Title of the summary matrix"))
    }

    private func picker(_ title: String, selection: Binding<LedgerColumnID>) -> some View {
        HStack(spacing: ZPDFSpacing.xs) {
            Text(title).zpdfText(.caption, .textSecondary)
            Picker("", selection: selection) {
                ForEach(model.options) { option in Text(option.title).tag(option.column) }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel(title)
        }
    }

    private func grid(_ matrix: LedgerMatrix) -> some View {
        let total = NSLocalizedString("Total", comment: "Summary matrix: the total row and column")
        return Grid(alignment: .trailing, horizontalSpacing: ZPDFSpacing.l, verticalSpacing: ZPDFSpacing.xs) {
            GridRow {
                Text(model.cornerTitle).zpdfText(.sectionHeader, .textSecondary).gridColumnAlignment(.leading)
                ForEach(Array(matrix.columnTitles.enumerated()), id: \.offset) { _, title in
                    Text(title).zpdfText(.sectionHeader, .textSecondary)
                }
                Text(total).zpdfText(.sectionHeader, .textPrimary)
            }
            ForEach(Array(matrix.rowTitles.enumerated()), id: \.offset) { index, title in
                GridRow {
                    Text(title).zpdfText(.control, .textPrimary)
                    ForEach(Array(matrix.cells[index].enumerated()), id: \.offset) { _, cell in
                        Text(cell.text).zpdfText(.monoNumeric, .textPrimary)
                    }
                    Text(matrix.rowTotals[index].text).zpdfText(.monoNumericStrong, .textPrimary)
                }
                .accessibilityElement(children: .combine)
            }
            GridRow {
                Text(total).zpdfText(.control, .textPrimary)
                ForEach(Array(matrix.columnTotals.enumerated()), id: \.offset) { _, cell in
                    Text(cell.text).zpdfText(.monoNumericStrong, .textPrimary)
                }
                Text(matrix.grandTotal.text).zpdfText(.monoNumericStrong, .textPrimary)
            }
            .accessibilityElement(children: .combine)
        }
    }
}
