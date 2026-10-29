import Foundation
import SwiftUI
import Testing
import ZPDFDesignSystem
import ZPDFUIPresentation
@testable import ZPDFUIShell

/// The UX round (nl-ux): its shell-tier bugs.
/// Each test names the old output it would have seen.
@MainActor
@Suite("nl-ux shell bugs", .shellTierSerialised)
struct NLUXShellBugTests {

    private static let sample = ZenitSampleProject.shared.markups

    private func zone(_ name: String, id: UUID = UUID()) -> ProjectZoneSummary {
        ProjectZoneSummary(id: id, name: name, kind: .room, colorRGBA: ColorRGBA.Zenit.Dark.cyan)
    }

    // MARK: - Zoom to Selection

    /// Old output: Properties ▸ Actions ▸ Zoom to Selection called
    /// `canvas.zoomTo(markupID: first.id)` — the mock canvas zoomed to 2.0 on the first markup
    /// and the selection collapsed to that one markup, and the command bus never heard it.
    @Test("Actions ▸ Zoom to Selection fits the whole selection through the shared command")
    func zoomToSelectionFitsTheWholeSelection() throws {
        let environment = ProjectShellEnvironment.mock()
        var forwarded: [ZPDFCommandID] = []
        environment.externalCommandHandler = { forwarded.append($0) }
        let targets = Array(Self.sample.prefix(3))
        try #require(targets.count == 3)
        let zoomBefore = environment.canvas.viewport.zoom
        let panel = InspectorPanel(environment: environment, panelState: ShellPanelState())

        panel.zoomToSelection(InspectorSelectionSummary(markups: targets))

        #expect(forwarded == [.zoomToSelection])
        #expect(environment.canvas.viewport.zoom == zoomBefore, "the first markup alone was not zoomed to")

        forwarded = []
        panel.zoomToSelection(InspectorSelectionSummary(markups: []))
        #expect(forwarded.isEmpty)
    }

    // MARK: - Locked / Hidden as controls

    /// Old output: the Locked and Hidden rows were `Text`; nothing on them could call
    /// `onSetLocked` / `onSetHidden`.
    @Test("The Locked and Hidden rows set the whole selection through the wired commands")
    func lockAndHideRowsAct() throws {
        let environment = ProjectShellEnvironment.mock()
        var locks: [(Set<UUID>, Bool)] = []
        var hides: [(Set<UUID>, Bool)] = []
        environment.inspectorEditing.onSetLocked = { locks.append(($0, $1)) }
        environment.inspectorEditing.onSetHidden = { hides.append(($0, $1)) }
        let unlocked = Self.sample.filter { !$0.locked }.prefix(2).map { var m = $0; m.hidden = false; return m }
        try #require(unlocked.count == 2)
        let summary = InspectorSelectionSummary(markups: Array(unlocked))
        let panel = InspectorPanel(environment: environment, panelState: ShellPanelState())

        panel.setLocked(true, for: summary)
        panel.setHidden(true, for: summary)

        #expect(locks.count == 1)
        #expect(locks.first?.0 == Set(unlocked.map(\.id)))
        #expect(locks.first?.1 == true)
        #expect(hides.count == 1)
        #expect(hides.first?.1 == true)
    }

    @Test("Hiding a selection with a locked markup is refused before it reaches the engine")
    func hideRefusesLockedSelection() throws {
        let environment = ProjectShellEnvironment.mock()
        var hides = 0
        environment.inspectorEditing.onSetHidden = { _, _ in hides += 1 }
        var locked = try #require(Self.sample.first)
        locked.locked = true
        locked.hidden = false
        let panel = InspectorPanel(environment: environment, panelState: ShellPanelState())
        panel.setHidden(true, for: InspectorSelectionSummary(markups: [locked]))
        #expect(hides == 0)
        #expect(InspectorPanel.booleanAccessibilityValue(nil) == InspectorSelectionSummary.mixedPlaceholder)
        #expect(InspectorPanel.booleanAccessibilityValue(true) == "On")
    }

    // MARK: - Project Zone as a popup

