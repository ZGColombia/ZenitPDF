import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIMeasurement

/// IM-019: the pieces the shipping canvas needs to route every measurement event through the
/// input state machine — presenter synchronisation, the canvas's gesture table, the ⌥-click
/// rectangle and a host that applies effects itself.
///
/// Every expected value is derived by hand from the gesture's rule, never read back from output.
@Suite("Canvas input routing: machine (IM-019)")
struct CanvasInputRoutingMachineTests {

    private static let pageID = UUID(uuidString: "00000000-0000-0000-0000-0000000019A1") ?? UUID()
    private static let areaA = UUID(uuidString: "00000000-0000-0000-0000-0000000019AA") ?? UUID()

    private func machine(canvas: Bool = true, shiftTolerance: Double = 6) -> MeasurementInputStateMachine {
        MeasurementInputStateMachine(
            configuration: MeasurementInputConfiguration(
                initialCursor: PDFPointValue(x: 100, y: 100),
                constrainedRayTolerance: shiftTolerance,
                appliesCanvasGestures: canvas
            )
        )
    }

    private func candidate(at point: PDFPointValue) -> SnapFeedbackSnapshot {
        SnapFeedbackSnapshot(kind: .endpoint, pagePoint: point, sourceLabel: "wall", pageID: Self.pageID)
    }

    private func squareA() -> CutoutParentCandidate {
        CutoutParentCandidate(
            markupID: Self.areaA,
            outerRing: [
                PDFPointValue(x: 0, y: 0), PDFPointValue(x: 100, y: 0),
                PDFPointValue(x: 100, y: 100), PDFPointValue(x: 0, y: 100)
            ],
            subject: ""
        )
    }

    private func p(_ x: Double, _ y: Double) -> PDFPointValue { PDFPointValue(x: x, y: y) }

    private func placements(_ effects: [MeasurementInputEffect]) -> [PDFPointValue] {
        effects.compactMap { if case let .placePoint(point) = $0 { return point } else { return nil } }
    }

    // MARK: - Synchronisation

    @Test("synchronize adopts the presenter's tool and points without an effect")
    func synchronizeAdoptsPresenterState() {
        var flow = machine()
        flow.synchronize(kind: .area, vertices: [p(0, 0), p(10, 0)], cutoutParentID: nil)
        #expect(flow.state.kind == .area)
        #expect(flow.state.phase == .drawing)
        #expect(flow.state.vertices == [p(0, 0), p(10, 0)])

        // A third point then closes nothing yet; the fourth click on the first vertex closes.
        _ = flow.handle(.placePoint(p(10, 10)))
        let closing = flow.handle(.placePoint(p(0, 0)))
        #expect(closing.first == .commitMeasurement, "three synced/placed vertices and a click on the first closes")
    }

    @Test("synchronize with no tool returns the machine to idle; a different tool re-arms it empty")
    func synchronizeToolChanges() {
        var flow = machine()
        flow.handle(.armTool(.length))
        flow.handle(.placePoint(p(1, 1)))
        flow.synchronize(kind: nil, vertices: [], cutoutParentID: nil)
        #expect(flow.state.phase == .idle)
        #expect(flow.state.kind == nil)
        #expect(flow.state.vertices.isEmpty)

        flow.synchronize(kind: .count, vertices: [], cutoutParentID: nil)
        #expect(flow.state.phase == .armed)
        #expect(flow.state.kind == .count)
    }

    @Test("synchronize keeps a drag's press while the presenter still holds the same shape")
    func synchronizeKeepsDragPress() {
        var flow = machine()
        flow.synchronize(kind: .rectangleArea, vertices: [], cutoutParentID: nil)
        _ = flow.handle(.dragBegan(p(10, 10)))
        #expect(flow.state.dragPressPoint == p(10, 10))
        // The presenter's snapped anchor landed a hair away: the shape is the same shape.
        flow.synchronize(kind: .rectangleArea, vertices: [p(10.004, 10)], cutoutParentID: nil)
        #expect(flow.state.dragPressPoint == p(10, 10), "the press survives a vertex refresh")
        // The presenter dropped the shape (a cancel elsewhere): the press goes with it.
        flow.synchronize(kind: .rectangleArea, vertices: [], cutoutParentID: nil)
        #expect(flow.state.dragPressPoint == nil)
        #expect(flow.state.phase == .armed)
    }

