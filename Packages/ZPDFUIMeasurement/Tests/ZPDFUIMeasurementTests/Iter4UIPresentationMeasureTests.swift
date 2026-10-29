import Foundation
import SwiftUI
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIMeasurement

/// Quality-loop iteration 4, area "ui-presentation-measure": the one Shift rule — angle indicator,
/// rubber band, snap glyph and click (U-073) — and the one Scale Region resolution order (U-075).
/// Nothing here reaches a screen.
@MainActor
@Suite("Iteration 4 ui-presentation-measure (angle indicator, region order)")
struct Iter4UIPresentationMeasureTests {

    private static func p(_ x: Double, _ y: Double) -> PDFPointValue { PDFPointValue(x: x, y: y) }

    private func indicator(_ machine: MeasurementInputStateMachine) -> Double? {
        MeasurementInputStateMachine.constraintIndicatorDegrees(
            kind: machine.state.kind,
            placedPoints: machine.state.vertices,
            cursor: machine.state.rawCursor,
            incrementDegrees: machine.configuration.angleIncrementDegrees
        )
    }

    // MARK: - U-073

    /// Old output: the package's tested rule (`MeasurementInputState.constraintAngleDegrees`)
    /// read 45.0 here while `effectivePoint` held the third corner square to the edge — the
    /// canvas's private copy said `nil`. The rule now lives once, in the package.
    @Test("U-073: the rectangle's depth point shows no rose angle, the point is held square")
    func rectangleDepthStepHasNoRoseAngle() {
        var machine = MeasurementInputStateMachine(configuration: .standard)
        machine.handle(.armTool(.rectangleArea))
        machine.handle(.placePoint(Self.p(0, 0)))
        machine.handle(.placePoint(Self.p(100, 0)))
        machine.handle(.setModifiers(.shift))
        machine.handle(.pointerMoved(Self.p(150, 50)))
        #expect(indicator(machine) == nil, "old output: 45.0")
        // Hand-derived: the perpendicular at (100, 0) of an edge along +x is x = 100, and the
        // cursor's depth along it is 50.
        #expect(machine.effectivePoint == Self.p(100, 50))
    }

