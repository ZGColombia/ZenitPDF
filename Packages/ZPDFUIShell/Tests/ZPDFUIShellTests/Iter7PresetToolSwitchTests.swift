import Foundation
import Observation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIShell

/// Quality loop cycle 2 (iteration 7), X-018: a tool the person chooses off the toolbar, from a
/// menu or by its key replaces the armed Tool Library preset — the lit tool included — and a
/// style re-arm never does, in any set mode.
///
/// The library here does what the app core does when a preset arms (`AppCoreEnvironment`'s
/// `onArm`): it arms or puts down the measurement presenter, and it lights the tool the canvas
/// will use through the shell's mirror (`libraryArmed(_:)`) — the preset's drawing tool in Draw,
/// Select otherwise. Disarming puts the presenter down as the core does, so "the chosen tool
/// still draws" is something the seam has to re-arm, not something left over. The end-to-end
/// half, through the real app core and the app's own wiring, is `C2rPresetPickEndToEndTests` in
/// the application's tests.
@MainActor
@Suite("Iteration 7: a toolbar choice replaces the armed preset", .shellTierSerialised)
struct Iter7PresetToolSwitchTests {

    /// A Tool Library over fixed presets that arms and mirrors as the core does.
    @MainActor
    @Observable
    final class EchoingLibrary: ToolLibraryPresenting {
        let panels: [ToolLibraryPanel] = ToolLibraryPanel.allCases
        private(set) var activePanel: ToolLibraryPanel = .myTools
        let presets: [ToolPresetSummary]
        private(set) var activePresetID: ToolPresetSummary.ID?
        private(set) var reuseToolEnabled = true
        private(set) var searchText = ""
        private(set) var setModes: [ToolLibraryPanel: ToolSetMode] = [:]
        /// How many times the preset was disarmed.
        private(set) var clearCount = 0
        /// The core's `onArm`: what a preset arming does to the presenters and the toolbar.
        /// `nil` for a harness without the core's mirror.
        @ObservationIgnored var onArm: ((ToolPresetSummary?, ToolSetMode) -> Void)?

        init(presets: [ToolPresetSummary]) { self.presets = presets }

        func selectPanel(_ panel: ToolLibraryPanel) { activePanel = panel }
        func activatePreset(id: ToolPresetSummary.ID) {
            guard let preset = presets.first(where: { $0.id == id }) else { return }
            activePresetID = id
            onArm?(preset, mode(of: preset.panel))
        }
        func clearActivePreset() {
            guard activePresetID != nil else { return }
            activePresetID = nil
            clearCount += 1
            onArm?(nil, .draw)
        }
        func toggleFavorite(id: ToolPresetSummary.ID) {}
        func setReuseToolEnabled(_ enabled: Bool) { reuseToolEnabled = enabled }
        func setSearchText(_ text: String) { searchText = text }
        func movePreset(id: ToolPresetSummary.ID, to index: Int) {}
        func setMode(_ mode: ToolSetMode, for panel: ToolLibraryPanel) {
            setModes[panel] = mode
            if let preset = activePreset, preset.panel == panel { onArm?(preset, mode) }
        }
        @discardableResult
        func markupCommitted() -> Bool { reuseToolEnabled }
    }

    static func preset(
        _ name: String,
        markup: MarkupKind,
        measure: MeasurementKind? = nil,
        panel: ToolLibraryPanel = .myTools,
        symbol: String? = nil
    ) -> ToolPresetSummary {
        ToolPresetSummary(
            id: UUID(), name: name, category: "Test", panel: panel,
            markupKind: markup, measurementKind: measure,
            colorRGBA: ColorRGBA(red: 0.8, green: 0.2, blue: 0.1), defaultSubject: name,
            labelPattern: "\(name) 1", defaultStatus: .open,
            customDefaults: ["unitCost": "12"], countSymbolName: symbol
        )
    }

    static let kerb = preset("Kerb", markup: .measurement, measure: .length)
    static let slab = preset("Slab", markup: .measurement, measure: .area)
    static let rfi = preset("RFI", markup: .cloud)
    static let stamp = preset("Approved", markup: .stamp)
    static let doors = preset("Doors", markup: .count, measure: .count, panel: .countSymbols, symbol: "square")

