import CoreGraphics
import Foundation
import Observation
import ZPDFCompare
import ZPDFUIPresentation

/// `ComparePresenting` over `ZPDFCompare`.
///
/// A comparison is the longest operation in the product — two page rasterisations, an
/// alignment solve and a diff pass — so it runs as a cancellable ``OperationHandle`` with
/// progress, and the presenter shows the previous result until a new one is complete
/// rather than blanking the review pane while it works.
///
/// The engine reports two independent signals, raster and vector, and keeps them in
/// separate fields. They are concatenated here into one review list because that is what
/// the UI shows, but each difference keeps the signal it came from: a pixel finding is
/// never presented as a statement about geometry.
@MainActor
@Observable
public final class AppComparePresenter: ComparePresenting {

    // MARK: Published state

    public private(set) var revisions: [RevisionSummary] = []
    public private(set) var baselineRevisionID: RevisionSummary.ID?
    public private(set) var comparisonRevisionID: RevisionSummary.ID?
    public private(set) var diffs: [CompareDiffSummary] = []
    public private(set) var overlayOpacity: Double = 0.5
    public private(set) var overlayBlendMode: RevisionOverlayBlendMode = .multiply
    public private(set) var alignmentState: RevisionAlignmentState = .notAligned
    public private(set) var splitCanvasMode: SplitCanvasMode = .vertical
    public private(set) var isBlinking: Bool = false
    public private(set) var isPageSyncEnabled: Bool = true
    public private(set) var isZoomSyncEnabled: Bool = true

    /// The running comparison, so the UI can show progress and cancel it.
    public private(set) var operation: OperationHandle?

    /// What the review must say about how the standing result was produced, or `nil` when it
    /// was produced as asked. Today: a sheet too large for the raster budget is compared at a
    /// reduced resolution (R-156), where the detector's pixel thresholds drop proportionally
    /// larger changes. Before S-102 the comparator reported it and nothing showed it.
    public private(set) var resultNote: String?

    /// How fussy detection is: `0` reports every speck, `1` only substantial changes.
    ///
    /// Mirrors the review pane's tolerance, in the pane's own units rather than in
    /// `RasterDiffTolerance`'s: `ZPDFUIWorkflows` sits above this package and cannot be
    /// imported here, so the number crosses the seam as a plain fraction and is translated
    /// into engine options by ``rasterOptions`` at the moment a comparison is built.
    public private(set) var detectionTolerance: Double = 0.35

    /// The smallest region worth reporting, in square PDF points. Regions below it are
    /// dropped from the review list rather than shown and then ignored.
    public private(set) var minimumRegionAreaPoints: Double = 12

    /// Called when a difference is accepted, with the markup it should become. The
    /// environment routes it through the command bus, so promoting a diff is undoable like
    /// any other markup.
    public var onPromoteDiff: (@MainActor (CompareDiffSummary) -> Void)?

    // MARK: Private state

    private let comparator: RevisionComparator
    private var pageReferences: [RevisionSummary.ID: RevisionPageReference] = [:]

    /// The comparison in flight, or `nil`.
    ///
    /// Public so the caller that *started* a comparison can await the one it asked for.
    /// Without it the review pane's tolerance slider had no way to know when the
    /// re-detection it triggered had finished, so it could not record the run that makes a
    /// verdict presentable, and a verdict that cannot be recorded is a slider that empties
    /// the review and leaves it empty.
    @ObservationIgnored public private(set) var compareTask: Task<Void, Never>?

    /// Creates a presenter over a comparator.
    public init(comparator: RevisionComparator) {
        self.comparator = comparator
    }

