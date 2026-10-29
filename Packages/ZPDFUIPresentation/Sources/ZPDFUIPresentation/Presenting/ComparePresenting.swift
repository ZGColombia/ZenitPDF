import Foundation
import Observation

/// Presents Revision Compare and Revision Overlay.
@MainActor
public protocol ComparePresenting: ZenitPresenting {

    /// Revisions available for comparison.
    var revisions: [RevisionSummary] { get }
    /// The revision treated as the baseline, or `nil`.
    var baselineRevisionID: RevisionSummary.ID? { get }
    /// The revision compared against the baseline, or `nil`.
    var comparisonRevisionID: RevisionSummary.ID? { get }
    /// Detected differences, largest area first.
    var diffs: [CompareDiffSummary] { get }
    /// Overlay opacity for the comparison revision, `0...1`.
    var overlayOpacity: Double { get }
    /// How the two revisions are blended.
    var overlayBlendMode: RevisionOverlayBlendMode { get }
    /// How the revisions were brought into register.
    var alignmentState: RevisionAlignmentState { get }
    /// How the window is split for side-by-side review.
    var splitCanvasMode: SplitCanvasMode { get }
    /// Whether the overlay is alternating between revisions. Always reported as `false`
    /// while Reduce Motion is on.
    var isBlinking: Bool { get }
    /// Whether page navigation is synchronised between the two canvases.
    var isPageSyncEnabled: Bool { get }
    /// Whether zoom and pan are synchronised between the two canvases.
    var isZoomSyncEnabled: Bool { get }
    /// A sentence about how the standing result was produced when it was not produced as
    /// asked (a reduced resolution, S-102), or `nil`. The review shows it beside the result.
    var resultNote: String? { get }

    /// Sets the baseline revision.
    func setBaseline(id: RevisionSummary.ID)
    /// Sets the comparison revision.
    func setComparison(id: RevisionSummary.ID)
    /// Swaps baseline and comparison.
    func swapRevisions()
    /// Sets the overlay opacity, clamped to `0...1`.
    func setOverlayOpacity(_ opacity: Double)
    /// Sets the blend mode.
    func setOverlayBlendMode(_ mode: RevisionOverlayBlendMode)
    /// Turns blinking on or off. Implementations must refuse to turn it on under Reduce Motion.
    func setBlinking(_ enabled: Bool)
    /// Changes the Split Canvas layout.
    func setSplitCanvasMode(_ mode: SplitCanvasMode)
    /// Turns page synchronisation on or off.
    func setPageSyncEnabled(_ enabled: Bool)
    /// Turns zoom and pan synchronisation on or off.
    func setZoomSyncEnabled(_ enabled: Bool)
    /// Accepts one difference, which promotes it to a Zenit markup.
    func acceptDiff(id: CompareDiffSummary.ID)
    /// Rejects one difference.
    func rejectDiff(id: CompareDiffSummary.ID)
    /// Accepts every outstanding difference.
    func acceptAllDiffs()
}

extension ComparePresenting {

    /// The baseline revision, resolved from ``baselineRevisionID``.
    public var baselineRevision: RevisionSummary? {
        guard let baselineRevisionID else { return nil }
        return revisions.first { $0.id == baselineRevisionID }
    }

    /// The comparison revision, resolved from ``comparisonRevisionID``.
    public var comparisonRevision: RevisionSummary? {
        guard let comparisonRevisionID else { return nil }
        return revisions.first { $0.id == comparisonRevisionID }
    }

    /// A presenter with nothing to add about how its result was produced.
    public var resultNote: String? { nil }
}
