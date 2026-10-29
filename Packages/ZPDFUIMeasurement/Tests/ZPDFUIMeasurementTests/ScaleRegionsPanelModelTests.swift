import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIMeasurement

/// Fixtures shared by the Scale Regions suites.
@MainActor
private enum RegionFixture {

    static let pageID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    static func scale(_ ratio: String, id: Int = 1) -> ScaleSummary {
        ScaleSummary(
            id: UUID(uuidString: "22222222-2222-2222-2222-2222222222\(String(format: "%02d", id))")!,
            name: "Plan \(ratio)",
            displayString: ratio,
            isUniform: true,
            sx: 0.0176,
            sy: 0.0176,
            unit: .metre,
            version: 1,
            locked: false
        )
    }

    static func square(_ origin: Double, _ side: Double = 100) -> [PDFPointValue] {
        [
            PDFPointValue(x: origin, y: origin),
            PDFPointValue(x: origin + side, y: origin),
            PDFPointValue(x: origin + side, y: origin + side),
            PDFPointValue(x: origin, y: origin + side)
        ]
    }

    static func region(
        _ name: String,
        priority: Int,
        locked: Bool = false,
        visible: Bool = true,
        ratio: String = "1:50",
        id: UUID = UUID(),
        pageID: UUID = RegionFixture.pageID
    ) -> ScaleRegionSummary {
        ScaleRegionSummary(
            id: id,
            name: name,
            pageID: pageID,
            pageLabel: "A-101",
            scale: scale(ratio),
            boundary: square(0),
            priority: priority,
            locked: locked,
            colorRGBA: ColorRGBA.Zenit.Dark.cyan,
            isVisible: visible
        )
    }

    /// A model with the polygon, rename and assign-scale hooks wired, which is the state the
    /// shipping panel is in (ProjectStructureWiring wires all three). Since S-091 an unwired
    /// rename or assign refuses instead of succeeding silently.
    static func wiredModel(regions: [ScaleRegionSummary] = []) -> ScaleRegionsPanelModel {
        let model = ScaleRegionsPanelModel(regions: regions, pageDefaultScale: scale("1:100", id: 9))
        model.onBeginPolygon = {}
        model.onRenameRegion = { _, _ in }
        model.onAssignScale = { _, _ in }
        model.setAvailableScales([scale("1:50"), scale("1:20", id: 2)])
        return model
    }

    static func drawSquare(in model: ScaleRegionsPanelModel, at origin: Double = 0) {
        model.beginRegion()
        model.completePolygon(square(origin), pageID: pageID, pageLabel: "A-101")
    }
}

/// Creating a Scale Region from a drawn polygon, and the four ways the panel refuses to.
@Suite("Scale Regions: creating a region")
@MainActor
struct ScaleRegionCreationTests {

    @Test("Add Scale Region asks the canvas for a boundary before anything else happens")
    func addArmsThePolygonTool() {
        let model = RegionFixture.wiredModel()
        var armed = 0
        model.onBeginPolygon = { armed += 1 }

        #expect(model.beginRegion())
        #expect(armed == 1)
        #expect(model.isAwaitingPolygon)
        #expect(model.draft == nil, "no draft exists until a polygon arrives")
    }

    @Test("A closed polygon opens a draft with a name, a colour and the top priority")
    func polygonOpensADraft() {
        let existing = RegionFixture.region("Stair Detail", priority: 4)
        let model = RegionFixture.wiredModel(regions: [existing])
        RegionFixture.drawSquare(in: model)

        let draft = try? #require(model.draft)
        #expect(draft?.name == "Scale Region 2")
        #expect(draft?.priority == 5, "a new region resolves above the ones already there")
        #expect(draft?.pageLabel == "A-101")
        #expect(!model.isAwaitingPolygon)
        #expect(model.refusal == nil)
        #expect(draft?.colorRGBA != existing.colorRGBA, "an unused colour is preferred")
    }

    @Test("A draft never arrives with a scale, and cannot be created without one")
    func aDraftHasNoScaleUntilOneIsAssigned() {
        let model = RegionFixture.wiredModel()
        var created: [ScaleRegionCreation] = []
        model.onCreateRegion = { created.append($0) }
        RegionFixture.drawSquare(in: model)

        #expect(model.draft?.scale == nil)
        #expect(!model.canCommitDraft)
        #expect(!model.commitDraft())
        #expect(model.refusal == .scaleNotAssigned)
        #expect(created.isEmpty, "nothing may be created at a scale nobody stated")
        #expect(model.draft != nil, "the refusal keeps the draft; it does not throw the work away")
    }

    @Test("With a scale assigned the region is created exactly as drawn")
    func assigningAScaleMakesTheDraftCommittable() {
        let model = RegionFixture.wiredModel()
        var created: [ScaleRegionCreation] = []
        model.onCreateRegion = { created.append($0) }
        RegionFixture.drawSquare(in: model, at: 20)
        model.setDraftName("Stair Detail")
        model.assignDraftScale(RegionFixture.scale("1:20", id: 2))

        #expect(model.canCommitDraft)
        #expect(model.commitDraft())
        #expect(created.count == 1)
        #expect(created.first?.name == "Stair Detail")
        #expect(created.first?.scale.displayString == "1:20")
        #expect(created.first?.boundary == RegionFixture.square(20))
        #expect(created.first?.pageID == RegionFixture.pageID)
        #expect(model.draft == nil, "the draft is spent once the region exists")
        #expect(model.selection == created.first?.id, "the new region is the selected one")
    }

