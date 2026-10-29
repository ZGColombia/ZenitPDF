import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIMeasurement

/// NL-MEASURE-05 (ADR-0030 §5.6): A while drawing makes the next segment a three-point arc. The
/// next click is the point the arc passes through — never a vertex — and the click after it is the
/// arc's end. Backspace takes the through point back before any vertex. Outside a shape A does
/// nothing here, and the canvas keeps it as the Area tool.
@Suite("Arc segment while drawing (NL-MEASURE-05)")
struct ArcSegmentInputTests {

    private func machine() -> MeasurementInputStateMachine {
        MeasurementInputStateMachine(configuration: MeasurementInputConfiguration(
            initialCursor: PDFPointValue(x: 100, y: 100),
            appliesCanvasGestures: true
        ))
    }

    private func p(_ x: Double, _ y: Double) -> PDFPointValue { PDFPointValue(x: x, y: y) }

    private func placements(_ effects: [MeasurementInputEffect]) -> [PDFPointValue] {
        effects.compactMap { if case let .placePoint(point) = $0 { return point } else { return nil } }
    }

    @Test("Outside a shape, A is not an arc toggle")
    func notWhileArmed() {
        var flow = machine()
        _ = flow.handle(.armTool(.polylength))
        #expect(!flow.acceptsArcToggle)
        #expect(flow.handle(.toggleArcSegment).isEmpty)
        #expect(!flow.state.isArcNextSegment)
    }

    @Test("Polylength: A, a through point that is not a vertex, then the arc's end")
    func threePointArc() {
        var flow = machine()
        _ = flow.handle(.armTool(.polylength))
        _ = flow.handle(.placePoint(p(0, 0)))
        #expect(flow.acceptsArcToggle)
        let toggled = flow.handle(.toggleArcSegment)
        #expect(toggled.contains(.setArcSegment(true)))
        #expect(flow.state.awaitsArcThroughPoint)

        let through = flow.handle(.placePoint(p(5, 5)))
        #expect(through.contains(.placeArcThroughPoint(p(5, 5))))
        #expect(placements(through).isEmpty, "the through point is not a vertex")
        #expect(flow.state.vertices == [p(0, 0)])
        #expect(flow.state.arcThroughPoint == p(5, 5))

        let end = flow.handle(.placePoint(p(10, 0)))
        #expect(placements(end) == [p(10, 0)])
        #expect(flow.state.vertices == [p(0, 0), p(10, 0)])
        #expect(!flow.state.isArcNextSegment && flow.state.arcThroughPoint == nil, "one segment, then straight again")
    }

    @Test("A twice is straight again; Backspace takes the through point back first")
    func toggleOffAndBackspace() {
        var flow = machine()
        _ = flow.handle(.armTool(.area))
        _ = flow.handle(.placePoint(p(0, 0)))
        _ = flow.handle(.placePoint(p(10, 0)))
        _ = flow.handle(.toggleArcSegment)
        #expect(flow.handle(.toggleArcSegment).contains(.setArcSegment(false)))
        #expect(!flow.state.isArcNextSegment)

        _ = flow.handle(.toggleArcSegment)
        _ = flow.handle(.placePoint(p(12, 2)))
        let back = flow.handle(.removeLastVertex)
        #expect(back.contains(.removeArcThroughPoint))
        #expect(!back.contains(.removeLastPoint))
        #expect(flow.state.vertices == [p(0, 0), p(10, 0)])
        #expect(flow.state.awaitsArcThroughPoint, "the arc stays armed for a new through point")
        let again = flow.handle(.removeLastVertex)
        #expect(again.contains(.removeLastPoint))
        #expect(flow.state.vertices == [p(0, 0)])
    }

    @Test("While the through point is awaited, a click on the first vertex is the through point, not a close")
    func throughPointNeverCloses() {
        var flow = machine()
        _ = flow.handle(.armTool(.area))
        for point in [p(0, 0), p(10, 0), p(10, 10)] { _ = flow.handle(.placePoint(point)) }
        _ = flow.handle(.toggleArcSegment)
        #expect(flow.state.firstVertexCloseTarget(configuration: flow.configuration) == nil)
        let effects = flow.handle(.placePoint(p(0, 0)))
        #expect(effects.contains(.placeArcThroughPoint(p(0, 0))))
        #expect(!effects.contains(.commitMeasurement))
        // With the through point placed, the click on the first vertex closes: the closing edge is
        // the arc.
        let close = flow.handle(.placePoint(p(0, 0)))
        #expect(close.contains(.commitMeasurement))
    }

    @Test("Length: first point, A, through point, end — the end commits")
    func lengthArc() {
        var flow = machine()
        _ = flow.handle(.armTool(.length))
        _ = flow.handle(.placePoint(p(0, 0)))
        _ = flow.handle(.toggleArcSegment)
        _ = flow.handle(.placePoint(p(5, 5)))
        #expect(flow.state.vertices.count == 1)
        let end = flow.handle(.placePoint(p(10, 0)))
        #expect(end.contains(.commitMeasurement))
    }

