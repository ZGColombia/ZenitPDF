import AppKit
import Foundation
import SwiftUI
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIWorkflows

/// The compare panel once claimed "No differences found" while both
/// pickers still read "Choose…". These tests pin the structural fix — a verdict requires a
/// `RevisionCompareRun`, and no run exists until a comparison actually completed.
@Suite("Compare verdict honesty", .workflowsTierSerialised)
@MainActor
struct RevisionCompareVerdictTests {

    @Test("No verdict exists before a comparison has run")
    func noRunMeansNoVerdict() {
        let model = RevisionCompareModel()
        #expect(model.latestRun == nil)
        // Without a run there is no `RevisionCompareRun` value to hand to `countSummary(for:diffs:)`,
        // so the "No differences found" sentence is unreachable — and `currentRun` returns nil
        // for every selection, chosen or not.
        #expect(model.currentRun(baseline: UUID(), comparison: UUID()) == nil)
        #expect(model.currentRun(baseline: nil, comparison: nil) == nil)
    }

    @Test("A missing selection never yields a run, even when a stale run is recorded")
    func missingSelectionYieldsNoRun() {
        let model = RevisionCompareModel()
        let baseline = UUID()
        let comparison = UUID()
        model.recordRun(RevisionCompareRun(
            baselineRevisionID: baseline,
            comparisonRevisionID: comparison,
            settings: model.settings
        ))
        #expect(model.currentRun(baseline: nil, comparison: comparison) == nil)
        #expect(model.currentRun(baseline: baseline, comparison: nil) == nil)
        #expect(model.currentRun(baseline: nil, comparison: nil) == nil)
    }

    @Test("A recorded run only stands for the exact revisions it examined")
    func runIsBoundToItsRevisions() {
        let model = RevisionCompareModel()
        let baseline = UUID()
        let comparison = UUID()
        let other = UUID()
        model.recordRun(RevisionCompareRun(
            baselineRevisionID: baseline,
            comparisonRevisionID: comparison,
            settings: model.settings
        ))
        #expect(model.currentRun(baseline: baseline, comparison: comparison) != nil)
        #expect(model.currentRun(baseline: comparison, comparison: baseline) == nil)
        #expect(model.currentRun(baseline: baseline, comparison: other) == nil)
    }

    @Test("Changing the tolerance withdraws the verdict until the core re-detects")
    func toleranceChangeWithdrawsTheVerdict() {
        let model = RevisionCompareModel()
        let baseline = UUID()
        let comparison = UUID()
        model.recordRun(RevisionCompareRun(
            baselineRevisionID: baseline,
            comparisonRevisionID: comparison,
            settings: model.settings
        ))
        #expect(model.currentRun(baseline: baseline, comparison: comparison) != nil)
        model.setTolerance(0.8)
        #expect(model.latestRun == nil)
        #expect(model.currentRun(baseline: baseline, comparison: comparison) == nil)
    }

    @Test("A run recorded at another tolerance is not presented at this one")
    func staleToleranceRunIsRejected() {
        let model = RevisionCompareModel()
        let baseline = UUID()
        let comparison = UUID()
        let staleSettings = RevisionCompareSettings(tolerance: 0.1)
        model.recordRun(RevisionCompareRun(
            baselineRevisionID: baseline,
            comparisonRevisionID: comparison,
            settings: staleSettings
        ))
        // The model's own settings are still the default 0.35, so the 0.1 run does not match.
        #expect(model.currentRun(baseline: baseline, comparison: comparison) == nil)
    }

    @Test("Invalidating a run also drops the review focus")
    func invalidationClearsFocus() {
        let model = RevisionCompareModel()
        let diff = CompareDiffSummary(
            id: UUID(),
            changeKind: .added,
            pageLabel: "A-101",
            areaInSquarePoints: 25,
            confidence: 0.9,
            isAccepted: false
        )
        model.focusDifference(id: diff.id, in: [diff])
        #expect(model.focusedDiffID == diff.id)
        model.invalidateRun()
        #expect(model.focusedDiffID == nil)
    }

