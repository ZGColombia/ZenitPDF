import Foundation
import Testing
@testable import ZPDFUIPresentation

/// The three tool-set polish rules that are pure value logic: which preset a number key names,
/// which cursor a mode wears, and how a per-markup skip report groups.
///
/// | Area | Rule | Test |
/// |---|---|---|
/// | Slots | Slots are the first nine of the active set, in the panel's own order | ``slotsFollowTheSetsOwnOrder()`` |
/// | Slots | A slot past the end of the set names nothing | ``anEmptySlotNamesNothing()`` |
/// | Cursor | Apply and Place wear their own cursor, not Select's | ``applyAndPlaceDoNotWearTheSelectCursor()`` |
/// | Cursor | With nothing armed the mode is ignored | ``anUnarmedModeChangesNoCursor()`` |
/// | Skips | Twelve identical skips are one line with a count | ``twelveIdenticalSkipsAreOneLine()`` |
/// | Skips | A markup that skipped something else gets its own line | ``theOddMarkupOutKeepsItsOwnLine()`` |
@MainActor
@Suite("Tool slots, mode cursors and per-markup skips")
struct ToolSlotAndArmedModeTests {

    // MARK: - Fixtures

    private static func preset(
        _ name: String,
        panel: ToolLibraryPanel = .myTools,
        category: String = "Concrete",
        sortIndex: Int
    ) -> ToolPresetSummary {
        ToolPresetSummary(
            id: UUID(),
            name: name,
            category: category,
            panel: panel,
            markupKind: .measurement,
            measurementKind: .area,
            colorRGBA: ColorRGBA(red: 0.1, green: 0.2, blue: 0.3, alpha: 1),
            defaultSubject: name,
            sortIndex: sortIndex
        )
    }

    /// Twelve presets in `My Tools` plus one in `Project Tools`, so "the first nine of the
    /// active set" has something to be wrong about in both directions.
    private static func library() -> [ToolPresetSummary] {
        var presets = (0..<12).map { preset("Tool \($0)", sortIndex: $0) }
        presets.append(preset("Elsewhere", panel: .projectTools, sortIndex: 0))
        return presets
    }

    // MARK: - Slot order

    @Test("The slots are the first nine of the set, in the order the panel lists them")
    func slotsFollowTheSetsOwnOrder() throws {
        let presets = Self.library()
        let slots = ToolSlotOrder.slots(presets, in: .myTools)
        #expect(slots.count == ToolSlotOrder.slotCount)
        #expect(slots.map(\.name) == (0..<9).map { "Tool \($0)" })
        // The tenth tool exists and is deliberately unreachable from the number row.
        #expect(ToolSlotOrder.slotNumber(of: presets[9].id, in: presets, panel: .myTools) == nil)
        #expect(ToolSlotOrder.slotNumber(of: presets[0].id, in: presets, panel: .myTools) == 1)
        #expect(ToolSlotOrder.slotNumber(of: presets[8].id, in: presets, panel: .myTools) == 9)
    }