    /// Installs the revisions available for comparison and the page each one points at.
    public func setRevisions(
        _ revisions: [RevisionSummary],
        pages: [RevisionSummary.ID: RevisionPageReference]
    ) {
        self.revisions = revisions
        pageReferences = pages
        // A selection the new list no longer holds is dropped, and the standing result with it.
        // It used to survive, so the pane showed an old comparison and Compare returned silently
        // on the missing page reference (BH-444).
        let known = Set(revisions.map(\.id))
        if let baseline = baselineRevisionID, !known.contains(baseline) { baselineRevisionID = nil }
        if let comparison = comparisonRevisionID, !known.contains(comparison) { comparisonRevisionID = nil }
        if baselineRevisionID == nil { baselineRevisionID = revisions.first(where: \.isBaseline)?.id }
        if comparisonRevisionID == nil {
            comparisonRevisionID = revisions.first { $0.id != baselineRevisionID }?.id
        }
        invalidateComparison()
    }

    /// Adds one revision — the drag-and-drop path, where a dropped
    /// drawing becomes a new revision of the current document so Revision Compare has
    /// something to compare against.
    ///
    /// Adding an id that is already installed replaces its registration. The first baseline
    /// and the first non-baseline become the default selection, and any previous comparison
    /// result is invalidated rather than left standing against the new list.
    public func addRevision(_ summary: RevisionSummary, page: RevisionPageReference) {
        revisions.removeAll { $0.id == summary.id }
        revisions.append(summary)
        pageReferences[summary.id] = page
        if baselineRevisionID == nil, summary.isBaseline { baselineRevisionID = summary.id }
        if comparisonRevisionID == nil, !summary.isBaseline { comparisonRevisionID = summary.id }
        invalidateComparison()
    }

    // MARK: ComparePresenting

    public func setBaseline(id: RevisionSummary.ID) {
        guard revisions.contains(where: { $0.id == id }) else { return }
        baselineRevisionID = id
        if comparisonRevisionID == id { comparisonRevisionID = revisions.first { $0.id != id }?.id }
        invalidateComparison()
    }

    public func setComparison(id: RevisionSummary.ID) {
        guard revisions.contains(where: { $0.id == id }) else { return }
        comparisonRevisionID = id
        if baselineRevisionID == id { baselineRevisionID = revisions.first { $0.id != id }?.id }
        invalidateComparison()
    }

    public func swapRevisions() {
        let baseline = baselineRevisionID
        baselineRevisionID = comparisonRevisionID
        comparisonRevisionID = baseline
        invalidateComparison()
    }

    public func setOverlayOpacity(_ opacity: Double) {
        overlayOpacity = min(1, max(0, opacity))
    }

    public func setOverlayBlendMode(_ mode: RevisionOverlayBlendMode) {
        overlayBlendMode = mode
    }

    /// Turns blinking on or off.
    ///
    /// Revision Compare offers no blink control, and this package cannot read the system's
    /// Reduce Motion setting: a view that offers blinking gates it by Reduce Motion before it
    /// calls this, as the Revision Overlay's does (`RevisionOverlayModel.setBlinking(_:reduceMotion:)`).
    /// The flag that stood in for it here was never set outside tests (R-063).
    public func setBlinking(_ enabled: Bool) {
        isBlinking = enabled
    }

    /// Sets how fussy detection is and withdraws the standing result.
    ///
    /// The result is invalidated rather than kept: a difference list computed at the old
    /// tolerance says nothing about the new one, and leaving it on screen under a moved
    /// slider is the exact silent wrongness `CORE_LOOP.md` lists. Returns `true` when
    /// anything actually changed, so a caller can skip a re-detection it does not need.
    @discardableResult
    public func setDetection(tolerance: Double, minimumRegionAreaPoints area: Double) -> Bool {
        let clampedTolerance = min(1, max(0, tolerance))
        let clampedArea = max(0, area)
        guard clampedTolerance != detectionTolerance || clampedArea != minimumRegionAreaPoints
        else { return false }
        detectionTolerance = clampedTolerance
        minimumRegionAreaPoints = clampedArea
        invalidateComparison()
        return true
    }

