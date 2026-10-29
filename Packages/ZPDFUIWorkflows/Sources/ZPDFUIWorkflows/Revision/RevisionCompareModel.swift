import Foundation
import Observation
import ZPDFUIPresentation

/// How the two revisions are shown while they are being compared.
public enum RevisionCompareDisplayMode: String, Hashable, Sendable, CaseIterable, Identifiable {

    /// Both sheets, next to each other, with the same page and zoom.
    case sideBySide
    /// One picture showing only what is not the same in both.
    case difference

    /// Stable identity.
    public var id: String { rawValue }

    /// A localized name for the mode switch.
    public var displayName: String {
        switch self {
        case .sideBySide: return NSLocalizedString("Side by Side", comment: "Revision Compare display mode")
        case .difference: return NSLocalizedString("Differences Only", comment: "Revision Compare display mode")
        }
    }

    /// A localized sentence explaining what the mode is good for.
    public var explanation: String {
        switch self {
        case .sideBySide:
            return NSLocalizedString(
                "Read both sheets as drawn. Best for understanding what a change means.",
                comment: "Explanation of side-by-side compare"
            )
        case .difference:
            return NSLocalizedString(
                "Show only what is not the same in both. Best for finding a change you would otherwise miss.",
                comment: "Explanation of difference compare"
            )
        }
    }
}

/// How fussy the difference detector is being.
public struct RevisionCompareSettings: Hashable, Sendable {

    /// `0` reports every speck, `1` reports only substantial changes.
    public var tolerance: Double
    /// The smallest region worth reporting, in square PDF points.
    public var minimumRegionAreaPoints: Double

    /// Creates settings.
    public init(tolerance: Double = 0.35, minimumRegionAreaPoints: Double = 12) {
        self.tolerance = min(1, max(0, tolerance))
        self.minimumRegionAreaPoints = max(0, minimumRegionAreaPoints)
    }

    /// A localized description of what the current tolerance means in practice.
    public var toleranceExplanation: String {
        switch tolerance {
        case ..<0.2:
            return NSLocalizedString(
                "Reporting almost everything. Expect differences caused by how the sheets were plotted, not by the design.",
                comment: "Compare tolerance explanation, very low"
            )
        case 0.2..<0.55:
            return NSLocalizedString(
                "A balanced setting. Small plotting differences are ignored; changed linework is reported.",
                comment: "Compare tolerance explanation, medium"
            )
        default:
            return NSLocalizedString(
                "Reporting only substantial changes. A thin line that moved slightly will not appear.",
                comment: "Compare tolerance explanation, high"
            )
        }
    }
}

/// The receipt that one comparison actually ran, and what it ran against.
///
/// This type exists because the first assembled build reported "No differences found" while
/// both revision pickers still read "Choose…" — a verdict with nothing behind it. Every verdict
/// API in this package now takes a `RevisionCompareRun` as a required parameter, so a claim
/// about differences is unconstructible without evidence that a comparison happened. The core
/// records one of these when detection completes; nothing else may.
public struct RevisionCompareRun: Hashable, Sendable, Identifiable {

    /// Stable identity of this run.
    public let id: UUID
    /// The revision the run measured against.
    public let baselineRevisionID: RevisionSummary.ID
    /// The revision the run checked.
    public let comparisonRevisionID: RevisionSummary.ID
    /// The settings the run used. A verdict is only valid for these exact settings.
    public let settings: RevisionCompareSettings
    /// When detection finished.
    public let completedAt: Date

    /// Creates a run receipt.
    public init(
        id: UUID = UUID(),
        baselineRevisionID: RevisionSummary.ID,
        comparisonRevisionID: RevisionSummary.ID,
        settings: RevisionCompareSettings,
        completedAt: Date = Date()
    ) {
        self.id = id
        self.baselineRevisionID = baselineRevisionID
        self.comparisonRevisionID = comparisonRevisionID
        self.settings = settings
        self.completedAt = completedAt
    }
}

/// The review state of Revision Compare: how it is displayed, how fussy it is, and which
/// difference the person is looking at.
///
/// Detection itself belongs to the core. This model owns the review, which is the part that has
/// to stay honest: a difference is a candidate until a person accepts it, and Zenit says so.
@MainActor
@Observable
public final class RevisionCompareModel {

