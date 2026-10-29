import AppKit
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
import ZPDFUIShell

/// Markup layers in the application (ADR-0032, unit r2-layers): every request the Navigator's
/// Layers page, the Inspector's Layer row and the canvas's Move to Layer make, turned into
/// session commands — each one undoable step — and the two questions a person answers (a new
/// layer's name, where a deleted layer's markups go), asked through ``ZenitModalPresenter`` so a
/// test answers them by injection and nothing reaches the screen.
@MainActor
enum MarkupLayerActions {

    static let newLayerIdentifier = "layers.new-layer"
    static let deleteLayerIdentifier = "layers.delete-layer"

    /// Test seam: the name typed into the New Layer field before the alert is answered.
    static var typeNameForTesting: String?
    /// Test seam: the layer chosen for a deleted layer's markups.
    static var chooseDeleteTargetForTesting: UUID?

    // MARK: Rows

    /// The Navigator's rows for a snapshot: every layer, top first, with its project-wide count.
    static func rows(from snapshot: DocumentSnapshot) -> [MarkupLayerRow] {
        var counts: [UUID: Int] = [:]
        for markup in snapshot.markups {
            counts[markup.layerID ?? MarkupLayer.defaultID.rawValue, default: 0] += 1
        }
        return snapshot.markupLayers.map { layer in
            MarkupLayerRow(
                id: layer.id.rawValue,
                name: layer.name,
                isVisible: layer.visible,
                isLocked: layer.locked,
                isPrintable: layer.printable,
                markupCount: counts[layer.id.rawValue] ?? 0,
                isDefault: layer.isDefault
            )
        }
    }

    /// The ledger's layer filter as layer identities, resolved by the names the column shows.
    static func ledgerFilterLayerIDs(core: AppCoreEnvironment) -> Set<UUID>? {
        guard let names = LedgerLayerFilter.layers(in: core.ledger.filter) else { return nil }
        let wanted = Set(names)
        return Set(core.snapshot.markupLayers.filter { wanted.contains($0.name) }.map(\.id.rawValue))
    }

    /// Installs the snapshot's layers into the shell's model.
    static func refresh(_ model: MarkupLayerPanelModel, core: AppCoreEnvironment) {
        model.apply(
            rows: rows(from: core.snapshot),
            activeLayerID: core.snapshot.activeMarkupLayerID.rawValue,
            ledgerFilterLayerIDs: ledgerFilterLayerIDs(core: core)
        )
    }

    // MARK: Commands

    /// Runs one layer command; a refusal is said in the warning tray, never swallowed.
    @discardableResult
    static func perform(_ command: DocumentCommand, core: AppCoreEnvironment) async -> Bool {
        do {
            _ = try await core.commands.perform(command)
            await core.refresh()
            return true
        } catch {
            ZenitPDFProjectDocument.reportRefusedEdit(error, core: core)
            await core.refresh()
            return false
        }
    }

    /// Replaces the layer list with `edit` applied, as one named step.
    static func editList(
        core: AppCoreEnvironment,
        change: MarkupLayerChange,
        _ edit: (MarkupLayerSet) throws -> MarkupLayerSet
    ) async {
        let current = MarkupLayerSet(core.snapshot.markupLayers)
        guard let next = try? edit(current), next != current else { return }
        await perform(.setMarkupLayers(next.layers, change: change), core: core)
    }

    static func rename(_ id: UUID, to name: String, core: AppCoreEnvironment) async {
        await editList(core: core, change: .rename) { try $0.renaming(LayerID(id), to: name) }
    }

    static func move(_ id: UUID, to index: Int, core: AppCoreEnvironment) async {
        await editList(core: core, change: .reorder) { try $0.moving(LayerID(id), to: index) }
    }

    static func setVisible(_ visible: Bool, layer id: UUID, core: AppCoreEnvironment) async {
        await editList(core: core, change: visible ? .show : .hide) { try $0.updating(LayerID(id)) { $0.visible = visible } }
        // A layer hidden now takes its markups out of the selection: they cannot be seen.
        if !visible { dropUnselectable(core: core) }
    }

    static func setLocked(_ locked: Bool, layer id: UUID, core: AppCoreEnvironment) async {
        await editList(core: core, change: locked ? .lock : .unlock) { try $0.updating(LayerID(id)) { $0.locked = locked } }
        if locked { dropUnselectable(core: core) }
    }

    static func setPrintable(_ printable: Bool, layer id: UUID, core: AppCoreEnvironment) async {
        await editList(core: core, change: printable ? .print : .dontPrint) { try $0.updating(LayerID(id)) { $0.printable = printable } }
    }

    /// Moves markups onto a layer, one step.
    static func assign(_ markupIDs: Set<UUID>, to id: UUID, core: AppCoreEnvironment) async {
        guard !markupIDs.isEmpty else { return }
        let ordered = core.snapshot.markups.map(\.id).filter(markupIDs.contains).map(MarkupID.init)
        await perform(.setMarkupLayer(ids: ordered, layerID: LayerID(id)), core: core)
        dropUnselectable(core: core)
    }

    /// Makes a layer the one new markups go to.
    static func setActive(_ id: UUID, core: AppCoreEnvironment) async {
        await core.session.setActiveMarkupLayer(LayerID(id))
        await core.refresh()
    }

    /// Narrows the ledger to layers, or lifts the layer filter with `nil`. The ledger's other
    /// rules stay as they were.
    static func filterLedger(to ids: Set<UUID>?, core: AppCoreEnvironment) {
        let names = ids.map { wanted in
            core.snapshot.markupLayers.filter { wanted.contains($0.id.rawValue) }.map(\.name)
        }
        core.ledger.setFilter(LedgerLayerFilter.applying(layers: names, to: core.ledger.filter))
    }

