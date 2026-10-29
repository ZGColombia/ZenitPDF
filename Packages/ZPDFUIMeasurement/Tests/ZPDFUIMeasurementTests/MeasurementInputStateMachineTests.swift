import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIMeasurement

/// Covers the keyboard drawing contract without a view layer.
@Suite("Measurement input state machine")
struct MeasurementInputStateMachineTests {

    private static let pageID = UUID(uuidString: "00000000-0000-0000-0000-00000000FEED") ?? UUID()

    private func makeMachine(reusesTool: Bool = true) -> MeasurementInputStateMachine {
        MeasurementInputStateMachine(
            configuration: MeasurementInputConfiguration(
                angleIncrementDegrees: 15,
                reusesToolAfterCommit: reusesTool,
                initialCursor: PDFPointValue(x: 100, y: 100)
            )
        )
    }

    private func candidate(
        _ kind: SnapCandidateKind,
        at point: PDFPointValue,
        label: String = "wall"
    ) -> SnapFeedbackSnapshot {
        SnapFeedbackSnapshot(
            kind: kind,
            pagePoint: point,
            sourceLabel: label,
            pageID: Self.pageID
        )
    }

    // MARK: Arming

    @Test("Starts idle and arms a tool")
    func armsATool() {
        var machine = makeMachine()
        #expect(machine.state.phase == .idle)

        let effects = machine.handle(.armTool(.polylength))
        #expect(machine.state.phase == .armed)
        #expect(machine.state.kind == .polylength)
        #expect(effects.contains(.activateTool(.polylength)))
    }

    @Test("Re-arming the same tool clears the geometry")
    func rearmingClearsGeometry() {
        var machine = makeMachine()
        machine.handle(.armTool(.area))
        machine.handle(.placePoint(PDFPointValue(x: 10, y: 10)))
        machine.handle(.placePoint(PDFPointValue(x: 20, y: 10)))
        #expect(machine.state.vertices.count == 2)

        machine.handle(.armTool(.area))
        #expect(machine.state.vertices.isEmpty)
        #expect(machine.state.phase == .armed)
    }

    @Test("Placing a point while idle does nothing")
    func placingWhileIdleIsIgnored() {
        var machine = makeMachine()
        let effects = machine.handle(.placePoint(PDFPointValue(x: 1, y: 1)))
        #expect(effects.isEmpty)
        #expect(machine.state.vertices.isEmpty)
    }

    // MARK: Vertices

    @Test("Placing a point moves the flow to drawing")
    func placingMovesToDrawing() {
        var machine = makeMachine()
        machine.handle(.armTool(.length))
        let effects = machine.handle(.placePoint(PDFPointValue(x: 10, y: 10)))
        #expect(machine.state.phase == .drawing)
        #expect(machine.state.vertices.count == 1)
        #expect(effects.contains(.placePoint(PDFPointValue(x: 10, y: 10))))
    }

    @Test("Backspace removes the last vertex and returns to armed when empty")
    func backspaceRemovesVertex() {
        var machine = makeMachine()
        machine.handle(.armTool(.length))
        machine.handle(.placePoint(PDFPointValue(x: 10, y: 10)))

        let effects = machine.handle(.removeLastVertex)
        #expect(effects.contains(.removeLastPoint))
        #expect(machine.state.vertices.isEmpty)
        #expect(machine.state.phase == .armed)
    }

    @Test("Backspace with nothing placed only announces")
    func backspaceWithNothingPlaced() {
        var machine = makeMachine()
        machine.handle(.armTool(.length))
        let effects = machine.handle(.removeLastVertex)
        #expect(!effects.contains(.removeLastPoint))
        #expect(effects.count == 1)
    }

    // MARK: Finish

    @Test("Return is refused before the minimum point count, and keeps the geometry")
    func returnIsRefusedEarly() {
        var machine = makeMachine()
        machine.handle(.armTool(.area))
        machine.handle(.placePoint(PDFPointValue(x: 0, y: 0)))
        machine.handle(.placePoint(PDFPointValue(x: 10, y: 0)))
        #expect(!machine.state.canFinish)

        let effects = machine.handle(.finish)
        #expect(!effects.contains(.commitMeasurement))
        #expect(effects.contains { if case .rejectFinish = $0 { return true } else { return false } })
        #expect(machine.state.vertices.count == 2)
    }

    @Test("Return commits and keeps the tool armed when reuse is on")
    func returnCommitsAndReuses() {
        var machine = makeMachine(reusesTool: true)
        machine.handle(.armTool(.area))
        machine.handle(.placePoint(PDFPointValue(x: 0, y: 0)))
        machine.handle(.placePoint(PDFPointValue(x: 10, y: 0)))
        machine.handle(.placePoint(PDFPointValue(x: 10, y: 10)))
        #expect(machine.state.canFinish)

        let effects = machine.handle(.finish)
        #expect(effects.contains(.commitMeasurement))
        #expect(!effects.contains(.deactivateTool))
        #expect(machine.state.phase == .armed)
        #expect(machine.state.kind == .area)
        #expect(machine.state.vertices.isEmpty)
    }

    @Test("Return disarms the tool when reuse is off")
    func returnDisarmsWhenReuseOff() {
        var machine = makeMachine(reusesTool: false)
        machine.handle(.armTool(.polylength))
        machine.handle(.placePoint(PDFPointValue(x: 0, y: 0)))
        machine.handle(.placePoint(PDFPointValue(x: 10, y: 0)))

        let effects = machine.handle(.finish)
        #expect(effects.contains(.commitMeasurement))
        #expect(effects.contains(.deactivateTool))
        #expect(machine.state.phase == .idle)
        #expect(machine.state.kind == nil)
    }

    // MARK: Two-click length

    @Test("Two clicks yield a finished length, no Return, no third click")
    func twoClicksFinishALength() {
        var machine = makeMachine(reusesTool: true)
        machine.handle(.armTool(.length))
        machine.handle(.placePoint(PDFPointValue(x: 0, y: 0)))
        #expect(machine.state.phase == .drawing)

        let effects = machine.handle(.placePoint(PDFPointValue(x: 120, y: 0)))
        #expect(effects.contains(.placePoint(PDFPointValue(x: 120, y: 0))))
        #expect(effects.contains(.commitMeasurement))
        #expect(machine.state.vertices.isEmpty)
    }

