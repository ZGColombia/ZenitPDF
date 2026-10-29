import AppKit
import Testing
@testable import ZenitPDFAppKit

/// Scrolling past the edge of a page turns the page.
///
/// On a 23-sheet elevation set, scrolling could not reach the next sheet. The canvas shows one page at a time, so a scroll panned inside
/// that page and stopped dead at its edge, and there was no page-navigation command of any kind
/// in the table — the Navigator was the only route through a document, and it can be closed.
///
/// These assert the three rules most likely to be wrong and least likely to be noticed:
/// the threshold, the reversal reset, and one turn per gesture.
@MainActor
@Suite(.appTierSerialised)
struct CanvasPageTurnTests {

    /// A scroll view with a recording page-turn callback.
    private func makeScrollView() -> (ZenitCanvasScrollView, Recorder) {
        let recorder = Recorder()
        let scrollView = ZenitCanvasScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        scrollView.onTurnPage = { forward in
            recorder.turns.append(forward)
            return recorder.succeeds
        }
        return (scrollView, recorder)
    }

    final class Recorder {
        var turns: [Bool] = []
        /// What `onTurnPage` returns — `false` models being at the end of the document.
        var succeeds = true
    }

    private var threshold: CGFloat { ZenitCanvasScrollView.pageTurnOverscrollThreshold }

    @Test("One small scroll at the bottom edge does not turn the page")
    func belowThresholdDoesNothing() {
        let (scrollView, recorder) = makeScrollView()
        scrollView.beginScrollGesture(atTop: false, atBottom: true)
        scrollView.considerTurningPage(deltaY: -10, wasAtTop: false, wasAtBottom: true)
        #expect(recorder.turns.isEmpty, "the page turned on a 10-point nudge at the edge")
    }

    @Test("Accumulated overscroll past the threshold turns forward exactly once")
    func accumulatesToOneTurn() {
        let (scrollView, recorder) = makeScrollView()
        scrollView.beginScrollGesture(atTop: false, atBottom: true)
        var delivered: CGFloat = 0
        while delivered < threshold * 3 {
            scrollView.considerTurningPage(deltaY: -20, wasAtTop: false, wasAtBottom: true)
            delivered += 20
        }
        #expect(recorder.turns == [true], "got \(recorder.turns); a flick must move one sheet")
    }

    @Test("Scrolling up at the top edge turns backward")
    func turnsBackwardAtTheTop() {
        let (scrollView, recorder) = makeScrollView()
        scrollView.beginScrollGesture(atTop: true, atBottom: false)
        for _ in 0..<20 {
            scrollView.considerTurningPage(deltaY: 20, wasAtTop: true, wasAtBottom: false)
        }
        #expect(recorder.turns == [false])
    }

    @Test("Overscroll away from an edge the content is not against is ignored")
    func mustBeAtTheEdge() {
        let (scrollView, recorder) = makeScrollView()
        scrollView.beginScrollGesture(atTop: false, atBottom: true)
        for _ in 0..<20 {
            scrollView.considerTurningPage(deltaY: -20, wasAtTop: false, wasAtBottom: false)
        }
        #expect(recorder.turns.isEmpty, "the page turned while there was still page to scroll")
    }

    @Test("A wobble at the edge never sums to a turn")
    func reversalResetsTheAccumulator() {
        let (scrollView, recorder) = makeScrollView()
        scrollView.beginScrollGesture(atTop: true, atBottom: true)
        // Alternating directions, each individually well under the threshold, repeated far
        // past it in total. Without the reversal reset these would sum and turn the page.
        for _ in 0..<20 {
            scrollView.considerTurningPage(deltaY: -20, wasAtTop: true, wasAtBottom: true)
            scrollView.considerTurningPage(deltaY: 20, wasAtTop: true, wasAtBottom: true)
        }
        #expect(recorder.turns.isEmpty, "a wobble turned the page")
    }

    @Test("A refused turn does not consume the gesture, so the end of the document rubber-bands")
    func refusedTurnDoesNotLatch() {
        let (scrollView, recorder) = makeScrollView()
        recorder.succeeds = false
        scrollView.beginScrollGesture(atTop: false, atBottom: true)
        for _ in 0..<30 {
            scrollView.considerTurningPage(deltaY: -20, wasAtTop: false, wasAtBottom: true)
        }
        // It keeps asking — it must not mark the gesture as spent on a turn that never happened.
        #expect(recorder.turns.count > 1)
        #expect(recorder.turns.allSatisfy { $0 })
    }

    @Test("With no callback wired, nothing happens and nothing crashes")
    func withoutACallback() {
        let scrollView = ZenitCanvasScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        scrollView.beginScrollGesture(atTop: false, atBottom: true)
        scrollView.considerTurningPage(deltaY: -500, wasAtTop: false, wasAtBottom: true)
    }

    // MARK: - The gesture has to begin at the edge

    @Test("Scrolling down through a zoomed-in sheet and arriving at the bottom does not turn")
    func arrivingAtTheEdgeMidGestureDoesNotTurn() {
        let (scrollView, recorder) = makeScrollView()
        // The gesture begins in the middle of a tall, zoomed-in sheet.
        scrollView.beginScrollGesture(atTop: false, atBottom: false)
        // …scrolls down through it…
        for _ in 0..<10 {
            scrollView.considerTurningPage(deltaY: -20, wasAtTop: false, wasAtBottom: false)
        }
        // …and reaches the bottom, still in the same gesture, and keeps going hard.
        for _ in 0..<30 {
            scrollView.considerTurningPage(deltaY: -20, wasAtTop: false, wasAtBottom: true)
        }
        #expect(
            recorder.turns.isEmpty,
            """
            Zoomed in, scrolling down a little must not turn the page. One continuous scroll that happens to reach the bottom must never \
            turn the page, however far it overscrolls.
            """
        )
    }

    @Test("A second gesture, begun at the edge, does turn")
    func aFreshGestureAtTheEdgeTurns() {
        let (scrollView, recorder) = makeScrollView()
        scrollView.beginScrollGesture(atTop: false, atBottom: false)
        for _ in 0..<30 {
            scrollView.considerTurningPage(deltaY: -20, wasAtTop: false, wasAtBottom: true)
        }
        #expect(recorder.turns.isEmpty)

        // Fingers up, fingers down again — this one starts at the edge.
        scrollView.endScrollGesture()
        scrollView.beginScrollGesture(atTop: false, atBottom: true)
        for _ in 0..<Int(threshold / 20) + 1 {
            scrollView.considerTurningPage(deltaY: -20, wasAtTop: false, wasAtBottom: true)
        }
        #expect(recorder.turns == [true])
    }

    @Test("With no gesture in progress nothing turns")
    func noGestureNoTurn() {
        let (scrollView, recorder) = makeScrollView()
        for _ in 0..<30 {
            scrollView.considerTurningPage(deltaY: -20, wasAtTop: false, wasAtBottom: true)
        }
        #expect(recorder.turns.isEmpty)
    }

    @Test("A gesture begun at the bottom cannot turn backward, and vice versa")
    func theEdgeTheGestureBeganAtIsTheOnlyOneItCanTurnFrom() {
        let (scrollView, recorder) = makeScrollView()
        scrollView.beginScrollGesture(atTop: false, atBottom: true)
        // Pushing up at the top, in a gesture that began at the bottom.
        for _ in 0..<30 {
            scrollView.considerTurningPage(deltaY: 20, wasAtTop: true, wasAtBottom: false)
        }
        #expect(recorder.turns.isEmpty)
    }
}
