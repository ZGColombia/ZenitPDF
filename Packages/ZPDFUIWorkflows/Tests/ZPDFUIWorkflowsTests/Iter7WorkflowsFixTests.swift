import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIWorkflows

/// Loop iteration 7, area ui-workflows-ledger, the workflows half: X-031 (an imported tool set
/// can be removed again) and X-035 (Batch Apply forgets a failed run on Preview Again and once a
/// choice changes).
@Suite("Loop iteration 7 — ui-workflows-ledger workflows fixes", .workflowsTierSerialised)
@MainActor
struct Iter7WorkflowsFixTests {

    // MARK: - X-031

    /// A `.zpdftools` file of `count` count tools, all filed under `category`.
    private static func setFile(count: Int, category: String) -> Data {
        let entries = (0..<count).map { index in
            """
            {"id": "\(UUID().uuidString)", "name": "Tool \(index)", "category": "\(category)",
             "markupType": "count", "measurementTool": "count"}
            """
        }
        return Data("""
        {"schemaVersion": 1, "name": "\(category)", "presets": [\(entries.joined(separator: ","))]}
        """.utf8)
    }

    /// A tool the office subscription listed: read-only, in Imported Libraries, "(read-only)" set.
    private static func subscribed(_ name: String, sortIndex: Int) -> ToolPresetSummary {
        ToolPresetSummary(
            id: UUID(), name: name, category: "Office \(SubscribedToolSet.categorySuffix)", panel: .importedLibraries,
            markupKind: .measurement, measurementKind: .length, colorRGBA: ColorRGBA.Zenit.Dark.cyan,
            defaultSubject: name, isReadOnly: true, sortIndex: sortIndex
        )
    }

    @Test("X-031: the one subscription rule — read-only, Imported Libraries, the (read-only) set")
    func subscriptionRule() {
        let office = Self.subscribed("Wall", sortIndex: 0)
        #expect(SubscribedToolSet.owns(office))
        var handImported = office
        handImported.category = "Office"
        #expect(!SubscribedToolSet.owns(handImported))
        var editable = office
        editable.isReadOnly = false
        #expect(!SubscribedToolSet.owns(editable))
        var elsewhere = office
        elsewhere.panel = .myTools
        #expect(!SubscribedToolSet.owns(elsewhere))
    }

    /// Old output: Remove was disabled whenever `preset.isReadOnly`, and every imported tool is
    /// read-only, so a hand-imported set could never leave the app-wide Tool Library. There was
    /// no `canRemove`, no Remove Imported Set and no way to take a set out whole.
    @Test("X-031: a hand-imported tool can be removed; a subscribed or built-in read-only one cannot")
    func removalRule() throws {
        let mine = ToolLibraryFixtures.simple("Mine", sortIndex: 0)
        var builtIn = ToolLibraryFixtures.simple("Built in", sortIndex: 1)
        builtIn.isReadOnly = true
        let office = Self.subscribed("Office wall", sortIndex: 0)
        let model = ToolLibraryEditingModel(presets: [mine, builtIn, office])
        model.beginImport(data: Self.setFile(count: 2, category: "Trial kit"), fileName: "Trial.zpdftools")
        model.confirmImport()
        let imported = model.presets.filter { $0.category == "Trial kit" }
        #expect(imported.count == 2)
        #expect(imported.allSatisfy { $0.isReadOnly && $0.panel == .importedLibraries })

        #expect(model.canRemove(mine))
        #expect(imported.allSatisfy(model.canRemove))
        #expect(!model.canRemove(office), "the next refresh would put a subscribed tool straight back")
        #expect(!model.canRemove(builtIn))

        // The guard is the model's, not only the menu's.
        model.delete(id: office.id)
        model.delete(id: builtIn.id)
        #expect(model.presets.contains { $0.id == office.id })
        #expect(model.presets.contains { $0.id == builtIn.id })
        #expect(model.pendingDeletion == nil)

        let first = try #require(imported.first)
        model.delete(id: first.id)
        #expect(!model.presets.contains { $0.id == first.id })
        #expect(model.pendingDeletion?.preset.id == first.id)
    }

