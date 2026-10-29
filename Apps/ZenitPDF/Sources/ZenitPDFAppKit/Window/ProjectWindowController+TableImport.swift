import AppKit
import Foundation
import SwiftUI
import ZPDFAppCore
import ZPDFContracts
import ZPDFServiceClient
import ZPDFServiceWire
import ZPDFUIPresentation
import ZPDFUIWorkflows

/// Feature 31's application host: drag a rectangle around a schedule printed on the sheet,
/// review what the engine read, and accept it as `.read` ledger rows (ADR-0012).
///
/// The engine and the review model never touch the session; everything session-shaped
/// happens here, in `acceptTableImport`. The review sheet's presentation is injectable so
/// tests drive the model without a sheet on screen.
extension ProjectWindowController {

    /// How the review panel reaches the screen, returning the closure that takes it OFF
    /// the screen again. The default sheets it on the window; a test injects a capture.
    ///
    /// Returning the dismissal is the whole fix for LT-16 (2026-08-29): the old comment
    /// said "the model's accept/cancel closures are wrapped by the caller to end the
    /// sheet", and no caller ever did — Add worked, Cancel and Escape did nothing, and
    /// the window was dead behind an immortal sheet.
    static var tableReviewPresenter: (@MainActor (TableImportReviewModel, NSWindow?) -> () -> Void) = { model, window in
        guard let window else { return {} }
        let host = NSHostingController(rootView: TableImportReviewView(model: model))
        let panel = NSWindow(contentViewController: host)
        panel.styleMask = [.titled]
        // Through the one modal door: recorded, and refused on a visible window in a
        // process with no user (R-039).
        ZenitModalPresenter.beginSheet(panel, on: window, identifier: "tableImport.review") {}
        return { [weak window, weak panel] in
            guard let window, let panel else { return }
            window.endSheet(panel)
        }
    }

    /// Late-bound dismissal: the model's closures must end a sheet that only exists
    /// after the model is built, so they call through this box.
    @MainActor final class SheetDismissBox {
        var dismiss: () -> Void = {}
    }

    func beginTableImport(for document: ZenitPDFProjectDocument) {
        guard let canvas = canvasController(for: document) else { return }
        document.core?.status.setActiveToolNote(NSLocalizedString(
            "Drag a rectangle around the printed table.",
            comment: "Status note after Tools ▸ Import Table from Drawing…"
        ))
        beginRegionCapture(
            on: canvas,
            for: document,
            cancelNote: NSLocalizedString(
                "Table import cancelled.",
                comment: "Status note when the table-import region capture ends without a rectangle"
            )
        ) { [weak self, weak document] (pageRect: PDFRectValue) in
            guard let self, let document else { return }
            self.runTableImport(for: document, region: pageRect)
        }
    }

    private func runTableImport(for document: ZenitPDFProjectDocument, region: PDFRectValue) {
        Task { @MainActor in
            guard let core = document.core, let drawing = document.currentPageDrawing else { return }
            guard let currentID = core.document.currentPageID,
                  let page = drawing.pages.first(where: { $0.id.rawValue == currentID })
            else { return }

            // The two inputs: positioned text lines, and the page's drawn rule lines.
            // r2-platform (NL-AUTO-03): the drawing's own text in the region,
            // else the project's stored recognition, else the region recognised on this Mac for
            // this import — a scanned schedule imports too. Weak reads (under 50 %) stay out.
            let recognised = await PageTextLoader.lines(document: document, page: page, region: region, allowRegionOCR: true)
                .filter { $0.confidence >= 0.5 }
                .map(\.recognisedTextLine)
            let engine = TableImportEngine()
            let extraction = try? await GeometryExtraction.client.extractPageGeometry(
                documentAt: drawing.url,
                pageIndex: page.index,
                options: GeometryWireOptions(includesHiddenOptionalContent: false, password: document.drawingPassword)
            )
            let rules = extraction.map { engine.ruleLines(in: $0) } ?? []

            switch engine.propose(region: region, recognisedLines: recognised, ruleLines: rules) {
            case .failure(let refusal):
                let box = SheetDismissBox()
                let model = TableImportReviewModel(
                    refusal: Self.reviewRefusal(refusal),
                    onCancel: { box.dismiss() }
                )
                box.dismiss = Self.tableReviewPresenter(model, self.window)
            case .success(let proposal):
                let box = SheetDismissBox()
                let model = TableImportReviewModel(
                    table: Self.reviewTable(from: proposal),
                    onAccept: { [weak self, weak document] outcome in
                        box.dismiss()
                        guard let self, let document else { return }
                        self.acceptTableImport(
                            proposal: proposal,
                            outcome: outcome,
                            document: document,
                            pageID: page.id
                        )
                    },
                    onCancel: { box.dismiss() }
                )
                box.dismiss = Self.tableReviewPresenter(model, self.window)
            }
        }
    }

