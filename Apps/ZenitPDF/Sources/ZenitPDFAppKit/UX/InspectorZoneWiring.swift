import AppKit
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIShell

/// The Inspector's Project Zone popup, joined to the document (nl-ux).
///
/// The popup files the Inspector's selection — explicit ids, not "whatever the canvas has
/// selected now" — into a zone, or out of every zone with `nil`, through the same
/// `DocumentCommand.setMarkupZone` the Zones page's "Assign Selection" runs: one undo step,
/// persisted with the project, the ledger regrouped on the next refresh.
extension ZenitPDFProjectDocument {

    func wireInspectorZoneAssignment(shell: ProjectShellEnvironment, core: AppCoreEnvironment) {
        shell.inspectorEditing.onSetZone = { [weak self, weak core] markupIDs, zoneID in
            guard let self, let core, !markupIDs.isEmpty else { return }
            let ids = markupIDs.sorted { $0.uuidString < $1.uuidString }.map(MarkupID.init)
            Task { @MainActor in
                do {
                    try await core.commands.perform(.setMarkupZone(ids: ids, zoneID: zoneID.map(ZoneID.init)))
                    await core.refresh()
                    self.refreshProjectStructureIfPossible()
                } catch {
                    Self.reportRefusedEdit(error, core: core)
                }
            }
        }
    }
}