    /// The engine options the current tolerance means.
    ///
    /// The intensity threshold is `2 + tolerance * 30`, written here and only here (the review
    /// pane's unused copy was removed in U-068), so the sentence the pane prints
    /// under the slider describes what the detector is about to do rather than something
    /// adjacent to it.
    public var rasterOptions: RasterDiffOptions {
        RasterDiffOptions(
            tolerance: RasterDiffTolerance(
                intensityTolerance: Int((2 + detectionTolerance * 30).rounded()),
                minimumRegionPixelCount: RasterDiffTolerance.standard.minimumRegionPixelCount,
                groupingRadiusPixels: RasterDiffTolerance.standard.groupingRadiusPixels,
                usesEightConnectivity: RasterDiffTolerance.standard.usesEightConnectivity,
                borderMarginPixels: RasterDiffTolerance.standard.borderMarginPixels
            )
        )
    }

    public func setSplitCanvasMode(_ mode: SplitCanvasMode) { splitCanvasMode = mode }
    public func setPageSyncEnabled(_ enabled: Bool) { isPageSyncEnabled = enabled }
    public func setZoomSyncEnabled(_ enabled: Bool) { isZoomSyncEnabled = enabled }

    public func acceptDiff(id: CompareDiffSummary.ID) {
        guard let index = diffs.firstIndex(where: { $0.id == id }) else { return }
        diffs[index].isAccepted = true
        onPromoteDiff?(diffs[index])
    }

    public func rejectDiff(id: CompareDiffSummary.ID) {
        diffs.removeAll { $0.id == id }
    }

    public func acceptAllDiffs() {
        for index in diffs.indices where !diffs[index].isAccepted {
            diffs[index].isAccepted = true
            onPromoteDiff?(diffs[index])
        }
    }

    // MARK: Running a comparison

    /// Cancels any running comparison and clears the review list.
    public func invalidateComparison() {
        compareTask?.cancel()
        compareTask = nil
        operation?.cancel()
        operation = nil
        diffs = []
        alignmentState = .notAligned
        resultNote = nil
    }

    /// Runs the comparison between the selected revisions.
    ///
    /// Cancellable throughout: the handle's `cancel()` cancels the task, and the comparator
    /// observes `Task.isCancelled` at its own checkpoints. A cancelled comparison leaves
    /// the review list empty rather than half-populated.
    public func compare(renderScale: Double = 2) {
        guard let baselineID = baselineRevisionID, let comparisonID = comparisonRevisionID,
              let baseline = pageReferences[baselineID], let revised = pageReferences[comparisonID]
        else { return }

        compareTask?.cancel()
        let handle = OperationHandle(
            title: NSLocalizedString("Comparing revisions", comment: "Progress title for a revision compare")
        )
        operation = handle

        let comparator = self.comparator
        let request = RevisionCompareRequest(
            baseline: baseline,
            revised: revised,
            renderScale: renderScale,
            raster: rasterOptions
        )
        let pageLabel = revisions.first { $0.id == comparisonID }?.revisionLabel ?? ""
        let minimumArea = minimumRegionAreaPoints

        let task = Task { [weak self] in
            let sink = ProgressSink(handle: handle)
            sink(OperationProgress(stage: .reading, detail: baseline.label))
            do {
                sink(OperationProgress(stage: .working, fraction: 0.3, detail: revised.label))
                let result = try await comparator.compare(request)
                guard !Task.isCancelled else {
                    sink(.cancelled)
                    return
                }
                sink(OperationProgress(stage: .finishing, fraction: 0.9))
                guard !Task.isCancelled else {
                    sink(.cancelled)
                    return
                }
                sink(.completed)
                // The task is the presenter's, so it already runs on the main actor: the check
                // above and this call are one uninterrupted step. `await MainActor.run` was a
                // suspension point between them, where a replaced comparison could cancel this
                // task and clear the list, and `present` then filled it for the old pair (T-028).
                self?.present(result, pageLabel: pageLabel, minimumArea: minimumArea)
            } catch is CancellationError {
                sink(.cancelled)
            } catch {
                // A comparison replaced while it failed says nothing about the new pair.
                guard !Task.isCancelled else {
                    sink(.cancelled)
                    return
                }
                sink(OperationProgress(stage: .failed, detail: String(describing: error)))
                self?.apply(
                    diffs: [],
                    alignment: .failed(reason: String(describing: error)),
                    note: nil
                )
            }
        }
        compareTask = task
        handle.attach(cancelling: task)
    }

