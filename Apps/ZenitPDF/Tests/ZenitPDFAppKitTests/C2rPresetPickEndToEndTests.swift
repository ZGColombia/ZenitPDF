import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// Quality loop cycle 2, X-018 end to end: the real `AppCoreEnvironment`, its
/// `AppToolLibraryPresenter`, the shell's toolbar and the application's own wiring between them
/// (`ProjectStructureWiring`'s library mirror, the canvas seam). The shell-tier cases are
/// `Iter7PresetToolSwitchTests`; the core's echo is `Iter7AppCoreTests.theEchoIsTheDrawingTool`.
@MainActor
@Suite(.appTierSerialised)
struct C2rPresetPickEndToEndTests {

    /// A Length preset whose row differs from a plain Length in every field the finding names.
    static func preset(_ name: String, _ kind: MeasurementKind, costCode: String = "1234") -> ToolPresetSummary {
        ToolPresetSummary(
            id: UUID(), name: name, category: "Test", panel: .myTools,
            markupKind: .measurement, measurementKind: kind,
            colorRGBA: ColorRGBA(red: 0.8, green: 0.2, blue: 0.1), defaultSubject: name,
            labelPattern: "K", defaultStatus: .open, customDefaults: ["custom.costCode": costCode]
        )
    }

    /// Draws a 100 pt Length on the canvas and commits it with Return, as a person does.
    static func drawLength(_ harness: Fix2Harness, y: Double) async {
        harness.canvas.handleClick(at: PDFPointValue(x: 100, y: y), additive: false)
        harness.canvas.handleClick(at: PDFPointValue(x: 200, y: y), additive: false)
        await harness.core.measurement.settlePlacements()
        harness.shell.perform(.finishGeometry)
        await harness.settle()
    }

    @Test("X-018: Kerb armed in Draw, then the Length key — the next Length is a plain Length")
    func theLengthKeyAfterAPresetCommitsAPlainLength() async throws {
        let harness = try await Fix2Harness.make("C2rPresetPick.pdf")
        defer { harness.tearDown() }
        let core = harness.core
        let shell = harness.shell
        let costCode = LedgerColumnDefinition(id: ColumnID(UUID()), key: "custom.costCode", title: "Cost code", kind: .text)
        try await core.session.addCustomColumns([costCode])
        await core.refresh()
        let kerb = Self.preset("Kerb", .length)
        core.toolLibrary.setPresets(core.toolLibrary.presets + [kerb])
        core.toolLibrary.setMode(.draw, for: kerb.panel)

        // The everyday gesture: a tile in the library, and the toolbar follows.
        core.toolLibrary.activatePreset(id: kerb.id)
        #expect(shell.toolbar.activeSelection.mode == .measure(.length))
        #expect(shell.toolbar.activeSelection.presetID == kerb.id, "the lit Length names the preset")
        await Self.drawLength(harness, y: 100)
        var records = await harness.records()
        let underPreset = try #require(records.last)
        // The control: drawn under the preset, a Length is Kerb's row. Without it the
        // assertions below could pass for a preset that never applied.
        #expect(underPreset.subject == "Kerb" && underPreset.status == .open)
        #expect(underPreset.customValues[costCode.id] == .text("1234"))

        // L — the menu command the key equivalent runs — with Length already lit.
        shell.perform(.measureLength)
        // Old output: Kerb still armed (the choice equalled the lit selection and was dropped).
        #expect(core.toolLibrary.activePresetID == nil)
        #expect(core.measurement.activeKind == .length, "the disarm put Length down; the choice re-armed it")
        #expect(harness.canvas.armedMode == .measure(.length))

        await Self.drawLength(harness, y: 300)
        records = await harness.records()
        #expect(records.count == 2)
        let plain = try #require(records.last)
        // Old output: subject "Kerb", status Open, cost code 1234, label "K".
        #expect(plain.subject == "Length")
        #expect(plain.status == .none)
        #expect(plain.customValues.isEmpty)
        #expect(plain.label != "K")
    }

    @Test("X-018: Area lit, an Apply preset armed — Select shows; choosing Area disarms it and Area draws")
    func choosingTheLitChipLeavesApply() async throws {
        let harness = try await Fix2Harness.make("C2rPresetApply.pdf")
        defer { harness.tearDown() }
        let core = harness.core
        let shell = harness.shell
        let slab = Self.preset("Slab", .area)
        core.toolLibrary.setPresets(core.toolLibrary.presets + [slab])
        core.toolLibrary.setMode(.apply, for: slab.panel)
        defer { core.toolLibrary.setMode(.draw, for: slab.panel) }

        shell.perform(.measureArea)
        core.toolLibrary.activatePreset(id: slab.id)
        // Old output: the Area chip stayed lit over a disarmed presenter.
        #expect(shell.toolbar.activeSelection.mode == .select)
        #expect(shell.toolbar.activeSelection.presetID == slab.id)
        #expect(core.measurement.activeKind == nil)
        #expect(core.status.snapshot.activeToolNote == ToolSetMode.apply.shortHelp,
                "the mirror's status refresh does not wipe what Apply means")

        shell.perform(.measureArea)
        // Old output: Slab still armed, Area unarmed — the next click went to the preset.
        #expect(core.toolLibrary.activePresetID == nil)
        #expect(core.measurement.activeKind == .area)
        harness.canvas.handleClick(at: PDFPointValue(x: 100, y: 100), additive: false)
        await core.measurement.settlePlacements()
        #expect(core.measurement.placedPoints.count == 1, "the click is the area's first vertex")
    }

    @Test("X-018: restyling a markup in the Inspector under an Apply preset keeps the preset armed")
    func aStyleEditKeepsTheApplyPreset() async throws {
        let harness = try await Fix2Harness.make("C2rPresetStyle.pdf")
        defer { harness.tearDown() }
        let core = harness.core
        let shell = harness.shell
        let slab = Self.preset("Slab", .area)
        core.toolLibrary.setPresets(core.toolLibrary.presets + [slab])
        core.toolLibrary.setMode(.apply, for: slab.panel)
        defer { core.toolLibrary.setMode(.draw, for: slab.panel) }

        shell.toolbar.activateShape(.rectangle)
        core.toolLibrary.activatePreset(id: slab.id)
        // The call `InspectorEditingSupport.apply` makes for a restyled rectangle.
        shell.toolbar.rememberStyle(MarkupStyleEdit(lineWidth: 6), kinds: [.rectangle])
        // Old output: nil — the style re-arm of the lit Rectangle reached the disarm.
        #expect(core.toolLibrary.activePresetID == slab.id)
        #expect(core.toolLibrary.armedSetMode == .apply)
    }
}