    /// Selected markups that are hidden or locked by their layer leave the selection: a locked
    /// layer cannot be selected and a hidden one cannot be seen (ADR-0032).
    static func dropUnselectable(core: AppCoreEnvironment) {
        let selected = core.canvas.selectedMarkupIDs
        guard !selected.isEmpty else { return }
        let blocked = Set(core.snapshot.markups.filter { $0.layerLocked == true || $0.layerHidden == true }.map(\.id))
        let kept = selected.subtracting(blocked)
        if kept != selected { core.canvas.select(markupIDs: kept, additive: false) }
    }

    // MARK: Questions

    /// Asks for a new layer's name, adds it at the top, makes it active, and moves `markupIDs`
    /// onto it — all one undo step.
    static func newLayer(moving markupIDs: Set<UUID>, core: AppCoreEnvironment, window: NSWindow?) {
        let current = MarkupLayerSet(core.snapshot.markupLayers)
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("New Layer", comment: "New markup layer dialogue title")
        alert.informativeText = markupIDs.isEmpty
            ? NSLocalizedString("New markups go onto the new layer.", comment: "New markup layer dialogue detail")
            : NSLocalizedString("The selected markups move onto the new layer, and new markups go there too.", comment: "New markup layer dialogue detail with a selection")
        let field = NSTextField(string: current.suggestedName())
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 22)
        field.setAccessibilityLabel(NSLocalizedString("Layer name", comment: "Accessibility label of the New Layer name field"))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: NSLocalizedString("Add Layer", comment: "New markup layer dialogue: confirm"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Alert button"))
        if let typed = typeNameForTesting { field.stringValue = typed }
        ZenitModalPresenter.runAlert(alert, identifier: newLayerIdentifier, sheetedOn: window, answerWithoutAUser: .dismissed) { answer in
            guard answer == .button(0) else { return }
            let name = field.stringValue
            Task { @MainActor in await addLayer(named: name, moving: markupIDs, core: core) }
        }
    }

    /// Adds a layer named `name` at the top and makes it active; `markupIDs` move onto it in the
    /// same step. The testable half of ``newLayer(moving:core:window:)``.
    static func addLayer(named name: String, moving markupIDs: Set<UUID>, core: AppCoreEnvironment) async {
        let current = MarkupLayerSet(core.snapshot.markupLayers)
        let layer = MarkupLayer(id: LayerID(UUID()), name: name, order: 0)
        guard let next = try? current.adding(layer) else {
            core.status.setActiveToolNote(MarkupLayerRefusal.emptyName.description)
            return
        }
        var commands: [DocumentCommand] = [.setMarkupLayers(next.layers, change: .add)]
        let ordered = core.snapshot.markups.map(\.id).filter(markupIDs.contains).map(MarkupID.init)
        if !ordered.isEmpty { commands.append(.setMarkupLayer(ids: ordered, layerID: layer.id)) }
        do {
            _ = try await core.commands.performBatch(commands, actionName: MarkupLayerChange.add.actionName)
            await core.session.setActiveMarkupLayer(layer.id)
        } catch {
            ZenitPDFProjectDocument.reportRefusedEdit(error, core: core)
        }
        await core.refresh()
    }

    /// Asks where a deleted layer's markups go — offering every other layer, the default first —
    /// then deletes it and moves them, one step. A layer holding no markups is deleted after the
    /// same confirmation, with nothing to move.
    static func deleteLayer(_ id: UUID, core: AppCoreEnvironment, window: NSWindow?) {
        let set = MarkupLayerSet(core.snapshot.markupLayers)
        guard let layer = set.layer(LayerID(id)), !layer.isDefault else { return }
        let others = [set.layer(MarkupLayer.defaultID)].compactMap { $0 } + set.layers.filter { !$0.isDefault && $0.id != layer.id }
        let count = rows(from: core.snapshot).first { $0.id == id }?.markupCount ?? 0
        let alert = NSAlert()
        alert.messageText = String(format: NSLocalizedString("Delete the layer “%@”?", comment: "Delete markup layer dialogue title; layer name"), layer.name)
        alert.informativeText = count == 0
            ? NSLocalizedString("The layer holds no markups.", comment: "Delete markup layer dialogue detail: empty layer")
            : String(format: NSLocalizedString("Its %d markups move to the layer you choose. Their quantities stay in the Quantity Ledger.", comment: "Delete markup layer dialogue detail; markup count"), count)
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26), pullsDown: false)
        for other in others {
            popup.addItem(withTitle: other.name)
            popup.lastItem?.representedObject = other.id.rawValue.uuidString
        }
        popup.setAccessibilityLabel(NSLocalizedString("Move markups to", comment: "Accessibility label of the delete-layer target popup"))
        if count > 0 { alert.accessoryView = popup }
        alert.addButton(withTitle: NSLocalizedString("Delete Layer", comment: "Delete markup layer dialogue: confirm"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Alert button"))
        if let chosen = chooseDeleteTargetForTesting, let index = others.firstIndex(where: { $0.id.rawValue == chosen }) {
            popup.selectItem(at: index)
        }
        ZenitModalPresenter.runAlert(alert, identifier: deleteLayerIdentifier, sheetedOn: window, answerWithoutAUser: .dismissed) { answer in
            guard answer == .button(0) else { return }
            let target = (popup.selectedItem?.representedObject as? String).flatMap(UUID.init(uuidString:))
                ?? MarkupLayer.defaultID.rawValue
            Task { @MainActor in
                await perform(.deleteMarkupLayer(LayerID(id), moveMarkupsTo: LayerID(target)), core: core)
            }
        }
    }
}