    @Test("The no-differences verdict is only utterable with a run in hand")
    func verdictRequiresRunObject() {
        let model = RevisionCompareModel()
        let run = RevisionCompareRun(
            baselineRevisionID: UUID(),
            comparisonRevisionID: UUID(),
            settings: model.settings
        )
        let verdict = model.countSummary(for: run, diffs: [])
        #expect(verdict == "No differences found at this tolerance")

        // CR-200: the same sentence used to be produced when the run *did* find differences and
        // the change-type filter was hiding all of them — a verdict about the drawing delivered
        // by a checkbox in the sidebar. Old output: "No differences found at this tolerance".
        let hidden = CompareDiffSummary(
            id: UUID(),
            changeKind: .added,
            pageLabel: "A-101",
            areaInSquarePoints: 40,
            confidence: 0.8,
            isAccepted: false
        )
        model.visibleChangeKinds = [.removed]
        let filtered = model.countSummary(for: run, diffs: [hidden])
        #expect(filtered != "No differences found at this tolerance")
        #expect(filtered.contains("1"))
        #expect(filtered.lowercased().contains("filter"))
        model.visibleChangeKinds = Set(CompareChangeKind.allCases)
        let review = model.countSummary(for: run, diffs: [
            CompareDiffSummary(
                id: UUID(),
                changeKind: .modified,
                pageLabel: "A-101",
                areaInSquarePoints: 40,
                confidence: 0.8,
                isAccepted: false
            )
        ])
        #expect(review.contains("1"))
        #expect(!review.contains("No differences"))
    }
}

/// No dead ends. Every panel and mode this package ships is
/// enumerated in ``WorkflowPanelKind``; each is registered with a required exit route, `Escape`
/// backs out one level, and the exhaustive switch below refuses to compile if a new surface is
/// added without proving it takes a close action.
@Suite("Every panel has a way out", .workflowsTierSerialised)
@MainActor
struct PanelCloseTests {

    @Test("Each panel kind registers with an exit route and Escape leaves it", arguments: WorkflowPanelKind.allCases)
    func escapeLeavesEveryPanel(kind: WorkflowPanelKind) {
        let registry = ZPDFModeExitRegistry()
        var closed = false
        registry.register(kind.makeRegistration(onClose: { closed = true }))

        #expect(registry.hasActiveMode)
        #expect(registry.topmost?.id == kind.id)
        #expect(registry.exitRoute(for: kind.id) != nil)
        #expect(!(registry.topmost?.exitRoute.menuTitle.isEmpty ?? true))

        #expect(registry.escapeBacksOutOneLevel())
        #expect(closed, "The exit route of \(kind.rawValue) must actually run its close action")
        #expect(!registry.hasActiveMode)
        // With nothing left, Escape has nothing to do and says so.
        #expect(!registry.escapeBacksOutOneLevel())
    }