    @Test("synchronize restores a cutout's parent from the presenter's parent id")
    func synchronizeRestoresCutoutParent() {
        var flow = machine()
        flow.handle(.setCutoutParents([squareA()]))
        flow.synchronize(kind: .polygonCutout, vertices: [p(10, 10)], cutoutParentID: Self.areaA)
        #expect(flow.state.cutoutParent?.markupID == Self.areaA)
        // A later vertex keeps that parent, even outside it: the engine subtracts the part
        // inside (X-cutout-ui; it used to be refused against the parent).
        let placed = flow.handle(.placePoint(p(150, 10)))
        #expect(!placed.contains { if case .rejectFinish = $0 { return true } else { return false } })
        #expect(flow.state.vertices == [p(10, 10), p(150, 10)])
        #expect(flow.state.cutoutParent?.markupID == Self.areaA)
    }

    // MARK: - Canvas gestures

    @Test("Canvas gestures: Area is drawn by press-drag-release as well as by clicks")
    func areaDragInCanvasMode() {
        var flow = machine()
        flow.synchronize(kind: .area, vertices: [], cutoutParentID: nil)
        let press = flow.handle(.dragBegan(p(10, 10)))
        #expect(placements(press) == [p(10, 10)])
        let release = flow.handle(.dragEnded(p(60, 40)))
        #expect(placements(release) == [p(60, 40)])
        #expect(release.contains(.commitMeasurement))

        var semantics = machine(canvas: false)
        semantics.synchronize(kind: .area, vertices: [], cutoutParentID: nil)
        #expect(semantics.handle(.dragBegan(p(10, 10))).isEmpty, "without the canvas table Area is a click tool")
    }

    @Test("Canvas gestures: a press on a click-placed shape continues it, its release is not a drag")
    func pressContinuesClickPlacedShape() {
        var flow = machine()
        flow.synchronize(kind: .area, vertices: [p(0, 0), p(50, 0)], cutoutParentID: nil)
        #expect(flow.handle(.dragBegan(p(50, 50))).isEmpty)
        #expect(flow.state.vertices == [p(0, 0), p(50, 0)], "old semantics cancelled the polygon here")
        #expect(flow.handle(.dragEnded(p(55, 55))).isEmpty, "no press behind it: the canvas routes it as a click")
        #expect(flow.state.vertices == [p(0, 0), p(50, 0)])
    }

    // MARK: - ⌥-click rectangle

    @Test("⌥-click with an edge placed derives the rectangle: depth, P4 = P1 + P3 − P2, commit")
    func optionRectangleFromEdge() {
        var flow = machine()
        flow.synchronize(kind: .area, vertices: [p(0, 0), p(100, 0)], cutoutParentID: nil)
        flow.handle(.pointerMoved(p(90, 40)))
        let effects = flow.handle(.placeRectangleDepthAtCursor)
        // P4 = (0,0) + (90,40) − (100,0) = (−10, 40).
        #expect(placements(effects) == [p(90, 40), p(-10, 40)])
        #expect(effects.contains(.commitMeasurement))
        #expect(flow.state.phase == .armed)
    }

    @Test("⌥-click rectangle under Shift holds the depth perpendicular to the edge")
    func optionRectangleShift() {
        var flow = machine()
        flow.synchronize(kind: .area, vertices: [p(0, 0), p(100, 0)], cutoutParentID: nil)
        flow.handle(.setModifiers(.shift))
        flow.handle(.pointerMoved(p(90, 40)))
        let effects = flow.handle(.placeRectangleDepthAtCursor)
        // The perpendicular of a horizontal edge through its end (100,0) is x = 100:
        // depth (100, 40), P4 = (0,0) + (100,40) − (100,0) = (0, 40).
        #expect(placements(effects) == [p(100, 40), p(0, 40)])
    }

    @Test("⌥-click rectangle uses the snapped depth point")
    func optionRectangleSnaps() {
        var flow = machine()
        flow.synchronize(kind: .area, vertices: [p(0, 0), p(100, 0)], cutoutParentID: nil)
        flow.handle(.pointerMoved(p(90, 40)))
        flow.handle(.setSnapCandidates([candidate(at: p(100, 50))]))
        let effects = flow.handle(.placeRectangleDepthAtCursor)
        #expect(placements(effects) == [p(100, 50), p(0, 50)])
    }

    @Test("⌥-click without exactly two vertices, or on a tool without the gesture, is a plain click")
    func optionRectangleFallsBack() {
        var one = machine()
        one.synchronize(kind: .area, vertices: [p(0, 0)], cutoutParentID: nil)
        one.handle(.pointerMoved(p(40, 0)))
        let second = one.handle(.placeRectangleDepthAtCursor)
        #expect(placements(second) == [p(40, 0)])
        #expect(!second.contains(.commitMeasurement))

        var polylength = machine()
        polylength.synchronize(kind: .polylength, vertices: [p(0, 0), p(10, 0)], cutoutParentID: nil)
        polylength.handle(.pointerMoved(p(20, 5)))
        let third = polylength.handle(.placeRectangleDepthAtCursor)
        #expect(placements(third) == [p(20, 5)])
        #expect(polylength.state.vertices.count == 3)
    }
}

