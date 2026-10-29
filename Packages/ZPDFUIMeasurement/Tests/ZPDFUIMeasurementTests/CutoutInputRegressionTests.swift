import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIMeasurement

/// The cutout path through the input flow, which had no test of any kind before this file.
///
/// `MeasurementInputStateMachineTests` is 995 lines and covers arming, clicks, drags, Escape,
/// Backspace, snapping and the angle constraint — and mentions the word "cutout" exactly zero
/// times, as does every other suite in this package. A cutout is the one tool whose commit
/// changes *another markup's* number, so an untested parent resolution is an untested change to
/// a quantity somebody has already read. Finding CR-201.
@Suite("Cutout parent resolution and the input flow")
struct CutoutInputRegressionTests {

    // MARK: - Fixtures

    private static func square(
        x: Double,
        y: Double,
        side: Double
    ) -> [PDFPointValue] {
        [
            PDFPointValue(x: x, y: y),
            PDFPointValue(x: x + side, y: y),
            PDFPointValue(x: x + side, y: y + side),
            PDFPointValue(x: x, y: y + side)
        ]
    }

    private static func candidate(
        _ id: UUID,
        x: Double = 0,
        y: Double = 0,
        side: Double,
        name: String = ""
    ) -> CutoutParentCandidate {
        CutoutParentCandidate(
            markupID: id,
            outerRing: square(x: x, y: y, side: side),
            subject: name
        )
    }

    private static func resolvedID(
        _ resolution: CutoutParentResolution
    ) -> UUID? {
        if case let .resolved(parent) = resolution { return parent.markupID }
        return nil
    }

    // MARK: - CR-199: the tie-break

    /// Old output: the resolution followed the order the candidates arrived in — `low` for one
    /// ordering and `high` for the reverse — because `min(by:)` keeps the first of two equal
    /// elements and the canvas publishes the candidates in no promised order. Two
    /// identical slabs under one click, or a duplicated area left where it was, therefore had
    /// the hole subtracted from whichever the provider happened to list first, and the answer
    /// could differ between two runs over the same drawing.
    @Test("Two equally sized parents resolve to the same one whatever order they arrive in")
    func equalAreaTieBreakIsDeterministic() {
        let low = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let high = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
        let point = PDFPointValue(x: 50, y: 50)

        let forwards = CutoutParentResolver.resolve(
            firstPoint: point,
            candidates: [Self.candidate(low, side: 100), Self.candidate(high, side: 100)]
        )
        let backwards = CutoutParentResolver.resolve(
            firstPoint: point,
            candidates: [Self.candidate(high, side: 100), Self.candidate(low, side: 100)]
        )

        #expect(Self.resolvedID(forwards) == Self.resolvedID(backwards))
        #expect(Self.resolvedID(forwards) == low, "the tie must be broken by identity, not by arrival order")
    }

    /// The rule the tie-break sits under is unchanged: the smallest containing area wins.
    @Test("The smallest containing area still wins, whatever order they arrive in")
    func smallestAreaWins() {
        let building = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
        let slab = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        let point = PDFPointValue(x: 20, y: 20)

        // The slab has the later identity, so a tie-break by id alone would pick the building.
        for order in [[building, slab], [slab, building]] {
            let candidates = order.map { id in
                id == building
                    ? Self.candidate(building, side: 500)
                    : Self.candidate(slab, side: 40)
            }
            let resolution = CutoutParentResolver.resolve(firstPoint: point, candidates: candidates)
            #expect(Self.resolvedID(resolution) == slab)
        }
    }