    /// How the two revisions are shown.
    public var displayMode: RevisionCompareDisplayMode = .sideBySide
    /// How fussy the detector is.
    public private(set) var settings: RevisionCompareSettings
    /// Which change types are shown.
    public var visibleChangeKinds: Set<CompareChangeKind> = Set(CompareChangeKind.allCases)
    /// The difference currently under review, or `nil`.
    public private(set) var focusedDiffID: CompareDiffSummary.ID?
    /// The completed comparison the current diffs belong to, or `nil` when nothing has run.
    /// While this is `nil` the review renders no verdict, no counts and no tolerance reading —
    /// there is nothing honest to say yet.
    public private(set) var latestRun: RevisionCompareRun?

    /// The tolerance a person is dragging towards, or `nil` when nothing is being dragged.
    ///
    /// A drag used to commit every tick straight into ``settings``, and every tick withdrew the
    /// run — so the slider under the cursor vanished on its first movement along with the whole
    /// review, and the core re-detected once per pixel. Finding BH-055 and IM-032. While a drag
    /// is in progress the value lives here, the standing run stays valid, and one commit
    /// happens when the drag ends.
    public private(set) var toleranceDraft: Double?
    /// Whether a tolerance drag is in progress.
    public private(set) var isAdjustingTolerance = false

    /// Runs when the tolerance changes, so the core can re-detect.
    public var onSettingsChange: (@MainActor (RevisionCompareSettings) -> Void)?
    /// Runs when the review moves to a difference, so the canvas can scroll to it.
    public var onFocusDifference: (@MainActor (CompareDiffSummary) -> Void)?
    /// Asks the host for a revised PDF to add as a revision (L-57, L-93). Set, the empty sheet
    /// and the revision bar offer Add Revision…; unset (a preview), they do not.
    public var onAddRevision: (@MainActor () -> Void)?

    /// What the sheet says while it has no pair of revisions to compare.
    ///
    /// L-93: with no revision the toolbar's Compare opened two "Choose…" pop-ups with nothing
    /// in them and "Select two revisions to compare", and nothing on the sheet said how a
    /// revision gets there — it could only arrive by an ⌥ drop from Finder. With fewer than two
    /// revisions the sheet now says so and offers Add Revision…; with two or more it asks for
    /// the pair as before.
    public static func emptyState(revisionCount: Int, canAddRevision: Bool) -> RevisionCompareEmptyState {
        guard revisionCount < 2 else {
            return RevisionCompareEmptyState(
                title: NSLocalizedString("Select two revisions to compare", comment: "Revision Compare empty state title"),
                message: NSLocalizedString(
                    "Choose a baseline and a comparison revision above.",
                    comment: "Revision Compare empty state message"
                ),
                actionTitle: nil
            )
        }
        return RevisionCompareEmptyState(
            title: NSLocalizedString(
                "This drawing has no revision to compare with yet",
                comment: "Revision Compare empty state title when fewer than two revisions exist"
            ),
            message: canAddRevision
                ? NSLocalizedString(
                    "Add the revised PDF of this drawing. It is compared with the drawing as it is now; neither file is changed.",
                    comment: "Revision Compare empty state message when a revision can be added from the sheet"
                )
                : NSLocalizedString(
                    "Add the revised PDF of this drawing with File ▸ Drawing Set ▸ Add Revision…, then compare it here.",
                    comment: "Revision Compare empty state message when the sheet cannot add a revision itself"
                ),
            actionTitle: canAddRevision
                ? NSLocalizedString("Add Revision…", comment: "Revision Compare: choose a revised PDF to add as a revision")
                : nil
        )
    }

    /// Creates the model.
    public init(settings: RevisionCompareSettings = RevisionCompareSettings()) {
        self.settings = settings
    }

    /// Sets the tolerance and tells the core to re-detect. The standing verdict is withdrawn
    /// first: a result computed at the old tolerance says nothing about the new one.
    public func setTolerance(_ tolerance: Double) {
        var updated = settings
        updated.tolerance = min(1, max(0, tolerance))
        guard updated != settings else { return }
        invalidateRun()
        settings = updated
        onSettingsChange?(updated)
    }

    /// The tolerance the slider, its readout and its explanation show: the draft while a drag
    /// is in progress, the committed setting otherwise.
    public var displayedTolerance: Double {
        toleranceDraft ?? settings.tolerance
    }