// MARK: - Controller

/// A host that records every effect call, like the shipping canvas's driver.
@MainActor
private final class RecordingTarget: MeasurementInputEffectApplying, CountPointEditing, CutoutCommitting {
    var calls: [String] = []
    func activate(kind: MeasurementKind) { calls.append("activate \(kind.rawValue)") }
    func deactivate() { calls.append("deactivate") }
    func placePoint(_ point: PDFPointValue) { calls.append("place \(point.x),\(point.y)") }
    func removeLastPoint() { calls.append("removeLast") }
    func commitActiveMeasurement() { calls.append("commit") }
    func cancelActiveMeasurement() { calls.append("cancel") }
    func removePoint(at index: Int) { calls.append("remove \(index)") }
    func commitActiveCutout(parentMarkupID: UUID) { calls.append("commitCutout") }
}

/// A host without the optional conformances.
@MainActor
private final class PlainTarget: MeasurementInputEffectApplying {
    var calls: [String] = []
    func activate(kind: MeasurementKind) {}
    func deactivate() {}
    func placePoint(_ point: PDFPointValue) { calls.append("place") }
    func removeLastPoint() {}
    func commitActiveMeasurement() { calls.append("commit") }
    func cancelActiveMeasurement() { calls.append("cancel") }
}

@MainActor
@Suite("Canvas input routing: controller (IM-019)")
struct CanvasInputRoutingControllerTests {

    private func p(_ x: Double, _ y: Double) -> PDFPointValue { PDFPointValue(x: x, y: y) }

    @Test("A target host receives the effects in order, and lastEffects reports them")
    func targetReceivesEffects() {
        let target = RecordingTarget()
        let input = MeasurementInputController(target: target, announcer: { _ in })
        input.synchronize(kind: .length, vertices: [], cutoutParentID: nil)
        #expect(target.calls.isEmpty, "synchronising applies nothing")
        for point in [p(0, 0), p(30, 40)] {
            input.send(.pointerMoved(point))
            input.send(.placePointAtCursor)
        }
        #expect(target.calls == ["place 0.0,0.0", "place 30.0,40.0", "commit"])
        #expect(input.lastEffects.contains(.commitMeasurement))
        #expect(input.lastEffects.contains(.placePoint(p(30, 40))))
    }

    @Test("A target host that adopts CountPointEditing gets ⌥-click removal by index")
    func targetCountRemoval() {
        let target = RecordingTarget()
        let input = MeasurementInputController(target: target, announcer: { _ in })
        input.synchronize(kind: .count, vertices: [p(10, 10), p(50, 10), p(90, 10)], cutoutParentID: nil)
        input.send(.pointerMoved(p(51, 11)))
        input.send(.removePoint(near: p(51, 11)))
        #expect(target.calls == ["remove 1"])
        #expect(input.state.vertices == [p(10, 10), p(90, 10)])
    }

    @Test("A target host without CountPointEditing refuses removal and reports no effect")
    func plainTargetRefusesRemoval() {
        let target = PlainTarget()
        let input = MeasurementInputController(target: target, announcer: { _ in })
        input.synchronize(kind: .count, vertices: [p(10, 10), p(50, 10)], cutoutParentID: nil)
        input.send(.pointerMoved(p(50, 10)))
        input.send(.removePoint(near: p(50, 10)))
        #expect(input.lastEffects.isEmpty)
        #expect(input.state.vertices.count == 2)
        #expect(target.calls.isEmpty)
    }

    @Test("A target host that adopts CutoutCommitting commits cutouts through it")
    func targetCutoutCommit() {
        let target = RecordingTarget()
        let input = MeasurementInputController(target: target, announcer: { _ in })
        input.setCutoutParents([
            CutoutParentCandidate(
                markupID: UUID(),
                outerRing: [p(0, 0), p(200, 0), p(200, 200), p(0, 200)],
                subject: ""
            )
        ])
        input.synchronize(kind: .polygonCutout, vertices: [], cutoutParentID: nil)
        for point in [p(10, 10), p(100, 10), p(50, 100)] {
            input.send(.pointerMoved(point))
            input.send(.placePointAtCursor)
        }
        input.send(.finish)
        #expect(target.calls.last == "commitCutout")
        #expect(!target.calls.contains("commit"))
    }

    @Test("A presenter still drives the controller through the original initialiser")
    func presenterInitStillWorks() {
        let presenter = MockMeasurementToolPresenter()
        let input = MeasurementInputController(presenter: presenter, announcer: { _ in })
        input.send(.armTool(.length))
        input.send(.pointerMoved(p(0, 0)))
        input.send(.placePointAtCursor)
        #expect(presenter.placedPoints.count == 1)
        #expect(input.lastEffects.contains(.placePoint(p(0, 0))))
    }
}