    /// CR-202: each panel's **rendered** Escape route runs the view's `onClose` — not the test's
    /// own closure — and each panel renders the one close button `zpdf-hit-probe` clicks (the
    /// click half: `CR202CloseScenarios.swift`; why it cannot run in `xctest` is in
    /// ``RenderedPanel``). The view is rendered off screen, in a window that is never ordered in,
    /// and Escape goes through the window's key-equivalent path. Old shape of this test: construct
    /// the view, call `close()` directly, assert `closed` — green against a view that ignored
    /// `onClose` entirely. The exhaustive `switch` stays: a new `WorkflowPanelKind` case still
    /// fails compilation here until its surface shows how it is closed.
    @Test("Every panel view's rendered Escape route runs its close action", arguments: WorkflowPanelKind.allCases)
    func everyPanelViewIsConstructibleWithClose(kind: WorkflowPanelKind) {
        let environment = MockPresenters.makeEnvironment()
        let marker = WorkflowPanelCloseButton.markerIdentifier
        /// The panel, built around the close action the harness hands it.
        let make: ((@escaping () -> Void) -> AnyView)?
        let size: NSSize

        // Exhaustive on purpose: a new WorkflowPanelKind case fails compilation here until the
        // new surface demonstrates how it is closed.
        switch kind {
        case .toolLibrary:
            size = NSSize(width: 380, height: 640)
            make = { close in
                AnyView(ToolLibraryPanelView(
                    presenter: environment.toolLibrary,
                    model: ToolLibraryEditingModel(presets: environment.project.presets),
                    onClose: close
                ))
            }
        case .search:
            // Search is the shell's navigator page (`NavigatorSearchPage`); this package ships no
            // search view since the unused `SearchPanel` was deleted (R-127). The kind stays in the
            // list because the app registers it as a mode, and its registration must still close.
            size = .zero
            make = nil
            var closed = false
            kind.makeRegistration(onClose: { closed = true }).exitRoute.performExit()
            #expect(closed, "search's registered exit route must run its close action")
        case .ocrRun:
            size = NSSize(width: 560, height: 720)
            make = { close in AnyView(OCRRunSheet(model: OCRRunModel(pages: environment.project.pages), onClose: close)) }
            // The sheet has two ways out: the header's close glyph (checked below with the
            // other panels) and the footer's Close button, which owns Escape — so the Escape
            // check below is the footer button's.
            let footer = RenderedPanel.markerCount(OCRRunSheet.footerCloseMarkerIdentifier, size: size) {
                AnyView(OCRRunSheet(model: OCRRunModel(pages: environment.project.pages), onClose: $0))
            }
            #expect(footer == 1, "the OCR footer Close button is rendered once (found \(footer))")
        case .onboarding:
            size = .zero
            make = nil
            let model = OnboardingModel(store: InMemoryOnboardingProgressStore())
            _ = OnboardingFlow(model: model)
            model.skip()
            #expect(!model.isVisible, "onboarding's Skip must take the guide away")
        case .revisionCompare:
            size = NSSize(width: 1_100, height: 760)
            make = { close in
                AnyView(RevisionCompareView(
                    presenter: environment.compare,
                    model: RevisionCompareModel(),
                    onClose: close
                ) { _ in EmptyStandInCanvas() })
            }
        case .revisionOverlay:
            size = NSSize(width: 1_100, height: 760)
            make = { close in
                AnyView(RevisionOverlayView(
                    model: RevisionOverlayModel(revisions: environment.project.revisions),
                    onClose: close
                ) { EmptyStandInCanvas() })
            }
        case .splitCanvas:
            size = NSSize(width: 900, height: 56)
            make = { close in
                AnyView(SplitCanvasControls(controller: SplitCanvasController(layout: .twoColumns), onClose: close))
            }
        case .batchApply:
            // The batch sheet closes through its model rather than through a view closure, so
            // that Cancel means "stop the batch" while one is running and "dismiss" when none
            // is — one control, two honest meanings, and no dead end either way. Its rendered
            // footer button owns Escape; pressing Escape on the rendered sheet must reach it.
            size = .zero
            make = nil
            let model = BatchApplyModel()
            var closed = 0
            model.onClose = { closed += 1 }
            model.cancel()
            #expect(closed == 1, "batch apply's Cancel must run its close action")
            let rendered = BatchApplyModel()
            var renderedCloses = 0
            rendered.onClose = { renderedCloses += 1 }
            let window = RenderedPanel.host(BatchApplySheet(model: rendered, title: "Batch Apply"), size: NSSize(width: 520, height: 640))
            defer { window.close() }
            RenderedPanel.pressEscape(in: window)
            #expect(renderedCloses == 1, "Escape on the rendered batch sheet must close it (closed \(renderedCloses))")
        }

        guard let make else { return }
        let markers = RenderedPanel.markerCount(marker, size: size, make)
        #expect(markers == 1, "\(kind.rawValue) renders exactly one panel close button (found \(markers))")
        let escape = RenderedPanel.closesOnEscape(size: size, make)
        #expect(escape == 1, "Escape on the rendered \(kind.rawValue) must run onClose once (ran \(escape))")
    }