    @Test("A point inside nothing is refused, and a degenerate ring hosts nothing")
    func refusals() {
        let point = PDFPointValue(x: 500, y: 500)
        #expect(
            CutoutParentResolver.resolve(
                firstPoint: point,
                candidates: [Self.candidate(UUID(), side: 100)]
            ) == .refused(.noAreaUnderPoint)
        )
        #expect(
            CutoutParentResolver.resolve(firstPoint: point, candidates: []) == .refused(.noAreaUnderPoint)
        )

        let degenerate = CutoutParentCandidate(
            markupID: UUID(),
            outerRing: [PDFPointValue(x: 0, y: 0), PDFPointValue(x: 10, y: 0)]
        )
        #expect(
            CutoutParentResolver.resolve(
                firstPoint: PDFPointValue(x: 5, y: 0),
                candidates: [degenerate]
            ) == .refused(.noAreaUnderPoint)
        )
    }

    /// The edge is inside, because an estimator who snaps the first cutout vertex onto the
    /// parent's own wall line must not be told they are outside it.
    @Test("A point on the parent's own edge counts as inside")
    func edgeIsInclusive() {
        let ring = Self.square(x: 0, y: 0, side: 100)
        #expect(CutoutParentResolver.ring(ring, contains: PDFPointValue(x: 0, y: 50)))
        #expect(CutoutParentResolver.ring(ring, contains: PDFPointValue(x: 100, y: 100)))
        #expect(CutoutParentResolver.ring(ring, contains: PDFPointValue(x: 50, y: 50)))
        #expect(!CutoutParentResolver.ring(ring, contains: PDFPointValue(x: 100.5, y: 50)))
    }

    /// X-cutout-ui. Old output: the vertex at (300, 10) was refused with "This point is outside
    /// Slab. Every cutout corner must stay inside the area it subtracts from." — a containment rule
    /// of the interface's own. The engine accepts a cutout that only partly overlaps its area and
    /// subtracts the part inside, so the vertex is placed and the parent stays the one the first
    /// vertex chose.
    @MainActor
    @Test("A later vertex may leave the parent the first one chose")
    func laterVerticesMayLeaveTheParent() {
        let parent = Self.candidate(UUID(), side: 100, name: "Slab")
        var machine = Self.cutoutMachine(parents: [parent])
        machine.handle(.placePoint(PDFPointValue(x: 10, y: 10)))
        let effects = machine.handle(.placePoint(PDFPointValue(x: 300, y: 10)))
        #expect(effects.contains(.placePoint(PDFPointValue(x: 300, y: 10))))
        #expect(!effects.contains { if case .rejectFinish = $0 { return true } else { return false } })
        #expect(machine.state.cutoutRefusal == nil)
        #expect(machine.state.cutoutParent?.markupID == parent.markupID)
    }

    // MARK: - CR-198: Backspace and the parent it leaves behind

    private static func cutoutMachine(
        parents: [CutoutParentCandidate]
    ) -> MeasurementInputStateMachine {
        var machine = MeasurementInputStateMachine()
        machine.handle(.armTool(.polygonCutout))
        machine.handle(.setCutoutParents(parents))
        return machine
    }

    /// Old output: `.refused` — specifically `.vertexOutsideParent(parentName: "A")`, because
    /// `state.cutoutParent` was still holding A after the Backspace, so the click inside B never
    /// went near `resolve` at all. Where A and B overlap the same leak did the quieter version
    /// of the same thing: the hole was subtracted from A.
    @MainActor
    @Test("Backspacing the first cutout vertex lets the next click choose a new parent")
    func backspaceReleasesTheCutoutParent() {
        let a = Self.candidate(UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!, x: 0, y: 0, side: 100, name: "A")
        let b = Self.candidate(UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!, x: 300, y: 0, side: 100, name: "B")
        var machine = Self.cutoutMachine(parents: [a, b])

        machine.handle(.placePoint(PDFPointValue(x: 10, y: 10)))
        #expect(machine.state.cutoutParent?.markupID == a.markupID)

        machine.handle(.removeLastVertex)
        #expect(machine.state.vertices.isEmpty)
        #expect(machine.state.phase == .armed)
        #expect(machine.state.cutoutParent == nil, "the abandoned parent is still holding the tool")
        #expect(machine.state.cutoutRefusal == nil)

        let effects = machine.handle(.placePoint(PDFPointValue(x: 310, y: 10)))
        #expect(machine.state.cutoutParent?.markupID == b.markupID)
        #expect(!effects.contains { if case .rejectFinish = $0 { return true } else { return false } })
    }

    /// The half that must not change: a Backspace that leaves the first vertex standing leaves
    /// the parent standing with it. A cutout belongs to the area it started in.
    @MainActor
    @Test("Backspacing a later vertex does not re-open the parent question")
    func backspaceKeepsTheParentWhileTheFirstVertexStands() {
        let a = Self.candidate(UUID(), x: 0, y: 0, side: 100, name: "A")
        var machine = Self.cutoutMachine(parents: [a])

        machine.handle(.placePoint(PDFPointValue(x: 10, y: 10)))
        machine.handle(.placePoint(PDFPointValue(x: 20, y: 10)))
        machine.handle(.removeLastVertex)

        #expect(machine.state.vertices.count == 1)
        #expect(machine.state.cutoutParent?.markupID == a.markupID)
    }

    /// A refused click leaves a refusal on the state; taking the geometry away has to take the
    /// refusal with it, or the panel keeps explaining a click nobody made any more. The refusal
    /// standing over a placed point is an Ellipse Cutout's second corner whose box centre lies
    /// in no area (a polygon cutout's later vertex is no longer refused, X-cutout-ui).
    @MainActor
    @Test("Backspacing back to nothing clears a standing refusal")
    func backspaceClearsTheRefusal() {
        let a = Self.candidate(UUID(), x: 0, y: 0, side: 100, name: "A")
        var machine = MeasurementInputStateMachine()
        machine.handle(.armTool(.ellipseCutout))
        machine.handle(.setCutoutParents([a]))

        machine.handle(.placePoint(PDFPointValue(x: 10, y: 10)))
        machine.handle(.placePoint(PDFPointValue(x: 900, y: 900)))
        #expect(machine.state.cutoutRefusal != nil, "the fixture is meant to leave a refusal standing")

        machine.handle(.removeLastVertex)
        #expect(machine.state.vertices.isEmpty)
        #expect(machine.state.cutoutRefusal == nil)
        #expect(machine.state.cutoutParent == nil)
    }

    /// Old output: `isClickPlacingDragTool` stayed `true` after the vertex it was set for was
    /// taken away, so the tool sat in click-by-click mode with no corner placed and the next
    /// press-drag-release was read as two clicks instead of one drag.
    @MainActor
    @Test("Backspacing the anchor takes the three-point rectangle out of click mode")
    func backspaceClearsClickPlacingMode() {
        var machine = MeasurementInputStateMachine()
        machine.handle(.armTool(.rectangleArea))
        let anchor = PDFPointValue(x: 10, y: 10)
        machine.handle(.dragBegan(anchor))
        machine.handle(.dragEnded(anchor))
        #expect(machine.state.isClickPlacingDragTool, "the fixture is meant to enter click mode")

        machine.handle(.removeLastVertex)
        #expect(machine.state.vertices.isEmpty)
        #expect(!machine.state.isClickPlacingDragTool)
    }

    /// ⌥-clicking the last count point away is the same road back to armed.
    @MainActor
    @Test("Removing the last count point leaves no per-shape state behind")
    func removingTheLastCountPointResets() {
        var machine = MeasurementInputStateMachine()
        machine.handle(.armTool(.count))
        let point = PDFPointValue(x: 10, y: 10)
        machine.handle(.placePoint(point))
        #expect(machine.state.phase == .drawing)

        machine.handle(.removePoint(near: point))
        #expect(machine.state.vertices.isEmpty)
        #expect(machine.state.phase == .armed)
        #expect(!machine.state.isClickPlacingDragTool)
        #expect(machine.state.cutoutParent == nil)
    }
}
