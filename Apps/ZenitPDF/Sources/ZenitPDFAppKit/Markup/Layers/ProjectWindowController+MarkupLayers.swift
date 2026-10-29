import AppKit
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIShell

/// The window-level wiring of markup layers (ADR-0032, unit r2-layers): the shell's
/// ``MarkupLayerPanelModel`` answered by ``MarkupLayerActions``, and the rows refreshed from every
/// snapshot the document takes.
extension ProjectWindowController {

    func wireMarkupLayers(shell: ProjectShellEnvironment, document: ZenitPDFProjectDocument) {
        let model = shell.markupLayers
        model.onNewLayer = { [weak self, weak document] markupIDs in
            guard let core = document?.core else { return }
            MarkupLayerActions.newLayer(moving: markupIDs, core: core, window: self?.window)
        }
        model.onRename = { [weak document] id, name in
            guard let core = document?.core else { return }
            Task { @MainActor in await MarkupLayerActions.rename(id, to: name, core: core) }
        }
        model.onMove = { [weak document] id, index in
            guard let core = document?.core else { return }
            Task { @MainActor in await MarkupLayerActions.move(id, to: index, core: core) }
        }
        model.onSetVisible = { [weak document] id, visible in
            guard let core = document?.core else { return }
            Task { @MainActor in await MarkupLayerActions.setVisible(visible, layer: id, core: core) }
        }
        model.onSetLocked = { [weak document] id, locked in
            guard let core = document?.core else { return }
            Task { @MainActor in await MarkupLayerActions.setLocked(locked, layer: id, core: core) }
        }
        model.onSetPrintable = { [weak document] id, printable in
            guard let core = document?.core else { return }
            Task { @MainActor in await MarkupLayerActions.setPrintable(printable, layer: id, core: core) }
        }
        model.onDelete = { [weak self, weak document] id in
            guard let core = document?.core else { return }
            MarkupLayerActions.deleteLayer(id, core: core, window: self?.window)
        }
        model.onSetActive = { [weak document] id in
            guard let core = document?.core else { return }
            Task { @MainActor in await MarkupLayerActions.setActive(id, core: core) }
        }
        model.onAssign = { [weak document] markupIDs, id in
            guard let core = document?.core else { return }
            Task { @MainActor in await MarkupLayerActions.assign(markupIDs, to: id, core: core) }
        }
        model.onFilterLedger = { [weak document, weak shell] ids in
            guard let core = document?.core else { return }
            MarkupLayerActions.filterLedger(to: ids, core: core)
            if let shell { MarkupLayerActions.refresh(shell.markupLayers, core: core) }
        }
        // NL-UX-09: a ledger row under the pointer outlines its markup on the canvas — and turns
        // nothing: a markup on another sheet is outlined when that sheet is on screen.
        shell.onLedgerHover = { [weak self, weak document] id in
            guard let self, let document else { return }
            self.canvasController(for: document)?.showLedgerHover(id)
        }
        // Chained, so every refresh hook installed before keeps running.
        guard let core = document.core else { return }
        let previous = core.onDidRefresh
        core.onDidRefresh = { [weak shell, weak core] snapshot in
            previous?(snapshot)
            guard let shell, let core else { return }
            MarkupLayerActions.refresh(shell.markupLayers, core: core)
        }
        MarkupLayerActions.refresh(model, core: core)
    }
}