    /// - Parameter mirrored: `false` builds a harness without the core's arming and mirror, so
    ///   whatever chip was lit before a preset armed stays lit.
    private func makeEnvironment(mirrored: Bool = true) -> (ProjectShellEnvironment, EchoingLibrary) {
        let mocks = MockPresenters.makeEnvironment()
        let library = EchoingLibrary(presets: [Self.kerb, Self.slab, Self.rfi, Self.stamp, Self.doors])
        let environment = ProjectShellEnvironment(
            document: mocks.document,
            canvas: mocks.canvas,
            ledger: mocks.ledger,
            toolLibrary: library,
            search: mocks.search,
            compare: mocks.compare,
            measurement: mocks.measurement,
            status: mocks.status
        )
        guard mirrored else { return (environment, library) }
        let measurement = mocks.measurement
        library.onArm = { [weak environment] preset, mode in
            guard let preset else {
                // Disarming puts both drawing families down (`clearActivePreset()` → `onArm(nil)`).
                measurement.deactivate()
                return
            }
            if mode == .draw, let kind = preset.measurementKind {
                measurement.activate(kind: kind)
            } else {
                measurement.deactivate()
            }
            environment?.libraryArmed(mode == .draw ? (preset.drawingTool ?? .select) : .select)
        }
        return (environment, library)
    }

    // MARK: Choosing the lit tool

    @Test("Kerb (Length, Draw): choosing Length again — chip, menu or L — disarms it, and Length draws")
    func choosingTheLitToolDisarmsTheDrawPreset() {
        let (environment, library) = makeEnvironment()
        library.activatePreset(id: Self.kerb.id)
        #expect(environment.toolbar.activeSelection.mode == .measure(.length), "the mirror lit the preset's tool")
        #expect(environment.toolbar.activeSelection.presetID == Self.kerb.id, "the lit tool names the preset")
        #expect(library.activePresetID == Self.kerb.id, "the mirror is not a choice")

        environment.toolbar.activateMeasurement(.length)
        // Old output: activePresetID == Kerb, clearCount 0 — `arm` dropped the choice as equal to
        // the lit Length, so the next Length was filed under "Kerb" with its status, label and
        // unit cost.
        #expect(library.activePresetID == nil)
        #expect(library.clearCount == 1)
        #expect(environment.toolbar.activeSelection.presetID == nil)
        #expect(environment.measurement.activeKind == .length, "the disarm put Length down; the choice re-armed it")

        // The menu command and its key (L) are the same choice.
        library.activatePreset(id: Self.kerb.id)
        environment.perform(.measureLength)
        #expect(library.activePresetID == nil)
        #expect(library.clearCount == 2)
        #expect(environment.measurement.activeKind == .length)
    }

    @Test("Kerb (Draw), then another tool: disarmed, and the chosen tool armed")
    func choosingAnotherToolDisarmsTheDrawPreset() {
        let (environment, library) = makeEnvironment()
        library.activatePreset(id: Self.kerb.id)
        environment.toolbar.activateMeasurement(.area)
        #expect(library.activePresetID == nil)
        #expect(environment.measurement.activeKind == .area)

        library.activatePreset(id: Self.kerb.id)
        environment.perform(.measureArea)
        #expect(library.activePresetID == nil)
        #expect(environment.measurement.activeKind == .area)
    }

    @Test("Door Count armed from the library, then plain Count: disarmed; the Count palette's own preset is kept")
    func plainCountDisarmsACountPreset() {
        let (environment, library) = makeEnvironment()
        library.activatePreset(id: Self.doors.id)
        #expect(environment.toolbar.activeSelection.mode == .measure(.count))
        #expect(environment.toolbar.activeSelection.countSymbolName == "square", "the mirror carries the glyph")

        // The palette choosing the armed preset again is that preset, so it stays — and the
        // palette's selection and the mirror's are one selection.
        let lit = environment.toolbar.activeSelection
        environment.toolbar.activateCountPreset(id: Self.doors.id)
        #expect(library.activePresetID == Self.doors.id)
        #expect(environment.toolbar.activeSelection == lit)

        // Plain Count (the palette's "Count" item; the Count key when no count preset is left).
        environment.toolbar.activateMeasurement(.count)
        // Old output: Doors still armed — plain Count was the lit selection.
        #expect(library.activePresetID == nil)
        #expect(environment.measurement.activeKind == .count)
    }