    @Test("A blank or duplicated name is refused with the name in the sentence")
    func namesAreValidated() {
        let model = RegionFixture.wiredModel(regions: [RegionFixture.region("Stair Detail", priority: 1)])
        model.onCreateRegion = { _ in }
        RegionFixture.drawSquare(in: model)
        model.assignDraftScale(RegionFixture.scale("1:20", id: 2))

        model.setDraftName("   ")
        #expect(!model.commitDraft())
        #expect(model.refusal == .nameEmpty)

        model.setDraftName("Stair Detail")
        #expect(!model.commitDraft())
        #expect(model.refusal == .nameTaken("Stair Detail"))
        #expect(model.refusal?.message.contains("Stair Detail") == true)
    }

    @Test("Two points cannot bound an area, and the refusal counts them")
    func twoPointsAreRefused() {
        let model = RegionFixture.wiredModel()
        model.beginRegion()
        let accepted = model.completePolygon(
            [PDFPointValue(x: 0, y: 0), PDFPointValue(x: 10, y: 0)],
            pageID: RegionFixture.pageID,
            pageLabel: "A-101"
        )
        #expect(!accepted)
        #expect(model.refusal == .polygonTooFewPoints(count: 2))
        #expect(model.draft == nil)
        #expect(!model.isAwaitingPolygon, "a refused polygon ends the wait rather than hanging")
    }

    @Test("A boundary with no extent is refused")
    func degenerateBoundaryIsRefused() {
        let model = RegionFixture.wiredModel()
        model.beginRegion()
        let flat = [
            PDFPointValue(x: 0, y: 5),
            PDFPointValue(x: 40, y: 5),
            PDFPointValue(x: 80, y: 5)
        ]
        #expect(!model.completePolygon(flat, pageID: RegionFixture.pageID, pageLabel: "A-101"))
        #expect(model.refusal == .polygonHasNoExtent)
    }

    @Test("A rejection from the core is carried through in its own words")
    func coreRejectionIsSurfaced() {
        let model = RegionFixture.wiredModel()
        RegionFixture.drawSquare(in: model)
        model.rejectDraft(reason: "The boundary crosses itself.")
        #expect(model.refusal == .rejectedByCore("The boundary crosses itself."))
        #expect(model.refusal?.message == "The boundary crosses itself.")
    }

    /// CR-193: this used to assert `draft == nil` and the two flags beside it, and nothing
    /// about the one thing "leaves no half-armed canvas behind" actually names — the disarm
    /// hook. It therefore passed against the CR-187 defect, where cancelling after the boundary
    /// was drawn cleared the draft and left the canvas armed. It now asserts the hook fired.
    @Test("Cancelling throws the draft away and leaves no half-armed canvas behind")
    func cancelClearsEverything() {
        let model = RegionFixture.wiredModel()
        var disarms = 0
        model.onCancelPolygonDrawing = { disarms += 1 }

        RegionFixture.drawSquare(in: model)
        #expect(model.draft != nil, "the fixture is meant to leave a drawn boundary behind")

        model.cancelRegionCreation()
        #expect(model.draft == nil)
        #expect(!model.isAwaitingPolygon)
        #expect(model.refusal == nil)
        #expect(disarms == 1, "the canvas was left armed with no draft to be about")
    }
}

/// CR-187, CR-179 and CR-178: the state a Scale Region capture leaves behind.
@Suite("Scale Regions: capture teardown and locked priority")
@MainActor
struct ScaleRegionTeardownTests {

    // MARK: - CR-187: the disarm

    /// Old output: `disarms == 0`. `cancelRegionCreation` fired `onCancelPolygonDrawing` only
    /// while `isAwaitingPolygon` was still true, and `completePolygon` sets it false — so the
    /// ordinary cancel, the one from the draft editor after the boundary is drawn, skipped the
    /// disarm and left the boundary tool selected in the toolbar with the status bar still
    /// telling the person to close a polygon.
    @Test("Cancelling after the boundary is drawn still disarms the canvas")
    func cancelAfterDrawingDisarms() {
        let model = RegionFixture.wiredModel()
        var disarms = 0
        model.onCancelPolygonDrawing = { disarms += 1 }

        RegionFixture.drawSquare(in: model)
        #expect(!model.isAwaitingPolygon, "the boundary has landed; nothing is being awaited")

        model.cancelRegionCreation()
        #expect(disarms == 1)
    }

    /// The other half of the rule: an escape *before* the boundary lands still disarms once,
    /// and a cancel with no capture at all disarms nothing.
    @Test("The disarm fires once per capture, and never without one")
    func disarmIsNotFiredWithoutACapture() {
        let model = RegionFixture.wiredModel()
        var disarms = 0
        model.onCancelPolygonDrawing = { disarms += 1 }

        model.cancelRegionCreation()
        #expect(disarms == 0, "nothing was ever armed")

        model.beginRegion()
        model.cancelRegionCreation()
        #expect(disarms == 1)

        model.cancelRegionCreation()
        #expect(disarms == 1, "a second cancel has nothing left to disarm")
    }

    /// A capture that ends in a region is not a cancelled capture.
    @Test("Committing a draft does not tell the canvas the drawing was abandoned")
    func commitDoesNotDisarmAsACancel() {
        let model = RegionFixture.wiredModel()
        var disarms = 0
        model.onCancelPolygonDrawing = { disarms += 1 }
        model.onCreateRegion = { _ in }

        RegionFixture.drawSquare(in: model)
        model.assignDraftScale(RegionFixture.scale("1:50"))
        #expect(model.commitDraft())
        #expect(disarms == 0)

        model.cancelRegionCreation()
        #expect(disarms == 0, "the capture was finished, not abandoned")
    }

    // MARK: - CR-179: a draft belongs to the page it was drawn on