    @Test("A finished length keeps the tool armed when Reuse is on")
    func finishedLengthReusesTool() {
        var machine = makeMachine(reusesTool: true)
        machine.handle(.armTool(.length))
        machine.handle(.placePoint(PDFPointValue(x: 0, y: 0)))
        let effects = machine.handle(.placePoint(PDFPointValue(x: 50, y: 50)))
        #expect(!effects.contains(.deactivateTool))
        #expect(machine.state.phase == .armed)
        #expect(machine.state.kind == .length)
    }

    @Test("A finished length returns to Select when Reuse is off")
    func finishedLengthReturnsToSelect() {
        var machine = makeMachine(reusesTool: false)
        machine.handle(.armTool(.length))
        machine.handle(.placePoint(PDFPointValue(x: 0, y: 0)))
        let effects = machine.handle(.placePoint(PDFPointValue(x: 50, y: 50)))
        #expect(effects.contains(.commitMeasurement))
        #expect(effects.contains(.deactivateTool))
        #expect(machine.state.phase == .idle)
        #expect(machine.state.kind == nil)
    }

    @Test("A Shift-constrained second click both constrains and finishes")
    func shiftConstrainedSecondClickFinishes() {
        var machine = makeMachine()
        machine.handle(.armTool(.length))
        machine.handle(.placePoint(PDFPointValue(x: 0, y: 0)))
        machine.handle(.setModifiers(.shift))
        let radians = 20.0 * .pi / 180
        machine.handle(.pointerMoved(PDFPointValue(x: cos(radians) * 100, y: sin(radians) * 100)))

        let effects = machine.handle(.placePointAtCursor)
        #expect(effects.contains(.commitMeasurement))
        guard case let .placePoint(placed)? = effects.first else {
            Issue.record("Expected the constrained point to be placed")
            return
        }
        let angle = atan2(placed.y, placed.x) * 180 / .pi
        #expect(abs(angle - 15) < 1e-6)
    }

    @Test("Escape cancels an in-progress length and keeps the tool armed")
    func escapeCancelsInProgressLength() {
        var machine = makeMachine()
        machine.handle(.armTool(.length))
        machine.handle(.placePoint(PDFPointValue(x: 5, y: 5)))

        let effects = machine.handle(.cancel)
        #expect(effects.contains(.cancelMeasurement))
        #expect(!effects.contains(.commitMeasurement))
        #expect(machine.state.phase == .armed)
        #expect(machine.state.vertices.isEmpty)
    }

    @Test("The third click finishes a three-point tool")
    func thirdClickFinishesAngle() {
        var machine = makeMachine()
        machine.handle(.armTool(.angle))
        machine.handle(.placePoint(PDFPointValue(x: 0, y: 0)))
        machine.handle(.placePoint(PDFPointValue(x: 10, y: 0)))
        let effects = machine.handle(.placePoint(PDFPointValue(x: 10, y: 10)))
        #expect(effects.contains(.commitMeasurement))
        #expect(machine.state.phase == .armed)
    }

    // MARK: Rectangle drag

    @Test("Drag yields a finished rectangle: press, drag, release, one gesture")
    func dragYieldsAFinishedRectangle() {
        var machine = makeMachine(reusesTool: true)
        machine.handle(.armTool(.rectangleArea))

        let began = machine.handle(.dragBegan(PDFPointValue(x: 10, y: 10)))
        #expect(began.contains(.placePoint(PDFPointValue(x: 10, y: 10))))
        #expect(machine.state.phase == .drawing)

        machine.handle(.dragMoved(PDFPointValue(x: 60, y: 40)))
        #expect(machine.state.rawCursor == PDFPointValue(x: 60, y: 40))

        let ended = machine.handle(.dragEnded(PDFPointValue(x: 110, y: 80)))
        #expect(ended.contains(.placePoint(PDFPointValue(x: 110, y: 80))))
        #expect(ended.contains(.commitMeasurement))
        #expect(machine.state.phase == .armed)
        #expect(machine.state.vertices.isEmpty)
    }

    @Test("A rectangle drag disarms on release when Reuse is off")
    func rectangleDragRespectsReuseOff() {
        var machine = makeMachine(reusesTool: false)
        machine.handle(.armTool(.rectangleArea))
        machine.handle(.dragBegan(PDFPointValue(x: 0, y: 0)))
        let ended = machine.handle(.dragEnded(PDFPointValue(x: 100, y: 50)))
        #expect(ended.contains(.commitMeasurement))
        #expect(ended.contains(.deactivateTool))
        #expect(machine.state.phase == .idle)
    }

    @Test("A drag released without moving cancels instead of committing a zero ellipse")
    func degenerateDragCancels() {
        // The ellipse is a pure drag tool; the rectangle now treats the same gesture as its
        // first click, covered separately below.
        var machine = makeMachine()
        machine.handle(.armTool(.ellipseArea))
        machine.handle(.dragBegan(PDFPointValue(x: 25, y: 25)))

        let ended = machine.handle(.dragEnded(PDFPointValue(x: 25, y: 25)))
        #expect(ended.contains(.cancelMeasurement))
        #expect(!ended.contains(.commitMeasurement))
        #expect(machine.state.phase == .armed)
        #expect(machine.state.vertices.isEmpty)
    }

    @Test("Drag events do not place vertices for a click tool")
    func dragIgnoredForClickTool() {
        var machine = makeMachine()
        machine.handle(.armTool(.length))
        machine.handle(.dragBegan(PDFPointValue(x: 10, y: 10)))
        #expect(machine.state.vertices.isEmpty)
        #expect(machine.state.rawCursor == PDFPointValue(x: 10, y: 10))
        #expect(machine.handle(.dragEnded(PDFPointValue(x: 20, y: 20))).isEmpty)
    }

    @Test("Escape cancels a rectangle mid-drag")
    func escapeCancelsMidDrag() {
        var machine = makeMachine()
        machine.handle(.armTool(.rectangleArea))
        machine.handle(.dragBegan(PDFPointValue(x: 0, y: 0)))
        machine.handle(.dragMoved(PDFPointValue(x: 40, y: 40)))

        let effects = machine.handle(.cancel)
        #expect(effects.contains(.cancelMeasurement))
        #expect(machine.state.phase == .armed)
        #expect(machine.state.vertices.isEmpty)
    }

