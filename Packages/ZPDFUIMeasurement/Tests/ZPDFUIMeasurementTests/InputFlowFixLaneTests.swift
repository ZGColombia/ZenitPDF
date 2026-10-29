import Foundation
import Observation
import os
import SwiftUI
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIMeasurement

/// Bug hunt 2, the drawing input flow: the state machine and its controller.
///
/// Every sequence is driven through `MeasurementInputStateMachine` or through
/// `MeasurementInputController` over the mock presenter, so nothing reaches a screen.
@Suite("Input flow fixes (bug hunt 2)")
struct InputFlowFixLaneTests {

    private static let pageID = UUID(uuidString: "00000000-0000-0000-0000-00000000BEEF") ?? UUID()
    private static let areaA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A") ?? UUID()
    private static let areaB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B") ?? UUID()

    private func machine() -> MeasurementInputStateMachine {
        MeasurementInputStateMachine(
            configuration: MeasurementInputConfiguration(initialCursor: PDFPointValue(x: 100, y: 100))
        )
    }

    private func square(_ id: UUID, x: Double, y: Double, side: Double) -> CutoutParentCandidate {
        CutoutParentCandidate(
            markupID: id,
            outerRing: [
                PDFPointValue(x: x, y: y), PDFPointValue(x: x + side, y: y),
                PDFPointValue(x: x + side, y: y + side), PDFPointValue(x: x, y: y + side)
            ],
            subject: ""
        )
    }

    private func candidate(at point: PDFPointValue) -> SnapFeedbackSnapshot {
        SnapFeedbackSnapshot(kind: .endpoint, pagePoint: point, sourceLabel: "wall", pageID: Self.pageID)
    }

    private func twoDisjointAreas() -> [CutoutParentCandidate] {
        [square(Self.areaA, x: 0, y: 0, side: 100), square(Self.areaB, x: 500, y: 0, side: 100)]
    }

    // MARK: BH-047 / IM-106

    /// Old output: `cutoutParent == A` after the release, and the next press inside B was
    /// refused as "outside A".
    ///
    /// Since T-058 an Ellipse Cutout's parent is decided at the release, from the box's centre,
    /// so the press resolves nothing; what this test guards is unchanged: nothing the abandoned
    /// gesture decided may reach the next one.
    @Test("BH-047: a drag cutout released without moving forgets its parent")
    func degenerateReleaseForgetsParent() {
        var flow = machine()
        flow.handle(.armTool(.ellipseCutout))
        flow.handle(.setCutoutParents(twoDisjointAreas()))
        flow.handle(.dragBegan(PDFPointValue(x: 50, y: 50)))
        flow.handle(.dragEnded(PDFPointValue(x: 50, y: 50)))
        #expect(flow.state.phase == .armed)
        #expect(flow.state.cutoutParent == nil, "old output: parent A survived")

        let pressed = flow.handle(.dragBegan(PDFPointValue(x: 520, y: 20)))
        #expect(!pressed.contains { if case .rejectFinish = $0 { return true } else { return false } })
        let released = flow.handle(.dragEnded(PDFPointValue(x: 580, y: 80)))
        #expect(!released.contains { if case .rejectFinish = $0 { return true } else { return false } })
        #expect(released.contains(.commitCutout(parentMarkupID: Self.areaB)), "old output: refused as outside A")
    }

    // MARK: BH-259

    /// Old output: after a refused release the next press inside B was checked against A and
    /// refused, until Escape.
    ///
    /// Since T-058 the parent is decided at the release from the box's centre; the stale shape
    /// must still be thrown away before the next gesture is judged.
    @Test("BH-259: a fresh press discards the stale shape before checking its parent")
    func freshPressIsCheckedFresh() {
        var flow = machine()
        flow.handle(.armTool(.ellipseCutout))
        flow.handle(.setCutoutParents(twoDisjointAreas()))
        flow.handle(.dragBegan(PDFPointValue(x: 50, y: 40)))
        flow.handle(.dragEnded(PDFPointValue(x: 300, y: 60)))   // centre in no area: refused
        #expect(flow.state.cutoutRefusal != nil)

        let effects = flow.handle(.dragBegan(PDFPointValue(x: 550, y: 50)))
        #expect(effects.first == .cancelMeasurement)
        #expect(flow.state.cutoutParent == nil)
        #expect(flow.state.vertices == [PDFPointValue(x: 550, y: 50)])
        let released = flow.handle(.dragEnded(PDFPointValue(x: 560, y: 60)))
        #expect(released.contains(.commitCutout(parentMarkupID: Self.areaB)), "old output: refused as outside A")
    }

    // MARK: BH-260