    @Test("U-073: the rectangle's first edge still reads the rose angle; a count reads none")
    func roseAngleWhereItApplies() {
        var rectangle = MeasurementInputStateMachine(configuration: .standard)
        rectangle.handle(.armTool(.rectangleArea))
        rectangle.handle(.placePoint(Self.p(0, 0)))
        rectangle.handle(.setModifiers(.shift))
        rectangle.handle(.pointerMoved(Self.p(90, 100)))
        #expect(indicator(rectangle) == 45.0)

        #expect(MeasurementInputStateMachine.constraintIndicatorDegrees(
            kind: .count, placedPoints: [Self.p(0, 0)], cursor: Self.p(10, 10), incrementDegrees: 45
        ) == nil)
        #expect(MeasurementInputStateMachine.constraintIndicatorDegrees(
            kind: .length, placedPoints: [], cursor: Self.p(10, 10), incrementDegrees: 45
        ) == nil, "no anchor before the first point")
        #expect(MeasurementInputStateMachine.constraintIndicatorDegrees(
            kind: nil, placedPoints: [Self.p(0, 0)], cursor: Self.p(10, 10), incrementDegrees: 45
        ) == nil)
    }

    // MARK: - U-073 re-fix: the snap glyph and the rubber band read the click's rule

    private static let snapPage = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!

    private static func snap(_ point: PDFPointValue) -> SnapFeedbackSnapshot {
        SnapFeedbackSnapshot(kind: .endpoint, pagePoint: point, sourceLabel: "wall", pageID: snapPage)
    }

    private static func polar(_ origin: PDFPointValue, _ length: Double, _ degrees: Double) -> PDFPointValue {
        let radians = degrees * .pi / 180
        return p(origin.x + length * cos(radians), origin.y + length * sin(radians))
    }

    private static func near(_ a: PDFPointValue?, _ b: PDFPointValue, _ tolerance: Double = 1e-9) -> Bool {
        guard let a else { return false }
        return abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
    }

    /// The one Shift rule, asked the way the canvas asks it for its glyph and rubber band.
    private func shiftPlacement(
        _ machine: MeasurementInputStateMachine,
        optionHeld: Bool = false
    ) -> ShiftConstrainedPlacement? {
        MeasurementInputStateMachine.shiftConstrainedPlacement(
            kind: machine.state.kind,
            placedPoints: machine.state.vertices,
            cursor: machine.state.rawCursor,
            snap: machine.state.activeSnapCandidate?.pagePoint,
            optionHeld: optionHeld,
            incrementDegrees: machine.configuration.angleIncrementDegrees,
            rayTolerance: machine.configuration.constrainedRayTolerance
        )
    }

    /// The pre-fix canvas glyph filter (`PDFCanvasViewController.displayedSnapPoint`, iteration 4
    /// first pass): the candidate projected onto the rose ray from the last point, whatever the step.
    private func oldCanvasGlyph(_ machine: MeasurementInputStateMachine) -> PDFPointValue? {
        let anchor = machine.state.vertices.last!
        return MeasurementInputStateMachine.projectOntoConstrainedRay(
            machine.state.activeSnapCandidate!.pagePoint,
            anchor: anchor,
            rayPoint: MeasurementInputStateMachine.constrain(
                machine.state.rawCursor, to: anchor, incrementDegrees: machine.configuration.angleIncrementDegrees
            ),
            tolerance: machine.configuration.constrainedRayTolerance
        )
    }

    private static func placedPoints(_ effects: [MeasurementInputEffect]) -> [PDFPointValue] {
        effects.compactMap { if case let .placePoint(point) = $0 { return point } else { return nil } }
    }

    /// First edge (0, 0) → 100 pt at 30°, so the perpendicular at its end runs at 120° and the rose
    /// rays from there at 90° and 135°. The candidate sits 40 pt up the perpendicular and 5 pt
    /// along the edge: 112.9° from the edge end, about 15 pt from either rose ray (tolerance 6).
    ///
    /// Old output: the canvas glyph was `nil` (hidden) while the click snapped to the candidate's
    /// foot on the perpendicular.
    @Test("U-073: rectangle depth step at 30°, Shift, a snap off every rose ray: the glyph is the click")
    func depthStepGlyphIsTheClick() {
        var machine = MeasurementInputStateMachine(configuration: .standard)
        machine.handle(.armTool(.rectangleArea))
        let start = Self.p(0, 0)
        let end = Self.polar(start, 100, 30)
        machine.handle(.placePoint(start))
        machine.handle(.placePoint(end))
        machine.handle(.setModifiers(.shift))
        let candidate = Self.polar(Self.polar(end, 40, 120), 5, 30)
        machine.handle(.setSnapCandidates([Self.snap(candidate)]))
        machine.handle(.pointerMoved(Self.p(candidate.x + 2, candidate.y - 1)))

        #expect(oldCanvasGlyph(machine) == nil, "the old filter hid this glyph")
        let held = shiftPlacement(machine)
        #expect(held?.snap != nil, "old output: nil")
        #expect(held?.snap == machine.effectivePoint, "the glyph is where the click lands")
        // Hand-derived: the candidate's foot on the perpendicular is 40 pt up it from the edge end.
        #expect(Self.near(machine.effectivePoint, Self.polar(end, 40, 120), 1e-9), "\(machine.effectivePoint)")
        #expect(held?.roseDegrees == nil, "no rose angle on the depth step")
        // The rubber band is held to the same perpendicular: no component along the edge.
        let band = held!.cursor
        let alongEdge = (band.x - end.x) * cos(Double.pi / 6) + (band.y - end.y) * sin(Double.pi / 6)
        #expect(abs(alongEdge) < 1e-9, "band \(band)")

        let effects = machine.handle(.placePointAtCursor)
        #expect(Self.placedPoints(effects).first == held?.snap, "\(effects)")
    }

    /// Area with two vertices and `⌥` held is the same depth step: the `⌥`-click holds the depth
    /// square to the edge under Shift, and the canvas asks the rule with `optionHeld`.
    ///
    /// Old output: the canvas treated it as a rose step — glyph hidden, rubber band on the 90° ray,
    /// "90.0°" in the pill — while the `⌥`-click placed the depth on the perpendicular.
    @Test("U-073: Area's ⌥ rectangle reads the same depth-step rule as its ⌥-click")
    func optionRectangleDepthIsTheClick() {
        var machine = MeasurementInputStateMachine(configuration: .standard)
        machine.handle(.armTool(.area))
        let start = Self.p(0, 0)
        let end = Self.polar(start, 100, 30)
        machine.handle(.placePoint(start))
        machine.handle(.placePoint(end))
        machine.handle(.setModifiers(.shift))
        let candidate = Self.polar(Self.polar(end, 40, 120), 5, 30)
        machine.handle(.setSnapCandidates([Self.snap(candidate)]))
        machine.handle(.pointerMoved(Self.p(candidate.x + 2, candidate.y - 1)))

        let withOption = shiftPlacement(machine, optionHeld: true)
        #expect(withOption?.snap != nil)
        #expect(Self.near(withOption?.snap, Self.polar(end, 40, 120), 1e-9))
        #expect(withOption?.roseDegrees == nil)
        #expect(MeasurementInputStateMachine.constraintIndicatorDegrees(
            kind: .area, placedPoints: machine.state.vertices, cursor: machine.state.rawCursor,
            optionHeld: true, incrementDegrees: 45
        ) == nil)
        // Without ⌥ the next click continues the polygon, held to the rose.
        let withoutOption = shiftPlacement(machine)
        #expect(withoutOption?.snap == nil, "the candidate is off the 90° ray and ignored")
        #expect(withoutOption?.roseDegrees == 90)
        #expect(withoutOption?.point == machine.effectivePoint)

        let effects = machine.handle(.placeRectangleDepthAtCursor)
        let placed = Self.placedPoints(effects)
        #expect(placed.first == withOption?.snap, "\(effects)")
        #expect(placed.count == 2, "the depth point and the derived fourth corner")
    }

    /// On a rose step the glyph is the candidate's distance along the ray, or hidden when the
    /// candidate is off it — and either way the click lands on the held point.
    @Test("U-073: on a rose step the glyph and the click agree, on and off the ray")
    func roseStepGlyphIsTheClick() {
        var machine = MeasurementInputStateMachine(configuration: .standard)
        machine.handle(.armTool(.length))
        machine.handle(.placePoint(Self.p(0, 0)))
        machine.handle(.setModifiers(.shift))
        machine.handle(.pointerMoved(Self.p(70, 10)))

        machine.handle(.setSnapCandidates([Self.snap(Self.p(80, 3))]))
        let onRay = shiftPlacement(machine)
        #expect(onRay?.snap == Self.p(80, 0))
        #expect(onRay?.snap == machine.effectivePoint)
        #expect(onRay?.roseDegrees == 0)

        machine.handle(.setSnapCandidates([Self.snap(Self.p(80, 30))]))
        let offRay = shiftPlacement(machine)
        #expect(offRay?.snap == nil)
        #expect(offRay?.cursor == machine.effectivePoint)
        #expect(Self.near(offRay?.cursor, Self.p((70.0 * 70 + 10 * 10).squareRoot(), 0)))
    }

    /// Old output: the canvas's rubber band stayed on the raw pointer (190, 400) on a Rectangle
    /// Area's first edge while the click and the pill held it to the 45° ray.
    @Test("U-073: the Rectangle Area's first edge is held to the rose, band and click alike; a count never")
    func rectangleFirstEdgeIsHeld() {
        var machine = MeasurementInputStateMachine(configuration: .standard)
        machine.handle(.armTool(.rectangleArea))
        machine.handle(.placePoint(Self.p(100, 300)))
        machine.handle(.setModifiers(.shift))
        machine.handle(.pointerMoved(Self.p(190, 400)))
        let held = shiftPlacement(machine)
        #expect(held?.cursor == machine.effectivePoint)
        #expect(held?.roseDegrees == 45)
        #expect(Self.near(held?.cursor, Self.p(195.13148795220224, 395.13148795220224), 1e-9), "\(String(describing: held))")

        #expect(MeasurementInputStateMachine.shiftConstrainedPlacement(
            kind: .count, placedPoints: [Self.p(0, 0)], cursor: Self.p(10, 20), snap: Self.p(11, 21),
            incrementDegrees: 45, rayTolerance: 6
        ) == nil, "BH-256: a count mark is never held")
        #expect(MeasurementInputStateMachine.shiftConstrainedPlacement(
            kind: .length, placedPoints: [], cursor: Self.p(10, 20), snap: nil,
            incrementDegrees: 45, rayTolerance: 6
        ) == nil, "nothing placed, nothing to hold to")
    }

    // MARK: - U-075

    private static let pageID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!

    private static func region(_ name: String, priority: Int) -> ScaleRegionSummary {
        ScaleRegionSummary(
            id: UUID(),
            name: name,
            pageID: pageID,
            pageLabel: "A-101",
            scale: ScaleSummary(
                id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
                name: "Plan 1:50",
                displayString: "1:50",
                isUniform: true,
                sx: 0.0176,
                sy: 0.0176,
                unit: .metre,
                version: 1,
                locked: false
            ),
            boundary: [Self.p(0, 0), Self.p(100, 0), Self.p(100, 100)],
            priority: priority,
            locked: false,
            colorRGBA: ColorRGBA.Zenit.Dark.cyan
        )
    }

    /// Before the fix the panel's rows came from `ScaleRegionsPanel.ordered` and Raise/Lower
    /// found its index in `ScaleRegionsPanelModel.ordered` — two copies of one comparator.
    @Test("U-075: Raise moves the region on the row that was clicked, ties included")
    func rowsAndMovesShareOneOrder() {
        let high = Self.region("High", priority: 3)
        let tieB = Self.region("B", priority: 1)
        let tieA = Self.region("A", priority: 1)
        let model = ScaleRegionsPanelModel(regions: [tieB, high, tieA])
        var written: [UUID] = []
        model.onReorderRegions = { written = $0 }

        // The rows the panel draws, read from the panel: the host hands it `model.regions`
        // unsorted (ScaleRegionsPanelHost).
        func panelRows() -> [ScaleRegionSummary] {
            ScaleRegionsPanel(regions: model.regions, pageDefaultScale: nil, selection: .constant(nil)).rows
        }
        let rows = panelRows()
        #expect(rows.map(\.name) == ["High", "A", "B"])
        #expect(model.ordered.map(\.id) == rows.map(\.id))

        // Raise the last row ("B"): it swaps with the row above it ("A"), not with anything else.
        #expect(model.movePriority(regionID: rows[2].id, by: -1))
        #expect(written == [high.id, tieB.id, tieA.id])
        #expect(panelRows().map(\.name) == ["High", "B", "A"])
        #expect(model.ordered.map(\.id) == panelRows().map(\.id))
    }

    /// The comparator alone. The document's per-page list (`DocumentPresenting.scaleRegions(onPage:)`,
    /// the Inspector's popup) is tested through a presenter in ZPDFUIPresentationTests,
    /// `Iter4ScaleRegionOrderTests.documentListBreaksTiesByName`.
    @Test("U-075: the shared comparator breaks a priority tie by name whatever the input order")
    func comparatorBreaksTiesByName() {
        let regions = [Self.region("Zeta", priority: 1), Self.region("Alpha", priority: 1), Self.region("Top", priority: 5)]
        #expect(ScaleRegionSummary.inResolutionOrder(regions).map(\.name) == ["Top", "Alpha", "Zeta"])
        #expect(ScaleRegionSummary.inResolutionOrder(regions.reversed()).map(\.name) == ["Top", "Alpha", "Zeta"])
    }
}
