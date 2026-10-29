import AppKit
import Foundation
import Testing
import ZPDFDesignSystem
import ZPDFUIPresentation
@testable import ZPDFUIShell

/// Fix round 2, shell part D2: the toolbar model, the toolbar builder and the keyboard map.
///
/// | ID | Rule | Test |
/// |---|---|---|
/// | BH-054 / IM-138 | the Count palette follows the Tool Library | ``countPaletteFollowsTheLibrary()``, ``builderBindsTheCountPalette()`` |
/// | IM-031 | the Measure button keeps meaning the rarer tool | ``measurePaletteKeepsTheRarerTool()`` |
/// | BH-824 | Text and Callout never become the Shapes memory | ``textIsNotAShape()`` |
/// | IM-141 | the Shapes memory restores | ``shapeMemoryRestores()`` |
/// | BH-283 | shifted digit rows reach the slots | ``shiftedDigitRowsReachTheSlots()`` |
/// | IM-116 | every toolbar tool has a canvas key | ``everyToolHasACanvasKey()``, ``lettersArmToolsOnlyOnTheCanvas()`` |
/// | BH-799 | `⌘?` cannot slip past the Help audit | ``helpChordWithoutShiftIsCaught()`` |
/// | BH-300 / IM-140 | the Measure chip is `.measureTool`, and its overflow keeps the list | ``measureChipIsTheMeasureTool()`` |
/// | IM-139 | tooltips carry the usage hint | ``tooltipsCarryTheHint()`` |
/// | IM-226 | the Measure palette is grouped by family | ``measurePaletteIsGrouped()`` |
/// | IM-227 | an empty Count palette points at the next step | ``emptyCountPaletteOffersTheNextStep()`` |
@Suite("Fix2 D2 — toolbar, palettes and keyboard map", .shellTierSerialised)
@MainActor
struct Fix2D2ToolbarAndCommandTests {

    /// A preset list a test can change after the palette was bound — the Tool Library gaining
    /// and losing presets while the window is open.
    @MainActor
    private final class PresetBox {
        var presets: [ToolPresetSummary]
        init(_ presets: [ToolPresetSummary]) { self.presets = presets }
    }

    private func newCountPreset(like base: ToolPresetSummary) -> ToolPresetSummary {
        ToolPresetSummary(
            id: UUID(),
            name: "Floor Socket",
            category: base.category,
            panel: base.panel,
            markupKind: .count,
            measurementKind: .count,
            colorRGBA: base.colorRGBA,
            defaultSubject: "Floor Socket",
            countSymbolName: "circle.fill",
            sortIndex: 10_000
        )
    }

    // MARK: - BH-054 / IM-138

    /// Old output, against the palette frozen at shell init (`updateCountPalette(from:)` called
    /// once; no live source):
    ///
    /// ```
    /// ✘ Expectation failed: (toolbar.activeSelection.presetID → nil) == added.id
    ///   — the preset the menu listed armed plain Count
    /// ✘ Expectation failed: (toolbar.lastUsedCountPresetID → nil) == added.id
    /// ✘ Expectation failed: (toolbar.activeSelection.presetID → <deleted id>) != added.id
    ///   — the deleted preset kept being re-armed with a dead id
    /// ```
    @Test("A count preset created after the shell was built arms as itself; a deleted one is not re-armed")
    func countPaletteFollowsTheLibrary() throws {
        let sample = ZenitSampleProject.shared.presets
        let base = try #require(sample.first { $0.markupKind == .count })
        let box = PresetBox(sample)
        let toolbar = ZenitToolbarModel()
        toolbar.bindCountPalette { box.presets }

        let added = newCountPreset(like: base)
        box.presets.append(added)
        #expect(toolbar.countPalette.contains { $0.id == added.id }, "the palette did not see the new preset")

        toolbar.activateCountPreset(id: added.id)
        #expect(toolbar.activeSelection.presetID == added.id)
        #expect(toolbar.activeSelection.countSymbolName == "circle.fill")
        #expect(toolbar.lastUsedCountPresetID == added.id)

        box.presets.removeAll { $0.id == added.id }
        #expect(toolbar.lastUsedCountPreset?.id != added.id)
        toolbar.selectTool(.select)
        toolbar.activateLastUsedCount()
        #expect(toolbar.activeSelection.mode == .measure(.count))
        #expect(toolbar.activeSelection.presetID != added.id, "a deleted preset was re-armed")
    }