    /// Old output: the raw press and the snapped release were 3 pt apart, so a click became a
    /// committed two-corner sliver.
    @Test("BH-260: a click beside a live snap candidate is still a click")
    func clickWithSnapCandidateIsAClick() {
        var rectangle = machine()
        rectangle.handle(.armTool(.rectangleArea))
        rectangle.handle(.setSnapCandidates([candidate(at: PDFPointValue(x: 203, y: 200))]))
        let pressed = rectangle.handle(.dragBegan(PDFPointValue(x: 200, y: 200)))
        #expect(pressed.contains(.placePoint(PDFPointValue(x: 203, y: 200))), "the press snaps like the release")
        let released = rectangle.handle(.dragEnded(PDFPointValue(x: 200, y: 200)))
        #expect(!released.contains(.commitMeasurement), "old output: a sliver was committed")
        #expect(rectangle.state.isClickPlacingDragTool)

        var ellipse = machine()
        ellipse.handle(.armTool(.ellipseArea))
        ellipse.handle(.setSnapCandidates([candidate(at: PDFPointValue(x: 203, y: 200))]))
        ellipse.handle(.dragBegan(PDFPointValue(x: 200, y: 200)))
        let ellipseRelease = ellipse.handle(.dragEnded(PDFPointValue(x: 200, y: 200)))
        #expect(ellipseRelease.first == .cancelMeasurement)
        #expect(!ellipseRelease.contains(.commitMeasurement))
    }

    // MARK: BH-256

    /// Old output: the mark landed on a 45° ray from the previous one, ~26 pt off the socket.
    @Test("BH-256: Shift does not angle-constrain count marks")
    func shiftDoesNotConstrainCount() {
        var flow = machine()
        flow.handle(.armTool(.count))
        flow.handle(.placePoint(PDFPointValue(x: 0, y: 0)))
        flow.handle(.setModifiers(.shift))
        let target = PDFPointValue(x: 100 * cos(.pi / 6), y: 100 * sin(.pi / 6))
        flow.handle(.pointerMoved(target))
        #expect(flow.effectivePoint == target)
        #expect(MeasurementInputStateMachine.constraintIndicatorDegrees(
            kind: flow.state.kind,
            placedPoints: flow.state.vertices,
            cursor: flow.state.rawCursor,
            incrementDegrees: flow.configuration.angleIncrementDegrees
        ) == nil)
        flow.handle(.placePointAtCursor)
        #expect(flow.state.vertices.last == target)
    }

    // MARK: BH-257

    /// Old output: after two click-mode corners Return committed the edge as a rectangle.
    @Test("BH-257: a click-placed rectangle cannot finish on two corners")
    func clickPlacedRectangleNeedsThreeCorners() {
        var flow = machine()
        flow.handle(.armTool(.rectangleArea))
        flow.handle(.dragBegan(PDFPointValue(x: 0, y: 0)))
        flow.handle(.dragEnded(PDFPointValue(x: 0, y: 0)))       // first corner, click mode
        flow.handle(.dragBegan(PDFPointValue(x: 100, y: 0)))
        let second = flow.handle(.dragEnded(PDFPointValue(x: 100, y: 0)))
        #expect(flow.state.vertices.count == 2)
        #expect(!flow.state.canFinish)
        #expect(flow.state.remainingVertexCount == 1)
        #expect(second.contains(.announce("Point 2 placed. 1 more point needed.")))
        let finish = flow.handle(.finish)
        #expect(!finish.contains(.commitMeasurement), "old output: the edge was committed")
    }

    // MARK: BH-258

    /// Old output: only `.activateTool`; the presenter kept its two points.
    @Test("BH-258: re-arming over a shape in progress tells the presenter to discard it")
    func rearmingCancelsPresenterShape() {
        var flow = machine()
        flow.handle(.armTool(.area))
        flow.handle(.placePoint(PDFPointValue(x: 0, y: 0)))
        flow.handle(.placePoint(PDFPointValue(x: 100, y: 0)))
        let effects = flow.handle(.armTool(.area))
        #expect(effects.first == .cancelMeasurement)
        #expect(effects.contains(.activateTool(.area)))
        #expect(flow.state.vertices.isEmpty)

        // Arming with nothing drawn does not cancel anything.
        var fresh = machine()
        #expect(fresh.handle(.armTool(.area)).first == .activateTool(.area))
    }

    // MARK: BH-746

    @Test("BH-746: Tab while snapping is suspended says so instead of naming a candidate")
    func tabWhileSuspended() {
        var flow = machine()
        flow.handle(.armTool(.length))
        flow.handle(.setSnapCandidates([candidate(at: PDFPointValue(x: 1, y: 1)), candidate(at: PDFPointValue(x: 2, y: 2))]))
        flow.handle(.setModifiers(.option))
        let effects = flow.handle(.cycleSnapCandidate(forward: true))
        guard case let .announceTransient(message)? = effects.first else {
            Issue.record("Expected a transient announcement")
            return
        }
        #expect(!message.contains("candidate"), "old output: 'candidate 1 of 2'")
        #expect(flow.state.activeSnapCandidate == nil)
    }

    // MARK: BH-748

    /// Old output: two clicks announced "Arc Length can be finished with Return".
    /// X-042: the third point now commits, as an Angle's does. Old output: the machine stayed in
    /// `.drawing` with `canFinish == true` after three points, a fourth could be placed and
    /// Return committed four points, of which the engine measured the first three.
    @Test("BH-748: Arc Length needs three points before it can finish, and the third commits")
    func arcLengthNeedsThreePoints() {
        var flow = machine()
        flow.handle(.armTool(.arcLength))
        // R-146: the machine reads the one minimum-point rule the canvas and presenter read.
        #expect(MeasurementKind.arcLength.minimumPointCount == 3)
        #expect(flow.state.requiredPointCount == MeasurementKind.arcLength.minimumPointCount)
        flow.handle(.placePoint(PDFPointValue(x: 0, y: 0)))
        flow.handle(.placePoint(PDFPointValue(x: 50, y: 20)))
        #expect(!flow.state.canFinish)
        let effects = flow.handle(.placePoint(PDFPointValue(x: 100, y: 0)))
        #expect(effects.contains(.commitMeasurement), "\(effects)")
        #expect(flow.state.phase != .drawing, "no fourth point can be placed")
        #expect(flow.state.vertices.isEmpty)
    }

    // MARK: IM-107

    /// W-074: Return now refuses with the sentence Finish uses. Old output:
    /// "Area: 2 more points needed.", through a hand-rolled plural.
    @Test("IM-107: one pluralised wording for the points still needed")
    func remainingPointsWording() {
        #expect(MeasurementPointPhrases.morePoints(1) == "1 more point")
        #expect(MeasurementPointPhrases.morePoints(2) == "2 more points")
        var flow = machine()
        flow.handle(.armTool(.area))
        flow.handle(.placePoint(PDFPointValue(x: 0, y: 0)))
        let refusal = flow.handle(.finish)
        #expect(refusal.contains(.rejectFinish("\(MeasurementKind.area.displayName) needs 2 more points before it can be finished.")))
    }

    // MARK: IM-205, BH-747

    // MARK: BH-745

    /// Old output: the refused midpoint announcement was gone for good.
    @Test("BH-745: a throttled announcement is kept and flushed once the interval passes")
    func throttleFlushesLatest() {
        var throttle = SnapAnnouncementThrottle(minimumInterval: 0.6)
        let start = Date(timeIntervalSince1970: 1_000)
        let first = throttle.shouldAnnounce("Endpoint", at: start)
        let second = throttle.shouldAnnounce("Midpoint", at: start.addingTimeInterval(0.3))
        #expect(first)
        #expect(!second)
        #expect(throttle.pendingMessage == "Midpoint")
        let early = throttle.flush(at: start.addingTimeInterval(0.4))
        #expect(early == nil, "not due yet")
        let due = throttle.flush(at: start.addingTimeInterval(0.6))
        #expect(due == "Midpoint")
        #expect(throttle.pendingMessage == nil)
    }
}