    @Test("Category comes before position, so the badge matches the list the panel draws")
    func categoriesOrderBeforePositions() {
        // The panel groups by category and sorts alphabetically; a slot numbering that walked
        // the raw array would number the rows in an order nobody is looking at.
        let presets = [
            Self.preset("Beta first in B", category: "Bravo", sortIndex: 0),
            Self.preset("Alpha first in A", category: "Alpha", sortIndex: 0),
            Self.preset("Alpha second in A", category: "Alpha", sortIndex: 1)
        ]
        #expect(ToolSlotOrder.slots(presets, in: .myTools).map(\.name) == [
            "Alpha first in A", "Alpha second in A", "Beta first in B"
        ])
    }

    @Test("A slot the set does not fill names nothing, and never falls through to another tool")
    func anEmptySlotNamesNothing() {
        let presets = [Self.preset("Only", sortIndex: 0)]
        #expect(ToolSlotOrder.preset(inSlot: 1, of: presets, in: .myTools)?.name == "Only")
        for slot in 2...9 {
            #expect(ToolSlotOrder.preset(inSlot: slot, of: presets, in: .myTools) == nil)
        }
        #expect(ToolSlotOrder.preset(inSlot: 0, of: presets, in: .myTools) == nil)
        #expect(ToolSlotOrder.preset(inSlot: 10, of: presets, in: .myTools) == nil)
        #expect(ToolSlotOrder.displayString(slot: 10) == nil)
        #expect(ToolSlotOrder.displayString(slot: 9) == "9")
    }

    @Test("The slots read off the active set, and follow the panel the person switched to")
    func slotsFollowTheActiveSet() {
        let presenter = MockToolLibraryPresenter()
        // The number keys' own path, `toolSlotPreset(_:)`, over every slot.
        func filledSlots() -> [ToolPresetSummary] {
            (1...ToolSlotOrder.slotCount).compactMap { presenter.toolSlotPreset($0) }
        }
        #expect(presenter.presets.contains { $0.panel == .myTools })
        #expect(!filledSlots().isEmpty)
        #expect(filledSlots().allSatisfy { $0.panel == .myTools })
        presenter.selectPanel(.projectTools)
        #expect(filledSlots().allSatisfy { $0.panel == .projectTools })
    }

    // MARK: - The cursor

    @Test("Apply and Place do not wear the Select cursor")
    func applyAndPlaceDoNotWearTheSelectCursor() {
        // The exact shape of the cursor defect: both modes disarm the drawing families, so the tool the
        // canvas holds is `.select` — and the cursor must still not be the Select arrow.
        let apply = CanvasCursorKind.resolve(tool: .select, setMode: .apply, hasArmedPreset: true)
        let place = CanvasCursorKind.resolve(tool: .select, setMode: .place, hasArmedPreset: true)
        #expect(apply == .apply)
        #expect(place == .place)
        #expect(apply != .select)
        #expect(place != .select)
        #expect(apply != place)
        #expect(apply.badgeSymbolName != nil, "drawn by Zenit, not the platform's arrow")
        #expect(place.badgeSymbolName != nil, "drawn by Zenit, not the platform's arrow")
    }

    @Test("With nothing armed the mode is ignored and the tool decides alone")
    func anUnarmedModeChangesNoCursor() {
        for mode in ToolSetMode.allCases {
            #expect(CanvasCursorKind.resolve(tool: .select, setMode: mode, hasArmedPreset: false) == .select)
            #expect(CanvasCursorKind.resolve(tool: .pan, setMode: mode, hasArmedPreset: false) == .pan)
        }
    }

    @Test("Draw keeps the tool's own cursor, and every tool has one")
    func drawKeepsTheToolsCursor() {
        #expect(CanvasCursorKind.resolve(tool: .measure(.area), setMode: .draw, hasArmedPreset: true) == .draw)
        #expect(CanvasCursorKind.resolve(tool: .markup(.text), setMode: .draw, hasArmedPreset: true) == .draw)
        #expect(CanvasCursorKind.resolve(tool: .pan, setMode: .draw, hasArmedPreset: true) == .pan)
        #expect(CanvasCursorKind.resolve(tool: .zoom, setMode: .draw, hasArmedPreset: true) == .zoom)
        #expect(CanvasCursorKind.resolve(tool: .calibrate, setMode: .draw, hasArmedPreset: false) == .draw)
        // No cursor may be silent about what a click does — the pointer shape is a signal a
        // screen-reader user never receives.
        for kind in CanvasCursorKind.allCases {
            #expect(!kind.verbDescription.isEmpty, "\(kind) has no spoken verb")
        }
    }

    @Test("Pan beats an armed Draw preset, because Space is a temporary tool over everything")
    func panOutranksAnArmedDrawPreset() {
        #expect(CanvasCursorKind.resolve(tool: .pan, setMode: .draw, hasArmedPreset: true) == .pan)
        // BH-281 corrected the second half: Pan (and Zoom) own the click whatever the preset's
        // set mode, so they keep their own cursor. An armed Place outranks the resting Select
        // state, which is the case this line was reaching for.
        #expect(CanvasCursorKind.resolve(tool: .pan, setMode: .place, hasArmedPreset: true) == .pan)
        #expect(CanvasCursorKind.resolve(tool: .select, setMode: .place, hasArmedPreset: true) == .place)
    }

    // MARK: - The armed state the panel and the status bar read

    @Test("The armed mode follows the preset's own set, not the panel on screen")
    func armedStateFollowsThePresetsSet() throws {
        let presenter = MockToolLibraryPresenter()
        let stamp = try #require(presenter.presets.first { $0.panel == .projectTools })
        presenter.setMode(.place, for: .projectTools)
        presenter.activatePreset(id: stamp.id)
        presenter.selectPanel(.myTools)

        let armed = try #require(presenter.armedModeState)
        #expect(armed.mode == .place)
        #expect(armed.presetName == stamp.name)
        #expect(armed.setName == ToolLibraryPanel.projectTools.displayName)
        #expect(armed.indicatorText.contains(ToolSetMode.place.displayName))
        #expect(armed.indicatorText.contains(stamp.name))
        // The panel is showing `My Tools`, which is still in Draw — and the banner must not
        // take its answer from there.
        #expect(presenter.mode(of: .myTools) == .draw)
        #expect(presenter.canvasCursorKind(tool: .select) == .place)
    }

    @Test("Draw arms a real tool, so nothing is substituted for its name")
    func drawSubstitutesNothing() throws {
        let presenter = MockToolLibraryPresenter()
        let preset = try #require(presenter.presets.first)
        presenter.activatePreset(id: preset.id)
        #expect(presenter.armedToolState?.mode == .draw)
        #expect(presenter.armedModeState == nil)
        #expect(presenter.canvasCursorKind(tool: .measure(.area)) == .draw)
    }

    // MARK: - Per-markup skips

    @Test("Twelve markups that skipped the same property are one line with a count")
    func twelveIdenticalSkipsAreOneLine() throws {
        let report = MarkupSkipReport(skips: (0..<12).map { _ in
            MarkupSkipReport.Skip(markupID: UUID(), propertyNames: ["Depth"])
        })
        #expect(report.groups.count == 1)
        #expect(report.lines.count == 1)
        #expect(report.groups.first?.markupCount == 12)
        let line = try #require(report.lines.first)
        #expect(line.contains("12"))
        #expect(line.contains("Depth"))
    }

    @Test("The markup that skipped something else keeps its own line")
    func theOddMarkupOutKeepsItsOwnLine() throws {
        // This is the skip-report defect stated exactly: the old report was the union, so "one of the forty
        // also skipped the wall height" was invisible.
        var skips = (0..<11).map { _ in
            MarkupSkipReport.Skip(markupID: UUID(), propertyNames: ["Depth"])
        }
        skips.append(MarkupSkipReport.Skip(markupID: UUID(), propertyNames: ["Wall height", "Depth"]))
        let report = MarkupSkipReport(skips: skips)

        #expect(report.groups.count == 2)
        // Largest group first, so the common answer leads.
        #expect(report.groups[0].markupCount == 11)
        #expect(report.groups[1].markupCount == 1)
        #expect(report.groups[1].propertyNames == ["Depth", "Wall height"])
        #expect(report.groups[1].line.contains("1 markup"))
        #expect(report.summarySentence.contains("Wall height"))
    }

    @Test("Order of arrival does not change the grouping")
    func groupingIsOrderIndependent() {
        let a = MarkupSkipReport.Skip(markupID: UUID(), propertyNames: ["Depth", "Slope"])
        let b = MarkupSkipReport.Skip(markupID: UUID(), propertyNames: ["Slope", "Depth"])
        let report = MarkupSkipReport(skips: [a, b])
        #expect(report.groups.count == 1)
        #expect(report.groups[0].markupCount == 2)
        #expect(report.groups[0].propertyNames == ["Depth", "Slope"])
    }

    @Test("A markup that skipped nothing is not a line in a report about what was skipped")
    func nothingSkippedIsNoReport() {
        let report = MarkupSkipReport(skips: [
            MarkupSkipReport.Skip(markupID: UUID(), propertyNames: [])
        ])
        #expect(report.isEmpty)
        #expect(report.lines.isEmpty)
        #expect(report.summarySentence.isEmpty)
        #expect(MarkupSkipReport(skips: []).isEmpty)
    }
}
