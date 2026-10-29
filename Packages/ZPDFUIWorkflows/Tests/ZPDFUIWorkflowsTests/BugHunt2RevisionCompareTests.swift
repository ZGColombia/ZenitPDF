import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIWorkflows

// MARK: - Revision Compare (bug hunt 2)

/// BH-055, BH-309, BH-836, BH-837, BH-838, IM-032 and IM-033: the compare review model under
/// a tolerance drag, a change filter and keyboard review.
@Suite("Revision Compare review, bug hunt 2", .workflowsTierSerialised)
@MainActor
struct BugHunt2RevisionCompareTests {

    private func diff(_ kind: CompareChangeKind, area: Double, accepted: Bool = false) -> CompareDiffSummary {
        CompareDiffSummary(
            id: UUID(),
            changeKind: kind,
            pageLabel: "A-101",
            areaInSquarePoints: area,
            confidence: 0.9,
            isAccepted: accepted
        )
    }

    private func recordedModel() -> (RevisionCompareModel, UUID, UUID) {
        let model = RevisionCompareModel()
        let baseline = UUID()
        let comparison = UUID()
        model.recordRun(RevisionCompareRun(
            baselineRevisionID: baseline,
            comparisonRevisionID: comparison,
            settings: model.settings
        ))
        return (model, baseline, comparison)
    }

    // MARK: BH-055 / IM-032

    /// Old output: after the first drag tick `currentRun` was `nil` (the run was withdrawn on
    /// every tick) and `onSettingsChange` had fired once per tick — 20 detections for one drag,
    /// and the slider unmounted under the cursor.
    @Test("A tolerance drag keeps the run and commits once on release")
    func toleranceDragCommitsOnce() {
        let (model, baseline, comparison) = recordedModel()
        var deliveries: [Double] = []
        model.onSettingsChange = { deliveries.append($0.tolerance) }

        model.setAdjustingTolerance(true)
        for step in 1...20 {
            model.previewTolerance(Double(step) / 20)
            #expect(model.currentRun(baseline: baseline, comparison: comparison) != nil)
            #expect(model.displayedTolerance == Double(step) / 20)
        }
        #expect(deliveries.isEmpty)
        #expect(model.settings.tolerance == 0.35)

        model.setAdjustingTolerance(false)
        #expect(deliveries == [1.0])
        #expect(model.settings.tolerance == 1.0)
        #expect(model.toleranceDraft == nil)
        #expect(model.currentRun(baseline: baseline, comparison: comparison) == nil)
    }

    @Test("A value outside a drag (keyboard step) commits at once")
    func keyboardStepCommitsImmediately() {
        let (model, _, _) = recordedModel()
        var deliveries: [Double] = []
        model.onSettingsChange = { deliveries.append($0.tolerance) }
        model.previewTolerance(0.5)
        #expect(deliveries == [0.5])
        #expect(model.settings.tolerance == 0.5)
    }

    @Test("Releasing without moving commits nothing")
    func releaseWithoutMoveIsFree() {
        let (model, baseline, comparison) = recordedModel()
        var count = 0
        model.onSettingsChange = { _ in count += 1 }
        model.setAdjustingTolerance(true)
        model.setAdjustingTolerance(false)
        #expect(count == 0)
        #expect(model.currentRun(baseline: baseline, comparison: comparison) != nil)
    }

    // MARK: BH-836

    /// Old output: with five visible and nothing focused, Previous landed on position 4.
    @Test("Previous with nothing focused lands on the last difference")
    func previousFromUnfocusedLandsOnLast() {
        let model = RevisionCompareModel()
        let diffs = (1...5).map { diff(.added, area: Double($0)) }
        model.focusPreviousDifference(in: diffs)
        #expect(model.focusedPosition(in: diffs) == 5)

        let two = RevisionCompareModel()
        let pair = [diff(.added, area: 2), diff(.removed, area: 1)]
        two.focusPreviousDifference(in: pair)
        #expect(two.focusedPosition(in: pair) == 2)

        let next = RevisionCompareModel()
        next.focusNextDifference(in: diffs)
        #expect(next.focusedPosition(in: diffs) == 1)
    }

    // MARK: BH-837

    /// Old output: `counts[.added] == nil` once Added was hidden, so the badge read "Added 0"
    /// beside a header saying seven were hidden.
    @Test("The legend counts a hidden type instead of reporting zero")
    func legendCountsHiddenTypes() {
        let model = RevisionCompareModel()
        let diffs = (1...7).map { diff(.added, area: Double($0)) } + [diff(.modified, area: 1)]
        model.visibleChangeKinds = [.modified]
        #expect(model.counts(from: diffs)[.added] == 7)
        #expect(model.counts(from: diffs)[.modified] == 1)
        #expect(model.visibleDiffs(from: diffs).count == 1)
    }

    // MARK: BH-838