    /// Old output: `model.draft != nil` after the page turn, holding page 3's `pageID` and page
    /// 3's boundary. Create then emitted that `pageID` while `canCommitDraft` checked the name
    /// against page 4's regions — a region created on a page nobody was looking at.
    @Test("A boundary drawn on one page does not survive a turn to another")
    func staleDraftIsDroppedOnAPageChange() {
        let model = RegionFixture.wiredModel()
        var disarms = 0
        model.onCancelPolygonDrawing = { disarms += 1 }
        RegionFixture.drawSquare(in: model)
        #expect(model.draft?.pageID == RegionFixture.pageID)

        let nextPage = UUID()
        model.setRegions(
            [RegionFixture.region("On the next page", priority: 1, pageID: nextPage)],
            pageID: nextPage
        )

        #expect(model.draft == nil, "page 3's boundary was still open over page 4")
        #expect(disarms == 1, "and the canvas was still armed for it")
    }

    /// The page is inferred from the regions when the caller does not name it, which is what
    /// the shipping host currently does.
    @Test("The page is inferred from the regions when the caller does not say")
    func staleDraftIsDroppedFromInferredPage() {
        let model = RegionFixture.wiredModel()
        RegionFixture.drawSquare(in: model)

        model.setRegions([RegionFixture.region("Elsewhere", priority: 1, pageID: UUID())])
        #expect(model.draft == nil)
    }

    /// A refresh of the same page must not throw away work in progress.
    @Test("A refresh of the page being drawn on leaves the draft alone")
    func aRefreshOfTheSamePageKeepsTheDraft() {
        let model = RegionFixture.wiredModel()
        var disarms = 0
        model.onCancelPolygonDrawing = { disarms += 1 }
        RegionFixture.drawSquare(in: model)

        model.setRegions(
            [RegionFixture.region("Same page", priority: 1)],
            pageID: RegionFixture.pageID
        )
        #expect(model.draft != nil)
        #expect(disarms == 0)

        // And an empty refresh with no page named cannot infer one, so it changes nothing.
        model.setRegions([])
        #expect(model.draft != nil)
    }

    /// A capture armed before the boundary was drawn is abandoned by a page turn too.
    @Test("An armed capture does not follow the person to another page")
    func armedCaptureIsDroppedOnAPageChange() {
        let model = RegionFixture.wiredModel()
        var disarms = 0
        model.onCancelPolygonDrawing = { disarms += 1 }
        model.setCurrentPage(RegionFixture.pageID)
        model.beginRegion()
        #expect(model.isAwaitingPolygon)

        model.setCurrentPage(UUID())
        #expect(!model.isAwaitingPolygon)
        #expect(disarms == 1)
    }

    // MARK: - CR-178: a lock covers the resolution order

    /// Old output: `movePriority` returned `true`, `applyLocalOrder` rewrote every priority
    /// including the locked region's, and the locked region moved from priority 3 to 2 — its
    /// winning scale changed with nobody unlocking anything.
    @Test("A locked region refuses to be moved through the resolution order")
    func lockedRegionRefusesAPriorityMove() {
        let locked = RegionFixture.region("Stair Detail", priority: 3, locked: true)
        let other = RegionFixture.region("Plan", priority: 2)
        let model = RegionFixture.wiredModel(regions: [locked, other])
        var published = 0
        model.onReorderRegions = { _ in published += 1 }

        #expect(!model.movePriority(regionID: locked.id, by: 1))
        #expect(model.refusal == .regionLocked(name: "Stair Detail"))
        #expect(published == 0)
        #expect(model.region(locked.id)?.priority == 3, "a locked priority was rewritten")
        #expect(model.ordered.map(\.name) == ["Stair Detail", "Plan"])
    }

    /// The case the first guard alone would miss: the locked row does not move, but everything
    /// that decides its winning scale does.
    @Test("An unlocked region cannot jump over a locked one either")
    func movingPastALockedRegionIsRefused() {
        let top = RegionFixture.region("Top", priority: 3)
        let locked = RegionFixture.region("Stair Detail", priority: 2, locked: true)
        let bottom = RegionFixture.region("Bottom", priority: 1)
        let model = RegionFixture.wiredModel(regions: [top, locked, bottom])
        var published = 0
        model.onReorderRegions = { _ in published += 1 }

        #expect(!model.movePriority(regionID: bottom.id, by: -1))
        #expect(model.refusal == .regionLocked(name: "Stair Detail"))
        #expect(!model.movePriority(regionID: top.id, by: 1))
        #expect(published == 0)
        #expect(model.region(locked.id)?.priority == 2)
        #expect(model.ordered.map(\.name) == ["Top", "Stair Detail", "Bottom"])
    }

    /// Moves that leave every locked region's standing alone still work, and still leave the
    /// locked numbers untouched and nobody tied.
    @Test("A move that does not cross a locked region still reorders")
    func aMoveClearOfTheLockStillWorks() {
        let locked = RegionFixture.region("Stair Detail", priority: 9, locked: true)
        let middle = RegionFixture.region("Middle", priority: 3)
        let bottom = RegionFixture.region("Bottom", priority: 1)
        let model = RegionFixture.wiredModel(regions: [locked, middle, bottom])
        var published: [[UUID]] = []
        model.onReorderRegions = { published.append($0) }

        #expect(model.movePriority(regionID: bottom.id, by: -1))
        #expect(published.count == 1)
        #expect(published[0] == [locked.id, bottom.id, middle.id])
        #expect(model.ordered.map(\.name) == ["Stair Detail", "Bottom", "Middle"])
        #expect(model.region(locked.id)?.priority == 9, "the locked number is the core's, not ours")
        #expect(Set(model.regions.map(\.priority)).count == 3, "no two regions are left tied")
    }
}

/// Priority, lock and visibility on regions that already exist.
@Suite("Scale Regions: priority, lock and visibility")
@MainActor
struct ScaleRegionEditingTests {