    @Test("The toolbar builder binds the window's Count palette to its Tool Library")
    func builderBindsTheCountPalette() {
        let environment = ProjectShellEnvironment.mock()
        _ = ZenitToolbarBuilder(environment: environment)
        #expect(
            environment.toolbar.countPalette.map(\.id)
                == ZenitToolbarModel.countPresets(in: environment.toolLibrary.presets).map(\.id)
        )
    }

    // MARK: - IM-031

    @Test("Using Length, Area or Count leaves the Measure button on the rarer tool")
    func measurePaletteKeepsTheRarerTool() {
        let toolbar = ZenitToolbarModel()
        // The historical default, Length, has its own chip; the Measure button starts on the
        // palette's first tool instead.
        #expect(toolbar.lastUsedMeasurementKind == ZenitToolbarModel.defaultMeasurementPalette.first)

        toolbar.activateMeasurement(.volume)
        toolbar.activateMeasurement(.length)
        #expect(toolbar.activeTool == .length)
        toolbar.activateMeasurement(.count)
        toolbar.activateMeasurement(.area)
        #expect(toolbar.lastUsedMeasurementKind == .volume)

        toolbar.activateLastUsedMeasurement()
        #expect(toolbar.activeSelection.mode == .measure(.volume))
        #expect(toolbar.activeTool == .measure, "clicking Measure lit a different chip")

        // A restored `.length` (the layout state's own default) is not a palette tool either.
        toolbar.restoreLastUsed(measurementKind: .length, countPresetID: nil)
        #expect(toolbar.lastUsedMeasurementKind == .volume)
    }

    // MARK: - BH-824 / IM-141

    @Test("Arming Text or Callout through the shape path does not become the Shapes memory")
    func textIsNotAShape() {
        let toolbar = ZenitToolbarModel()
        toolbar.activateShape(.cloud)
        toolbar.activateShape(.text)
        #expect(toolbar.activeSelection.mode == .markup(.text), "Text is still armed")
        #expect(toolbar.activeTool == .text)
        toolbar.activateShape(.callout)
        #expect(toolbar.lastUsedShapeKind == .cloud)
        toolbar.activateLastUsedShape()
        #expect(toolbar.activeTool == .shapes)
    }

    @Test("The Shapes memory restores without announcing a change, and ignores a non-shape")
    func shapeMemoryRestores() {
        let toolbar = ZenitToolbarModel()
        var persisted = 0
        toolbar.onPersistableChange = { persisted += 1 }
        toolbar.restoreLastUsed(measurementKind: .slope, countPresetID: nil, shapeKind: .cloud)
        #expect(toolbar.lastUsedShapeKind == .cloud)
        #expect(toolbar.lastUsedMeasurementKind == .slope)
        toolbar.restoreLastUsed(measurementKind: nil, countPresetID: nil, shapeKind: .text)
        #expect(toolbar.lastUsedShapeKind == .cloud)
        #expect(persisted == 0)
    }

    // MARK: - BH-283

    /// Old output: `slot(forCharactersIgnoringModifiers: "1", modifiers: [.shift])` → nil, and
    /// the unshifted AZERTY press reports "&" → nil, so no slot was reachable on that layout.
    @Test("A layout that needs Shift for its digits still reaches the number-key slots")
    func shiftedDigitRowsReachTheSlots() throws {
        #expect(ToolSlotShortcut.slot(forCharactersIgnoringModifiers: "1", modifiers: [.shift]) == 1)
        #expect(ToolSlotShortcut.slot(forCharactersIgnoringModifiers: "&", modifiers: []) == nil)
        #expect(ToolSlotShortcut.slot(forCharactersIgnoringModifiers: "1", modifiers: [.command, .shift]) == nil)
        #expect(ToolSlotShortcut.slot(forCharactersIgnoringModifiers: "!", modifiers: [.shift]) == nil)

        let presenter = MockToolLibraryPresenter()
        let router = ToolSlotKeyRouter(presenter: presenter)
        let first = try #require(router.preset(inSlot: 1))
        presenter.clearActivePreset()
        #expect(router.handleKey(characters: "1", modifiers: [.shift], focus: .canvas))
        #expect(presenter.activePresetID == first.id)
        // The audit covers the shifted chord too.
        #expect(ToolSlotShortcut.auditChords.count == 18)
    }

    // MARK: - IM-116

    private static let toolbarToolCommands: [ZPDFCommandID] = [
        .selectTool, .panTool, .zoomTool, .calibrateScale, .measureLength, .measureArea,
        .textTool, .calloutTool, .shapesTool, .measureTool, .measureCount, .cutoutTool
    ]

    @Test("Every toolbar tool has a shortcut, and the audits stay clean")
    func everyToolHasACanvasKey() {
        let table = ZPDFCommandTable.standard
        for id in Self.toolbarToolCommands {
            #expect(table.command(id)?.binding != nil, "\(id.rawValue) has no shortcut")
        }
        #expect(table.conflicts().isEmpty, "\(table.conflicts().map(\.description))")
        #expect(table.undeclaredShadows().isEmpty, "\(table.undeclaredShadows())")
        #expect(table.systemShortcutTakeovers().isEmpty)
        #expect(ToolSlotShortcut.conflicts(with: table).isEmpty)
        // Letters are canvas-only, never digits, and never reach the menu bar's key equivalents.
        let letters = CanvasToolShortcut.commands(in: table)
        #expect(Set(letters.map(\.id)) == [
            .selectTool, .panTool, .zoomTool, .textTool, .calloutTool,
            .shapesTool, .measureTool, .cutoutTool, .calibrateScale,
            // nl-ux: Area joined the letters when ⌘A went back to Select All.
            .measureArea
        ])
        for command in letters {
            #expect(command.context == .canvas)
            #expect(command.binding?.modifiers.contains(.command) == false)
            #expect(Int(command.binding?.key ?? "") == nil)
        }
        #expect(table.command(.selectTool)?.binding?.displayString == "S")
        #expect(table.command(.calibrateScale)?.binding?.displayString == "\u{21E7}C")
    }

    @Test("A tool letter arms its tool on the canvas, and types a letter everywhere else")
    func lettersArmToolsOnlyOnTheCanvas() {
        #expect(CanvasToolShortcut.command(forCharactersIgnoringModifiers: "s", modifiers: []) == .selectTool)
        #expect(CanvasToolShortcut.command(forCharactersIgnoringModifiers: "C", modifiers: [.shift]) == .calibrateScale)
        #expect(CanvasToolShortcut.command(forCharactersIgnoringModifiers: "c", modifiers: []) == .calloutTool)
        #expect(CanvasToolShortcut.command(forCharactersIgnoringModifiers: "s", modifiers: [.command]) == nil)
        #expect(CanvasToolShortcut.command(forCharactersIgnoringModifiers: "q", modifiers: []) == nil)

        let environment = ProjectShellEnvironment.mock()
        let router = ToolSlotKeyRouter(presenter: environment.toolLibrary)
        // Unwired, a letter is passed on, never swallowed.
        #expect(!router.handleKey(characters: "p", modifiers: [], focus: .canvas))

        router.performCommand = { environment.perform($0) }
        #expect(router.handleKey(characters: "p", modifiers: [], focus: .canvas))
        #expect(environment.toolbar.activeTool == .pan)
        #expect(!router.handleKey(characters: "t", modifiers: [], focus: .editingText))
        #expect(!router.handleKey(characters: "t", modifiers: [], focus: .elsewhere))
        #expect(environment.toolbar.activeTool == .pan)
        #expect(router.handleKey(characters: "m", modifiers: [], focus: .canvas))
        #expect(environment.toolbar.activeTool == .measure)
    }

    // MARK: - BH-799

    /// Old output: `systemShortcutTakeovers()` → `[]` — chord `"1:?"` against the reserved `"3:?"`.
    @Test("A Help chord written without the Shift bit is still caught by the takeover audit")
    func helpChordWithoutShiftIsCaught() {
        let helpish = ZPDFCommand(
            id: .find,
            title: "Help search",
            group: .panels,
            binding: .character("?", [.command]),
            context: .application
        )
        #expect(ZPDFCommandTable(commands: [helpish]).systemShortcutTakeovers() == [.find])
        // Letters keep their Shift: ⇧⌘S is not ⌘S.
        let saveAs = ZPDFCommand(
            id: .saveAs, title: "Save As", group: .file,
            binding: .character("s", [.command, .shift])
        )
        #expect(ZPDFCommandTable(commands: [saveAs]).systemShortcutTakeovers().isEmpty)
    }

    // MARK: - BH-300 / IM-140 / IM-139

    private func builtItem(
        _ identifier: NSToolbarItem.Identifier,
        environment: ProjectShellEnvironment
    ) throws -> (ZenitToolbarBuilder, NSToolbarItem) {
        let builder = ZenitToolbarBuilder(environment: environment)
        let toolbar = builder.makeToolbar()
        let item = try #require(builder.toolbar(toolbar, itemForItemIdentifier: identifier, willBeInsertedIntoToolbar: true))
        return (builder, item)
    }

    private func run(_ item: NSMenuItem) throws {
        let action = try #require(item.action)
        let target = try #require(item.target as? NSObject)
        target.perform(action, with: item)
    }

    /// Old output: the tooltip read "Measure. Click to use Volume again, … (⌘L)" and the overflow
    /// row ran `.measureLength`: `(lastUsedMeasurementKind → .length) == .volume`; and the
    /// overflow form had no submenu.
    @Test("The Measure chip is the Measure tool: tooltip, overflow row and overflow list")
    func measureChipIsTheMeasureTool() throws {
        let environment = ProjectShellEnvironment.mock()
        let (builder, item) = try builtItem(.zenitMeasure, environment: environment)
        environment.toolbar.activateMeasurement(.volume)

        let lengthChord = try #require(ZPDFCommandTable.standard.command(.measureLength)?.binding?.displayString)
        let help = try #require(builder.liveHelpText(for: .zenitMeasure))
        #expect(!help.contains(lengthChord), "the tooltip offers Length's shortcut: \(help)")
        #expect(help.contains(MeasurementKind.volume.displayName))

        let menuForm = try #require(item.menuFormRepresentation)
        #expect(menuForm.tag == ZPDFCommandID.allCases.firstIndex(of: .measureTool))
        environment.toolbar.selectTool(.select)
        try run(menuForm)
        #expect(environment.toolbar.activeSelection.mode == .measure(.volume))
        #expect(environment.toolbar.lastUsedMeasurementKind == .volume)

        let submenu = try #require(menuForm.submenu)
        builder.menuNeedsUpdate(submenu)
        let rows = submenu.items.filter { !$0.isSeparatorItem }
        #expect(rows.count == environment.toolbar.measurementPalette.count)
        #expect(rows.filter { $0.state == .on }.map(\.title) == [MeasurementKind.volume.displayName])
        let slope = try #require(rows.first { $0.title == MeasurementKind.slope.displayName })
        try run(slope)
        #expect(environment.toolbar.activeSelection.mode == .measure(.slope))
    }

    @Test("A tool tooltip carries the usage hint the command table already writes down")
    func tooltipsCarryTheHint() throws {
        let environment = ProjectShellEnvironment.mock()
        let (builder, _) = try builtItem(.zenitPan, environment: environment)
        let help = try #require(builder.liveHelpText(for: .zenitPan))
        #expect(help.contains("Space bar"), "\(help)")
        #expect(help.contains("(P)"), "the new canvas key is shown: \(help)")
    }

    // MARK: - IM-226 / IM-227

    @Test("The Measure palette is cut into families without being reordered")
    func measurePaletteIsGrouped() {
        let toolbar = ZenitToolbarModel()
        let sections = toolbar.measurementPaletteSections
        #expect(sections.flatMap { $0 } == toolbar.measurementPalette)
        #expect(sections.count == 7)
        #expect(sections.first == [.dimension, .polylength, .perimeter])
        #expect(sections.last == [.temporaryMeasure])
    }

    @Test("An empty Count palette offers plain Count and the Tool Library")
    func emptyCountPaletteOffersTheNextStep() throws {
        let environment = ProjectShellEnvironment.mock()
        let builder = ZenitToolbarBuilder(environment: environment)
        environment.toolbar.bindCountPalette { [] }
        let rows = builder.paletteMenuItems(.count)
        let plain = try #require(rows.first { $0.title == "Use Plain Count" })
        #expect(rows.contains { $0.title == "Open Tool Library…" })
        #expect(rows.first?.isEnabled == false, "the empty-state line is a label, not a control")
        try run(plain)
        #expect(environment.toolbar.activeSelection.mode == .measure(.count))
    }
}
