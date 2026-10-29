import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIWorkflows

/// Loop iteration 1, area appcore, R-054: the Tool Library's Favorites and Recent sets list what
/// their names say. Old output: both counted and listed 0 tools — no preset's own set is Recent,
/// and starring a preset changed nothing a set filtered on.
@Suite("Tool Library Favorites and Recent (R-054)", .workflowsTierSerialised)
@MainActor
struct Iter1AppCoreToolLibraryTests {

    @Test("Favorites lists every starred preset of any set, and starring one adds it")
    func favoritesListsStarred() {
        let wall = ToolLibraryFixtures.simple("Wall", category: "Walls", sortIndex: 0)
        var slab = ToolLibraryFixtures.simple("Slab", category: "Floors", panel: .projectTools, sortIndex: 0)
        slab.isFavorite = true
        let door = ToolLibraryFixtures.simple("Door", category: "Openings", sortIndex: 1)
        let model = ToolLibraryEditingModel(presets: [wall, slab, door])
        #expect(model.presets(in: .favorites).map(\.name) == ["Slab"])
        model.toggleFavorite(id: wall.id)
        #expect(model.presets(in: .favorites).map(\.name) == ["Slab", "Wall"], "sorted by category, as every set is")
        #expect(model.panelContent(in: .favorites).visibleCount == 2)
        // Each still belongs to its own set.
        #expect(model.presets(in: .myTools).map(\.name) == ["Door", "Wall"], "Openings before Walls")
        #expect(model.presets(in: .projectTools).map(\.name) == ["Slab"])
    }

    @Test("Recent lists the presenter's recently armed presets, newest first, under one heading")
    func recentListsTheHistory() {
        let wall = ToolLibraryFixtures.simple("Wall", category: "Walls", sortIndex: 0)
        let slab = ToolLibraryFixtures.simple("Slab", category: "Floors", sortIndex: 1)
        let door = ToolLibraryFixtures.simple("Door", category: "Openings", sortIndex: 2)
        let model = ToolLibraryEditingModel(presets: [wall, slab, door])
        let history = [door.id, wall.id]
        #expect(model.presets(in: .recent, recent: history).map(\.name) == ["Door", "Wall"])
        let groups = model.groupedPresets(in: .recent, recent: history)
        #expect(groups.count == 1)
        #expect(groups.first?.category == ToolLibraryEditingModel.recentSectionTitle)
        #expect(groups.first?.presets.map(\.name) == ["Door", "Wall"])
        #expect(model.panelContent(in: .recent, recent: history).visibleCount == 2)
        #expect(model.presets(in: .recent, matching: "Wa", recent: history).map(\.name) == ["Wall"])
        #expect(model.presets(in: .recent).isEmpty, "no history, nothing recent")
        // An id the library no longer holds is skipped, not shown as a blank tile.
        #expect(model.presets(in: .recent, recent: [UUID(), slab.id]).map(\.name) == ["Slab"])
    }

    @Test("The number keys walk the same Favorites and Recent lists the panel shows")
    func numberKeysFollowTheLists() {
        let wall = ToolLibraryFixtures.simple("Wall", category: "Walls", sortIndex: 0)
        var slab = ToolLibraryFixtures.simple("Slab", category: "Floors", panel: .projectTools, sortIndex: 0)
        slab.isFavorite = true
        let presets = [wall, slab]
        #expect(ToolSlotOrder.preset(inSlot: 1, of: presets, in: .favorites)?.id == slab.id)
        #expect(ToolSlotOrder.preset(inSlot: 1, of: presets, in: .recent, recent: [wall.id, slab.id])?.id == wall.id)
        #expect(ToolSlotOrder.slotNumber(of: slab.id, in: presets, panel: .recent, recent: [wall.id, slab.id]) == 2)
        let model = ToolLibraryEditingModel(presets: presets)
        #expect(model.panelContent(in: .favorites).slotNumber(of: slab.id) == 1, "the badge in Favorites")
        // A presenter without history lists nothing under Recent (the protocol default).
        #expect(MockToolLibraryPresenter().recentPresetIDs.isEmpty)
    }
}