    @Test("Regions list highest priority first, ties broken by name")
    func resolutionOrderIsStable() {
        let model = RegionFixture.wiredModel(regions: [
            RegionFixture.region("Beta", priority: 2),
            RegionFixture.region("Alpha", priority: 2),
            RegionFixture.region("Top", priority: 9)
        ])
        #expect(model.ordered.map(\.name) == ["Top", "Alpha", "Beta"])
    }

    @Test("Raising a region publishes the whole new order, not one changed priority")
    func priorityMovePublishesTheWholeOrder() {
        let low = RegionFixture.region("Low", priority: 1)
        let mid = RegionFixture.region("Mid", priority: 2)
        let high = RegionFixture.region("High", priority: 3)
        let model = RegionFixture.wiredModel(regions: [low, mid, high])
        var published: [[UUID]] = []
        model.onReorderRegions = { published.append($0) }

        #expect(model.movePriority(regionID: low.id, by: -1))
        #expect(published.count == 1)
        #expect(published[0] == [high.id, low.id, mid.id])
        #expect(model.ordered.map(\.name) == ["High", "Low", "Mid"], "the list re-sorts immediately")
        #expect(Set(model.regions.map(\.priority)).count == 3, "no two regions are left tied")
    }

    @Test("Moving off either end does nothing and publishes nothing")
    func priorityMoveIsClamped() {
        let top = RegionFixture.region("Top", priority: 2)
        let bottom = RegionFixture.region("Bottom", priority: 1)
        let model = RegionFixture.wiredModel(regions: [top, bottom])
        var published = 0
        model.onReorderRegions = { _ in published += 1 }

        #expect(!model.movePriority(regionID: top.id, by: -1))
        #expect(!model.movePriority(regionID: bottom.id, by: 1))
        #expect(published == 0)
    }

    @Test("A locked region refuses a scale edit and names itself in the refusal")
    func lockBlocksScaleEdits() {
        let locked = RegionFixture.region("Stair Detail", priority: 1, locked: true)
        let model = RegionFixture.wiredModel(regions: [locked])
        var calibrated = 0
        var assigned = 0
        var renamed = 0
        model.onCalibrateRegion = { _ in calibrated += 1 }
        model.onAssignScale = { _, _ in assigned += 1 }
        model.onRenameRegion = { _, _ in renamed += 1 }

        #expect(!model.editScale(regionID: locked.id))
        #expect(model.refusal == .regionLocked(name: "Stair Detail"))
        #expect(!model.assignScale(RegionFixture.scale("1:20", id: 2), to: locked.id))
        #expect(!model.rename(regionID: locked.id, to: "Anything"))
        #expect(calibrated == 0 && assigned == 0 && renamed == 0)
    }

    @Test("Unlocking is never refused, because it is the way out of every other refusal")
    func unlockingAlwaysWorks() {
        let locked = RegionFixture.region("Stair Detail", priority: 1, locked: true)
        let model = RegionFixture.wiredModel(regions: [locked])
        var unlocked: [(UUID, Bool)] = []
        model.onSetLocked = { unlocked.append(($0, $1)) }

        model.setLocked(false, regionID: locked.id)
        #expect(unlocked.count == 1)
        #expect(unlocked[0].1 == false)
        #expect(model.refusal == nil)
    }

    @Test("Hiding an outline is a view choice, so a locked region still allows it")
    func visibilitySurvivesTheLock() {
        let locked = RegionFixture.region("Stair Detail", priority: 1, locked: true, visible: true)
        let model = RegionFixture.wiredModel(regions: [locked])
        var visibility: [(UUID, Bool)] = []
        model.onSetVisible = { visibility.append(($0, $1)) }

        model.setVisible(false, regionID: locked.id)
        #expect(visibility.count == 1)
        #expect(visibility[0].1 == false)
        #expect(model.refusal == nil)
    }

    @Test("An action on a region that is gone refuses instead of touching the wrong one")
    func staleIdentitiesRefuse() {
        let model = RegionFixture.wiredModel(regions: [RegionFixture.region("Only", priority: 1)])
        #expect(!model.editScale(regionID: UUID()))
        #expect(model.refusal == .unknownRegion)
    }

    @Test("A refreshed region list drops a selection that no longer exists")
    func selectionFollowsTheCore() {
        let gone = RegionFixture.region("Gone", priority: 1)
        let model = RegionFixture.wiredModel(regions: [gone])
        model.selection = gone.id
        model.setRegions([RegionFixture.region("Other", priority: 1)])
        #expect(model.selection == nil)
    }
}

/// Overlap is reported, never resolved — the rule, enforced at the seam.
@Suite("Scale Regions: overlaps are reported, not resolved")
@MainActor
struct ScaleRegionOverlapTests {

    private func overlappingModel() -> (ScaleRegionsPanelModel, ScaleRegionOverlap) {
        let first = RegionFixture.region("Plan", priority: 1)
        let second = RegionFixture.region("Stair Detail", priority: 2)
        let model = RegionFixture.wiredModel(regions: [first, second])
        let overlap = ScaleRegionOverlap(
            first: first.id,
            second: second.id,
            firstName: first.name,
            secondName: second.name
        )
        model.setOverlaps([overlap])
        return (model, overlap)
    }

    @Test("An overlap the core reported is shown against both regions, with both names")
    func overlapIsAttributedToBothRegions() {
        let (model, overlap) = overlappingModel()
        // The set the panel draws its overlap badges from (U-073: the model's own
        // `isOverlapping(_:)` had no caller outside the tests).
        let overlapping = ScaleRegionsPanel.overlappingIDs(model.overlaps)
        #expect(overlapping.contains(overlap.first))
        #expect(overlapping.contains(overlap.second))
        #expect(overlap.message.contains("Plan"))
        #expect(overlap.message.contains("Stair Detail"))
    }