    /// Publishes a finished comparison: its review list, its registration and its note.
    func present(_ result: RevisionComparisonResult, pageLabel: String, minimumArea: Double) {
        apply(
            diffs: CompareBridge.diffs(of: result, pageLabel: pageLabel, minimumAreaInSquarePoints: minimumArea),
            alignment: CompareBridge.alignmentState(of: result),
            note: CompareBridge.note(of: result)
        )
    }

    private func apply(diffs: [CompareDiffSummary], alignment: RevisionAlignmentState, note: String?) {
        self.diffs = diffs
        alignmentState = alignment
        resultNote = note
    }
}

/// Converts comparison results into the review list's vocabulary.
public enum CompareBridge {

    /// The differences a review pane lists, largest first.
    ///
    /// Ordered by page area rather than by pixel count: a thin long line and a small dense
    /// blob can have the same changed-pixel count, and the estimator cares which one covers
    /// more of the drawing.
    /// - Parameter minimumAreaInSquarePoints: regions smaller than this are left out of the
    ///   review list entirely. The review pane's "smallest region worth reporting" control
    ///   sets it; `0`, the default, reports everything the engine found.
    public static func diffs(
        of result: RevisionComparisonResult,
        pageLabel: String,
        minimumAreaInSquarePoints: Double = 0
    ) -> [CompareDiffSummary] {
        result.allRegions
            .filter { Double($0.pageBounds.width * $0.pageBounds.height) >= minimumAreaInSquarePoints }
            .sorted { $0.pageBounds.width * $0.pageBounds.height > $1.pageBounds.width * $1.pageBounds.height }
            .map { region in
                CompareDiffSummary(
                    id: UUID(),
                    changeKind: changeKind(region.classification),
                    baselinePageID: nil,
                    comparisonPageID: nil,
                    pageLabel: pageLabel,
                    baselineBounds: rect(region.pageBounds),
                    comparisonBounds: rect(region.pageBounds),
                    areaInSquarePoints: Double(region.pageBounds.width * region.pageBounds.height),
                    confidence: region.confidence,
                    isAccepted: false
                )
            }
    }

    /// Everything a finished comparison has to say beside its list: a reduced resolution and a
    /// refused geometry pass, in that order, or `nil` when neither applies.
    public static func note(of result: RevisionComparisonResult) -> String? {
        let notes = [resolutionNote(of: result), vectorRefusalNote(of: result)].compactMap { $0 }
        return notes.isEmpty ? nil : notes.joined(separator: " ")
    }

    /// The sentence a review shows when the geometry pass was refused and the rendered pages
    /// decided alone (U-078): a sheet over the geometry diff's primitive limit, or one whose
    /// geometry could not be read. `nil` when the pass ran or was not asked for.
    public static func vectorRefusalNote(of result: RevisionComparisonResult) -> String? {
        switch result.vector?.refusal {
        case nil:
            return nil
        case let .primitiveBudgetExceeded(count, limit)?:
            return String(
                format: NSLocalizedString(
                    "Compared as rendered pages only: a sheet has %1$ld drawn elements, more than the %2$ld the geometry comparison can check.",
                    comment: "Revision Compare note when the geometry comparison was skipped for a dense sheet; element count and limit"),
                count, limit)
        case .extractionFailed?, .other?:
            return NSLocalizedString(
                "Compared as rendered pages only: the geometry of a sheet could not be read.",
                comment: "Revision Compare note when the geometry comparison was skipped because a sheet could not be scanned")
        }
    }