    private func acceptTableImport(
        proposal: TableImportProposal,
        outcome: TableImportReviewOutcome,
        document: ZenitPDFProjectDocument,
        pageID: PageID
    ) {
        Task { @MainActor in
            guard let core = document.core else { return }
            struct FreshIdentifiers: IdentifierGenerating {
                func nextIdentifier() -> UUID { UUID() }
            }
            let acceptance = TableImportAcceptance.records(
                from: proposal,
                documentID: await core.session.documentID,
                pageID: pageID,
                identifiers: FreshIdentifiers(),
                timestamps: SystemTimestampProvider(),
                subjectColumnIndex: outcome.subjectColumnIndex
            )
            let landing = Self.tableImportLanding(
                records: acceptance.records,
                bindings: acceptance.columnBindings,
                outcome: outcome
            )
            do {
                // One batch, columns first: the whole schedule and its columns land or none of
                // it does, and one ⌘Z takes both back. Performing row by row left rows 1…6 of a
                // refused 12 in the ledger (BH-901, IM-184); adding the columns straight on the
                // session afterwards put them outside the undo step, so undoing an import left
                // its empty columns behind (R-055).
                try await core.commands.performBatch(
                    Self.tableImportCommands(landing),
                    actionName: NSLocalizedString(
                        "Import Table",
                        comment: "Undo action name for landing an imported drawing table"
                    )
                )
                document.noteImportedLedgerColumns(landing.definitions)
                await core.commands.settle()
                await core.refresh()
                var note = String(
                    format: NSLocalizedString(
                        "%d read rows added from the drawing — marked ⌐, never counted as measured",
                        comment: "Status note after a table import lands; the glyph marks read rows"
                    ),
                    landing.records.count
                )
                if !landing.keptAsText.isEmpty {
                    note += " " + String(
                        format: NSLocalizedString(
                            "(kept as text because some cells are not numbers: %@)",
                            comment: "Appended to the table import note; the argument lists column names"
                        ),
                        landing.keptAsText.joined(separator: ", ")
                    )
                }
                core.status.setActiveToolNote(note)
            } catch {
                ZenitPDFProjectDocument.reportRefusedEdit(error, core: core)
            }
        }
    }

    /// The one undoable batch a landing is: its columns, then its rows (R-055).
    static func tableImportCommands(_ landing: TableImportLanding) -> [DocumentCommand] {
        (landing.definitions.isEmpty ? [] : [.addCustomColumns(landing.definitions)])
            + landing.records.map { .addMarkup($0) }
    }

    /// What an accepted table import lands: the column definitions, under the reviewer's
    /// titles **and kinds**, and the records with number cells typed as numbers.
    struct TableImportLanding {
        var definitions: [LedgerColumnDefinition]
        var records: [MarkupRecord]
        /// Columns the reviewer marked Number that stay text, because some read cells are not
        /// numbers — never coerced to zero.
        var keptAsText: [String]
    }

    /// Builds the landing. Pure, for BH-365's regression test: the reviewer's Number choice
    /// used to be discarded and every column created as text, so a quantity column could not
    /// be summed or used in a formula. A Number column whose every read cell parses becomes a
    /// number column with `.number` cells; one with an unparsable cell stays text, as the
    /// review contract requires ("these cells stay text"), and the note says so.
    static func tableImportLanding(
        records acceptedRecords: [MarkupRecord],
        bindings: [TableImportAcceptance.ColumnBinding],
        outcome: TableImportReviewOutcome
    ) -> TableImportLanding {
        var definitions: [LedgerColumnDefinition] = []
        var records = acceptedRecords
        var keptAsText: [String] = []
        for binding in bindings {
            let column = outcome.columns.first { $0.index == binding.index }
            let title = column?.title ?? binding.title
            var kind: ZPDFContracts.ColumnKind = .text
            var dimension: ZPDFContracts.QuantityDimension?
            if column?.kind == .number {
                let allParse = records.allSatisfy { record in
                    guard case let .text(text)? = record.customValues[binding.columnID] else { return true }
                    return TableImportReviewModel.numberValue(of: text) != nil
                }
                if allParse, column?.unparsedRowIndexes.isEmpty ?? true {
                    kind = .number
                    dimension = .count
                    for index in records.indices {
                        guard case let .text(text)? = records[index].customValues[binding.columnID],
                              let value = TableImportReviewModel.numberValue(of: text) else { continue }
                        records[index].customValues[binding.columnID] = .number(.count(value))
                    }
                } else {
                    keptAsText.append(title)
                }
            }
            definitions.append(LedgerColumnDefinition(
                id: binding.columnID,
                key: "zenit.import.\(binding.columnID.rawValue.uuidString)",
                title: title,
                kind: kind,
                dimension: dimension,
                order: 0  // re-assigned by the session when appended
            ))
        }
        return TableImportLanding(definitions: definitions, records: records, keptAsText: keptAsText)
    }

    // MARK: - Mapping the engine's vocabulary to the panel's

    static func reviewTable(from proposal: TableImportProposal) -> TableImportReviewTable {
        TableImportReviewTable(
            columns: proposal.columns.map { column in
                TableImportReviewTable.Column(
                    index: column.index,
                    title: column.title,
                    headerWasPrinted: !(column.headerText ?? "").isEmpty
                )
            },
            rows: proposal.rows.map { row in
                TableImportReviewTable.Row(
                    cells: row.cells.map { cell in
                        TableImportReviewTable.Cell(text: cell.isUnread ? "" : cell.text)
                    },
                    sourceText: row.sourceText
                )
            },
            columnOrigin: proposal.columnSource == .ruleLines ? .ruleLines : .textAlignment,
            unplacedTexts: proposal.unplacedTexts
        )
    }

    static func reviewRefusal(_ refusal: TableImportRefusal) -> TableImportReviewRefusal {
        switch refusal {
        case .emptyRegion:
            return .emptyRegion
        case .textWithoutPositions(let count):
            return .textWithoutPositions(lineCount: count)
        case .noColumnStructure(let rules, let clusters):
            return .noColumnStructure(interiorRuleCount: rules, alignmentClusterCount: clusters)
        case .noRows:
            return .noRows
        }
    }
}
