import AppKit
import Foundation
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation

/// Measure ▸ Split Area (NL-MEASURE-06): select one area, choose the command, click
/// the two ends of the dividing line. The parts replace the area as one undoable step; a
/// refusal is said in the status note and nothing changes.
@MainActor
public enum AreaSplitFlow {

    /// The area each document is waiting to split, while its two clicks are collected.
    private static var pending: [UUID: MarkupID] = [:]

    /// Arms the split of the single selected area. Returns the refusal to say when there is none.
    static func arm(_ document: ZenitPDFProjectDocument) -> String? {
        guard let core = document.core else { return nil }
        let selected = core.canvas.selectedMarkupIDs
        guard selected.count == 1, let id = selected.first else {
            return NSLocalizedString("Select one area to split.", comment: "Split refusal: nothing or several selected")
        }
        PendingPointPicks.disarmAll(document)  // one borrowed pick at a time (R-001)
        pending[document.documentIdentity] = MarkupID(id)
        return nil
    }

    static func isArmed(_ document: ZenitPDFProjectDocument) -> Bool { pending[document.documentIdentity] != nil }

    static func disarm(_ document: ZenitPDFProjectDocument) { pending.removeValue(forKey: document.documentIdentity) }

    /// The two points arrived: split, as one batch.
    static func finish(points: [PDFPointValue], document: ZenitPDFProjectDocument) async {
        guard let id = pending.removeValue(forKey: document.documentIdentity),
              points.count == 2, let core = document.core else { return }
        do {
            let commands = try await core.session.splitCommands(markup: id, along: points.map { PDFPoint(shown: $0) })
            try await core.commands.performBatch(
                commands,
                actionName: NSLocalizedString("Split Area", comment: "Undo action name for splitting an area")
            )
            await core.refresh()
        } catch let refusal as AreaSplitRefusal {
            core.status.setActiveToolNote(refusal.message)
        } catch {
            ZenitPDFProjectDocument.reportRefusedEdit(error, core: core)
        }
    }

    /// Measure ▸ Merge Areas: the selected same-subject areas become the first of them, in
    /// document order, as one undoable step (NL-MEASURE-06). A refusal is said, nothing changes.
    static func merge(_ document: ZenitPDFProjectDocument) async {
        guard let core = document.core else { return }
        let selected = core.canvas.selectedMarkupIDs
        let ordered = await core.session.orderedMarkups.map(\.id).filter { selected.contains($0.rawValue) }
        do {
            // A gap the areas close around is kept open as a cutout, in the same step (K-10).
            let plan = try await core.session.mergePlan(markups: ordered)
            try await core.commands.performBatch(
                plan.commands,
                actionName: NSLocalizedString("Merge Areas", comment: "Undo action name for merging areas")
            )
            await core.refresh()
            if let note = plan.statusNote { core.status.setActiveToolNote(note) }
        } catch let refusal as AreaSplitRefusal {
            core.status.setActiveToolNote(refusal.message)
        } catch {
            ZenitPDFProjectDocument.reportRefusedEdit(error, core: core)
        }
    }
}