    /// The sentence a review shows when the sheet was compared below the requested resolution,
    /// or `nil` when it was compared as asked. The percentage is the linear scale actually
    /// rendered over the scale requested — the coarser of the two sheets' scales, since each is
    /// fitted to the budget on its own (R-156, V-080).
    public static func resolutionNote(of result: RevisionComparisonResult) -> String? {
        let rendered = result.effectiveRenderScale
        guard result.isResolutionReduced, result.requestedRenderScale > 0,
              rendered.isFinite, result.requestedRenderScale.isFinite else { return nil }
        let percent = Int((rendered / result.requestedRenderScale * 100).rounded())
        return String(
            format: NSLocalizedString(
                "Compared at %d%% of the requested resolution: this sheet is too large to render in full, so small changes may be missed.",
                comment: "Revision Compare note when a sheet over the raster budget was compared at a reduced resolution; percentage of the requested scale"),
            percent)
    }

    static func changeKind(_ classification: DifferenceClassification) -> CompareChangeKind {
        switch classification {
        case .added: .added
        case .removed: .removed
        case .changed, .unchanged: .modified
        }
    }

    static func rect(_ rect: CGRect) -> PDFRectValue {
        PDFRectValue(
            x: Double(rect.origin.x),
            y: Double(rect.origin.y),
            width: Double(rect.size.width),
            height: Double(rect.size.height)
        )
    }

    /// How the two revisions were brought into register, with the error figure the UI shows.
    ///
    /// For a point solve that figure is the page-point residual, in rendered pixels. For a
    /// Vision alignment it is the mean absolute gray-level difference after the transform
    /// (CR-131): Vision solves no correspondences, so its page-point residual is `.zero` by
    /// construction, and reporting it would show every automatic alignment as exact.
    ///
    /// An alignment that Vision proposed and the comparator rejected is reported as
    /// *failed with a reason*, not as "not aligned": the user has to know a registration
    /// was attempted and refused, because comparing unregistered sheets produces a review
    /// list that is entirely noise.
    public static func alignmentState(of result: RevisionComparisonResult) -> RevisionAlignmentState {
        if let rejection = result.autoAlignmentRejection {
            return .failed(reason: String(describing: rejection))
        }
        let solution = result.alignment
        // The page-point residual of a point solve, in rendered pixels.
        let residual = solution.residual.rootMeanSquare * result.renderScale
        switch solution.provenance {
        case .automaticVision:
            // Vision does not report an inlier ratio, so the UI's `inlierRatio` carries the
            // fraction of the pixel difference the transform actually removed — the measure
            // the comparator itself used to accept the registration. Reporting a fabricated
            // ratio would make a weak alignment look strong.
            let metrics = result.autoAlignmentMetrics
            let improvement = metrics?.improvement ?? 0
            // Nor does it report a reprojection error — `residual` is 0 here — so the error
            // field carries the gray-level dissimilarity the aligner did measure. The
            // solution's own field is preferred; the metrics recorded the same number when
            // the registration was accepted, and stand in for a solution that was rebuilt
            // in page space without it.
            let dissimilarity = solution.pixelDissimilarity
                ?? metrics?.meanAbsoluteDifferenceAfter
                ?? residual
            return .automatic(
                inlierRatio: min(1, max(0, improvement)),
                medianReprojectionErrorPixels: dissimilarity
            )
        case .manualThreePoint:
            return .manualThreePoint(residualPixels: residual)
        case .manualTwoPoint:
            return .manualTwoPoint(residualPixels: residual)
        case .pageBox, .explicit, .manualTranslation:
            // A translation-only manual registration has no dedicated presentation state; it
            // is reported as the manual alignment it most resembles, with its residual.
            return .manualTwoPoint(residualPixels: residual)
        case .identity:
            return solution.transform.isIdentity() ? .notAligned : .manualTwoPoint(residualPixels: residual)
        }
    }
}