    @Test("Escape backs out one level at a time, newest mode first")
    func escapeIsOneLevelNewestFirst() {
        let registry = ZPDFModeExitRegistry()
        var order: [String] = []
        registry.register(WorkflowPanelKind.toolLibrary.makeRegistration(onClose: { order.append("toolLibrary") }))
        registry.register(WorkflowPanelKind.revisionCompare.makeRegistration(onClose: { order.append("revisionCompare") }))

        #expect(registry.escapeBacksOutOneLevel())
        #expect(order == ["revisionCompare"])
        #expect(registry.topmost?.id == WorkflowPanelKind.toolLibrary.id)
        #expect(registry.escapeBacksOutOneLevel())
        #expect(order == ["revisionCompare", "toolLibrary"])
        #expect(!registry.hasActiveMode)
    }

    @Test("Re-registering a mode replaces it instead of stacking a duplicate")
    func reRegistrationDoesNotStack() {
        let registry = ZPDFModeExitRegistry()
        registry.register(WorkflowPanelKind.search.makeRegistration(onClose: {}))
        registry.register(WorkflowPanelKind.search.makeRegistration(onClose: {}))
        #expect(registry.modes.count == 1)
        registry.unregister(id: WorkflowPanelKind.search.id)
        #expect(!registry.hasActiveMode)
    }

    @Test("Exit-all empties the stack, for the quit path that must never be blocked")
    func exitAllEmptiesTheStack() {
        let registry = ZPDFModeExitRegistry()
        var closed: Set<String> = []
        for kind in WorkflowPanelKind.allCases {
            registry.register(kind.makeRegistration(onClose: { closed.insert(kind.id) }))
        }
        registry.exitAll()
        #expect(!registry.hasActiveMode)
        #expect(closed == Set(WorkflowPanelKind.allCases.map(\.id)))
    }
}

/// The canvas view modes: entering keeps the way back, leaving hands it over.
@Suite("Canvas view modes are dismissible", .workflowsTierSerialised)
@MainActor
struct CanvasViewModeCoordinatorTests {

    private func token(zoom: Double) -> CanvasReturnToken {
        CanvasReturnToken(
            documentID: UUID(),
            viewport: ViewportSnapshot(
                pageID: UUID(),
                pageIndex: 3,
                zoom: zoom,
                visiblePageRect: PDFRectValue(x: 100, y: 220, width: 400, height: 300)
            )
        )
    }

    @Test("Leaving a mode returns the exact token it was entered with")
    func leaveReturnsTheEntryToken() {
        let coordinator = CanvasViewModeCoordinator()
        let entry = token(zoom: 1.45)
        var restored: (mode: DismissibleCanvasMode, token: CanvasReturnToken?)?
        coordinator.onLeave = { restored = ($0, $1) }

        coordinator.enter(.revisionCompare, returning: entry)
        #expect(coordinator.isInMode)
        #expect(coordinator.activeMode == .revisionCompare)

        let returned = coordinator.leave()
        #expect(returned == entry)
        #expect(restored?.mode == .revisionCompare)
        #expect(restored?.token == entry)
        #expect(!coordinator.isInMode)
        #expect(coordinator.returnToken == nil)
    }

    @Test("Switching modes keeps the original return token")
    func modeSwitchKeepsTheOriginalToken() {
        let coordinator = CanvasViewModeCoordinator()
        let original = token(zoom: 0.12)
        coordinator.enter(.splitCanvas, returning: original)
        coordinator.enter(.revisionOverlay, returning: token(zoom: 4.0))
        #expect(coordinator.activeMode == .revisionOverlay)
        #expect(coordinator.leave() == original)
    }

    @Test("Leaving with no mode active does nothing and reports nothing")
    func leaveWithoutModeIsHarmless() {
        let coordinator = CanvasViewModeCoordinator()
        var leaveCount = 0
        coordinator.onLeave = { _, _ in leaveCount += 1 }
        #expect(coordinator.leave() == nil)
        #expect(leaveCount == 0)
    }

    @Test("Every dismissible mode has an English display name")
    func everyModeIsNameable() {
        for mode in DismissibleCanvasMode.allCases {
            #expect(!mode.displayName.isEmpty)
        }
    }
}

/// A canvas stand-in for view-construction tests.
private struct EmptyStandInCanvas: View {
    var body: some View { Color.clear }
}