    @Test("X-031: Remove Imported Set takes the set out whole, as one step, and the Undo bar puts it back in order")
    func removeImportedSetAndPutItBack() throws {
        let mine = ToolLibraryFixtures.simple("Mine", sortIndex: 0)
        let office = Self.subscribed("Office wall", sortIndex: 0)
        let model = ToolLibraryEditingModel(presets: [mine, office])
        var steps: [ToolLibraryUndoStep] = []
        var removedIDs: [UUID] = []
        model.onUndoableChange = { steps.append($0) }
        model.onChange = { change in
            if case let .removed(preset) = change { removedIDs.append(preset.id) }
        }
        model.beginImport(data: Self.setFile(count: 3, category: "Trial kit"), fileName: "Trial.zpdftools")
        model.confirmImport()
        model.beginImport(data: Self.setFile(count: 1, category: "Doors"), fileName: "Doors.zpdftools")
        model.confirmImport()
        let trialOrder = model.presets(in: .importedLibraries).filter { $0.category == "Trial kit" }
        #expect(trialOrder.map(\.name) == ["Tool 0", "Tool 1", "Tool 2"])

        // The subscribed set is not offered; the two hand-imported sets are, in panel order.
        let sets = model.removableImportedSets()
        #expect(Set(sets.map(\.category)) == ["Trial kit", "Doors"])
        #expect(sets.first { $0.category == "Trial kit" }?.toolCount == 3)
        #expect(sets.first { $0.category == "Trial kit" }?.menuTitle == "Trial kit — 3 tools")

        let stepsBefore = steps.count
        model.removeImportedSet(category: "Trial kit")
        #expect(!model.presets.contains { $0.category == "Trial kit" })
        #expect(model.presets.contains { $0.id == office.id }, "a subscribed tool is never removed by it")
        #expect(model.presets.contains { $0.id == mine.id })
        #expect(model.presets.contains { $0.category == "Doors" })
        #expect(Set(removedIDs) == Set(trialOrder.map(\.id)), "each removal is reported for persistence")
        #expect(steps.count == stepsBefore + 1, "one ⌘Z for the whole set")
        #expect(steps.last?.actionName == "Remove Imported Set")
        let pending = try #require(model.pendingDeletion)
        #expect(pending.presets.map(\.id) == trialOrder.map(\.id))
        #expect(pending.message == "Removed the imported set “Trial kit” (3 tools) from your Tool Library.")
        #expect(model.removableImportedSets().map(\.category) == ["Doors"])

        model.undoDelete()
        #expect(model.pendingDeletion == nil)
        let restored = model.presets(in: .importedLibraries).filter { $0.category == "Trial kit" }
        #expect(restored.map(\.id) == trialOrder.map(\.id), "back in the order they were listed")
        #expect(restored.map(\.sortIndex) == [0, 1, 2])
    }

    @Test("X-031: the document's Undo of a removed set restores it and retires the Undo bar")
    func documentUndoOfARemovedSet() throws {
        let model = ToolLibraryEditingModel(presets: [ToolLibraryFixtures.simple("Mine", sortIndex: 0)])
        var steps: [ToolLibraryUndoStep] = []
        model.onUndoableChange = { steps.append($0) }
        model.beginImport(data: Self.setFile(count: 2, category: "Trial kit"), fileName: "Trial.zpdftools")
        model.confirmImport()
        let ids = Set(model.presets.filter { $0.category == "Trial kit" }.map(\.id))

        model.removeImportedSet(category: "Trial kit")
        model.revert(try #require(steps.last))
        #expect(Set(model.presets.filter { $0.category == "Trial kit" }.map(\.id)) == ids)
        #expect(model.pendingDeletion == nil, "the Undo bar cannot put the set back a second time")

        // Removing a set nobody can remove does nothing.
        let count = model.presets.count
        model.removeImportedSet(category: "No such set")
        #expect(model.presets.count == count)
    }

    // MARK: - X-035

    static let failure = "The drawing could not be written to after 40 pages."

    /// A model whose every run fails with ``failure`` after 40 of 312 placements.
    static func failingModel() -> BatchApplyModel {
        let model = BatchApplyModel()
        model.onPlan = { _ in BatchApplyModelTests.plan(placements: 312) }
        model.onRun = { _, _ in
            BatchApplyReceipt(createdMarkupIDs: (0..<40).map { _ in UUID() }, failureMessage: failure)
        }
        return model
    }

    /// The reported state. Old output (cycle-1 fix, c2r checker): after Preview Again,
    /// `previewSentence` was the fresh count, `canApply` was true, and `resultFailure` — the line
    /// the sheet renders in warning colour — still read "The drawing could not be written to
    /// after 40 pages."; cycle 1's test pinned that. Before cycle 1 the sheet read
    /// `receipt?.failureMessage`, which nothing clears.
    @Test("X-035: Preview Again after a failed run shows the fresh count alone")
    func previewAgainClearsTheFailure() async {
        let model = Self.failingModel()
        model.preview()
        await model.run()
        #expect(model.resultFailure == Self.failure)
        #expect(model.resultSentence == nil)
        #expect(model.needsFreshPreview)
        #expect(model.previewSentence == "Not counted since the last run.")

        // Preview Again — the sheet's button calls `preview()`.
        model.preview()
        #expect(!model.needsFreshPreview)
        #expect(model.canApply)
        #expect(model.previewSentence != "Not counted since the last run.")
        #expect(model.resultFailure == nil, "the old error must not sit under a fresh count with Apply live")
        #expect(model.receipt?.failureMessage == Self.failure, "the receipt still records what happened")

        // A second failure is reported again: the clearing is per preview, not a one-shot mute.
        await model.run()
        #expect(model.resultFailure == Self.failure)
    }

    /// Old output: the sheet read `receipt?.failureMessage`, which nothing clears, so after the
    /// anchor changed the fresh preview sat over "The drawing could not be written to after 40
    /// pages." in warning colour, with Apply live.
    @Test("X-035: a failed run's message goes once a choice changes, and a later run reports only itself")
    func failureFollowsTheResultLifecycle() async {
        let model = Self.failingModel()
        model.preview()
        await model.run()
        #expect(model.resultFailure == Self.failure)

        // A new choice is a new batch: the failure goes before the coalesced preview lands,
        // although the receipt still records it.
        model.anchorCorner = .topLeft
        #expect(model.resultFailure == nil)
        #expect(model.receipt?.failureMessage == Self.failure)

        // A failure, then a run that does not fail: the run reports its own outcome alone.
        model.preview()
        await model.run()
        #expect(model.resultFailure == Self.failure)
        model.preview()
        model.onRun = { _, _ in .cancelled }
        await model.run()
        #expect(model.resultFailure == nil)
        #expect(model.resultSentence == "Batch cancelled. Nothing was placed.")
    }
}
