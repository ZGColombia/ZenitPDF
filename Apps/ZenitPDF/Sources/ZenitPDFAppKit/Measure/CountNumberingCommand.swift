import AppKit
import Foundation
import ZPDFAppCore
import ZPDFContracts

/// Measure ▸ Number Count Marks (NL-MEASURE-12): the selected counts show 1…n beside their marks
/// in placement order, or stop showing them. One undo step for the whole selection.
extension ProjectWindowController {

    func toggleCountNumbering(for document: ZenitPDFProjectDocument) {
        guard let core = document.core else { return }
        let selected = core.canvas.selectedMarkupIDs
        Task { @MainActor in
            var records: [MarkupRecord] = []
            for id in selected {
                if let record = await core.session.markup(MarkupID(id)) { records.append(record) }
            }
            let (commands, turnsOn) = CountNumbering.toggleCommands(for: records)
            guard !commands.isEmpty else {
                core.status.setActiveToolNote(NSLocalizedString(
                    "Select one or more counts to number their marks.",
                    comment: "Number Count Marks refusal: no count selected"
                ))
                return
            }
            do {
                try await core.commands.performBatch(
                    commands,
                    actionName: turnsOn
                        ? NSLocalizedString("Number Count Marks", comment: "Undo action name: counts numbered")
                        : NSLocalizedString("Remove Count Numbers", comment: "Undo action name: count numbers removed")
                )
                core.status.setActiveToolNote(turnsOn
                    ? NSLocalizedString("Count marks are numbered in the order they were placed.", comment: "Status note after numbering counts")
                    : NSLocalizedString("Count numbers removed.", comment: "Status note after removing count numbers"))
            } catch {
                ZenitPDFProjectDocument.reportRefusedEdit(error, core: core)
            }
        }
    }
}
