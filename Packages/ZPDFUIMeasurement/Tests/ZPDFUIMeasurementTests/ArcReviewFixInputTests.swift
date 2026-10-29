import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIMeasurement

/// Review fix (ADR-0030 §5.7, r2-arcs-fix): A during a Scale Region or Project Zone boundary capture.
/// The capture arms the Area kind, so the machine alone would take A as "arc next segment"; the
/// presenter draws a boundary straight and refuses the arc. The controller now asks the host.
@Suite("Arc toggle only where the host draws arcs (ADR-0030 §5.7)")
struct ArcReviewFixInputTests {

    /// A host that can draw arcs in general but not in the shape in progress — a boundary capture.
    @MainActor
    final class BoundaryTarget: MeasurementInputEffectApplying, ArcSegmentDrawing {
        var calls: [String] = []
        var isArcNextSegment = false
        var arcThroughPoint: PDFPointValue?
        var drawsArcSegments: Bool { false }
        func activate(kind: MeasurementKind) { calls.append("activate") }
        func deactivate() { calls.append("deactivate") }
        func placePoint(_ point: PDFPointValue) { calls.append("place \(point.x),\(point.y)") }
        func removeLastPoint() { calls.append("remove") }
        func commitActiveMeasurement() { calls.append("commit") }
        func cancelActiveMeasurement() { calls.append("cancel") }
        // The presenter's refusal: an arc it does not draw is reset at once.
        func setArcNextSegment(_ isArc: Bool) { isArcNextSegment = false; arcThroughPoint = nil; calls.append("arc refused") }
        func placeArcThroughPoint(_ point: PDFPointValue) { calls.append("through dropped \(point.x),\(point.y)") }
        func removeArcThroughPoint() { calls.append("unthrough") }
    }

    /// Old output: `acceptsArcToggle` was true (the machine's kind is Area and the host adopts
    /// `ArcSegmentDrawing`), the machine armed the arc while the presenter refused it, and the next
    /// click became a through point the presenter dropped — the click was lost.
    @Test("A boundary capture does not take A as an arc, and the next click is still a vertex")
    @MainActor
    func boundaryCaptureKeepsClicks() {
        let target = BoundaryTarget()
        let controller = MeasurementInputController(target: target, announcer: { _ in })
        controller.send(.armTool(.area))
        controller.send(.placePoint(PDFPointValue(x: 0, y: 0)))
        #expect(!controller.acceptsArcToggle)
        controller.send(.toggleArcSegment)
        #expect(!controller.state.isArcNextSegment)
        controller.send(.placePoint(PDFPointValue(x: 10, y: 0)))
        #expect(target.calls.last == "place 10.0,0.0", "\(target.calls)")
        #expect(!target.calls.contains { $0.hasPrefix("through dropped") })
    }
}