    /// Marks the start or end of a tolerance drag.
    ///
    /// Ending a drag commits the draft through ``setTolerance(_:)`` exactly once, so a drag of
    /// any length costs one detection.
    public func setAdjustingTolerance(_ adjusting: Bool) {
        if adjusting {
            isAdjustingTolerance = true
            return
        }
        isAdjustingTolerance = false
        guard let draft = toleranceDraft else { return }
        toleranceDraft = nil
        setTolerance(draft)
    }

    /// Receives one slider value.
    ///
    /// During a drag the value is parked in ``toleranceDraft``; a value that arrives outside a
    /// drag — a keyboard step, an accessibility increment — commits at once, because no
    /// drag-end will follow it.
    public func previewTolerance(_ tolerance: Double) {
        let clamped = min(1, max(0, tolerance))
        if isAdjustingTolerance {
            toleranceDraft = clamped
        } else {
            setTolerance(clamped)
        }
    }

    // MARK: - Run lifecycle

    /// Records that a comparison finished. Called by the host when the core hands back diffs.
    public func recordRun(_ run: RevisionCompareRun) {
        latestRun = run
    }

    /// Withdraws the standing verdict. Called whenever an input to the comparison changes —
    /// a revision picker, a swap, the tolerance — so a stale result can never masquerade as a
    /// fresh one.
    public func invalidateRun() {
        latestRun = nil
        focusedDiffID = nil
    }

    /// The run the review may honestly present, or `nil`.
    ///
    /// A recorded run only counts while it matches the revisions on screen and the current
    /// settings. Anything else — no run, a run for other revisions, a run at another tolerance —
    /// resolves to `nil`, and with `nil` there is no verdict to render.
    public func currentRun(
        baseline: RevisionSummary.ID?,
        comparison: RevisionSummary.ID?
    ) -> RevisionCompareRun? {
        guard let latestRun,
              let baseline,
              let comparison,
              latestRun.baselineRevisionID == baseline,
              latestRun.comparisonRevisionID == comparison,
              latestRun.settings == settings else { return nil }
        return latestRun
    }

    /// The differences that pass the change-type filter, largest first.
    public func visibleDiffs(from diffs: [CompareDiffSummary]) -> [CompareDiffSummary] {
        diffs
            .filter { visibleChangeKinds.contains($0.changeKind) }
            .sorted { $0.areaInSquarePoints > $1.areaInSquarePoints }
    }

    /// How many differences of each type were detected, whether or not the type is shown.
    ///
    /// The legend reads this. It used to count only the visible differences, so hiding a type
    /// made its badge read `0` while the header said seven were hidden — the legend was stating
    /// there were no added differences when there were seven. Finding BH-837. The header's
    /// ``countSummary(for:diffs:)`` still counts what is shown; that is a different sentence.
    public func counts(from diffs: [CompareDiffSummary]) -> [CompareChangeKind: Int] {
        var counts: [CompareChangeKind: Int] = [:]
        for diff in diffs {
            counts[diff.changeKind, default: 0] += 1
        }
        return counts
    }

    /// Whether a change type may be hidden right now. The last shown type cannot be: a review
    /// with every type hidden shows nothing and says nothing. The legend disables that button
    /// and explains why, instead of swallowing the click. Finding BH-838.
    public func canHideChangeKind(_ kind: CompareChangeKind) -> Bool {
        !(visibleChangeKinds.count == 1 && visibleChangeKinds.contains(kind))
    }

    /// Shows or hides one change type, refusing to hide the last shown one.
    /// Returns whether the request was applied.
    @discardableResult
    public func setChangeKind(_ kind: CompareChangeKind, visible: Bool) -> Bool {
        if visible {
            visibleChangeKinds.insert(kind)
            return true
        }
        guard canHideChangeKind(kind) else { return false }
        visibleChangeKinds.remove(kind)
        return true
    }

    /// The differences Accept All may accept: the ones that are shown and still pending.
    ///
    /// Accept All used to accept every pending difference in the presenter, including the ones
    /// the change filter was hiding, and each of those became a markup on the drawing. Finding
    /// BH-309. Under a filter the button now means what the list under it shows.
    public func pendingVisibleDiffIDs(in diffs: [CompareDiffSummary]) -> [CompareDiffSummary.ID] {
        visibleDiffs(from: diffs).filter { !$0.isAccepted }.map(\.id)
    }