    @Test("Tools whose segments cannot be arcs ignore A")
    func unsupportedTools() {
        for kind in [MeasurementKind.count, .ellipseCutout, .angle, .radius, .rectangleArea] {
            var flow = machine()
            _ = flow.handle(.armTool(kind))
            _ = flow.handle(.placePoint(p(0, 0)))
            #expect(flow.handle(.toggleArcSegment).isEmpty, "\(kind)")
        }
    }

    /// C-08 (ADR-0037): the engine subtracts a cutout on its arcs, so a Polygon Cutout draws arc
    /// segments like an area. The through point is free to leave the parent like any later
    /// vertex: the engine subtracts the part inside (X-cutout-ui).
    /// Old output: A mid-cutout did nothing (`supportsArcSegments` left the cutout out), so a
    /// round opening could only be clicked as chords.
    @Test("Polygon Cutout: A, a through point inside the parent, then the arc's end")
    func polygonCutoutArc() {
        var flow = machine()
        let parent = UUID(uuidString: "0C080C08-0000-4000-8000-000000000001")!
        _ = flow.handle(.setCutoutParents([CutoutParentCandidate(
            markupID: parent,
            outerRing: [p(0, 0), p(100, 0), p(100, 100), p(0, 100)],
            subject: ""
        )]))
        _ = flow.handle(.armTool(.polygonCutout))
        _ = flow.handle(.placePoint(p(20, 20)))
        #expect(flow.state.cutoutParent?.markupID == parent)
        #expect(flow.acceptsArcToggle)
        #expect(flow.handle(.toggleArcSegment).contains(.setArcSegment(true)))
        let through = flow.handle(.placePoint(p(30, 10)))
        #expect(through.contains(.placeArcThroughPoint(p(30, 10))))
        #expect(placements(through).isEmpty)
        let end = flow.handle(.placePoint(p(40, 20)))
        #expect(placements(end) == [p(40, 20)])
        #expect(flow.state.vertices == [p(20, 20), p(40, 20)])
        // X-cutout-ui: a through point outside the parent is placed, like a later vertex. It used
        // to be refused, by a containment rule stricter than the engine's.
        _ = flow.handle(.toggleArcSegment)
        let outside = flow.handle(.placePoint(p(150, 50)))
        #expect(outside.contains(.placeArcThroughPoint(p(150, 50))))
        #expect(flow.state.cutoutRefusal == nil)
    }

    @Test("Escape and a commit forget the arc in progress")
    func resetOnCancelAndCommit() {
        var flow = machine()
        _ = flow.handle(.armTool(.polylength))
        _ = flow.handle(.placePoint(p(0, 0)))
        _ = flow.handle(.toggleArcSegment)
        _ = flow.handle(.placePoint(p(5, 5)))
        _ = flow.handle(.cancel)
        #expect(!flow.state.isArcNextSegment && flow.state.arcThroughPoint == nil)
    }

    // MARK: The controller

    @MainActor
    final class ArcTarget: MeasurementInputEffectApplying, ArcSegmentDrawing {
        var calls: [String] = []
        var isArcNextSegment = false
        var arcThroughPoint: PDFPointValue?
        func activate(kind: MeasurementKind) { calls.append("activate") }
        func deactivate() { calls.append("deactivate") }
        func placePoint(_ point: PDFPointValue) { calls.append("place \(point.x),\(point.y)") }
        func removeLastPoint() { calls.append("remove") }
        func commitActiveMeasurement() { calls.append("commit") }
        func cancelActiveMeasurement() { calls.append("cancel") }
        func setArcNextSegment(_ isArc: Bool) { isArcNextSegment = isArc; if !isArc { arcThroughPoint = nil }; calls.append("arc \(isArc)") }
        func placeArcThroughPoint(_ point: PDFPointValue) { arcThroughPoint = point; calls.append("through \(point.x),\(point.y)") }
        func removeArcThroughPoint() { arcThroughPoint = nil; calls.append("unthrough") }
    }

    @MainActor
    final class PlainTarget: MeasurementInputEffectApplying {
        func activate(kind: MeasurementKind) {}
        func deactivate() {}
        func placePoint(_ point: PDFPointValue) {}
        func removeLastPoint() {}
        func commitActiveMeasurement() {}
        func cancelActiveMeasurement() {}
    }

    @Test("The controller hands the arc to a host that can draw it, and to no other")
    @MainActor
    func controller() {
        let target = ArcTarget()
        let controller = MeasurementInputController(target: target, announcer: { _ in })
        controller.send(.armTool(.polylength))
        controller.send(.placePoint(PDFPointValue(x: 0, y: 0)))
        #expect(controller.acceptsArcToggle)
        controller.send(.toggleArcSegment)
        controller.send(.placePoint(PDFPointValue(x: 5, y: 5)))
        controller.send(.placePoint(PDFPointValue(x: 10, y: 0)))
        #expect(target.calls.contains("arc true"))
        #expect(target.calls.contains("through 5.0,5.0"))
        #expect(target.calls.last == "place 10.0,0.0")

        let plain = MeasurementInputController(target: PlainTarget(), announcer: { _ in })
        plain.send(.armTool(.polylength))
        plain.send(.placePoint(PDFPointValue(x: 0, y: 0)))
        #expect(!plain.acceptsArcToggle)
        plain.send(.toggleArcSegment)
        #expect(!plain.state.isArcNextSegment, "a host that cannot draw arcs never arms one")
    }
}