    /// Old output: the Project Zone row was `Text`; a zone could be assigned only from the
    /// Zones page, and a markup could not be filed out of a zone from anywhere.
    @Test("The Project Zone popup files the selection into a zone, and out of every zone")
    func zonePopupAssigns() throws {
        let environment = ProjectShellEnvironment.mock()
        let kitchen = zone("Kitchen")
        environment.projectZones.setZones([kitchen, zone("Hall")])
        var calls: [(Set<UUID>, UUID?)] = []
        environment.inspectorEditing.onSetZone = { calls.append(($0, $1)) }
        let targets = Self.sample.filter { !$0.locked }.prefix(2)
        try #require(targets.count == 2)
        let summary = InspectorSelectionSummary(markups: Array(targets))
        let panel = InspectorPanel(environment: environment, panelState: ShellPanelState())

        #expect(panel.canAssignZone(summary))
        panel.assignZone(kitchen.id, for: summary)
        panel.assignZone(nil, for: summary)
        panel.assignZone(UUID(), for: summary)  // not a zone of this project: refused

        #expect(calls.count == 2)
        #expect(calls[0].0 == Set(targets.map(\.id)))
        #expect(calls[0].1 == kitchen.id)
        #expect(calls[1].1 == nil)
    }

    @Test("The zone popup is off, with a reason, for a locked selection or an unwired host")
    func zonePopupDisabledStates() throws {
        let environment = ProjectShellEnvironment.mock()
        let panel = InspectorPanel(environment: environment, panelState: ShellPanelState())
        let target = try #require(Self.sample.first { !$0.locked })
        let summary = InspectorSelectionSummary(markups: [target])
        #expect(!panel.canAssignZone(summary), "unwired")
        #expect(!InspectorPanel.zoneDisabledReason(summary, wired: false).isEmpty)
        environment.inspectorEditing.onSetZone = { _, _ in }
        #expect(panel.canAssignZone(summary))
        var locked = target
        locked.locked = true
        #expect(!panel.canAssignZone(InspectorSelectionSummary(markups: [locked])))
        #expect(!InspectorPanel.zoneDisabledReason(InspectorSelectionSummary(markups: [locked]), wired: true).isEmpty)
    }

    // MARK: - Layer row

    /// The Layer row is a value now, not a popup face. What it reads is unchanged.
    @Test("The Layer row reads the shared layer, None, or the mixed placeholder")
    func layerRowText() throws {
        var a = try #require(Self.sample.first)
        var b = try #require(Self.sample.dropFirst().first)
        a.layer = "Electrical"
        b.layer = "Electrical"
        #expect(InspectorPanel.layerText(InspectorSelectionSummary(markups: [a, b])) == "Electrical")
        b.layer = nil
        #expect(InspectorPanel.layerText(InspectorSelectionSummary(markups: [a, b])) == InspectorSelectionSummary.mixedPlaceholder)
        a.layer = nil
        #expect(InspectorPanel.layerText(InspectorSelectionSummary(markups: [a, b])) == "None")
    }

    // MARK: - Export chip

    /// Old output: the Export chip's action was `environment.perform(.export)`, which the app
    /// services with the ledger export alone.
    @Test("The Export chip opens the export chooser, not the ledger export")
    func exportChipOpensTheChooser() throws {
        let environment = ProjectShellEnvironment.mock()
        var forwarded: [ZPDFCommandID] = []
        var chooserOpened = 0
        environment.externalCommandHandler = { forwarded.append($0) }
        environment.onPresentExportChooser = { chooserOpened += 1 }
        let builder = ZenitToolbarBuilder(environment: environment)
        let chip = try #require(builder.workspaceChip(.zenitExport))

        chip.action()

        #expect(chooserOpened == 1)
        #expect(forwarded.isEmpty, "the ledger export was not run directly")
        #expect(chip.helpText().contains(ZenitToolbarBuilder.exportChipHelp))
    }

    @Test("Without a chooser wired, the Export chip still exports something")
    func exportChipFallsBack() throws {
        let environment = ProjectShellEnvironment.mock()
        var forwarded: [ZPDFCommandID] = []
        environment.externalCommandHandler = { forwarded.append($0) }
        environment.presentExportChooser()
        #expect(forwarded == [.export])
    }

    // MARK: - LT3-06

    /// LT3-06 invariant: for every tool the toolbar can arm, exactly one chip identity is lit.
    @Test("Exactly one tool chip is armed for every tool")
    func exactlyOneChipArmed() {
        let identifiers = ZenitToolbarBuilder.allowedItemIdentifiers
        for tool in ZenitToolIdentifier.allCases {
            let lit = identifiers.filter {
                ZenitToolbarBuilder.selectionIdentifier(for: tool, lastUsedMeasurement: .volume) == $0
            }
            #expect(lit.count == 1, "\(tool) lights \(lit.map(\.rawValue))")
        }
    }
}
