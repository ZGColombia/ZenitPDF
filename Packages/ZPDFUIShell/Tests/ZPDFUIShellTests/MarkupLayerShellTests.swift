import Foundation
import SwiftUI
import Testing
import ZPDFDesignSystem
import ZPDFUIPresentation
@testable import ZPDFUIShell

/// ADR-0032 (unit r2-layers): the shell's half of markup layers — the Navigator's model and the
/// Inspector's Layer popup. The shell renders what the application applies and routes requests;
/// these tests pin the routing and the refusals, without a window.
@MainActor
@Suite(.shellTierSerialised)
struct MarkupLayerShellTests {

    private static let sample = ZenitSampleProject.shared.markups
    private static let walls = UUID(uuidString: "00000000-0000-4000-8000-00000000A001")!
    private static let base = UUID(uuidString: "5A1E0000-0000-4000-8000-00000000DEF0")!

    private static func rows() -> [MarkupLayerRow] {
        [
            MarkupLayerRow(id: walls, name: "Walls", isVisible: false, isLocked: true, isPrintable: false, markupCount: 4),
            MarkupLayerRow(id: base, name: "Default", markupCount: 7, isDefault: true)
        ]
    }

    @Test("The model installs rows and routes each request once, refusing the no-ops and the default layer's delete")
    func modelRoutes() {
        let model = MarkupLayerPanelModel()
        #expect(!model.isInstalled, "a surface without a project keeps the name-derived list")
        model.apply(rows: Self.rows(), activeLayerID: Self.base)
        #expect(model.isInstalled)
        #expect(model.rows.map(\.name) == ["Walls", "Default"])

        var calls: [String] = []
        model.onRename = { id, name in calls.append("rename \(id == Self.walls) \(name)") }
        model.onMove = { id, index in calls.append("move \(id == Self.walls) \(index)") }
        model.onSetVisible = { _, visible in calls.append("visible \(visible)") }
        model.onSetLocked = { _, locked in calls.append("locked \(locked)") }
        model.onSetPrintable = { _, printable in calls.append("printable \(printable)") }
        model.onDelete = { id in calls.append("delete \(id == Self.walls)") }
        model.onSetActive = { id in calls.append("active \(id == Self.walls)") }
        model.onAssign = { ids, id in calls.append("assign \(ids.count) \(id == Self.walls)") }
        model.onNewLayer = { ids in calls.append("new \(ids.count)") }
        model.onFilterLedger = { ids in calls.append("filter \(ids.map { $0 == [Self.walls] } ?? false)") }

        model.rename(Self.walls, to: "  Partitions ")
        model.rename(Self.walls, to: "Walls")          // unchanged: nothing
        model.rename(Self.walls, to: "   ")            // blank: nothing
        model.move(Self.walls, to: 5)                  // clamped to the last index, 1
        model.move(Self.walls, to: 0)                  // already there: nothing
        model.setVisible(false, layer: Self.walls)     // already hidden: nothing
        model.setVisible(true, layer: Self.walls)
        model.setLocked(false, layer: Self.walls)
        model.setPrintable(true, layer: Self.walls)
        model.delete(Self.base)                        // the default layer: refused
        model.delete(Self.walls)
        model.setActive(Self.base)                     // already active: nothing
        model.setActive(Self.walls)
        // W-049: through the one gated route, the one the Navigator and the Inspector use. Walls
        // is locked, so the move goes to the default layer.
        let unlocked = Array(Self.sample.filter { !$0.locked }.prefix(2))
        model.assign([MarkupSummary](), to: Self.base)  // nothing selected: nothing
        model.assign(unlocked, to: Self.walls)          // a locked layer takes nothing
        model.assign(unlocked, to: Self.base)
        model.newLayer(moving: [UUID()])
        model.toggleLedgerFilter(Self.walls)

        #expect(calls == [
            "rename true Partitions", "move true 1", "visible true", "locked false", "printable true",
            "delete true", "active true", "assign \(unlocked.count) false", "new 1", "filter true"
        ])
        #expect(unlocked.count == 2)
    }

    @Test("Filtering the ledger by a layer toggles: the same layer again lifts the filter")
    func ledgerFilterToggles() {
        let model = MarkupLayerPanelModel()
        var last: Set<UUID>?? = .none
        model.onFilterLedger = { last = .some($0) }
        model.apply(rows: Self.rows(), activeLayerID: Self.base, ledgerFilterLayerIDs: [Self.walls])
        model.toggleLedgerFilter(Self.walls)
        #expect(last == .some(nil), "already Walls alone: lifted")
        model.apply(rows: Self.rows(), activeLayerID: Self.base, ledgerFilterLayerIDs: nil)
        model.toggleLedgerFilter(Self.walls)
        #expect(last == .some([Self.walls]))
    }

    @Test("The Inspector's Layer popup moves the selection, makes a layer from it, and is off for a locked selection")
    func inspectorPopup() throws {
        let environment = ProjectShellEnvironment.mock()
        let panel = InspectorPanel(environment: environment, panelState: ShellPanelState())
        let targets = Array(Self.sample.filter { !$0.locked }.prefix(2))
        try #require(targets.count == 2)
        let summary = InspectorSelectionSummary(markups: targets)
        #expect(panel.layerRefusal(summary) != nil, "no project layers installed yet")
        // W-052: the help comes from the same rule. Old output: "" — the hand-written reason
        // knew only the two lock cases.
        #expect(panel.layerRefusal(summary) == .unknownLayer)
        #expect(!MarkupLayerPanelModel.reason(.unknownLayer).isEmpty)

        environment.markupLayers.apply(rows: Self.rows(), activeLayerID: Self.base)
        var assigned: [(Set<UUID>, UUID)] = []
        var created: [Set<UUID>] = []
        environment.markupLayers.onAssign = { assigned.append(($0, $1)) }
        environment.markupLayers.onNewLayer = { created.append($0) }
        #expect(panel.layerRefusal(summary) == nil)
        // V-046: Walls is locked, and a locked layer takes nothing — the Navigator's rule too.
        panel.assignLayer(Self.walls, for: summary)
        #expect(assigned.isEmpty, "a locked target is refused")
        panel.assignLayer(Self.base, for: summary)
        panel.newLayer(for: summary)
        #expect(assigned.count == 1)
        #expect(assigned.first?.0 == Set(targets.map(\.id)))
        #expect(assigned.first?.1 == Self.base)
        #expect(created == [Set(targets.map(\.id))])

        // A markup on a locked layer: the popup is off and says why.
        var onLockedLayer = targets[0]
        onLockedLayer.locked = true
        onLockedLayer.layerLocked = true
        let locked = InspectorSelectionSummary(markups: [onLockedLayer])
        #expect(panel.layerRefusal(locked) != nil)
        #expect(panel.layerRefusal(locked) == .markupOnLockedLayer)
        #expect(panel.layerRefusal(locked).map(MarkupLayerPanelModel.reason)?.contains("locked layer") == true)
        #expect(InspectorPanel.lockedLayerReason == MarkupLayerPanelModel.reason(.markupOnLockedLayer))
        panel.assignLayer(Self.base, for: locked)
        #expect(assigned.count == 1, "refused, nothing routed")
    }

    @Test("A layer row speaks its name as a markup layer and its state in words, never colour alone")
    func spokenState() {
        let row = Self.rows()[0]
        #expect(MarkupLayerPanelModel.spokenName(row) == "Walls, markup layer")
        #expect(MarkupLayerPanelModel.spokenState(row, isActive: false) == "Hidden, Locked, Not printed, 4 markups")
        #expect(MarkupLayerPanelModel.spokenState(Self.rows()[1], isActive: true) == "Visible, Active, 7 markups")
        #expect(MarkupLayerRowView.subtitle(isActive: true, printable: false) == "New markups go here · Not printed")
    }
}