    @Test("The only overlap action reveals the shared area; no scale is chosen")
    func revealingAnOverlapChangesNoScale() {
        let (model, overlap) = overlappingModel()
        var revealed: [ScaleRegionOverlap] = []
        var assigned = 0
        var reordered = 0
        model.onRevealOverlap = { revealed.append($0) }
        model.onAssignScale = { _, _ in assigned += 1 }
        model.onReorderRegions = { _ in reordered += 1 }

        model.revealOverlap(overlap)
        #expect(revealed == [overlap])
        #expect(assigned == 0, "revealing an overlap must never assign a scale")
        #expect(reordered == 0, "nor silently reorder the regions to break the tie")
        #expect(model.overlaps.count == 1, "the overlap is still there; only the core clears it")
    }

    @Test("The panel invents no overlaps of its own: the core is the only source")
    func overlapsComeFromTheCoreOnly() {
        let model = RegionFixture.wiredModel(regions: [
            RegionFixture.region("A", priority: 1),
            RegionFixture.region("B", priority: 2)
        ])
        // Both fixtures share the same boundary, which really does overlap — and the panel
        // still reports nothing, because detecting it is the geometry package's job and a
        // second, weaker test here would be free to disagree with the one that decides
        // measurements.
        #expect(model.overlaps.isEmpty)
        model.setOverlaps([])
        #expect(model.overlaps.isEmpty)
    }
}

/// The crossing prompt: three legal outcomes, none of them preselected.
@Suite("Scale Regions: a markup that crosses two regions")
@MainActor
struct ScaleRegionCrossingTests {

    private func crossing(canSplit: Bool = true, withPageDefault: Bool = true) -> ScaleRegionCrossing {
        ScaleRegionCrossing(
            id: UUID(),
            measurementName: canSplit ? "Area" : "Count",
            pageLabel: "A-101",
            regions: [
                RegionFixture.region("Stair Detail", priority: 2, ratio: "1:20"),
                RegionFixture.region("Plan", priority: 1, ratio: "1:50")
            ],
            canSplitAtBoundary: canSplit,
            pageDefaultScale: withPageDefault ? RegionFixture.scale("1:100", id: 9) : nil
        )
    }

    @Test("Nothing is preselected, and Continue refuses until something is")
    func nothingIsPreselected() {
        let model = RegionFixture.wiredModel()
        var applied: [(UUID, ScaleRegionCrossingResolution)] = []
        model.onResolveCrossing = { applied.append(($0, $1)) }
        model.present(crossing: crossing())

        #expect(model.chosenCrossingResolution == nil)
        #expect(!model.confirmCrossing())
        #expect(model.refusal == .crossingUnresolved)
        #expect(applied.isEmpty, "no measurement is created while the question is open")
    }

    @Test("All three legal outcomes are offered, and only those")
    func theThreeOutcomesAreOffered() {
        let subject = crossing()
        let offered = subject.offeredResolutions
        #expect(offered.contains(.splitAtBoundary))
        #expect(offered.contains(.block))
        #expect(offered.contains(.useScale(regionID: subject.regions[0].id)))
        #expect(offered.contains(.useScale(regionID: subject.regions[1].id)))
        #expect(offered.contains(.useScale(regionID: nil)), "the page default is one of the choices")
        #expect(offered.count == 5)
    }

    @Test("Each offered outcome applies exactly what it says")
    func eachOutcomeApplies() {
        // One crossing, reused: the region identities in `useScale` have to be the ones this
        // crossing actually offers, which is the guard the next test exercises directly.
        let subject = crossing()
        for outcome in subject.offeredResolutions {
            let model = RegionFixture.wiredModel()
            var applied: [ScaleRegionCrossingResolution] = []
            model.onResolveCrossing = { _, resolution in applied.append(resolution) }
            model.present(crossing: subject)

            #expect(model.chooseCrossingResolution(outcome))
            #expect(model.confirmCrossing())
            #expect(applied == [outcome])
            #expect(model.crossing == nil)
            #expect(model.chosenCrossingResolution == nil)
        }
    }

    @Test("A count group cannot be cut, so splitting is not offered and is refused if asked")
    func splitIsNotOfferedForGeometryThatCannotBeCut() {
        let subject = crossing(canSplit: false)
        #expect(!subject.offeredResolutions.contains(.splitAtBoundary))

        let model = RegionFixture.wiredModel()
        var applied = 0
        model.onResolveCrossing = { _, _ in applied += 1 }
        model.present(crossing: subject)

        #expect(!model.chooseCrossingResolution(.splitAtBoundary))
        #expect(model.refusal == .crossingOutcomeNotOffered)
        #expect(model.chosenCrossingResolution == nil)
        #expect(!model.confirmCrossing())
        #expect(applied == 0)
    }

    @Test("A scale belonging to no candidate region is refused")
    func anUnofferedRegionIsRefused() {
        let model = RegionFixture.wiredModel()
        model.present(crossing: crossing())
        #expect(!model.chooseCrossingResolution(.useScale(regionID: UUID())))
        #expect(model.refusal == .crossingOutcomeNotOffered)
    }

    @Test("With no page default there is no page-default choice to make")
    func pageDefaultIsOnlyOfferedWhenThereIsOne() {
        let subject = crossing(withPageDefault: false)
        #expect(!subject.offeredResolutions.contains(.useScale(regionID: nil)))

        let model = RegionFixture.wiredModel()
        model.present(crossing: subject)
        #expect(!model.chooseCrossingResolution(.useScale(regionID: nil)))
        #expect(model.refusal == .crossingOutcomeNotOffered)
    }