// MARK: - Controller

private final class TestClock {
    var date = Date(timeIntervalSince1970: 10_000)
    func advance(_ seconds: TimeInterval) { date = date.addingTimeInterval(seconds) }
}


@MainActor
@Suite("Input controller fixes (bug hunt 2)")
struct InputControllerFixLaneTests {

    private func controller(
        _ presenter: MockMeasurementToolPresenter,
        clock: TestClock,
        spoken: @escaping @MainActor (String) -> Void = { _ in }
    ) -> MeasurementInputController {
        MeasurementInputController(
            presenter: presenter,
            configuration: MeasurementInputConfiguration(initialCursor: PDFPointValue(x: 100, y: 100)),
            announcementInterval: 0.6,
            announcer: spoken,
            now: { clock.date }
        )
    }

    /// Old output: the machine removed mark 3 and said "8 counted" while the presenter kept 9.
    @Test("BH-253: a presenter that cannot remove one mark keeps machine and presenter in step")
    func countRemovalWithoutSupport() {
        let presenter = MockMeasurementToolPresenter()
        let input = controller(presenter, clock: TestClock())
        input.send(.armTool(.count))
        for x in [10.0, 50, 90] {
            input.send(.pointerMoved(PDFPointValue(x: x, y: 10)))
            input.send(.placePointAtCursor)
        }
        input.send(.pointerMoved(PDFPointValue(x: 50, y: 10)))
        input.send(.removePoint(near: PDFPointValue(x: 50, y: 10)))
        #expect(input.state.vertices.count == 3, "old output: 2 in the machine")
        #expect(presenter.placedPoints.count == 3)
        #expect(input.lastAnnouncement?.contains("not available") == true)
    }

