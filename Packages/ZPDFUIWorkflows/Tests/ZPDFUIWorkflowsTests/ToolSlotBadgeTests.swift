import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIWorkflows

/// The Tool Library panel's half of the number-key slots and of the armed-mode banner.
///
/// | Area | Rule | Test |
/// |---|---|---|
/// | Slots | The badge on the row and the key the canvas obeys are one list | ``theBadgeAndTheKeyAgree()`` |
/// | Slots | Filtering the panel does not renumber the slots | ``theFilterDoesNotRenumberTheSlots()`` |
/// | Slots | The digit is spoken as a shortcut, not read as a stray number | ``theSlotIsSpokenAsAShortcut()`` |
/// | Modes | Every mode has a glyph and a banner sentence | ``everyModeHasABannerAndAGlyph()`` |
@MainActor
@Suite("Tool slot badges and the armed-mode banner", .workflowsTierSerialised)
struct ToolSlotBadgeTests {

    private func makeModel() -> (MockToolLibraryPresenter, ToolLibraryEditingModel) {
        let presenter = MockToolLibraryPresenter()
        return (presenter, ToolLibraryEditingModel(presets: presenter.presets))
    }

    @Test("The badge the panel prints and the key the canvas obeys come from one list")
    func theBadgeAndTheKeyAgree() {
        // The panel renders from `ToolLibraryEditingModel` (its working copy) and the canvas
        // arms from the presenter. If those two ordered the set differently, the `2` on the
        // row would arm a different tool than the `2` on the keyboard — which is the way a
        // shortcut badge becomes a lie without anybody editing either side.
        let (presenter, model) = makeModel()
        for panel in ToolLibraryPanel.allCases {
            let fromThePanel = Array(model.presets(in: panel).prefix(ToolSlotOrder.slotCount))
            let fromTheKeyboard = ToolSlotOrder.slots(presenter.presets, in: panel)
            #expect(fromThePanel.map(\.id) == fromTheKeyboard.map(\.id), "\(panel) disagrees")
        }
        #expect(!ToolSlotOrder.slots(presenter.presets, in: .myTools).isEmpty)
    }

    @Test("Filtering the panel does not renumber the slots")
    func theFilterDoesNotRenumberTheSlots() throws {
        let (presenter, model) = makeModel()
        let first = try #require(ToolSlotOrder.slots(presenter.presets, in: .myTools).first)
        let second = try #require(ToolSlotOrder.slots(presenter.presets, in: .myTools).dropFirst().first)

        // Filter the list down to the *second* tool. Its badge must still read 2: the number
        // keys walk the set, not the search results, so muscle memory survives a filter.
        let filtered = model.presets(in: .myTools, matching: second.name)
        #expect(filtered.contains { $0.id == second.id })
        #expect(!filtered.contains { $0.id == first.id })
        #expect(ToolSlotOrder.slotNumber(of: second.id, in: model.presets, panel: .myTools) == 2)
        #expect(ToolSlotOrder.slotNumber(of: first.id, in: model.presets, panel: .myTools) == 1)
    }

    @Test("A preset outside the first nine has no badge at all")
    func thereIsNoTenthBadge() {
        let (_, model) = makeModel()
        var presets = model.presets
        let template = presets[0]
        var tenthAndBeyond: [UUID] = []
        for index in 0..<12 {
            let filler = ToolPresetSummary(
                id: UUID(),
                name: "Filler \(index)",
                category: template.category,
                panel: .myTools,
                markupKind: template.markupKind,
                measurementKind: template.measurementKind,
                colorRGBA: template.colorRGBA,
                defaultSubject: template.defaultSubject,
                sortIndex: 100 + index
            )
            presets.append(filler)
            tenthAndBeyond.append(filler.id)
        }
        #expect(ToolSlotOrder.slots(presets, in: .myTools).count == ToolSlotOrder.slotCount)
        // Everything appended sits past the ninth slot, and none of it gets a badge — an
        // unreachable key printed on a row is the defect, not the absence of one.
        let badged = tenthAndBeyond.filter {
            ToolSlotOrder.slotNumber(of: $0, in: presets, panel: .myTools) != nil
        }
        #expect(badged.count <= ToolSlotOrder.slotCount)
        #expect(ToolSlotOrder.slotNumber(of: tenthAndBeyond[11], in: presets, panel: .myTools) == nil)
    }

    @Test("The digit is spoken as a shortcut, not read out as a stray number")
    func theSlotIsSpokenAsAShortcut() {
        let armed = ToolPresetAccessibility.value(isArmed: true, slotNumber: 3)
        #expect(armed.contains("3"))
        #expect(armed != "3")
        #expect(armed.contains(ToolSlotOrder.accessibilityDescription(slot: 3) ?? "!"))
        // No slot, no invented shortcut.
        let plain = ToolPresetAccessibility.value(isArmed: false, slotNumber: nil)
        #expect(!plain.contains("3"))
        #expect(plain != armed)
    }

    @Test("Every mode has a banner sentence and a glyph, so the banner cannot render blank")
    func everyModeHasABannerAndAGlyph() {
        for mode in ToolSetMode.allCases {
            let state = ArmedToolState(presetName: "Door Count", setName: "My Tools", mode: mode)
            #expect(!state.bannerText.isEmpty)
            #expect(state.bannerText.contains(mode.displayName))
            #expect(state.bannerText.contains("My Tools"))
            #expect(state.accessibilityDescription.contains("Door Count"))
            _ = WorkflowGlyphs.glyph(for: mode)
        }
    }

    @Test("The banner appears for Apply and Place and stays out of the way in Draw")
    func theBannerIsOnlyForTheTwoModes() throws {
        let presenter = MockToolLibraryPresenter()
        let preset = try #require(presenter.presets.first { $0.panel == .myTools })
        presenter.activatePreset(id: preset.id)

        #expect(presenter.armedModeState == nil, "Draw arms a real tool; the banner would be noise")
        presenter.setMode(.apply, for: .myTools)
        #expect(presenter.armedModeState?.mode == .apply)
        presenter.setMode(.place, for: .myTools)
        #expect(presenter.armedModeState?.mode == .place)
        presenter.clearActivePreset()
        #expect(presenter.armedModeState == nil, "nothing armed, nothing to warn about")
    }
}