    // MARK: Polygon close

    @Test("Clicking the first vertex closes a polygon area")
    func polygonClosesOnFirstVertex() {
        var machine = makeMachine()
        machine.handle(.armTool(.area))
        machine.handle(.placePoint(PDFPointValue(x: 0, y: 0)))
        machine.handle(.placePoint(PDFPointValue(x: 100, y: 0)))
        machine.handle(.placePoint(PDFPointValue(x: 100, y: 100)))
        machine.handle(.pointerMoved(PDFPointValue(x: 2, y: 3)))

        let effects = machine.handle(.placePointAtCursor)
        #expect(effects.contains(.commitMeasurement))
        #expect(!effects.contains { if case .placePoint = $0 { return true } else { return false } })
        #expect(machine.state.phase == .armed)
        #expect(machine.state.vertices.isEmpty)
    }

    @Test("The close affordance appears near the first vertex once the shape is valid")
    func closeAffordanceNearFirstVertex() {
        var machine = makeMachine()
        machine.handle(.armTool(.area))
        machine.handle(.placePoint(PDFPointValue(x: 0, y: 0)))
        machine.handle(.placePoint(PDFPointValue(x: 100, y: 0)))

        // Two vertices: no valid polygon yet, so no affordance even at zero distance.
        machine.handle(.pointerMoved(PDFPointValue(x: 1, y: 1)))
        #expect(machine.state.firstVertexCloseTarget(configuration: machine.configuration) == nil)

        machine.handle(.placePoint(PDFPointValue(x: 100, y: 100)))
        machine.handle(.pointerMoved(PDFPointValue(x: 1, y: 1)))
        let target = machine.state.firstVertexCloseTarget(configuration: machine.configuration)
        #expect(target == PDFPointValue(x: 0, y: 0))
        #expect(machine.effectivePoint == PDFPointValue(x: 0, y: 0))

        // Out of range again: the affordance disappears.
        machine.handle(.pointerMoved(PDFPointValue(x: 50, y: 50)))
        #expect(machine.state.firstVertexCloseTarget(configuration: machine.configuration) == nil)
    }

    @Test("A click near the first vertex before the minimum count places a vertex normally")
    func earlyFirstVertexClickPlacesNormally() {
        var machine = makeMachine()
        machine.handle(.armTool(.area))
        machine.handle(.placePoint(PDFPointValue(x: 0, y: 0)))
        machine.handle(.placePoint(PDFPointValue(x: 100, y: 0)))

        let effects = machine.handle(.placePoint(PDFPointValue(x: 1, y: 1)))
        #expect(effects.contains(.placePoint(PDFPointValue(x: 1, y: 1))))
        #expect(!effects.contains(.commitMeasurement))
        #expect(machine.state.vertices.count == 3)
    }

    @Test("The close affordance never appears for a non-closable tool")
    func noCloseAffordanceForPolylength() {
        var machine = makeMachine()
        machine.handle(.armTool(.polylength))
        machine.handle(.placePoint(PDFPointValue(x: 0, y: 0)))
        machine.handle(.placePoint(PDFPointValue(x: 100, y: 0)))
        machine.handle(.pointerMoved(PDFPointValue(x: 1, y: 1)))
        #expect(machine.state.firstVertexCloseTarget(configuration: machine.configuration) == nil)
    }

    @Test("Double-click closes a polygon and drops the duplicate vertex the pair placed")
    func doubleClickDropsDuplicateAndCloses() {
        var machine = makeMachine()
        machine.handle(.armTool(.area))
        machine.handle(.placePoint(PDFPointValue(x: 0, y: 0)))
        machine.handle(.placePoint(PDFPointValue(x: 100, y: 0)))
        machine.handle(.placePoint(PDFPointValue(x: 100, y: 100)))
        machine.handle(.placePoint(PDFPointValue(x: 0, y: 100)))
        // The first click of the double-click pair placed the same vertex again.
        machine.handle(.placePoint(PDFPointValue(x: 0, y: 100)))
        #expect(machine.state.vertices.count == 5)

        let effects = machine.handle(.doubleClick)
        #expect(effects.contains(.removeLastPoint))
        #expect(effects.contains(.commitMeasurement))
        #expect(machine.state.phase == .armed)
    }

    @Test("Double-click without a duplicate simply finishes")
    func doubleClickWithoutDuplicateFinishes() {
        var machine = makeMachine()
        machine.handle(.armTool(.area))
        machine.handle(.placePoint(PDFPointValue(x: 0, y: 0)))
        machine.handle(.placePoint(PDFPointValue(x: 100, y: 0)))
        machine.handle(.placePoint(PDFPointValue(x: 100, y: 100)))

        let effects = machine.handle(.doubleClick)
        #expect(!effects.contains(.removeLastPoint))
        #expect(effects.contains(.commitMeasurement))
    }

    @Test("Double-click before the minimum count is refused and keeps the geometry")
    func doubleClickTooEarlyIsRefused() {
        var machine = makeMachine()
        machine.handle(.armTool(.area))
        machine.handle(.placePoint(PDFPointValue(x: 0, y: 0)))
        machine.handle(.placePoint(PDFPointValue(x: 100, y: 0)))

        let effects = machine.handle(.doubleClick)
        #expect(!effects.contains(.commitMeasurement))
        #expect(effects.contains { if case .rejectFinish = $0 { return true } else { return false } })
        #expect(machine.state.vertices.count == 2)
    }

    @Test("Double-click is inert for a fixed-count tool")
    func doubleClickInertForLength() {
        var machine = makeMachine()
        machine.handle(.armTool(.length))
        machine.handle(.placePoint(PDFPointValue(x: 0, y: 0)))
        #expect(machine.handle(.doubleClick).isEmpty)
        #expect(machine.state.vertices.count == 1)
    }

    // MARK: CR-176 — the duplicate at exactly the minimum