    @Test("The Count palette replaces Kerb with its preset, and a later choice disarms that")
    func theCountPaletteReplacesThePreset() {
        let (environment, library) = makeEnvironment()
        library.activatePreset(id: Self.kerb.id)
        environment.toolbar.activateCountPreset(id: Self.doors.id)
        #expect(library.activePresetID == Self.doors.id, "the palette's own preset replaced Kerb")
        #expect(library.clearCount == 1)
        #expect(environment.toolbar.activeSelection.mode == .measure(.count))

        environment.toolbar.activateMeasurement(.length)
        #expect(library.activePresetID == nil)
    }

    // MARK: Apply and Place

    @Test("Apply/Place: the toolbar shows Select; choosing the chip lit before the arm disarms, and it draws")
    func applyAndPlaceAreLeftByChoosingTheLitChip() {
        for mode in [ToolSetMode.apply, .place] {
            let (environment, library) = makeEnvironment()
            environment.toolbar.activateMeasurement(.area)
            library.setMode(mode, for: .myTools)
            library.activatePreset(id: Self.slab.id)
            #expect(environment.measurement.activeKind == nil, "\(mode): the arming put the drawing tool down")
            // Old output: .measure(.area) — the Area chip stayed lit over a disarmed presenter.
            #expect(environment.toolbar.activeSelection.mode == .select, "\(mode)")
            #expect(environment.toolbar.activeSelection.presetID == Self.slab.id, "\(mode)")

            environment.toolbar.activateMeasurement(.area)
            // Old output: Slab still armed and Area not drawing — the choice equalled the lit
            // selection, so neither the disarm nor the presenter's arming ran, and the canvas
            // kept sending every click to the preset.
            #expect(library.activePresetID == nil, "\(mode)")
            #expect(environment.measurement.activeKind == .area, "\(mode)")
        }
    }

    @Test("Apply/Place: choosing Select, the tool already lit, disarms too")
    func applyAndPlaceAreLeftBySelect() {
        for mode in [ToolSetMode.apply, .place] {
            let (environment, library) = makeEnvironment()
            library.setMode(mode, for: .myTools)
            library.activatePreset(id: Self.kerb.id)
            #expect(environment.toolbar.activeTool == .select)
            environment.perform(.selectTool)
            #expect(library.activePresetID == nil, "\(mode)")
        }
    }

