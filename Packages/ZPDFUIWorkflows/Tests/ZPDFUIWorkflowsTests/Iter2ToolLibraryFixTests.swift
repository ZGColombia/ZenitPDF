import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIWorkflows

/// Loop iteration 2, area ui-workflows-ledger: Move Up, Move Down and Option-arrow are offered
/// only where they visibly reorder the list on screen (S-083), and the preset editor's Assembly
/// row reads typed parameters exactly as the ledger's Apply Assembly does (S-076).
@Suite("Tool Library, loop iteration 2", .workflowsTierSerialised)
@MainActor
struct Iter2ToolLibraryFixTests {

    private static func favourite(_ name: String, panel: ToolLibraryPanel, sortIndex: Int) -> ToolPresetSummary {
        var preset = ToolLibraryFixtures.simple(name, panel: panel, sortIndex: sortIndex)
        preset.isFavorite = true
        return preset
    }

    // MARK: - S-083

    /// Old output: in Recent both items were enabled (the preset's own set, My Tools, is
    /// editable), and Move Down on A rewrote My Tools to [B, A] — its 1–9 slots — while Recent,
    /// sorted by recency, still read A, B. In Favorites, a neighbour from Project Tools with the
    /// same category name made Move Down an enabled no-op.
    @Test("S-083: a move is offered only when the neighbour on screen is in the preset's own set and category")
    func moveIsOfferedOnlyWhereItReorders() {
        let a = Self.favourite("A", panel: .myTools, sortIndex: 0)
        let b = Self.favourite("B", panel: .myTools, sortIndex: 2)
        let p = Self.favourite("P", panel: .projectTools, sortIndex: 1)
        let model = ToolLibraryEditingModel(presets: [a, b, p])

        // Favorites: grouped by category and sorted by position, across sets.
        let favourites = model.groupedPresets(in: .favorites).flatMap(\.presets).map(\.id)
        #expect(favourites == [a.id, p.id, b.id])
        #expect(!model.canMove(id: a.id, by: 1, among: favourites, viewing: .favorites), "P is in Project Tools")
        #expect(!model.canMove(id: p.id, by: 1, among: favourites, viewing: .favorites), "B is in My Tools")
        #expect(model.canMove(id: a.id, by: 1, among: [a.id, b.id], viewing: .favorites), "a same-set neighbour reorders")

        // Recent: one "Recently Used" section in recency order, across sets.
        let recent = model.groupedPresets(in: .recent, recent: [a.id, b.id]).flatMap(\.presets).map(\.id)
        #expect(recent == [a.id, b.id])
        #expect(!model.canMove(id: a.id, by: 1, among: recent, viewing: .recent))
        #expect(!model.canMove(id: b.id, by: -1, among: recent, viewing: .recent))
        // What the old enabled item did: My Tools' order and slots changed, Recent did not.
        model.move(id: a.id, by: 1, among: recent)
        #expect(model.presets(in: .myTools).map(\.name) == ["B", "A"], "the hidden change the item no longer offers")
        #expect(model.groupedPresets(in: .recent, recent: [a.id, b.id]).flatMap(\.presets).map(\.id) == recent)
        model.move(id: a.id, by: -1, among: [b.id, a.id])

        // The preset's own set: an ordinary move, and nothing past either end.
        let mine = model.groupedPresets(in: .myTools).flatMap(\.presets).map(\.id)
        #expect(mine == [a.id, b.id])
        #expect(model.canMove(id: a.id, by: 1, among: mine, viewing: .myTools))
        #expect(model.canMove(id: b.id, by: -1, among: mine, viewing: .myTools))
        #expect(!model.canMove(id: a.id, by: -1, among: mine, viewing: .myTools))
        #expect(!model.canMove(id: b.id, by: 1, among: mine, viewing: .myTools))

        // An imported library is read-only wherever it is shown.
        let imported = ToolLibraryFixtures.simple("I", panel: .importedLibraries, sortIndex: 0)
        let second = ToolLibraryFixtures.simple("J", panel: .importedLibraries, sortIndex: 1)
        let readOnly = ToolLibraryEditingModel(presets: [imported, second])
        #expect(!readOnly.canMove(id: imported.id, by: 1, among: [imported.id, second.id], viewing: .importedLibraries))
    }

    // MARK: - S-076

    /// The same table the ledger's Apply Assembly is held to (ZPDFUILedgerTests
    /// Iter2LedgerFixTests.parameterTable). Hand-derived; `nil` is a refusal. The row reads in
    /// metres here, so the value is the SI parameter Apply Assembly passes on.
    static let parameterTable: [(text: String, value: Decimal?)] = [
        ("0,6", Decimal(string: "0.6")), ("0.6", Decimal(string: "0.6")), ("45,50", Decimal(string: "45.5")),
        ("45.50", Decimal(string: "45.5")), ("1 200", 1200), ("6e-1", Decimal(string: "0.6")),
        ("1,234.5", nil), ("1,200,300", nil), ("12abc", nil), ("0.6m", nil)
    ]

    @Test("S-076: the preset editor's Assembly row reads the texts Apply Assembly is held to")
    func presetRowReadsTheSharedTable() {
        let editor = ToolPresetAssemblyEditor(
            customDefaults: [:], catalog: Iter1RQuantitiesCoreWorkflowsTests.catalog, lengthUnit: .metre
        )
        let spacing = LedgerAssemblySummary.Input(name: "Spacing", dimension: .length, isFreeParameter: true, note: nil)
        for (text, value) in Self.parameterTable {
            #expect(editor.quantity(spacing, text: text)?.value == value, "\(text)")
        }
    }
}