    /// The focused difference, when it is still shown.
    public func focusedDiff(in diffs: [CompareDiffSummary]) -> CompareDiffSummary? {
        guard let focusedDiffID else { return nil }
        return visibleDiffs(from: diffs).first { $0.id == focusedDiffID }
    }

    /// Applies a decision — accept or dismiss — to the focused difference and moves the review
    /// on to the next one, so a keyboard review is one key per difference (IM-033).
    /// Returns `false` when nothing is focused.
    @discardableResult
    public func reviewFocusedDifference(
        in diffs: [CompareDiffSummary],
        _ decide: (CompareDiffSummary.ID) -> Void
    ) -> Bool {
        guard let focused = focusedDiff(in: diffs) else { return false }
        decide(focused.id)
        focusNextDifference(in: diffs)
        return true
    }

    /// A localized headline count for the review header.
    ///
    /// The `run` parameter is deliberate and load-bearing: it is the proof a comparison
    /// happened. Without a ``RevisionCompareRun`` in hand this method cannot be called, which
    /// makes "No differences found" structurally unreachable for a comparison that never ran.
    public func countSummary(for run: RevisionCompareRun, diffs: [CompareDiffSummary]) -> String {
        let visible = visibleDiffs(from: diffs)
        guard !visible.isEmpty else {
            // Two different facts, and they used to share one sentence. "Nothing was detected"
            // and "everything detected is hidden by the change-type filter" both produced
            // *"No differences found at this tolerance"*, which is a verdict about the drawing
            // being made by a checkbox in the sidebar — the exact class of untrue headline
            // `RevisionCompareRun` exists to make unconstructible. Finding CR-200.
            guard diffs.isEmpty else {
                return WorkflowPlurals.differencesAllHidden(diffs.count)
            }
            return NSLocalizedString(
                "No differences found at this tolerance",
                comment: "Revision Compare header when nothing was detected"
            )
        }
        let accepted = visible.filter(\.isAccepted).count
        // V-068: "1 difference to review", not "1 differences".
        let format = NSLocalizedString(
            "%1$@, %2$lld accepted",
            comment: "Revision Compare header: the candidates as '3 differences to review', the accepted count"
        )
        return String(format: format, WorkflowPlurals.differencesToReview(visible.count - accepted), accepted)
    }

    /// Moves the review to the next difference, wrapping at the end.
    public func focusNextDifference(in diffs: [CompareDiffSummary]) {
        advance(by: 1, in: diffs)
    }

    /// Moves the review to the previous difference, wrapping at the start.
    public func focusPreviousDifference(in diffs: [CompareDiffSummary]) {
        advance(by: -1, in: diffs)
    }

    /// Moves the review to one difference by identity.
    public func focusDifference(id: CompareDiffSummary.ID, in diffs: [CompareDiffSummary]) {
        guard let diff = diffs.first(where: { $0.id == id }) else { return }
        focusedDiffID = id
        onFocusDifference?(diff)
    }

    /// One-based position of the focused difference, for the "3 of 17" readout.
    public func focusedPosition(in diffs: [CompareDiffSummary]) -> Int? {
        let visible = visibleDiffs(from: diffs)
        guard let focusedDiffID,
              let index = visible.firstIndex(where: { $0.id == focusedDiffID }) else { return nil }
        return index + 1
    }

    private func advance(by delta: Int, in diffs: [CompareDiffSummary]) {
        let visible = visibleDiffs(from: diffs)
        guard !visible.isEmpty else { return }
        let count = visible.count
        // With nothing focused, Next lands on the first item and Previous on the last. The
        // sentinel used to be -1 for both directions, so Previous from an unfocused list went
        // to the second-to-last item. Finding BH-836.
        let current = visible.firstIndex { $0.id == focusedDiffID } ?? (delta < 0 ? count : -1)
        let next = ((current + delta) % count + count) % count
        focusDifference(id: visible[next].id, in: visible)
    }
}

/// What Revision Compare shows while there is no pair to compare (L-57, L-93).
public struct RevisionCompareEmptyState: Hashable, Sendable {
    public let title: String
    public let message: String
    /// The button's title, or `nil` when the sheet offers no button.
    public let actionTitle: String?

    public init(title: String, message: String, actionTitle: String?) {
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
    }
}
