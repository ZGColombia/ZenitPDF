import Foundation
import ZPDFUILedger
import ZPDFUIPresentation

/// NL-UX-09: the ledger's row context menu, wired to the doors the rest of the window already
/// uses — the canvas presenter for Zoom To and Select on Canvas, the ledger's bulk-edit seam for
/// Change Status (one undo step, one audit entry), the Inspector's lock hook, and the shell's
/// Delete command over the canvas selection. Nothing here is a second path.
extension LedgerPaneModel {

    /// The status choices the menu offers: the Status column's own options.
    var rowMenuStatuses: [(value: String, title: String)] {
        (presenter.columns.first { $0.id == .status }?.choices ?? []).map { ($0.value, $0.title) }
    }

    /// Installs the row menu on the table. Called once the pane knows its environment. With an
    /// explaining presenter the menu offers Explain…, and the panel's Show reveals the markup.
    public func installRowMenu(environment: ProjectShellEnvironment) {
        // NL-QTY-15 phase 2 rides the same moment: the pane now knows its window.
        batchSummary = environment.onBatchProjectSummary
        exportBatchSummary = environment.onExportBatchSummary
        importAssemblyRecipes = environment.onImportAssemblyRecipes
        exportAssemblyRecipes = environment.onExportAssemblyRecipes
        explainShow = { [weak environment] id in
            environment?.reveal(markupID: id)
        }
        var explain: (@MainActor (Set<UUID>) -> Void)?
        if canExplain {
            explain = { [weak self] rows in
                guard let self else { return }
                self.openExplain(rows)
            }
        }
        host.controller.rowMenu = rowMenuConfiguration(environment: environment, explain: explain)
        // NL-UX-09 (r2-layers): the row under the pointer outlines its markup on the canvas.
        host.controller.onHoverMarkup = { [weak environment] id in environment?.onLedgerHover?(id) }
    }

    // MARK: - Explain a number

    /// Whether the ledger can explain its numbers.
    public var canExplain: Bool { presenter is any LedgerExplaining }

    /// Opens the Explain panel over `rows`: the selection, or every row of a group whose heading
    /// was right-clicked.
    public func openExplain(_ rows: Set<UUID>) {
        guard let explaining = presenter as? any LedgerExplaining, !rows.isEmpty else { return }
        let title = rows.count == 1
            ? NSLocalizedString("1 row", comment: "Explain panel subtitle: one row explained")
            : String(format: NSLocalizedString("%d rows", comment: "Change report: how many rows changed"), rows.count)
        explainPanel = LedgerExplainModel(title: title, markupIDs: rows, presenter: explaining, onShow: explainShow)
    }

    /// Opens the Explain panel over the selected rows.
    public func explainSelection() { openExplain(host.selectedRowIDs) }

    /// Closes the Explain panel.
    public func closeExplain() { explainPanel = nil }

    /// The configuration, separate from the table so a test can drive every action.
    func rowMenuConfiguration(
        environment: ProjectShellEnvironment,
        explain: (@MainActor (Set<UUID>) -> Void)? = nil
    ) -> LedgerRowMenuConfiguration {
        LedgerRowMenuConfiguration(
            statuses: rowMenuStatuses,
            isLocked: { [weak environment] rows in
                guard let environment else { return false }
                return environment.canvas.visibleMarkups.contains { rows.contains($0.id) && $0.locked }
                    || environment.canvas.resolvedSelectedMarkups.contains { rows.contains($0.id) && $0.locked }
            },
            canExplain: explain != nil,
            perform: { [weak self, weak environment] action, rows in
                guard let self, let environment, !rows.isEmpty else { return }
                self.performRowMenuAction(action, rows: rows, environment: environment, explain: explain)
            }
        )
    }

    func performRowMenuAction(
        _ action: LedgerRowMenuAction,
        rows: Set<UUID>,
        environment: ProjectShellEnvironment,
        explain: (@MainActor (Set<UUID>) -> Void)?
    ) {
        switch action {
        case .zoomTo:
            // Either way the canvas may land on another sheet, so the page-scoped panels
            // follow (R-078).
            if rows.count == 1, let id = rows.first {
                environment.reveal(markupID: id)
            } else {
                // S-045: the fit turns to the rows' sheet first; it used to fit only the part of
                // the selection on the sheet on screen — nothing, for rows on another sheet.
                environment.canvas.select(markupIDs: rows, additive: false)
                environment.zoomToSelection()
            }
        case .selectOnCanvas:
            environment.canvas.select(markupIDs: rows, additive: false)
        case .setStatus(let value):
            // Not the panel's Apply: a refusal goes to the pane's notice, and no "Changed 3
            // markups" waits under the Bulk Edit panel to greet it as if applied there (L-85).
            applyBulkEdit(values: [.status: .choice(value)], color: nil, markupIDs: rows, fromPanel: false)
        case .toggleLock:
            let locked = rowMenuConfiguration(environment: environment).isLocked(rows)
            environment.inspectorEditing.onSetLocked?(rows, !locked)
        case .explain:
            explain?(rows)
        case .delete:
            environment.canvas.select(markupIDs: rows, additive: false)
            environment.perform(.deleteSelection)
        }
    }
}