    @Test("Escaping the prompt blocks the measurement rather than inventing a fourth outcome")
    func escapeBlocks() {
        let model = RegionFixture.wiredModel()
        var applied: [ScaleRegionCrossingResolution] = []
        model.onResolveCrossing = { _, resolution in applied.append(resolution) }
        model.present(crossing: crossing())
        model.cancelCrossing()

        #expect(applied == [.block])
        #expect(model.crossing == nil)
        #expect(model.chosenCrossingResolution == nil)
    }

    @Test("A second question cannot be opened while the first is unanswered")
    func oneQuestionAtATime() {
        let model = RegionFixture.wiredModel()
        var armed = 0
        model.onBeginPolygon = { armed += 1 }
        model.present(crossing: crossing())

        #expect(!model.beginRegion())
        #expect(model.refusal == .crossingPending)
        #expect(armed == 0)
    }

    @Test("The headline names the measurement, the region count and the page")
    func theHeadlineSaysWhatIsHappening() {
        let subject = crossing()
        #expect(subject.headline.contains("Area"))
        #expect(subject.headline.contains("2"))
        #expect(subject.headline.contains("A-101"))
        for outcome in subject.offeredResolutions {
            #expect(!subject.title(for: outcome).isEmpty)
            #expect(!subject.explanation(for: outcome).isEmpty)
        }
    }
}

/// No dead ends: the panel and every state inside it can be left.
@Suite("Scale Regions: no dead ends")
@MainActor
struct ScaleRegionDismissibilityTests {

    @Test("Every refusal carries a sentence a person can act on")
    func everyRefusalSpeaks() {
        let refusals: [ScaleRegionRefusal] = [
            .noPolygonDrawn,
            .polygonTooFewPoints(count: 2),
            .polygonHasNoExtent,
            .nameEmpty,
            .nameTaken("Plan"),
            .scaleNotAssigned,
            .regionLocked(name: "Plan"),
            .unknownRegion,
            .crossingPending,
            .crossingUnresolved,
            .crossingOutcomeNotOffered,
            .rejectedByCore("Boundary crosses itself.")
        ]
        for refusal in refusals {
            #expect(!refusal.message.isEmpty, "\(refusal) must say something")
        }
    }

    @Test("Every state the panel can be in has a way out that leaves nothing armed")
    func everyStateCanBeLeft() {
        let model = RegionFixture.wiredModel()
        model.onResolveCrossing = { _, _ in }

        // Waiting for a polygon.
        model.beginRegion()
        model.cancelRegionCreation()
        #expect(!model.isAwaitingPolygon && model.draft == nil)

        // Holding a draft.
        RegionFixture.drawSquare(in: model)
        model.cancelRegionCreation()
        #expect(model.draft == nil)

        // Holding a crossing question.
        model.present(crossing: ScaleRegionCrossing(
            id: UUID(),
            measurementName: "Length",
            pageLabel: "A-101",
            regions: [RegionFixture.region("Plan", priority: 1)],
            canSplitAtBoundary: true,
            pageDefaultScale: nil
        ))
        model.cancelCrossing()
        #expect(!model.isAwaitingCrossingDecision)
    }

    @Test("An unwired panel refuses out loud rather than pretending to create a region")
    func unwiredPanelDoesNotPretend() {
        let model = ScaleRegionsPanelModel()
        #expect(!model.beginRegion())
        #expect(model.refusal == .noPolygonDrawn)
        #expect(!model.isAwaitingPolygon)
    }
}

/// Deleting a region: the way out of a region, and the two refusals that stop it changing a
/// number nobody asked it to change.
@Suite("Scale Regions: deleting a region")
@MainActor
struct ScaleRegionDeletionTests {

    @Test("A region that measures nothing is deleted, and the panel drops its selection")
    func anEmptyRegionIsDeleted() {
        let region = RegionFixture.region("Stair Detail", priority: 1)
        let model = RegionFixture.wiredModel(regions: [region])
        var deleted: [UUID] = []
        model.onDeleteRegion = { deleted.append($0) }
        model.selection = region.id

        #expect(model.delete(regionID: region.id))
        #expect(deleted == [region.id])
        #expect(model.selection == nil)
        #expect(model.refusal == nil)
    }

    @Test("A region that still measures markups refuses, and says how many")
    func aRegionInUseRefuses() {
        let region = RegionFixture.region("Stair Detail", priority: 1)
        let model = RegionFixture.wiredModel(regions: [region])
        var deleted = 0
        model.onDeleteRegion = { _ in deleted += 1 }
        model.setMarkupCounts([region.id: 4])

        #expect(model.markupCount(of: region.id) == 4)
        #expect(!model.delete(regionID: region.id))
        #expect(model.refusal == .regionInUse(name: "Stair Detail", markupCount: 4))
        #expect(deleted == 0)
    }

    @Test("A locked region refuses deletion, and unlocking is the way out")
    func aLockedRegionRefuses() {
        let region = RegionFixture.region("Stair Detail", priority: 1, locked: true)
        let model = RegionFixture.wiredModel(regions: [region])
        var deleted = 0
        model.onDeleteRegion = { _ in deleted += 1 }

        #expect(!model.delete(regionID: region.id))
        #expect(model.refusal == .regionLocked(name: "Stair Detail"))
        #expect(deleted == 0)
    }

    @Test("An unwired panel refuses the deletion out loud rather than dropping it")
    func anUnwiredDeleteRefuses() {
        let region = RegionFixture.region("Stair Detail", priority: 1)
        let model = ScaleRegionsPanelModel(regions: [region])
        #expect(!model.delete(regionID: region.id))
        #expect(model.refusal != nil)
    }
}

/// Bug hunt 2 fixes in the Scale Regions panel.
@Suite("Scale Regions fixes (bug hunt 2)")
@MainActor
struct ScaleRegionsFixLaneTests {