    /// Old output: the binding setter silently reassigned the old set; nothing told the person
    /// the last type cannot be hidden.
    @Test("The last shown change type refuses to hide, and says so")
    func lastShownKindCannotHide() {
        let model = RevisionCompareModel()
        #expect(model.setChangeKind(.added, visible: false))
        #expect(model.setChangeKind(.removed, visible: false))
        #expect(model.visibleChangeKinds == [.modified])
        #expect(!model.canHideChangeKind(.modified))
        #expect(!model.setChangeKind(.modified, visible: false))
        #expect(model.visibleChangeKinds == [.modified])
        #expect(model.canHideChangeKind(.added))
        #expect(model.setChangeKind(.added, visible: true))
        #expect(model.canHideChangeKind(.modified))
        #expect(!CompareLegend.lastShownExplanation.isEmpty)
    }

    // MARK: BH-309

    /// Old output: Accept All called `presenter.acceptAllDiffs()`, which accepted all ten
    /// pending diffs including the seven hidden by the filter.
    @Test("Accept All under a filter accepts only the shown, pending differences")
    func acceptAllRespectsFilter() {
        let model = RevisionCompareModel()
        let shown = (1...3).map { diff(.added, area: Double($0)) }
        let alreadyAccepted = diff(.added, area: 9, accepted: true)
        let hidden = (1...7).map { diff(.removed, area: Double($0)) }
        model.visibleChangeKinds = [.added]
        let ids = Set(model.pendingVisibleDiffIDs(in: shown + [alreadyAccepted] + hidden))
        #expect(ids == Set(shown.map(\.id)))
        #expect(ids.count == 3)
    }

    // MARK: IM-033

    @Test("Accept on the focused difference decides it and advances the focus")
    func reviewFocusedDifferenceAdvances() {
        let model = RevisionCompareModel()
        let diffs = [diff(.added, area: 30), diff(.removed, area: 20), diff(.modified, area: 10)]
        var decided: [CompareDiffSummary.ID] = []
        #expect(!model.reviewFocusedDifference(in: diffs) { decided.append($0) })
        #expect(decided.isEmpty)

        model.focusNextDifference(in: diffs)
        #expect(model.focusedPosition(in: diffs) == 1)
        #expect(model.reviewFocusedDifference(in: diffs) { decided.append($0) })
        #expect(decided == [diffs[0].id])
        #expect(model.focusedPosition(in: diffs) == 2)
        #expect(model.focusedDiff(in: diffs)?.id == diffs[1].id)
    }
}

// MARK: - Tool preset parameter fields (bug hunt 2)

/// BH-056 and BH-057: the editor's length field and the JSON reader under hostile input.
@Suite("Tool preset fields and JSON reading, bug hunt 2", .workflowsTierSerialised)
struct BugHunt2ToolPresetInputTests {

    /// Old output: `shouldParse("")` returned `false` after `didRender("")` and a keystroke,
    /// because the keystroke reset the remembered rendering to `""` instead of forgetting it —
    /// the draft kept 0.25 m behind a blank field.
    @Test("Clearing a length field after typing parses the empty text and clears the draft")
    func clearingAfterTypingParses() {
        var echo = ToolPresetLengthField.EchoState()
        echo.didRender("")
        let typed = echo.shouldParse("0.25")
        #expect(typed)
        let cleared = echo.shouldParse("")
        #expect(cleared)
        #expect(ToolPresetLengthField.quantity(from: "", unit: .metre) == nil)
        #expect(ToolPresetLengthField.quantity(from: "0.25", unit: .metre)?.value == Decimal(string: "0.25"))
    }

    @Test("A rendering fed back through onChange is still skipped")
    func renderingIsNotReparsed() {
        var echo = ToolPresetLengthField.EchoState()
        echo.didRender("0.656168")
        let echoed = echo.shouldParse("0.656168")
        #expect(!echoed)
        let edited = echo.shouldParse("0.65616")
        #expect(edited)
        echo.didRender("")
        let renderedEmpty = echo.shouldParse("")
        #expect(!renderedEmpty)
    }

    /// Old output: a fatal error ("Double value cannot be converted to Int because the result
    /// would be greater than Int.max") on `Int(value)` for 2^63.
    @Test("intValue answers nil for 2^63 instead of trapping")
    func intValueSurvivesTwoToTheSixtyThree() throws {
        let data = Data(#"{"schemaVersion": 9223372036854775807, "pixelWidth": 9223372036854775808, "ok": 12}"#.utf8)
        let root = try ToolSetJSONValue.parse(data)
        #expect(root["schemaVersion"]?.intValue == nil)
        #expect(root["pixelWidth"]?.intValue == nil)
        #expect(root["ok"]?.intValue == 12)
        #expect(ToolSetJSONValue.number(-9223372036854775808).intValue == Int.min)
        #expect(ToolSetJSONValue.number(1.5).intValue == nil)
    }
}
