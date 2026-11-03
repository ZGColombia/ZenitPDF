import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIWorkflows

/// BH-308, BH-835, BH-840, BH-841, BH-842 and IM-147: the overlay's alignment and layer rules.
@Suite("Revision Overlay, bug hunt 2", .workflowsTierSerialised)
@MainActor
struct BugHunt2RevisionOverlayTests {

    private func revision(_ name: String) -> RevisionSummary {
        RevisionSummary(
            id: UUID(), documentID: UUID(), name: name, revisionLabel: "Rev \(name)", author: "",
            pageCount: 1, colorRGBA: ColorRGBA.Zenit.Dark.cyan, fileName: "\(name).pdf"
        )
    }

    private func pair(_ bx: Double, _ by: Double, _ cx: Double, _ cy: Double) -> RevisionAlignmentPointPair {
        RevisionAlignmentPointPair(
            baselinePoint: PDFPointValue(x: bx, y: by),
            comparisonPoint: PDFPointValue(x: cx, y: cy)
        )
    }

    /// Old output: `.success` with a = b = c = d = 0, residual 0 — "Exact fit", "Scale 0.0000".
    @Test("Coincident baseline points are refused, not fitted to a zero scale")
    func coincidentBaselineIsRefused() {
        let result = RevisionAlignmentSolver.similarity(pairs: [pair(50, 50, 0, 0), pair(50, 50, 100, 0)])
        #expect(result == .failure(.pointsCoincide))
        let model = RevisionOverlayModel(revisions: [revision("A"), revision("B")])
        model.capturePair(baseline: PDFPointValue(x: 50, y: 50), comparison: PDFPointValue(x: 0, y: 0))
        model.capturePair(baseline: PDFPointValue(x: 50, y: 50), comparison: PDFPointValue(x: 100, y: 0))
        #expect(model.fit == nil)
        if case .failed = model.alignmentState {} else { Issue.record("coincident points are a real failure") }
    }

    /// Old output: `.manualTwoPoint(residualPixels: 0.5)` for a 0.5 pt residual at 2 px/pt.
    @Test("The residual is reported in pixels, converted from points")
    func residualIsConvertedToPixels() throws {
        let fit = RevisionAlignmentFit(
            transform: RevisionAlignmentTransform(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0),
            residualRMSPoints: 0.5, maximumResidualPoints: 0.7, pairCount: 3, mode: .twoPoint
        )
        #expect(fit.alignmentState(pixelsPerPoint: 2) == .manualTwoPoint(residualPixels: 1.0))
        #expect(fit.alignmentState(pixelsPerPoint: .nan) == .manualTwoPoint(residualPixels: 0.5))

        let model = RevisionOverlayModel(revisions: [revision("A"), revision("B")])
        model.pixelsPerPoint = 3
        model.capturePair(baseline: PDFPointValue(x: 0, y: 0), comparison: PDFPointValue(x: 0, y: 0))
        model.capturePair(baseline: PDFPointValue(x: 100, y: 0), comparison: PDFPointValue(x: 50, y: 0))
        model.capturePair(baseline: PDFPointValue(x: 0, y: 101), comparison: PDFPointValue(x: 0, y: 50))
        let rms = try #require(model.fit?.residualRMSPoints)
        #expect(rms > 0)
        #expect(model.alignmentState == .manualTwoPoint(residualPixels: rms * 3))
    }

    /// Old output: `.failed(reason: "Mark 2 matching points…")` the moment the mode opened.
    @Test("No points marked is not aligned, not a failed automatic alignment")
    func nothingMarkedIsNotAligned() {
        let model = RevisionOverlayModel(revisions: [revision("A"), revision("B")])
        #expect(model.alignmentState == .notAligned)
        model.capturePair(baseline: PDFPointValue(x: 0, y: 0), comparison: PDFPointValue(x: 0, y: 0))
        #expect(model.alignmentState == .notAligned)
    }

    /// Old output: with three layers and one hidden the note still said one fit registers
    /// several sheets; with none visible the inspector said "Only one layer is visible".
    @Test("Layer notes count visible layers, and say 'one' only for one")
    func notesCountVisibleLayers() {
        let model = RevisionOverlayModel(revisions: [revision("A"), revision("B"), revision("C")])
        #expect(model.alignmentAppliesToSeveralSheets)
        model.setVisible(false, forLayer: model.layers[2].id)
        #expect(!model.alignmentAppliesToSeveralSheets)
        #expect(!model.showsSingleVisibleLayerNote)
        model.setVisible(false, forLayer: model.layers[1].id)
        #expect(model.showsSingleVisibleLayerNote)
        model.setVisible(false, forLayer: model.layers[0].id)
        #expect(!model.showsSingleVisibleLayerNote, "none visible is not 'only one visible'")
    }