    /// Old output: `effects` contained `.commitMeasurement` and no `.removeLastPoint`, and
    /// `machine.state.vertices` at the commit was
    /// `[(0,0), (100,0), (100,0)]` — a triangle with two vertices in the same place and an area
    /// of exactly zero, committed into the ledger. The duplicate survived because the drop was
    /// guarded by `vertices.count > kind.minimumPointCount`, which is false at *exactly* the
    /// minimum: an Area needs three points and the double-click's own first click had just
    /// placed the third on top of the second.
    @Test("A double-click at exactly the minimum count drops the duplicate rather than committing it")
    func doubleClickAtMinimumDropsTheDuplicate() {
        var machine = makeMachine()
        machine.handle(.armTool(.area))
        #expect(MeasurementKind.area.minimumPointCount == 3, "this test is about the boundary")
        machine.handle(.placePoint(PDFPointValue(x: 0, y: 0)))
        machine.handle(.placePoint(PDFPointValue(x: 100, y: 0)))
        // The first click of the double-click pair, landing on the previous vertex.
        machine.handle(.placePoint(PDFPointValue(x: 100, y: 0)))
        #expect(machine.state.vertices.count == 3)

        let effects = machine.handle(.doubleClick)

        #expect(effects.contains(.removeLastPoint), "the coincident vertex was kept")
        #expect(!effects.contains(.commitMeasurement), "a zero-area triangle reached the ledger")
        #expect(
            effects.contains { if case .rejectFinish = $0 { return true } else { return false } },
            "two points are not an Area, so the double-click must refuse"
        )
        // What is left is the two real corners. The duplicate is gone either way.
        #expect(machine.state.vertices == [PDFPointValue(x: 0, y: 0), PDFPointValue(x: 100, y: 0)])
        #expect(machine.state.phase == .drawing, "the work the person did is still there")
    }

    /// The same boundary a hair apart: within the close tolerance is a duplicate, outside it is
    /// a real, if short, third corner.
    @Test("At the minimum count, a genuine third corner still commits")
    func doubleClickAtMinimumKeepsAGenuineCorner() {
        var machine = makeMachine()
        machine.handle(.armTool(.area))
        machine.handle(.placePoint(PDFPointValue(x: 0, y: 0)))
        machine.handle(.placePoint(PDFPointValue(x: 100, y: 0)))
        // Well outside `firstVertexCloseTolerance` (6 pt), so this is a corner, not a stutter.
        machine.handle(.placePoint(PDFPointValue(x: 100, y: 60)))

        let effects = machine.handle(.doubleClick)
        #expect(!effects.contains(.removeLastPoint))
        #expect(effects.contains(.commitMeasurement))
    }

    /// A stutter one point above the minimum was already dropped, and still is.
    @Test("The duplicate is dropped above the minimum count as well")
    func doubleClickAboveMinimumStillDropsTheDuplicate() {
        var machine = makeMachine()
        machine.handle(.armTool(.area))
        machine.handle(.placePoint(PDFPointValue(x: 0, y: 0)))
        machine.handle(.placePoint(PDFPointValue(x: 100, y: 0)))
        machine.handle(.placePoint(PDFPointValue(x: 100, y: 100)))
        machine.handle(.placePoint(PDFPointValue(x: 100, y: 100)))

        let effects = machine.handle(.doubleClick)
        #expect(effects.contains(.removeLastPoint))
        #expect(effects.contains(.commitMeasurement))
        #expect(machine.state.phase == .armed)
    }

    // MARK: CR-177 — a count mark is not a vertex

    /// Old output: `effects` contained `.removeLastPoint` and `.commitMeasurement`, and
    /// `machine.state.vertices.count` fell from 2 to 1 before the group closed — the second
    /// socket was thrown away as a "duplicate vertex" and the group ended on the discard.
    /// Two count clicks 4 pt apart placed quickly are exactly what macOS delivers as a
    /// double-click, so counting a dense run of marks lost one mark and the group with it.
    @Test("Two fast count clicks close together are two marks, not one, and do not close the group")
    func doubleClickDoesNotCollapseCountMarks() {
        var machine = makeMachine()
        machine.handle(.armTool(.count))
        machine.handle(.placePoint(PDFPointValue(x: 40, y: 40)))
        machine.handle(.placePoint(PDFPointValue(x: 44, y: 40)))
        #expect(machine.state.vertices.count == 2)
        // 4 pt apart, inside the 6 pt tolerance that used to make the second one a duplicate.
        #expect(PDFPointValue(x: 40, y: 40).distance(to: PDFPointValue(x: 44, y: 40)) == 4)
        #expect(machine.configuration.firstVertexCloseTolerance == 6)

        let effects = machine.handle(.doubleClick)

        #expect(effects.isEmpty, "a double-click has no meaning for a tool with no path")
        #expect(machine.state.vertices.count == 2, "a count mark was discarded as a duplicate")
        #expect(machine.state.phase == .drawing, "the count group closed on the discard")
        #expect(machine.state.kind == .count)
    }

    /// The group still ends the way it is supposed to, and with both marks in it.
    @Test("Escape still ends a count group the double-click left alone")
    func countGroupStillEndsOnEscape() {
        var machine = makeMachine()
        machine.handle(.armTool(.count))
        machine.handle(.placePoint(PDFPointValue(x: 40, y: 40)))
        machine.handle(.placePoint(PDFPointValue(x: 44, y: 40)))
        machine.handle(.doubleClick)

        let effects = machine.handle(.cancel)
        #expect(effects.contains(.commitMeasurement))
        #expect(
            effects.contains { effect in
                if case let .announce(text) = effect { return text.contains("2 points") }
                return false
            },
            "the committed group must carry both marks"
        )
    }

    /// The exclusion is stated on the tool, not on the tool's name, so it stays true if another
    /// point-placement tool is ever added.
    @Test("Only the point-placement tools are excluded from the double-click gesture")
    func onlyPointPlacementToolsAreExcluded() {
        // The cutout tools are left out: they refuse every click until a parent area has been
        // published, so they never reach `.drawing` here and would prove nothing either way.
        for kind in MeasurementKind.allCases
        where kind.completingPointCount == nil && !kind.requiresParentArea {
            var machine = makeMachine()
            machine.handle(.armTool(kind))
            machine.handle(.placePoint(PDFPointValue(x: 0, y: 0)))
            machine.handle(.placePoint(PDFPointValue(x: 2, y: 0)))
            let effects = machine.handle(.doubleClick)
            if kind.isPointPlacement {
                #expect(effects.isEmpty, "\(kind.rawValue) is a set of marks, not a path")
                #expect(machine.state.vertices.count == 2, "\(kind.rawValue) lost a mark")
            } else {
                #expect(!effects.isEmpty, "\(kind.rawValue) ignored a double-click entirely")
                #expect(machine.state.vertices.count < 2, "\(kind.rawValue) kept a coincident pair")
            }
        }
    }

    @Test("Backspace still removes the last polygon vertex while drawing")
    func backspaceDuringPolygon() {
        var machine = makeMachine()
        machine.handle(.armTool(.area))
        machine.handle(.placePoint(PDFPointValue(x: 0, y: 0)))
        machine.handle(.placePoint(PDFPointValue(x: 100, y: 0)))
        machine.handle(.placePoint(PDFPointValue(x: 100, y: 100)))

        let effects = machine.handle(.removeLastVertex)
        #expect(effects.contains(.removeLastPoint))
        #expect(machine.state.vertices.count == 2)
        #expect(machine.state.phase == .drawing)
    }

    // MARK: Tool semantics table

    @Test("The semantics table matches the tool grammar")
    func semanticsTable() {
        #expect(MeasurementKind.length.completingPointCount == 2)
        // Three clicks: two corners define an edge, the third the depth, the fourth corner
        // is derived.
        #expect(MeasurementKind.rectangleArea.completingPointCount == 3)
        #expect(MeasurementKind.angle.completingPointCount == 3)
        // X-042: start, a point on the arc, end. Old output: nil, so a fourth point could be placed.
        #expect(MeasurementKind.arcLength.completingPointCount == 3)
        #expect(MeasurementKind.area.completingPointCount == nil)
        #expect(MeasurementKind.polylength.completingPointCount == nil)
        #expect(MeasurementKind.count.completingPointCount == nil)

        #expect(MeasurementKind.rectangleArea.usesDragGesture)
        #expect(MeasurementKind.ellipseArea.usesDragGesture)
        #expect(!MeasurementKind.length.usesDragGesture)
        #expect(!MeasurementKind.area.usesDragGesture)

        #expect(MeasurementKind.rectangleArea.derivesFourthCorner)
        #expect(!MeasurementKind.ellipseArea.derivesFourthCorner)
        #expect(!MeasurementKind.area.derivesFourthCorner)

        #expect(MeasurementKind.area.closesOnFirstVertex)
        #expect(MeasurementKind.perimeter.closesOnFirstVertex)
        #expect(!MeasurementKind.rectangleArea.closesOnFirstVertex)
        #expect(!MeasurementKind.polylength.closesOnFirstVertex)
    }

    // MARK: Escape

    @Test("Escape is two-stage: cancel the geometry, then disarm")
    func escapeIsTwoStage() {
        var machine = makeMachine()
        machine.handle(.armTool(.polylength))
        machine.handle(.placePoint(PDFPointValue(x: 0, y: 0)))

        let first = machine.handle(.cancel)
        #expect(first.contains(.cancelMeasurement))
        #expect(!first.contains(.deactivateTool))
        #expect(machine.state.phase == .armed)

        let second = machine.handle(.cancel)
        #expect(second.contains(.deactivateTool))
        #expect(machine.state.phase == .idle)

        #expect(machine.handle(.cancel).isEmpty)
    }

    // MARK: Tab cycling

    @Test("Tab cycles forward and wraps")
    func tabCyclesForward() {
        var machine = makeMachine()
        machine.handle(.armTool(.length))
        machine.handle(.setSnapCandidates([
            candidate(.intersection, at: PDFPointValue(x: 10, y: 10)),
            candidate(.endpoint, at: PDFPointValue(x: 10, y: 10)),
            candidate(.midpoint, at: PDFPointValue(x: 10, y: 10))
        ]))
        #expect(machine.state.snapCandidateIndex == 0)

        machine.handle(.cycleSnapCandidate(forward: true))
        #expect(machine.state.snapCandidateIndex == 1)
        machine.handle(.cycleSnapCandidate(forward: true))
        #expect(machine.state.snapCandidateIndex == 2)
        machine.handle(.cycleSnapCandidate(forward: true))
        #expect(machine.state.snapCandidateIndex == 0)
    }

    @Test("Shift-Tab cycles backwards")
    func shiftTabCyclesBackwards() {
        var machine = makeMachine()
        machine.handle(.armTool(.length))
        machine.handle(.setSnapCandidates([
            candidate(.intersection, at: PDFPointValue(x: 10, y: 10)),
            candidate(.endpoint, at: PDFPointValue(x: 10, y: 10))
        ]))

        machine.handle(.cycleSnapCandidate(forward: false))
        #expect(machine.state.snapCandidateIndex == 1)
    }

    @Test("Tab on a scanned page says Vector Snap is unavailable")
    func tabOnScannedPage() {
        var machine = makeMachine()
        machine.handle(.armTool(.length))
        machine.handle(.setVectorSnapAvailable(false))

        let effects = machine.handle(.cycleSnapCandidate(forward: true))
        // A Tab report is transient: the host may throttle it (IM-105).
        guard case let .announceTransient(message)? = effects.first else {
            Issue.record("Expected an announcement")
            return
        }
        #expect(message.contains("Vector Snap"))
    }

    @Test("The same candidate twice in a row is announced once")
    func repeatedCandidateIsSilent() {
        var machine = makeMachine()
        machine.handle(.armTool(.length))
        let list = [candidate(.endpoint, at: PDFPointValue(x: 10, y: 10))]

        #expect(machine.handle(.setSnapCandidates(list)).count == 1)
        #expect(machine.handle(.setSnapCandidates(list)).isEmpty)
    }

    // MARK: Modifiers

    @Test("Command suspends snapping while held")
    func commandSuspendsSnapping() {
        var machine = makeMachine()
        machine.handle(.armTool(.length))
        machine.handle(.setSnapCandidates([candidate(.endpoint, at: PDFPointValue(x: 10, y: 10))]))
        #expect(machine.state.activeSnapCandidate != nil)

        machine.handle(.setModifiers(.command))
        #expect(machine.state.activeSnapCandidate == nil)
        #expect(machine.state.isSnapSuspended)

        machine.handle(.setModifiers([]))
        #expect(machine.state.activeSnapCandidate != nil)
    }

    @Test("Option bypasses the acquired candidate and releasing restores it")
    func optionBypassesCandidate() {
        var machine = makeMachine()
        machine.handle(.armTool(.length))
        machine.handle(.setSnapCandidates([candidate(.endpoint, at: PDFPointValue(x: 10, y: 10))]))

        machine.handle(.setModifiers(.option))
        #expect(machine.state.snapCandidateIndex == nil)

        machine.handle(.setModifiers([]))
        #expect(machine.state.snapCandidateIndex == 0)
    }

    @Test("A snap candidate overrides the raw cursor when a point is placed")
    func candidateOverridesCursor() {
        var machine = makeMachine()
        machine.handle(.armTool(.length))
        machine.handle(.pointerMoved(PDFPointValue(x: 12, y: 9)))
        machine.handle(.setSnapCandidates([candidate(.endpoint, at: PDFPointValue(x: 10, y: 10))]))

        #expect(machine.effectivePoint == PDFPointValue(x: 10, y: 10))
        machine.handle(.placePointAtCursor)
        #expect(machine.state.vertices.first == PDFPointValue(x: 10, y: 10))
    }

    // MARK: Angle constraint

    @Test("Shift holds the segment to the angle increment and keeps its length")
    func shiftConstrainsAngle() {
        var machine = makeMachine()
        machine.handle(.armTool(.length))
        machine.handle(.placePoint(PDFPointValue(x: 0, y: 0)))
        machine.handle(.setModifiers(.shift))

        let distance = 100.0
        let radians = 20.0 * .pi / 180
        machine.handle(.pointerMoved(PDFPointValue(x: cos(radians) * distance, y: sin(radians) * distance)))

        let point = machine.effectivePoint
        let angle = atan2(point.y, point.x) * 180 / .pi
        #expect(abs(angle - 15) < 1e-6)
        #expect(abs((point.x * point.x + point.y * point.y).squareRoot() - distance) < 1e-6)
    }

    @Test("The angle constraint needs an anchor vertex")
    func constraintNeedsAnchor() {
        var machine = makeMachine()
        machine.handle(.armTool(.length))
        machine.handle(.setModifiers(.shift))
        machine.handle(.pointerMoved(PDFPointValue(x: 33, y: 77)))
        #expect(!machine.state.isAngleConstrained)
        #expect(machine.effectivePoint == PDFPointValue(x: 33, y: 77))
    }

    @Test("The constraint readout is normalised to 0 to 360 degrees")
    func constraintReadoutIsNormalised() {
        var machine = makeMachine()
        machine.handle(.armTool(.length))
        machine.handle(.placePoint(PDFPointValue(x: 0, y: 0)))
        machine.handle(.setModifiers(.shift))
        machine.handle(.pointerMoved(PDFPointValue(x: 10, y: -10)))

        let degrees = indicatorDegrees(machine)
        #expect(abs((degrees ?? -1) - 315) < 1e-6)
    }

    @Test("Constraining a point already on an increment leaves it alone")
    func constrainKeepsAlignedPoint() {
        let anchor = PDFPointValue(x: 5, y: 5)
        let constrained = MeasurementInputStateMachine.constrain(
            PDFPointValue(x: 15, y: 5),
            to: anchor,
            incrementDegrees: 15
        )
        #expect(abs(constrained.x - 15) < 1e-9)
        #expect(abs(constrained.y - 5) < 1e-9)
    }

    @Test("Constraining at zero distance is safe")
    func constrainAtZeroDistance() {
        let anchor = PDFPointValue(x: 5, y: 5)
        #expect(MeasurementInputStateMachine.constrain(anchor, to: anchor, incrementDegrees: 15) == anchor)
    }

    @Test("The remaining vertex count counts down as points are placed")
    func remainingCountsDown() {
        var machine = makeMachine()
        machine.handle(.armTool(.area))
        #expect(machine.state.remainingVertexCount == MeasurementKind.area.minimumPointCount)
        machine.handle(.placePoint(PDFPointValue(x: 0, y: 0)))
        #expect(machine.state.remainingVertexCount == MeasurementKind.area.minimumPointCount - 1)
    }

    // MARK: Shift = straight line

    private func makeStraightLineMachine() -> MeasurementInputStateMachine {
        // The shipped configuration: 45° increments.
        MeasurementInputStateMachine(configuration: .standard)
    }

    /// The indicator angle the canvas shows for this machine's drawing (U-073: the one rule).
    private func indicatorDegrees(_ machine: MeasurementInputStateMachine) -> Double? {
        MeasurementInputStateMachine.constraintIndicatorDegrees(
            kind: machine.state.kind,
            placedPoints: machine.state.vertices,
            cursor: machine.state.rawCursor,
            incrementDegrees: machine.configuration.angleIncrementDegrees
        )
    }

    @Test("The shipped default constrains to 45 degree increments")
    func defaultIncrementIsFortyFive() {
        #expect(MeasurementInputConfiguration.standard.angleIncrementDegrees == 45)
    }

    @Test("Shift held live: the rubber band follows the constrained ray, release frees it")
    func shiftConstrainsLiveAndReleasesLive() {
        var machine = makeStraightLineMachine()
        machine.handle(.armTool(.length))
        machine.handle(.placePoint(PDFPointValue(x: 0, y: 0)))
        machine.handle(.pointerMoved(PDFPointValue(x: 100, y: 12)))

        // Free movement first: the effective point is the raw cursor.
        #expect(machine.effectivePoint == PDFPointValue(x: 100, y: 12))

        // Shift down mid-draw: the same cursor now reads horizontal, exactly.
        machine.handle(.setModifiers(.shift))
        let constrained = machine.effectivePoint
        #expect(constrained.y == 0, "horizontal must be exact, got \(constrained.y)")
        #expect(constrained.x > 0)

        // Shift released mid-draw: free movement returns.
        machine.handle(.setModifiers([]))
        #expect(machine.effectivePoint == PDFPointValue(x: 100, y: 12))
    }

    @Test("The committed point is the constrained point")
    func committedPointIsConstrained() {
        var machine = makeStraightLineMachine()
        machine.handle(.armTool(.length))
        machine.handle(.placePoint(PDFPointValue(x: 10, y: 10)))
        machine.handle(.setModifiers(.shift))
        machine.handle(.pointerMoved(PDFPointValue(x: 110, y: 18)))

        let effects = machine.handle(.placePointAtCursor)
        guard case let .placePoint(placed)? = effects.first else {
            Issue.record("Expected the constrained point to be placed")
            return
        }
        #expect(placed.y == 10, "the committed segment must be exactly horizontal")
        #expect(effects.contains(.commitMeasurement))
    }

    @Test("Horizontal and vertical dominate an exact tie with a diagonal")
    func axisDominatesTies() {
        let anchor = PDFPointValue(x: 0, y: 0)
        // Exactly 22.5°: halfway between 0° and 45°. The axis wins.
        let up = MeasurementInputStateMachine.constrainedDirectionDegrees(
            from: anchor,
            toward: PDFPointValue(x: cos(22.5 * .pi / 180), y: sin(22.5 * .pi / 180)),
            incrementDegrees: 45
        )
        #expect(up == 0)
        // Exactly 67.5°: halfway between 45° and 90°. The axis wins again.
        let side = MeasurementInputStateMachine.constrainedDirectionDegrees(
            from: anchor,
            toward: PDFPointValue(x: cos(67.5 * .pi / 180), y: sin(67.5 * .pi / 180)),
            incrementDegrees: 45
        )
        #expect(side == 90)
    }

    @Test("The angle readout is exactly 0.0, 45.0 and 90.0")
    func angleReadoutIsExact() {
        var machine = makeStraightLineMachine()
        machine.handle(.armTool(.length))
        machine.handle(.placePoint(PDFPointValue(x: 0, y: 0)))
        machine.handle(.setModifiers(.shift))

        machine.handle(.pointerMoved(PDFPointValue(x: 100, y: 9)))
        #expect(indicatorDegrees(machine) == 0.0)

        machine.handle(.pointerMoved(PDFPointValue(x: 91, y: 100)))
        #expect(indicatorDegrees(machine) == 45.0)

        machine.handle(.pointerMoved(PDFPointValue(x: -3, y: 100)))
        #expect(indicatorDegrees(machine) == 90.0)
    }

    @Test("Snap composes with the constraint: a candidate on the ray wins by its distance")
    func snapOnConstrainedRayComposes() {
        var machine = makeStraightLineMachine()
        machine.handle(.armTool(.length))
        machine.handle(.placePoint(PDFPointValue(x: 0, y: 0)))
        machine.handle(.setModifiers(.shift))
        machine.handle(.pointerMoved(PDFPointValue(x: 100, y: 5)))
        // A candidate 2 points off the horizontal ray, at x = 80: near enough to be meant
        // for it. The placed point takes its distance but stays exactly on the ray.
        machine.handle(.setSnapCandidates([candidate(.endpoint, at: PDFPointValue(x: 80, y: 2))]))

        let point = machine.effectivePoint
        #expect(point.y == 0, "the snap point must not yank the line crooked")
        #expect(abs(point.x - 80) < 1e-9, "the candidate's distance along the ray wins")
    }

    @Test("A snap candidate off the constrained ray is ignored — the direction wins")
    func snapOffConstrainedRayIsIgnored() {
        var machine = makeStraightLineMachine()
        machine.handle(.armTool(.length))
        machine.handle(.placePoint(PDFPointValue(x: 0, y: 0)))
        machine.handle(.setModifiers(.shift))
        machine.handle(.pointerMoved(PDFPointValue(x: 100, y: 5)))
        // 40 points off the horizontal ray: clearly meant for other geometry.
        machine.handle(.setSnapCandidates([candidate(.endpoint, at: PDFPointValue(x: 80, y: 40))]))

        let point = machine.effectivePoint
        #expect(point.y == 0)
        // The distance comes from the cursor, not from the rejected candidate.
        let cursorDistance = (100.0 * 100.0 + 5.0 * 5.0).squareRoot()
        #expect(abs(point.x - cursorDistance) < 1e-9)
    }

    // MARK: Three-point rectangle

    @Test("Three clicks finish the rectangle: the third click commits with the derived corner")
    func threeClicksFinishTheRectangle() {
        var machine = makeStraightLineMachine()
        machine.handle(.armTool(.rectangleArea))

        // Each click is a press-and-release without movement.
        machine.handle(.dragBegan(PDFPointValue(x: 0, y: 0)))
        let first = machine.handle(.dragEnded(PDFPointValue(x: 0, y: 0)))
        #expect(!first.contains(.cancelMeasurement), "a click is a corner, not a failed drag")
        #expect(machine.state.vertices == [PDFPointValue(x: 0, y: 0)])
        #expect(machine.state.isClickPlacingDragTool)

        machine.handle(.dragBegan(PDFPointValue(x: 100, y: 0)))
        machine.handle(.dragEnded(PDFPointValue(x: 100, y: 0)))
        #expect(machine.state.vertices.count == 2)

        machine.handle(.dragBegan(PDFPointValue(x: 100, y: 40)))
        let third = machine.handle(.dragEnded(PDFPointValue(x: 100, y: 40)))
        #expect(third.contains(.placePoint(PDFPointValue(x: 100, y: 40))))
        // P4 = P1 + P3 − P2 = (0, 40).
        #expect(third.contains(.placePoint(PDFPointValue(x: 0, y: 40))))
        #expect(third.contains(.commitMeasurement))
        #expect(machine.state.phase == .armed)
        #expect(machine.state.vertices.isEmpty)
        #expect(!machine.state.isClickPlacingDragTool)
    }

    @Test("The derived corner makes a parallelogram from a skewed depth point")
    func derivedCornerIsParallelogram() {
        let fourth = MeasurementInputStateMachine.derivedFourthCorner(
            PDFPointValue(x: 0, y: 0),
            PDFPointValue(x: 100, y: 0),
            PDFPointValue(x: 110, y: 40)
        )
        #expect(fourth == PDFPointValue(x: 10, y: 40))
    }

    @Test("Shift on the depth point yields a true rectangle")
    func shiftDepthPointIsPerpendicular() {
        var machine = makeStraightLineMachine()
        machine.handle(.armTool(.rectangleArea))
        machine.handle(.dragBegan(PDFPointValue(x: 0, y: 0)))
        machine.handle(.dragEnded(PDFPointValue(x: 0, y: 0)))
        machine.handle(.dragBegan(PDFPointValue(x: 100, y: 0)))
        machine.handle(.dragEnded(PDFPointValue(x: 100, y: 0)))

        machine.handle(.setModifiers(.shift))
        machine.handle(.pointerMoved(PDFPointValue(x: 112, y: 40)))
        // The depth point is held to the perpendicular of the placed edge through P2.
        #expect(machine.effectivePoint == PDFPointValue(x: 100, y: 40))

        machine.handle(.dragBegan(PDFPointValue(x: 112, y: 40)))
        let third = machine.handle(.dragEnded(PDFPointValue(x: 112, y: 40)))
        #expect(third.contains(.placePoint(PDFPointValue(x: 100, y: 40))))
        #expect(third.contains(.placePoint(PDFPointValue(x: 0, y: 40))), "P4 closes a true rectangle")
        #expect(third.contains(.commitMeasurement))
    }

    @Test("A real drag still finishes the rectangle on release")
    func realDragStillFinishesRectangle() {
        var machine = makeStraightLineMachine()
        machine.handle(.armTool(.rectangleArea))
        machine.handle(.dragBegan(PDFPointValue(x: 10, y: 10)))
        machine.handle(.dragMoved(PDFPointValue(x: 60, y: 40)))
        let ended = machine.handle(.dragEnded(PDFPointValue(x: 110, y: 80)))
        #expect(ended.contains(.placePoint(PDFPointValue(x: 110, y: 80))))
        #expect(ended.contains(.commitMeasurement))
        #expect(machine.state.vertices.isEmpty)
    }

    @Test("Direct clicks on the rectangle also commit on the third with the derived corner")
    func directClicksFinishTheRectangle() {
        // The keyboard flow places through `.placePointAtCursor`; the same three-point
        // grammar must hold there.
        var machine = makeStraightLineMachine()
        machine.handle(.armTool(.rectangleArea))
        machine.handle(.placePoint(PDFPointValue(x: 0, y: 0)))
        machine.handle(.placePoint(PDFPointValue(x: 50, y: 0)))
        let effects = machine.handle(.placePoint(PDFPointValue(x: 50, y: 20)))
        #expect(effects.contains(.placePoint(PDFPointValue(x: 0, y: 20))))
        #expect(effects.contains(.commitMeasurement))
    }

    // MARK: Two-finger tap / secondary click

    @Test("A secondary click closes a polygon with three or more vertices")
    func secondaryClickClosesPolygon() {
        var machine = makeStraightLineMachine()
        machine.handle(.armTool(.area))
        machine.handle(.placePoint(PDFPointValue(x: 0, y: 0)))
        machine.handle(.placePoint(PDFPointValue(x: 100, y: 0)))
        machine.handle(.placePoint(PDFPointValue(x: 100, y: 100)))

        let effects = machine.handle(.secondaryClick)
        #expect(effects.contains(.commitMeasurement))
        #expect(machine.state.vertices.isEmpty)
        #expect(machine.state.phase == .armed)
    }

    @Test("A secondary click finishes a polylength as placed")
    func secondaryClickFinishesPolylength() {
        var machine = makeStraightLineMachine()
        machine.handle(.armTool(.polylength))
        machine.handle(.placePoint(PDFPointValue(x: 0, y: 0)))
        machine.handle(.placePoint(PDFPointValue(x: 100, y: 0)))

        let effects = machine.handle(.secondaryClick)
        #expect(effects.contains(.commitMeasurement))
    }

    @Test("A secondary click with too few vertices does nothing — never a cancel")
    func secondaryClickBelowMinimumDoesNothing() {
        var machine = makeStraightLineMachine()
        machine.handle(.armTool(.area))
        machine.handle(.placePoint(PDFPointValue(x: 0, y: 0)))
        machine.handle(.placePoint(PDFPointValue(x: 100, y: 0)))

        let effects = machine.handle(.secondaryClick)
        #expect(effects.isEmpty, "two vertices are not a polygon; the tap must be inert")
        #expect(machine.state.vertices.count == 2, "the tap must never cancel work")
        #expect(machine.state.phase == .drawing)

        // And a polylength one point short is equally inert.
        var poly = makeStraightLineMachine()
        poly.handle(.armTool(.polylength))
        poly.handle(.placePoint(PDFPointValue(x: 0, y: 0)))
        #expect(poly.handle(.secondaryClick).isEmpty)
        #expect(poly.state.vertices.count == 1)
    }

    @Test("A secondary click is inert for fixed-count and idle tools")
    func secondaryClickInertElsewhere() {
        var machine = makeStraightLineMachine()
        #expect(machine.handle(.secondaryClick).isEmpty, "idle: nothing to finish")

        machine.handle(.armTool(.length))
        machine.handle(.placePoint(PDFPointValue(x: 0, y: 0)))
        #expect(machine.handle(.secondaryClick).isEmpty, "a length finishes on its second click")
        #expect(machine.state.vertices.count == 1)
    }

    // MARK: Announcement throttle

    @Test("The throttle suppresses repeats and rapid announcements")
    func throttleSuppresses() {
        var throttle = SnapAnnouncementThrottle(minimumInterval: 1)
        let start = Date(timeIntervalSince1970: 1_000)
        // `shouldAnnounce` is mutating, so each call is hoisted out of `#expect`:
        // the macro captures its argument immutably.
        let first = throttle.shouldAnnounce("endpoint", at: start)
        let repeated = throttle.shouldAnnounce("endpoint", at: start.addingTimeInterval(5))
        let tooSoon = throttle.shouldAnnounce("midpoint", at: start.addingTimeInterval(0.2))
        let afterInterval = throttle.shouldAnnounce("midpoint", at: start.addingTimeInterval(1.5))
        #expect(first)
        #expect(!repeated)
        #expect(!tooSoon)
        #expect(afterInterval)
    }

    @Test("Resetting the throttle forgets its history")
    func throttleReset() {
        var throttle = SnapAnnouncementThrottle(minimumInterval: 1)
        let start = Date(timeIntervalSince1970: 2_000)
        let first = throttle.shouldAnnounce("endpoint", at: start)
        throttle.reset()
        let afterReset = throttle.shouldAnnounce("endpoint", at: start.addingTimeInterval(0.1))
        #expect(first)
        #expect(afterReset)
    }
}
