import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIMeasurement

/// Quality-loop iteration 3, area "ui-presentation-measure": the input machine, the cutout
/// resolver, the Scale Regions panel and the measurement strings. Nothing here reaches a screen:
/// the machine is a value, the controller drives the mock presenter, the panel is a model.
@MainActor
@Suite("Iteration 3 ui-presentation-measure (measurement input and panels)")
struct Iter3UIPresentationMeasureTests {

    private static func p(_ x: Double, _ y: Double) -> PDFPointValue { PDFPointValue(x: x, y: y) }

    /// The machine as the shipping canvas configures it (`appliesCanvasGestures`).
    private func canvasMachine() -> MeasurementInputStateMachine {
        MeasurementInputStateMachine(
            configuration: MeasurementInputConfiguration(reusesToolAfterCommit: true, appliesCanvasGestures: true)
        )
    }

    /// A click as the canvas routes it: the pointer moves there, then the machine places at
    /// the cursor (`routeMeasurementClick` → `.placePointAtCursor`).
    @discardableResult
    private func click(_ machine: inout MeasurementInputStateMachine, _ point: PDFPointValue) -> [MeasurementInputEffect] {
        machine.handle(.pointerMoved(point))
        return machine.handle(.placePointAtCursor)
    }

    // MARK: - T-055

    /// Old output: after two clicked corners `canFinish` was true (the kind's minimum, 2, was
    /// used because only a press-release sent as a *drag* set click mode), the announcement read
    /// "Point 2 placed. Rectangle Area can be finished with Return." and Return committed the
    /// edge's axis-aligned bounding box.
    @Test("T-055: two clicked Rectangle Area corners cannot be finished with Return")
    func clickedRectangleNeedsThreeCorners() {
        var machine = canvasMachine()
        machine.handle(.armTool(.rectangleArea))
        click(&machine, Self.p(130, 130))
        let second = click(&machine, Self.p(230, 130))
        #expect(machine.state.vertices.count == 2)
        #expect(!machine.state.isClickPlacingDragTool, "the canvas path never enters drag click mode")
        #expect(!machine.state.canFinish, "old output: true")
        #expect(machine.state.remainingVertexCount == 1)
        #expect(second.contains(.announce("Point 2 placed. 1 more point needed.")))
        let finish = machine.handle(.finish)
        #expect(!finish.contains(.commitMeasurement), "old output: the edge's bounding box was committed")
        // W-074: the sentence Finish says; it read "Rectangle Area: 1 more point needed.".
        #expect(finish.contains(.rejectFinish("Rectangle Area needs 1 more point before it can be finished.")))

        // The third click still finishes with the derived corner: P4 = P1 + P3 − P2 = (130, 180).
        let third = click(&machine, Self.p(230, 180))
        #expect(third.contains(.placePoint(Self.p(130, 180))))
        #expect(third.contains(.commitMeasurement))
    }

    /// Old output: `canCommit` true and `remainingPointCount` 0 at two points, so the shell's
    /// Finish and Measure ▸ Finish committed two points, which the presenter expands to a box.
    @Test("T-055: the presenter's commit gate needs three Rectangle Area corners")
    func presenterNeedsThreeCorners() {
        #expect(MeasurementKind.rectangleArea.minimumPointCount == 3)
        let presenter = MockMeasurementToolPresenter()
        var committed: [MarkupSummary] = []
        presenter.onCommit = { committed.append($0) }
        presenter.activate(kind: .rectangleArea)
        presenter.placePoint(Self.p(130, 130))
        presenter.placePoint(Self.p(230, 130))
        #expect(!presenter.canCommit, "old output: true")
        #expect(presenter.remainingPointCount == 1)
        #expect(presenter.commitRefusalReason == "Rectangle Area needs 1 more point before it can be finished.")
        presenter.commitActiveMeasurement()
        #expect(committed.isEmpty)
    }

