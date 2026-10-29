import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIMeasurement

/// RT-2 at the input controller: a machine-speed burst of clicks and Returns reaches the host in
/// exactly the order it was sent, each Return's commit between its own clicks and the next
/// shape's.
///
/// This half cannot interleave by construction: ``MeasurementInputController/send(_:)`` is
/// synchronous on the main actor — the machine decides and every effect is applied before
/// `send` returns — so there is no queue in which a later click could overtake a Return. The
/// test pins that, so a future asynchronous hop in `send` cannot slip in unnoticed. The
/// interleaving the live session saw happened one layer down, in the presenter's asynchronous
/// snap queue behind the commit fence; it is reproduced and fixed in ZPDFAppCore
/// (`RT2BurstAcrossReturnTests`).
@MainActor
@Suite("RT-2: the input controller applies a burst in the order it was sent")
struct RT2InputBurstOrderingTests {

    @MainActor
    private final class RecordingTarget: MeasurementInputEffectApplying {
        var calls: [String] = []
        func activate(kind: MeasurementKind) { calls.append("activate \(kind.rawValue)") }
        func deactivate() { calls.append("deactivate") }
        func placePoint(_ point: PDFPointValue) { calls.append("place \(Int(point.x)),\(Int(point.y))") }
        func removeLastPoint() { calls.append("removeLast") }
        func commitActiveMeasurement() { calls.append("commit") }
        func cancelActiveMeasurement() { calls.append("cancel") }
    }

    private static func square(at x: Double, _ y: Double) -> [PDFPointValue] {
        [
            PDFPointValue(x: x, y: y), PDFPointValue(x: x + 100, y: y),
            PDFPointValue(x: x + 100, y: y + 100), PDFPointValue(x: x, y: y + 100)
        ]
    }

    private static func placed(_ points: [PDFPointValue]) -> [String] {
        points.map { "place \(Int($0.x)),\(Int($0.y))" }
    }

    @Test("Three areas and part of a fourth, with Returns, sent back to back: every effect in send order")
    func burstIsAppliedInOrder() {
        let target = RecordingTarget()
        let input = MeasurementInputController(target: target, announcer: { _ in })
        input.synchronize(kind: .area, vertices: [], cutoutParentID: nil)
        let shapes = [Self.square(at: 100, 100), Self.square(at: 300, 300), Self.square(at: 500, 500)]
        let tail = Array(Self.square(at: 700, 700).prefix(2))

        var expected: [String] = []
        for shape in shapes {
            for point in shape {
                input.send(.pointerMoved(point))
                input.send(.placePoint(point))
            }
            input.send(.finish)
            expected += Self.placed(shape) + ["commit"]
        }
        for point in tail {
            input.send(.pointerMoved(point))
            input.send(.placePoint(point))
        }
        expected += Self.placed(tail)

        #expect(target.calls == expected, "applied: \(target.calls)")
        #expect(input.state.vertices == tail, "the shape in progress holds only the clicks after the last Return")
    }

    @Test("Each event's effects have reached the host before send returns")
    func effectsLandBeforeSendReturns() {
        let target = RecordingTarget()
        let input = MeasurementInputController(target: target, announcer: { _ in })
        input.synchronize(kind: .area, vertices: [], cutoutParentID: nil)
        for (index, point) in Self.square(at: 0, 0).enumerated() {
            input.send(.placePoint(point))
            #expect(target.calls.count == index + 1, "click \(index + 1) is applied before the next event")
        }
        input.send(.finish)
        #expect(target.calls.last == "commit", "the commit is applied before the next click is sent")
        input.send(.placePoint(PDFPointValue(x: 900, y: 900)))
        #expect(target.calls.suffix(2) == ["commit", "place 900,900"])
    }
}