    /// Old output: 30 slider ticks produced 30 `onLayersChange` calls — 30 composites.
    ///
    /// The bound comes from the contract, not from this machine's speed: two notifications are
    /// at least one interval apart, so a drag that lasted `elapsed` sends at most one per whole
    /// interval plus the first tick's, and the trailing flush adds one more. A slow runner
    /// stretches `elapsed`, and the bound with it; `dragWithinOneIntervalSendsOnce` checks the
    /// coalescing itself without a clock.
    @Test("An opacity drag is coalesced and the final value always arrives")
    func opacityDragIsCoalesced() async throws {
        let model = RevisionOverlayModel(revisions: [revision("A"), revision("B")])
        var delivered: [Double] = []
        model.onLayersChange = { layers in delivered.append(layers[0].opacity) }
        let id = model.layers[0].id
        let interval = model.opacityNotifyInterval
        #expect(interval == .milliseconds(100))
        let clock = ContinuousClock()
        let start = clock.now
        for tick in 1...30 {
            model.setOpacity(Double(tick) / 30, forLayer: id)
            try await Task.sleep(for: .milliseconds(10))
        }
        let elapsed = clock.now - start
        for _ in 0..<100 where delivered.last != 1.0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.layers[0].opacity == 1.0, "the layer follows every tick")
        #expect(delivered.last == 1.0, "the final value is delivered")
        #expect(delivered.count <= Int(elapsed / interval) + 2, "at most one composite per interval")
        #expect(Set(delivered).count == delivered.count, "no opacity is sent to the compositor twice")
        print("IM-147 measurement: 30 ticks over \(elapsed) -> \(delivered.count) composite requests")

        // Releasing the slider flushes at once.
        model.setOpacity(0.2, forLayer: id)
        model.setOpacity(0.3, forLayer: id)
        model.flushOpacityChange()
        #expect(delivered.last == 0.3)
    }

    /// The coalescing without a clock: a whole drag inside one interval reaches the compositor
    /// as its first tick and, on release, its last (IM-147).
    @Test("A drag inside one interval sends its first tick and, on release, its last")
    func dragWithinOneIntervalSendsOnce() {
        let model = RevisionOverlayModel(revisions: [revision("A"), revision("B")])
        model.opacityNotifyInterval = .seconds(3_600)
        var delivered: [Double] = []
        model.onLayersChange = { layers in delivered.append(layers[0].opacity) }
        let id = model.layers[0].id
        for tick in 1...30 {
            model.setOpacity(Double(tick) / 30, forLayer: id)
        }
        #expect(delivered == [1.0 / 30])
        model.flushOpacityChange()
        #expect(delivered == [1.0 / 30, 1.0])
    }

    /// Old output: [0.1, 0.3, 0.3] and then [.., 0.4, 0.5, 0.5]. A tick that came after the interval
    /// while the timed flush was still waiting for the main actor was sent at once, and the
    /// waiting flush sent it again — when its timer fired, or when the slider was released.
    /// Holding the main actor past the interval makes that order certain on any machine; a slow
    /// runner hit it every few ticks (IM-147).
    @Test("A tick after the interval cancels the flush that is still waiting")
    func lateFlushDoesNotDeliverTwice() async throws {
        let model = RevisionOverlayModel(revisions: [revision("A"), revision("B")])
        var delivered: [Double] = []
        model.onLayersChange = { layers in delivered.append(layers[0].opacity) }
        let id = model.layers[0].id
        let interval = model.opacityNotifyInterval
        let clock = ContinuousClock()
        func holdMainActor() {
            let until = clock.now + interval
            while clock.now < until {}
        }

        // The timer: the waiting flush fires after the tick that superseded it.
        model.setOpacity(0.1, forLayer: id)
        model.setOpacity(0.2, forLayer: id)
        holdMainActor()
        model.setOpacity(0.3, forLayer: id)
        try await Task.sleep(for: interval * 3)
        #expect(delivered.last == 0.3, "the latest value is delivered")
        #expect(Set(delivered).count == delivered.count, "no opacity is sent to the compositor twice")

        // The release: the slider ends the drag while a superseded flush is still waiting.
        model.setOpacity(0.4, forLayer: id)
        model.setOpacity(0.45, forLayer: id)
        holdMainActor()
        model.setOpacity(0.5, forLayer: id)
        model.flushOpacityChange()
        #expect(delivered.last == 0.5, "the latest value is delivered")
        #expect(Set(delivered).count == delivered.count, "no opacity is sent to the compositor twice")
    }
}

/// BH-307: nothing in a document-window overlay claims the window's Return key. (BH-306's error
/// card was deleted with the unused SwiftUI error presenter, R-128.)
@Suite("Overlay keyboard, bug hunt 2", .workflowsTierSerialised)
@MainActor
struct BugHunt2OverlayKeyboardTests {

    /// Old output: the onboarding action button carried `.keyboardShortcut(.defaultAction)`.
    @Test("The onboarding corner card does not claim Return")
    func onboardingDoesNotClaimReturn() {
        let model = OnboardingModel(store: InMemoryOnboardingProgressStore())
        #expect(!OnboardingFlow(model: model).claimsReturnKey)
        #expect(OnboardingFlow(model: model, claimsReturnKey: true).claimsReturnKey)
    }
}