    /// Old output: the cutout was cancelled while VoiceOver heard "finished with 3 points".
    @Test("BH-254: a cutout the presenter cannot commit is reported as discarded")
    func cutoutWithoutSupport() {
        let rewritten = MeasurementInputController.reconcilingCutoutCommit(
            [.commitCutout(parentMarkupID: UUID()), .announce("Polygon Cutout finished with 3 points.")],
            presenterCommitsCutouts: false
        )
        #expect(rewritten.first == .cancelMeasurement)
        #expect(!rewritten.contains(.announce("Polygon Cutout finished with 3 points.")))
        #expect(rewritten.contains { if case .rejectFinish = $0 { return true } else { return false } })

        let presenter = MockMeasurementToolPresenter()
        let input = controller(presenter, clock: TestClock())
        input.send(.armTool(.polygonCutout))
        input.setCutoutParents([
            CutoutParentCandidate(
                markupID: UUID(),
                outerRing: [PDFPointValue(x: 0, y: 0), PDFPointValue(x: 200, y: 0),
                            PDFPointValue(x: 200, y: 200), PDFPointValue(x: 0, y: 200)],
                subject: ""
            )
        ])
        for point in [PDFPointValue(x: 10, y: 10), PDFPointValue(x: 100, y: 10), PDFPointValue(x: 50, y: 100)] {
            input.send(.pointerMoved(point))
            input.send(.placePointAtCursor)
        }
        input.send(.finish)
        #expect(input.lastEffects.contains { if case .rejectFinish = $0 { return true } else { return false } })
        #expect(input.lastAnnouncement?.contains("finished") == false)
    }

    /// Old output: the commit landing 0.1 s after a snap announcement was never published.
    @Test("BH-255 / IM-105: state changes are never throttled, transient reports flush the latest")
    func announcementPriority() {
        let clock = TestClock()
        var spoken: [String] = []
        let input = controller(MockMeasurementToolPresenter(), clock: clock) { spoken.append($0) }
        input.send(.armTool(.length))
        input.send(.setSnapCandidates([
            SnapFeedbackSnapshot(kind: .endpoint, pagePoint: PDFPointValue(x: 5, y: 5), sourceLabel: "wall", pageID: UUID())
        ]))
        let snap = input.lastAnnouncement
        clock.advance(0.1)
        input.send(.pointerMoved(PDFPointValue(x: 0, y: 0)))
        input.send(.placePointAtCursor)
        #expect(input.lastAnnouncement != snap)
        #expect(input.lastAnnouncement?.hasPrefix("Point 1 placed") == true, "old output: dropped")

        // Five Tab presses inside half a second: the resting candidate is what gets spoken.
        // Three candidates, starting on the first: 1, 2, 0, 1, 2 — the third of three.
        clock.advance(1)
        input.send(.setSnapCandidates([1.0, 2, 3].map {
            SnapFeedbackSnapshot(kind: .endpoint, pagePoint: PDFPointValue(x: $0, y: $0), sourceLabel: "wall", pageID: UUID())
        }))
        for _ in 0..<5 {
            input.send(.cycleSnapCandidate(forward: true))
            clock.advance(0.1)
        }
        clock.advance(0.6)
        input.flushPendingAnnouncement()
        #expect(spoken.last?.hasSuffix("candidate 3 of 3.") == true)
    }

    @Test("IM-108: every published announcement is handed to the announcer once")
    func announcerIsCalled() {
        var spoken: [String] = []
        let input = controller(MockMeasurementToolPresenter(), clock: TestClock()) { spoken.append($0) }
        input.send(.armTool(.length))
        #expect(spoken.count == 1)
        #expect(spoken.first == input.lastAnnouncement)
    }

    /// Old output: `state` was reassigned on every pointer move, invalidating every reader.
    @Test("IM-104: a pointer move does not republish the drawing state")
    func pointerMoveDoesNotRepublishState() {
        let input = controller(MockMeasurementToolPresenter(), clock: TestClock())
        input.send(.armTool(.area))
        let changed = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = input.state
        } onChange: {
            changed.withLock { $0 = true }
        }
        input.send(.pointerMoved(PDFPointValue(x: 321, y: 123)))
        #expect(!changed.withLock { $0 })
        #expect(input.cursor == PDFPointValue(x: 321, y: 123))
        #expect(input.effectivePoint == PDFPointValue(x: 321, y: 123))

        input.send(.placePointAtCursor)
        #expect(changed.withLock { $0 })
        #expect(input.state.vertices == [PDFPointValue(x: 321, y: 123)])
    }
}
