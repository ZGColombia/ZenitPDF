import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIMeasurement

/// R-137: the keyboard cursor. Drawing needs a full keyboard flow (`ACCESSIBILITY_PLAN.md`)
/// for a measurement step completable without a pointer. The keys: arrows move the cursor,
/// Return places a point at it, ⌘Return finishes, and Space stays the temporary pan. Before
/// this there was no event for it at all: an arrow with a tool armed did nothing, and the only
/// way to place a vertex was a click.
@Suite("The keyboard cursor places points without a pointer")
struct KeyboardCursorInputTests {

    private static let pageID = UUID(uuidString: "5E1F0000-0000-0000-0000-000000000137")!

    private func machine() -> MeasurementInputStateMachine {
        MeasurementInputStateMachine(
            configuration: MeasurementInputConfiguration(initialCursor: PDFPointValue(x: 100, y: 100))
        )
    }

    private func placed(_ effects: [MeasurementInputEffect]) -> [PDFPointValue] {
        effects.compactMap { if case let .placePoint(point) = $0 { return point } else { return nil } }
    }

    @Test("Arrows move the cursor, Return-as-place puts two points down, and a Length commits")
    func keyboardOnlyLength() {
        var flow = machine()
        flow.handle(.armTool(.length))
        #expect(!flow.state.returnPlacesPoint, "Return finishes until an arrow is pressed")

        flow.handle(.moveKeyboardCursor(dx: 10, dy: 0))
        flow.handle(.moveKeyboardCursor(dx: 0, dy: -1))
        #expect(flow.state.rawCursor == PDFPointValue(x: 110, y: 99))
        #expect(flow.state.isKeyboardCursorActive)
        #expect(flow.state.returnPlacesPoint)
        let first = flow.handle(.placePointAtCursor)
        #expect(placed(first) == [PDFPointValue(x: 110, y: 99)])
        #expect(flow.state.phase == .drawing)
        #expect(flow.state.returnPlacesPoint, "placing a point keeps the keyboard cursor leading")

        // The next arrows start from the placed vertex.
        for _ in 0..<5 { flow.handle(.moveKeyboardCursor(dx: 10, dy: 0)) }
        #expect(flow.state.rawCursor == PDFPointValue(x: 160, y: 99))
        let second = flow.handle(.placePointAtCursor)
        #expect(placed(second) == [PDFPointValue(x: 160, y: 99)])
        #expect(second.contains(.commitMeasurement), "a Length is two points and done")
        #expect(flow.state.phase == .armed)
        #expect(flow.state.returnPlacesPoint, "the cursor still leads for the next measurement")
    }

    @Test("The pointer takes over again: a move or a press ends keyboard placement")
    func pointerEndsKeyboardPlacement() {
        var flow = machine()
        flow.handle(.armTool(.area))
        flow.handle(.moveKeyboardCursor(dx: 1, dy: 1))
        #expect(flow.state.returnPlacesPoint)
        flow.handle(.pointerMoved(PDFPointValue(x: 5, y: 5)))
        #expect(!flow.state.returnPlacesPoint)

        flow.handle(.moveKeyboardCursor(dx: 1, dy: 1))
        #expect(flow.state.rawCursor == PDFPointValue(x: 6, y: 6), "the cursor moves on from where the pointer left it")
        flow.handle(.dragBegan(PDFPointValue(x: 20, y: 20)))
        #expect(!flow.state.isKeyboardCursorActive)
    }

    @Test("No tool armed: arrows do nothing here, and putting the tool away ends the mode")
    func idleIgnoresArrows() {
        var flow = machine()
        #expect(flow.handle(.moveKeyboardCursor(dx: 5, dy: 5)).isEmpty)
        #expect(flow.state.rawCursor == PDFPointValue(x: 100, y: 100))
        #expect(!flow.state.isKeyboardCursorActive)

        flow.handle(.armTool(.polylength))
        flow.handle(.moveKeyboardCursor(dx: 5, dy: 5))
        flow.handle(.cancel)   // armed → Escape puts the tool away
        #expect(flow.state.phase == .idle)
        #expect(!flow.state.returnPlacesPoint)

        flow.handle(.armTool(.polylength))
        flow.handle(.moveKeyboardCursor(dx: 5, dy: 5))
        flow.synchronize(kind: nil, vertices: [], cutoutParentID: nil)
        #expect(!flow.state.isKeyboardCursorActive)
        #expect(flow.handle(.moveKeyboardCursor(dx: .nan, dy: 0)).isEmpty)
    }

    @Test("The keyboard cursor snaps, holds to the Shift ray and closes on the first vertex like the pointer")
    func cursorUsesTheSameRules() {
        var flow = machine()
        flow.handle(.armTool(.area))
        flow.handle(.moveKeyboardCursor(dx: -100, dy: -100))
        flow.handle(.placePointAtCursor)                       // (0, 0)
        flow.handle(.moveKeyboardCursor(dx: 50, dy: 0))
        flow.handle(.placePointAtCursor)                       // (50, 0)

        // Shift: 45° rose from (50, 0). Raw cursor (90, 3) is held to the horizontal, at its
        // distance from the anchor: 50 + √(40² + 3²).
        flow.handle(.moveKeyboardCursor(dx: 40, dy: 3))
        flow.handle(.setModifiers(.shift))
        #expect(flow.effectivePoint == PDFPointValue(x: 50 + (1609.0).squareRoot(), y: 0))
        flow.handle(.setModifiers([]))

        // A snap candidate at the cursor wins over the raw cursor, exactly as for a click.
        let candidate = SnapFeedbackSnapshot(
            kind: .endpoint, pagePoint: PDFPointValue(x: 91, y: 40), sourceLabel: "wall", pageID: Self.pageID
        )
        flow.handle(.moveKeyboardCursor(dx: 0, dy: 37))
        flow.handle(.setSnapCandidates([candidate]))
        let third = flow.handle(.placePointAtCursor)
        #expect(placed(third) == [PDFPointValue(x: 91, y: 40)])

        // Back to within the close tolerance of (0, 0): Return-as-place closes the outline.
        flow.handle(.setSnapCandidates([]))
        flow.handle(.moveKeyboardCursor(dx: -89, dy: -39))
        #expect(flow.state.firstVertexCloseTarget(configuration: flow.configuration) == PDFPointValue(x: 0, y: 0))
        let close = flow.handle(.placePointAtCursor)
        #expect(close.contains(.commitMeasurement))
        #expect(placed(close).isEmpty)
    }

    @Test("⌘Return still finishes while the keyboard cursor leads")
    func finishStillFinishes() {
        var flow = machine()
        flow.handle(.armTool(.polylength))
        flow.handle(.moveKeyboardCursor(dx: 1, dy: 0))
        flow.handle(.placePointAtCursor)
        flow.handle(.moveKeyboardCursor(dx: 10, dy: 0))
        flow.handle(.placePointAtCursor)
        #expect(flow.state.returnPlacesPoint)
        let effects = flow.handle(.finish)
        #expect(effects.contains(.commitMeasurement))
    }
}