    private func crossing() -> ScaleRegionCrossing {
        ScaleRegionCrossing(
            id: UUID(),
            measurementName: "Area",
            pageLabel: "A-101",
            regions: [
                RegionFixture.region("Stair Detail", priority: 2, ratio: "1:20"),
                RegionFixture.region("Plan", priority: 1, ratio: "1:50")
            ],
            canSplitAtBoundary: true,
            pageDefaultScale: RegionFixture.scale("1:100", id: 9)
        )
    }

    /// Old output: the panel's bare `@State` still held `.splitAtBoundary`, so crossing B
    /// opened with Split selected and Continue live.
    @Test("BH-048: a choice made for one crossing is not the answer to the next")
    func choiceDoesNotCarryOver() {
        let first = crossing()
        let second = crossing()
        var choice = ScaleRegionCrossingChoice()
        choice.choose(.splitAtBoundary, for: first)
        #expect(choice.resolution(for: first) == .splitAtBoundary)
        #expect(choice.resolution(for: second) == nil, "old output: .splitAtBoundary")
    }

    /// IM-110: the host binds the panel to the model, which resets for every crossing.
    @Test("IM-110: the model's choice is empty for every new crossing")
    func modelChoiceResets() {
        let model = RegionFixture.wiredModel()
        model.onResolveCrossing = { _, _ in }
        model.present(crossing: crossing())
        #expect(model.chooseCrossingResolution(.splitAtBoundary))
        #expect(model.confirmCrossing())
        model.present(crossing: crossing())
        #expect(model.chosenCrossingResolution == nil)
    }

    /// Old output: `#1FB6D9` in the subtitle, and no colour in the spoken value.
    @Test("BH-751 / IM-207: a region colour is named in words")
    func colourIsNamed() {
        #expect(ZenitRegionPalette.name(for: ColorRGBA.Zenit.Dark.cyan) == ZenitRegionPalette.entry(for: "cyan").name)
        #expect(ZenitRegionPalette.name(for: ColorRGBA.Zenit.Dark.danger) == ZenitRegionPalette.entry(for: "coral").name)
    }

    @Test("IM-206: regions are ordered once and overlaps looked up in a set")
    func orderingAndOverlapsOnce() {
        let high = RegionFixture.region("B", priority: 3)
        let tie1 = RegionFixture.region("A", priority: 1)
        let tie2 = RegionFixture.region("C", priority: 1)
        #expect(ScaleRegionSummary.inResolutionOrder([tie2, high, tie1]).map(\.name) == ["B", "A", "C"])
        let overlap = ScaleRegionOverlap(first: high.id, second: tie1.id, firstName: "B", secondName: "A")
        #expect(ScaleRegionsPanel.overlappingIDs([overlap]) == [high.id, tie1.id])

        // 400 regions: the per-row scan the panel used to do against one set lookup.
        let many = (0..<400).map { RegionFixture.region("R\($0)", priority: $0) }
        let overlaps = (0..<200).map { ScaleRegionOverlap(first: many[$0 * 2].id, second: many[$0 * 2 + 1].id, firstName: "a", secondName: "b") }
        let clock = ContinuousClock()
        let old = clock.measure {
            for region in many { _ = overlaps.contains { $0.first == region.id || $0.second == region.id } }
            for _ in many { _ = ScaleRegionSummary.inResolutionOrder(many).count }
        }
        let new = clock.measure {
            let ordered = ScaleRegionSummary.inResolutionOrder(many)
            let set = ScaleRegionsPanel.overlappingIDs(overlaps)
            for region in ordered { _ = set.contains(region.id) }
        }
        print("IM-206: 400 regions, per-row sort + scan \(old), once per render \(new)")
        #expect(new < old)
    }

    @Test("IM-112: one name rule, trimmed and case-insensitive, for create and rename")
    func oneNameRule() {
        let existing = RegionFixture.region("Zone A", priority: 1)
        let other = RegionFixture.region("Zone B", priority: 2)
        let model = RegionFixture.wiredModel(regions: [existing, other])
        model.onCreateRegion = { _ in }
        RegionFixture.drawSquare(in: model, at: 300)
        model.assignDraftScale(RegionFixture.scale("1:50"))
        model.setDraftName(" zone a ")
        #expect(!model.canCommitDraft, "old output: committable — the comparison was case-sensitive")
        #expect(model.draftProblem == .nameTaken("zone a"))
        #expect(!model.commitDraft())
        #expect(model.refusal == .nameTaken("zone a"))
        #expect(!model.rename(regionID: other.id, to: "ZONE A"))
        #expect(model.refusal == .nameTaken("ZONE A"))
        #expect(model.rename(regionID: existing.id, to: "zone a"), "renaming a region to its own name in another case is fine")
    }

    @Test("IM-209: a region-in-use refusal offers Show Measurements")
    func regionInUseOffersReveal() {
        let region = RegionFixture.region("Stair Detail", priority: 1)
        let model = RegionFixture.wiredModel(regions: [region])
        model.onDeleteRegion = { _ in }
        var revealed: [UUID] = []
        model.onRevealMarkups = { revealed.append($0) }
        model.setMarkupCounts([region.id: 4])
        #expect(!model.delete(regionID: region.id))
        #expect(model.canRevealRefusedMarkups)
        #expect(model.revealRefusedMarkups())
        #expect(revealed == [region.id])
    }
}

/// R-147. The suggested name has to pass the same rule the Create button reads.
@Suite("Scale Regions: the suggested name")
@MainActor
struct ScaleRegionSuggestedNameTests {

