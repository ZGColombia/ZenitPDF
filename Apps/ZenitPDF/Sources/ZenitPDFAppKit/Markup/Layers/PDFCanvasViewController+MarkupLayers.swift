import AppKit
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
import ZPDFUIShell

/// The canvas's share of markup layers (ADR-0032, unit r2-layers): the context menu's Move to
/// Layer, and the rule that a hidden layer is not drawn or hit and a locked layer is drawn but
/// never selected.
extension PDFCanvasViewController {

    /// Move to Layer ▸ every layer, the selection's own ticked, then New Layer… — one step each.
    func moveToLayerSubmenu(ids: Set<UUID>, markups: [MarkupSummary], enabled: Bool) -> NSMenuItem {
        let submenu = NSMenu()
        // The items carry their own enabled state (a locked layer's row is off).
        submenu.autoenablesItems = false
        let current = InspectorSelectionSummary.commonValue(markups.map { $0.layerID ?? MarkupLayer.defaultID.rawValue })
        let core = self.core
        for layer in core.snapshot.markupLayers {
            // V-046: the shell's one rule, the Navigator's and the Inspector's — a locked layer
            // takes nothing.
            let refusal = MarkupLayerPanelModel.assignRefusal(markups, targetIsLocked: layer.locked)
            let item = ContextMenuItem(title: layer.name, enabled: refusal == nil) {
                Task { @MainActor in await MarkupLayerActions.assign(ids, to: layer.id.rawValue, core: core) }
            }
            item.toolTip = refusal.map(MarkupLayerPanelModel.reason)
            item.state = current == layer.id.rawValue ? .on : .off
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        submenu.addItem(ContextMenuItem(
            title: NSLocalizedString("New Layer…", comment: "Canvas context menu: create a markup layer and move the selection onto it")
        ) { [weak self] in
            MarkupLayerActions.newLayer(moving: ids, core: core, window: self?.view.window)
        })
        let title = NSLocalizedString("Move to Layer", comment: "Canvas context menu submenu: markup layers")
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.submenu = submenu
        submenu.title = title
        parent.isEnabled = enabled
        return parent
    }

    /// The markups the snapshot says are on a hidden layer: left out of the scene altogether, so
    /// they are neither drawn nor hit. (A locked layer's markups are drawn and skipped by the hit
    /// test and the marquee through `AppCanvasPresenter.unselectableMarkupIDs`.)
    var layerHiddenMarkupIDs: Set<UUID> {
        // The scene is this sheet's; the other sheets' hidden markups cannot be in it.
        let page = core.document.currentPageID
        return Set(core.snapshot.markups.lazy.filter { $0.layerHidden == true && $0.pageID == page }.map(\.id))
    }
}