    /// A presenter driven straight through the controller (no canvas) still gets a finished box
    /// from one drag: the machine hands it the dragged box's four corners in drawing order.
    /// Old output: only the release corner was placed, so the presenter held two points.
    @Test("T-055: a drag through the controller over a presenter commits the whole box")
    func bareControllerDragCommitsTheBox() throws {
        let presenter = MockMeasurementToolPresenter()
        var committed: [MarkupSummary] = []
        presenter.onCommit = { committed.append($0) }
        let input = MeasurementInputController(presenter: presenter, announcer: { _ in })
        input.send(.armTool(.rectangleArea))
        input.send(.dragBegan(Self.p(10, 10)))
        input.send(.dragMoved(Self.p(60, 40)))
        input.send(.dragEnded(Self.p(110, 80)))
        #expect(input.lastEffects.contains(.placePoint(Self.p(110, 10))))
        #expect(input.lastEffects.contains(.placePoint(Self.p(110, 80))))
        #expect(input.lastEffects.contains(.placePoint(Self.p(10, 80))))
        let markup = try #require(committed.first)
        #expect(committed.count == 1)
        #expect(markup.boundsInPageSpace == PDFRectValue(x: 10, y: 10, width: 100, height: 70))
    }

    // MARK: - T-058

    /// A circle of radius `r` around (`cx`, `cy`) as a 360-gon, the way the canvas publishes a
    /// round parent.
    private static func circle(_ id: UUID, cx: Double, cy: Double, r: Double) -> CutoutParentCandidate {
        CutoutParentCandidate(
            markupID: id,
            outerRing: (0..<360).map { index in
                let angle = Double(index) * .pi / 180
                return p(cx + r * cos(angle), cy + r * sin(angle))
            },
            subject: "Round slab"
        )
    }

    private static let round = UUID(uuidString: "00000000-0000-0000-0000-0000000000C1") ?? UUID()
    private static let diamond = UUID(uuidString: "00000000-0000-0000-0000-0000000000D1") ?? UUID()
    private static let big = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1") ?? UUID()
    private static let small = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1") ?? UUID()