    /// Old output: the draft was named `Scale Region 2` beside `scale region 2`, `draftProblem`
    /// was `.nameTaken("Scale Region 2")` and `canCommitDraft` was false on the default name.
    @Test("A name that differs only in case or trailing space counts as taken")
    func suggestionSkipsCaseAndWhitespaceVariants() {
        let model = RegionFixture.wiredModel(regions: [
            RegionFixture.region("scale region 2", priority: 1)
        ])
        RegionFixture.drawSquare(in: model)
        #expect(model.draft?.name == "Scale Region 3")
        model.assignDraftScale(RegionFixture.scale("1:50"))
        #expect(model.draftProblem == nil)
        #expect(model.canCommitDraft)

        let spaced = RegionFixture.wiredModel(regions: [
            RegionFixture.region("Scale Region 2 ", priority: 1),
            RegionFixture.region("SCALE REGION 3", priority: 2)
        ])
        RegionFixture.drawSquare(in: spaced)
        // Two regions, so the count starts at 3; 3 is taken case-blind, so 4.
        #expect(spaced.draft?.name == "Scale Region 4")
        spaced.assignDraftScale(RegionFixture.scale("1:50"))
        #expect(spaced.canCommitDraft)
    }
}

/// S-091: a region's name and scale are fixed in place from its row. The model methods and the
/// app's hooks existed; nothing in the panel reached them, and a misnamed region still measuring
/// markups could not even be deleted and redrawn.
@Suite("Scale Regions: rename and assign scale from the row")
@MainActor
struct ScaleRegionRowEditingTests {

    @Test("Rename opens the field with the current name; Return commits the trimmed name through the hook")
    func renameCommits() {
        let region = RegionFixture.region("Stair Detial", priority: 1)
        let model = RegionFixture.wiredModel(regions: [region])
        var renamed: [(UUID, String)] = []
        model.onRenameRegion = { renamed.append(($0, $1)) }

        #expect(model.beginRename(regionID: region.id))
        #expect(model.renamingRegionID == region.id)
        #expect(model.renameDraft == "Stair Detial")
        model.renameDraft = "  Stair Detail "
        #expect(model.commitRename())
        #expect(renamed.count == 1)
        #expect(renamed.first?.0 == region.id)
        #expect(renamed.first?.1 == "Stair Detail")
        #expect(model.renamingRegionID == nil)
    }

    @Test("A taken name keeps the field open with the refusal; Escape closes it without an edit")
    func refusedRenameStaysOpen() {
        let first = RegionFixture.region("Stair Detail", priority: 1)
        let second = RegionFixture.region("Lift Core", priority: 2)
        let model = RegionFixture.wiredModel(regions: [first, second])
        var renamed = 0
        model.onRenameRegion = { _, _ in renamed += 1 }

        #expect(model.beginRename(regionID: second.id))
        model.renameDraft = "stair detail"
        #expect(!model.commitRename())
        #expect(model.refusal == .nameTaken("stair detail"))
        #expect(model.renamingRegionID == second.id, "the field stays open so the name can be fixed")
        model.cancelRename()
        #expect(model.renamingRegionID == nil)
        #expect(model.refusal == nil)
        #expect(renamed == 0)
    }

    @Test("An unchanged name closes the field without an edit")
    func unchangedNameIsNoEdit() {
        let region = RegionFixture.region("Stair Detail", priority: 1)
        let model = RegionFixture.wiredModel(regions: [region])
        var renamed = 0
        model.onRenameRegion = { _, _ in renamed += 1 }
        #expect(model.beginRename(regionID: region.id))
        #expect(model.commitRename())
        #expect(renamed == 0)
        #expect(model.renamingRegionID == nil)
    }

    @Test("A locked region refuses to open its name, as every other edit to it does")
    func lockedRegionRefusesRename() {
        let locked = RegionFixture.region("Stair Detail", priority: 1, locked: true)
        let model = RegionFixture.wiredModel(regions: [locked])
        #expect(!model.beginRename(regionID: locked.id))
        #expect(model.refusal == .regionLocked(name: "Stair Detail"))
        #expect(model.renamingRegionID == nil)
    }

    @Test("The rename field closes when its region disappears in a refresh")
    func renameClosesWithItsRegion() {
        let region = RegionFixture.region("Stair Detail", priority: 1)
        let model = RegionFixture.wiredModel(regions: [region])
        #expect(model.beginRename(regionID: region.id))
        model.setRegions([], pageID: RegionFixture.pageID)
        #expect(model.renamingRegionID == nil)
    }

    @Test("Without the hooks, rename and assign refuse instead of succeeding silently")
    func unwiredEditsRefuse() {
        let region = RegionFixture.region("Stair Detail", priority: 1)
        let model = ScaleRegionsPanelModel(regions: [region])
        // Old output: both returned true and nothing was stored.
        #expect(!model.rename(regionID: region.id, to: "Lift Core"))
        #expect(model.refusal != nil)
        #expect(!model.assignScale(RegionFixture.scale("1:20", id: 2), to: region.id))
        #expect(model.refusal != nil)
    }

    @Test("The row's scale menu offers every project scale and marks the one the region uses")
    func scaleMenuChoices() {
        let region = RegionFixture.region("Stair Detail", priority: 1, ratio: "1:50")
        let model = RegionFixture.wiredModel(regions: [region])
        let choices = ScaleRegionsPanel.scaleChoices(model.availableScales, for: region)
        #expect(choices.map(\.scale.displayString) == ["1:50", "1:20"])
        #expect(choices.map(\.isCurrent) == [true, false])

        var assigned: [(UUID, String)] = []
        model.onAssignScale = { assigned.append(($0, $1.displayString)) }
        #expect(model.assignScale(choices[1].scale, to: region.id))
        #expect(assigned.first?.0 == region.id)
        #expect(assigned.first?.1 == "1:20")
    }
}