    @Test("Draw → Apply with the preset armed: Select lit; Apply → Draw: the preset's tool again, kept")
    func aSetModeSwitchReMirrors() {
        let (environment, library) = makeEnvironment()
        library.activatePreset(id: Self.kerb.id)
        library.setMode(.apply, for: .myTools)
        #expect(environment.toolbar.activeSelection == ZenitToolSelection(
            mode: .select, presetID: Self.kerb.id, style: environment.toolbar.toolStyle
        ))
        library.setMode(.draw, for: .myTools)
        #expect(environment.toolbar.activeSelection.mode == .measure(.length))
        #expect(library.activePresetID == Self.kerb.id)
        #expect(library.clearCount == 0)
        #expect(environment.measurement.activeKind == .length)
    }

    // MARK: Style re-arms

    @Test("A style re-arm never disarms — Draw, Apply or Place, mirrored or not")
    func aStyleRearmIsNeverAChoice() {
        for mirrored in [true, false] {
            for mode in [ToolSetMode.draw, .apply, .place] {
                let (environment, library) = makeEnvironment(mirrored: mirrored)
                environment.toolbar.activateShape(.rectangle)
                library.setMode(mode, for: .myTools)
                library.activatePreset(id: Self.rfi.id)
                let before = environment.toolbar.activeSelection

                // What the Inspector does when a person restyles a selected markup.
                environment.toolbar.rememberStyle(MarkupStyleEdit(lineWidth: before.style.lineWidth + 2))
                let label = "\(mode), mirrored \(mirrored)"
                // Old output (Apply or Place, and Draw unmirrored): activePresetID nil — `setStyle`
                // re-armed the lit Rectangle, which reached the disarm as a tool change.
                #expect(library.activePresetID == Self.rfi.id, "\(label)")
                #expect(library.clearCount == 0, "\(label)")
                if before.mode.markupKind != nil {
                    #expect(environment.toolbar.activeSelection.style.lineWidth == before.style.lineWidth + 2,
                            "\(label): the lit markup tool was re-armed with the new stroke")
                }

                var thicker = environment.toolbar.toolStyle
                thicker.lineWidth += 1
                environment.toolbar.setStyle(thicker)
                #expect(library.activePresetID == Self.rfi.id, "\(label)")
            }
        }
    }

    @Test("A Cloud preset (Draw): restyled, it stays; Select disarms it")
    func aMarkupPresetKeepsThroughAStyleAndLeavesOnSelect() {
        let (environment, library) = makeEnvironment()
        var red = environment.toolbar.toolStyle
        red.lineWidth = 7
        environment.toolbar.setStyle(red)
        library.activatePreset(id: Self.rfi.id)
        #expect(environment.toolbar.activeSelection.mode == .markup(.cloud))
        // The core armed the cloud tool with the preset's look, and the canvas re-arms the tool
        // from this selection: the tool style would replace that look.
        #expect(environment.toolbar.activeSelection.style == Self.rfi.placementStyle)
        #expect(environment.toolbar.activeSelection.style.lineWidth != 7)
        var thicker = environment.toolbar.toolStyle
        thicker.lineWidth += 2
        environment.toolbar.setStyle(thicker)
        #expect(environment.toolbar.activeSelection.style.lineWidth == thicker.lineWidth)
        #expect(environment.toolbar.activeSelection.presetID == Self.rfi.id, "the re-arm keeps the preset's name")
        #expect(library.activePresetID == Self.rfi.id)

        environment.toolbar.selectTool(.select)
        #expect(library.activePresetID == nil)
    }

    // MARK: Presets that draw nothing, and nothing armed

    @Test("A preset that draws nothing in Draw lights Select naming it, and any choice disarms it")
    func aPresetWithoutADrawingToolIsDisarmed() {
        let (environment, library) = makeEnvironment()
        environment.toolbar.activateShape(.rectangle)
        #expect(Self.stamp.drawingTool == nil)
        library.activatePreset(id: Self.stamp.id)
        #expect(environment.toolbar.activeSelection.mode == .select)
        #expect(environment.toolbar.activeSelection.presetID == Self.stamp.id)
        environment.toolbar.selectTool(.pan)
        #expect(library.activePresetID == nil)
    }

    @Test("Nothing armed: a choice has nothing to disarm")
    func nothingArmedNothingCleared() {
        let (environment, library) = makeEnvironment()
        environment.toolbar.activateMeasurement(.length)
        environment.toolbar.activateMeasurement(.length)
        environment.toolbar.selectTool(.select)
        #expect(library.clearCount == 0)
    }

    @Test("onToolChosen: raised for every choice, the lit tool included; never for a style or the mirror")
    func whatCountsAsAChoice() {
        let toolbar = ZenitToolbarModel()
        var chosen: [ZenitToolSelection] = []
        toolbar.onToolChosen = { chosen.append($0) }
        toolbar.activateMeasurement(.length)
        toolbar.activateMeasurement(.length)
        toolbar.selectTool(.select)
        toolbar.selectTool(.select)
        toolbar.activateShape(.rectangle)
        toolbar.activateShapeVariant(.highlighter)
        toolbar.activateLastUsedMeasurement()
        toolbar.activateLastUsedCount()
        #expect(chosen.count == 8)
        #expect(chosen.allSatisfy { $0.presetID == nil })

        chosen = []
        toolbar.activateShape(.cloud)
        chosen = []
        var style = toolbar.toolStyle
        style.lineWidth += 3
        toolbar.setStyle(style)
        toolbar.rememberStyle(MarkupStyleEdit(lineWidth: 9))
        toolbar.showLibraryArm(.measure(.area), preset: Self.slab)
        toolbar.showLibraryArm(.select, preset: Self.stamp)
        #expect(chosen.isEmpty)
        #expect(toolbar.activeSelection.presetID == Self.stamp.id)
    }
}