    /// Old output: a concentric circular hole of radius 80 in a round parent of radius 100 was
    /// refused at the press — its box corner (120, 120) lies 113 from the centre, outside the
    /// parent — with "A cutout must start inside an area measurement."
    ///
    /// X-cutout-ui: a radius-105 opening, reaching past the radius-100 parent, used to be refused
    /// as not fitting. The engine subtracts the part inside, so it resolves to its parent too;
    /// whether a cutout overlaps its parent at all is the engine's verdict, not this resolver's.
    @Test("T-058: a round opening in a round parent resolves to it, fitting or reaching past it")
    func roundOpeningInRoundParent() {
        let parent = Self.circle(Self.round, cx: 200, cy: 200, r: 100)
        #expect(!parent.contains(Self.p(120, 120)), "the box corner really is outside the parent")
        #expect(
            CutoutParentResolver.resolveEllipse(corner: Self.p(120, 120), opposite: Self.p(280, 280), candidates: [parent])
                == .resolved(parent)
        )
        #expect(
            CutoutParentResolver.resolveEllipse(corner: Self.p(95, 95), opposite: Self.p(305, 305), candidates: [parent])
                == .resolved(parent)
        )
    }

    /// Old output: a radius-60 circle centred in a square turned 45° (inscribed radius 70.7) was
    /// refused, because its box corner (240, 240) is outside the turned square.
    ///
    /// X-cutout-ui: a radius-75 circle crossing the turned edges used to be refused as not
    /// fitting; the engine subtracts the part inside, so it resolves to the turned bay.
    @Test("T-058: a round opening in a rotated rectangular parent resolves to it, fitting or crossing its edges")
    func roundOpeningInRotatedParent() {
        let parent = CutoutParentCandidate(
            markupID: Self.diamond,
            outerRing: [Self.p(300, 200), Self.p(400, 300), Self.p(300, 400), Self.p(200, 300)],
            subject: "Turned bay"
        )
        #expect(!parent.contains(Self.p(240, 240)))
        #expect(
            CutoutParentResolver.resolveEllipse(corner: Self.p(240, 240), opposite: Self.p(360, 360), candidates: [parent])
                == .resolved(parent)
        )
        #expect(
            CutoutParentResolver.resolveEllipse(corner: Self.p(225, 225), opposite: Self.p(375, 375), candidates: [parent])
                == .resolved(parent)
        )
    }

    /// X-cutout-ui. Old output: `.refused(.ellipseOutsideParent(parentName: "Slab"))` — a narrow
    /// spike of the parent reaching into the opening made the interface refuse an opening the
    /// engine subtracts (the part inside the parent, around the spike).
    @Test("T-058: a notch of the parent reaching into the opening no longer refuses it")
    func notchIntoTheOpeningResolves() {
        let parent = CutoutParentCandidate(
            markupID: Self.big,
            outerRing: [
                Self.p(0, 0), Self.p(97.7, 0), Self.p(97.82, 90), Self.p(97.94, 0),
                Self.p(200, 0), Self.p(200, 200), Self.p(0, 200)
            ],
            subject: "Slab"
        )
        #expect(
            CutoutParentResolver.resolveEllipse(corner: Self.p(50, 50), opposite: Self.p(150, 150), candidates: [parent])
                == .resolved(parent)
        )
    }

    /// Old output: the press corner (40, 40) resolved the small area it lies in, and the release
    /// was refused as "outside" it, although the ellipse sits in the big area.
    @Test("T-058: the parent is the area the ellipse's centre is in, not the press corner's")
    func parentFromTheCentre() {
        let bigArea = CutoutParentCandidate(
            markupID: Self.big,
            outerRing: [Self.p(0, 0), Self.p(400, 0), Self.p(400, 400), Self.p(0, 400)],
            subject: "Floor"
        )
        let smallArea = CutoutParentCandidate(
            markupID: Self.small,
            outerRing: [Self.p(0, 0), Self.p(50, 0), Self.p(50, 50), Self.p(0, 50)],
            subject: "Pad"
        )
        var machine = canvasMachine()
        machine.handle(.armTool(.ellipseCutout))
        machine.handle(.setCutoutParents([bigArea, smallArea]))
        let pressed = machine.handle(.dragBegan(Self.p(40, 40)))
        #expect(!pressed.contains { if case .rejectFinish = $0 { return true } else { return false } })
        #expect(machine.state.cutoutParent == nil, "old output: the Pad, decided by the press corner")
        machine.handle(.dragMoved(Self.p(120, 120)))
        let released = machine.handle(.dragEnded(Self.p(200, 200)))
        #expect(released.contains(.commitCutout(parentMarkupID: Self.big)), "old output: refused as outside the Pad")
    }

    /// Old output: the press at the box corner was refused with "A cutout must start inside an
    /// area measurement."; the same with the keyboard's two placed corners.
    @Test("T-058: the machine accepts a round opening in a round parent, dragged or placed")
    func machineAcceptsRoundOpening() {
        let parent = Self.circle(Self.round, cx: 200, cy: 200, r: 100)
        var dragged = canvasMachine()
        dragged.handle(.armTool(.ellipseCutout))
        dragged.handle(.setCutoutParents([parent]))
        let pressed = dragged.handle(.dragBegan(Self.p(120, 120)))
        #expect(!pressed.contains { if case .rejectFinish = $0 { return true } else { return false } })
        dragged.handle(.dragMoved(Self.p(200, 200)))
        #expect(dragged.handle(.dragEnded(Self.p(280, 280))).contains(.commitCutout(parentMarkupID: Self.round)))

        var placed = MeasurementInputStateMachine()
        placed.handle(.armTool(.ellipseCutout))
        placed.handle(.setCutoutParents([parent]))
        #expect(placed.handle(.placePoint(Self.p(120, 120))).contains(.placePoint(Self.p(120, 120))))
        #expect(placed.handle(.placePoint(Self.p(280, 280))).contains(.commitCutout(parentMarkupID: Self.round)))

        // X-cutout-ui: an opening reaching past the parent is committed against it — the engine
        // subtracts the part inside. It used to be refused at the second corner.
        var tooBig = MeasurementInputStateMachine()
        tooBig.handle(.armTool(.ellipseCutout))
        tooBig.handle(.setCutoutParents([parent]))
        tooBig.handle(.placePoint(Self.p(90, 90)))
        let accepted = tooBig.handle(.placePoint(Self.p(310, 310)))
        #expect(!accepted.contains { if case .rejectFinish = $0 { return true } else { return false } })
        #expect(accepted.contains(.commitCutout(parentMarkupID: Self.round)))
    }

    // MARK: - T-056

    private static let regionPage = UUID(uuidString: "11111111-1111-1111-1111-111111111111") ?? UUID()

    private static func scale(_ ratio: String, id: Int) -> ScaleSummary {
        ScaleSummary(
            id: UUID(uuidString: "22222222-2222-2222-2222-2222222222\(String(format: "%02d", id))") ?? UUID(),
            name: "Plan \(ratio)", displayString: ratio, isUniform: true,
            sx: 0.0176, sy: 0.0176, unit: .metre, version: 1, locked: false
        )
    }

    private static let boundary = [p(0, 0), p(100, 0), p(100, 100), p(0, 100)]

    /// Old output: `commitDraft` cleared the draft before the core answered, so a refused create
    /// left no draft — the boundary the person drew was gone.
    @Test("T-056: a create the core refuses puts the draft back in the editor")
    func refusedCreateRestoresTheDraft() throws {
        let model = ScaleRegionsPanelModel()
        var created: [ScaleRegionCreation] = []
        model.onBeginPolygon = {}
        model.onCreateRegion = { created.append($0) }
        model.setRegions([], pageID: Self.regionPage)
        model.beginRegion()
        model.completePolygon(Self.boundary, pageID: Self.regionPage, pageLabel: "A-101")
        model.setDraftName("Detail A")
        model.assignDraftScale(Self.scale("1:20", id: 2))
        #expect(model.commitDraft())
        #expect(model.draft == nil)
        #expect(created.count == 1)

        model.rejectDraft(reason: "That scale was calibrated on another sheet.")
        let restored = try #require(model.draft, "old output: nil")
        #expect(restored.boundary == Self.boundary)
        #expect(restored.name == "Detail A")
        #expect(restored.scale?.id == Self.scale("1:20", id: 2).id)
        #expect(model.refusal == .rejectedByCore("That scale was calibrated on another sheet."))

        // Picking another scale and creating again works from the restored draft.
        model.assignDraftScale(Self.scale("1:50", id: 1))
        #expect(model.commitDraft())
        #expect(created.last?.scale.id == Self.scale("1:50", id: 1).id)
        #expect(created.last?.boundary == Self.boundary)
    }

    @Test("T-056: once the region exists, a later refusal does not bring a draft back")
    func acceptedCreateIsNotRestored() {
        let model = ScaleRegionsPanelModel()
        model.onBeginPolygon = {}
        var created: [ScaleRegionCreation] = []
        model.onCreateRegion = { created.append($0) }
        model.setRegions([], pageID: Self.regionPage)
        model.beginRegion()
        model.completePolygon(Self.boundary, pageID: Self.regionPage, pageLabel: "A-101")
        model.assignDraftScale(Self.scale("1:20", id: 2))
        #expect(model.commitDraft())
        let creation = created[0]
        model.setRegions([
            ScaleRegionSummary(
                id: creation.id, name: creation.name, pageID: Self.regionPage, pageLabel: "A-101",
                scale: creation.scale, boundary: creation.boundary, priority: creation.priority,
                locked: false, colorRGBA: creation.colorRGBA, isVisible: true
            )
        ], pageID: Self.regionPage)
        model.rejectDraft(reason: "Some later edit was refused.")
        #expect(model.draft == nil)
        #expect(model.refusal == .rejectedByCore("Some later edit was refused."))
    }

    // MARK: - T-062

    /// Old output: "1 pages, 1 markups, 1 measurements would be recalculated." and
    /// "1 pages, 1 markups. 1 measurements keep their values and are flagged …".
    @Test("T-062: the bulk scale summaries say the singular")
    func bulkScaleSingular() {
        let one = BulkScaleImpact(pageCount: 1, markupCount: 1, affectedMeasurementCount: 1)
        #expect(one.summary == "1 page, 1 markup, 1 measurement would be recalculated.")
        #expect(one.keepValuesSummary == "1 page, 1 markup. 1 measurement keeps its value and is flagged as measured against an older scale.")
        let many = BulkScaleImpact(pageCount: 4, markupCount: 30, affectedMeasurementCount: 12)
        #expect(many.summary == "4 pages, 30 markups, 12 measurements would be recalculated.")
        #expect(many.keepValuesSummary == "4 pages, 30 markups. 12 measurements keep their values and are flagged as measured against an older scale.")
        // Old output: "1 of these pages have a locked scale and will be skipped."
        #expect(BulkScaleSheet.lockedPagesWarning(1) == "1 of these pages has a locked scale and will be skipped.")
        #expect(BulkScaleSheet.lockedPagesWarning(3) == "3 of these pages have a locked scale and will be skipped.")
    }

    /// Old output: "1 sheets: 1 set, 0 proposed, 0 without a scale." and "Apply 1 Proposed Scales".
    @Test("T-062: the Page Scales summary and button say the singular")
    func pageScalesSingular() {
        let rows = [PageScaleRow(id: UUID(), label: "A-101", sizeText: "A1", status: .set(ratio: "1:100", source: "Calibrated"))]
        #expect(PageScalesPanel.summary(of: rows) == "1 sheet: 1 set, 0 proposed, 0 without a scale.")
        #expect(PageScalesPanel.applyProposalsTitle(1) == "Apply 1 Proposed Scale")
        #expect(PageScalesPanel.applyProposalsTitle(3) == "Apply 3 Proposed Scales")
    }

    /// Old output: "“Detail A” is the scale behind 1 measurements. Move them out before deleting
    /// it, or their numbers change without anyone deciding to."
    @Test("T-062: a region in use by one measurement says so in the singular")
    func regionInUseSingular() {
        #expect(
            ScaleRegionRefusal.regionInUse(name: "Detail A", markupCount: 1).message
                == "“Detail A” is the scale behind 1 measurement. Move it out before deleting the region, or its number changes without anyone deciding to."
        )
        #expect(
            ScaleRegionRefusal.regionInUse(name: "Detail A", markupCount: 3).message
                == "“Detail A” is the scale behind 3 measurements. Move them out before deleting it, or their numbers change without anyone deciding to."
        )
    }

    /// Old output: "Count finished with 1 points." and "Vertex removed. 1 points placed."
    @Test("T-062: the input machine's spoken counts say the singular")
    func machineAnnouncementsSingular() {
        var count = MeasurementInputStateMachine()
        count.handle(.armTool(.count))
        count.handle(.placePoint(Self.p(10, 10)))
        #expect(count.handle(.cancel).contains(.announce("Count finished with 1 point.")))

        var polyline = MeasurementInputStateMachine()
        polyline.handle(.armTool(.polylength))
        polyline.handle(.placePoint(Self.p(0, 0)))
        polyline.handle(.placePoint(Self.p(100, 0)))
        #expect(polyline.handle(.removeLastVertex).contains(.announce("Vertex removed. 1 point placed.")))
        polyline.handle(.placePoint(Self.p(100, 0)))
        polyline.handle(.placePoint(Self.p(100, 100)))
        #expect(polyline.handle(.finish).contains(.announce("Polylength finished with 3 points.")))
    }
}
