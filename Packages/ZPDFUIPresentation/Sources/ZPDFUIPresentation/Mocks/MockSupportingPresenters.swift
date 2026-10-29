// Debug and test builds only (R-142): a plain release build of ZPDFUIPresentation ships no
// mock. A release build that compiles tests passes -DZPDF_MOCKS (verify-viewer-budgets.sh).
#if DEBUG || ZPDF_MOCKS
import Foundation
import Observation

// MARK: - Tool Library

/// Mock implementation of ``ToolLibraryPresenting``.
@MainActor
@Observable
public final class MockToolLibraryPresenter: ToolLibraryPresenting {

    public let panels: [ToolLibraryPanel] = ToolLibraryPanel.allCases
    public private(set) var activePanel: ToolLibraryPanel = .myTools
    public private(set) var presets: [ToolPresetSummary]
    public private(set) var activePresetID: ToolPresetSummary.ID?
    public private(set) var reuseToolEnabled: Bool = true
    public private(set) var searchText: String = ""
    public private(set) var setModes: [ToolLibraryPanel: ToolSetMode] = [:]

    /// Called when the reuse-tool switch changes, so the status bar can follow.
    public var onReuseToolChange: (@MainActor (Bool) -> Void)?

    /// Builds the presenter over a sample project.
    public init(project: ZenitSampleProject = .shared) {
        self.presets = project.presets
        self.activePresetID = project.presets.first?.id
    }

    public func selectPanel(_ panel: ToolLibraryPanel) { activePanel = panel }

    public func activatePreset(id: ToolPresetSummary.ID) {
        guard presets.contains(where: { $0.id == id }) else { return }
        activePresetID = id
    }

    public func clearActivePreset() { activePresetID = nil }

    public func toggleFavorite(id: ToolPresetSummary.ID) {
        guard let index = presets.firstIndex(where: { $0.id == id }), !presets[index].isReadOnly
        else { return }
        presets[index].isFavorite.toggle()
    }

    public func setReuseToolEnabled(_ enabled: Bool) {
        reuseToolEnabled = enabled
        onReuseToolChange?(enabled)
    }

    public func setSearchText(_ text: String) { searchText = text }

    public func setMode(_ mode: ToolSetMode, for panel: ToolLibraryPanel) {
        setModes[panel] = mode
    }

    public func movePreset(id: ToolPresetSummary.ID, to index: Int) {
        guard let current = presets.firstIndex(where: { $0.id == id }),
              presets.indices.contains(index) else { return }
        let preset = presets.remove(at: current)
        presets.insert(preset, at: index)
        for offset in presets.indices {
            presets[offset].sortIndex = offset
        }
    }

    /// How many times a commit has been reported. The shell's tests read this to prove
    /// that both tool families ask, rather than deciding for themselves.
    public private(set) var markupCommittedCount: Int = 0

    @discardableResult
    public func markupCommitted() -> Bool {
        markupCommittedCount += 1
        guard !reuseToolEnabled else { return true }
        clearActivePreset()
        return false
    }
}

// MARK: - Search

/// Mock implementation of ``SearchPresenting``.
///
/// The sample result set is written for the query `"screed"`; any other query filters the
/// same set by substring so the empty state is reachable from the UI.
@MainActor
@Observable
public final class MockSearchPresenter: SearchPresenting {

    public var query: String = "" {
        didSet { if query != oldValue { runSearch() } }
    }
    public var scope: SearchScope = .default {
        didSet { if scope != oldValue { runSearch() } }
    }
    public private(set) var hits: [SearchHit] = []
    public private(set) var activeHitID: SearchHit.ID?
    public private(set) var isSearching: Bool = false

    /// Called when a hit is revealed, so the document can navigate to its page.
    public var onReveal: (@MainActor (SearchHit) -> Void)?

    private let allHits: [SearchHit]

    /// Builds the presenter over a sample project.
    public init(project: ZenitSampleProject = .shared) {
        self.allHits = project.searchHits
    }

    public var resultSummary: String {
        if hits.isEmpty {
            return query.isEmpty
                ? NSLocalizedString("Type to search", comment: "Search field placeholder summary")
                : NSLocalizedString("No results", comment: "Search summary when nothing matched")
        }
        if let position = activeHitPosition {
            let format = NSLocalizedString(
                "%1$d of %2$d results",
                comment: "Search summary: position of the revealed hit, total hits"
            )
            return String(format: format, position, hits.count)
        }
        let format = NSLocalizedString("%d results", comment: "Search summary: total hits")
        return String(format: format, hits.count)
    }

    public var showsOCRDisclaimer: Bool { hits.contains { $0.source == .ocrText } }

    public func runSearch() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            hits = []
            activeHitID = nil
            return
        }
        hits = allHits.filter { hit in
            scope.sources.contains(hit.source)
                && hit.snippet.localizedCaseInsensitiveContains(trimmed)
        }
        activeHitID = hits.first?.id
    }

    public func selectHit(id: SearchHit.ID) {
        guard let hit = hits.first(where: { $0.id == id }) else { return }
        activeHitID = id
        onReveal?(hit)
    }

    public func advance(by delta: Int) {
        guard !hits.isEmpty else { return }
        let current = hits.firstIndex { $0.id == activeHitID } ?? 0
        let count = hits.count
        let next = ((current + delta) % count + count) % count
        selectHit(id: hits[next].id)
    }

    public func clear() {
        query = ""
        hits = []
        activeHitID = nil
    }
}

// MARK: - Revision Compare

/// Mock implementation of ``ComparePresenting``.
@MainActor
@Observable
public final class MockComparePresenter: ComparePresenting {

    public private(set) var revisions: [RevisionSummary]
    public private(set) var baselineRevisionID: RevisionSummary.ID?
    public private(set) var comparisonRevisionID: RevisionSummary.ID?
    public private(set) var diffs: [CompareDiffSummary]
    private var promotedCount = 0
    public private(set) var overlayOpacity: Double = 0.6
    public private(set) var overlayBlendMode: RevisionOverlayBlendMode = .difference
    public private(set) var alignmentState: RevisionAlignmentState =
        .automatic(inlierRatio: 0.72, medianReprojectionErrorPixels: 1.4)
    public private(set) var splitCanvasMode: SplitCanvasMode = .vertical
    public private(set) var isBlinking: Bool = false
    public private(set) var isPageSyncEnabled: Bool = true
    public private(set) var isZoomSyncEnabled: Bool = true

    /// Mirrors the system Reduce Motion setting. Blinking is refused while it is `true`.
    public var prefersReducedMotion: Bool = false

    /// Builds the presenter over a sample project.
    public init(project: ZenitSampleProject = .shared) {
        self.revisions = project.revisions
        self.diffs = project.compareDiffs
        self.baselineRevisionID = project.revisions.first(where: \.isBaseline)?.id
        self.comparisonRevisionID = project.revisions.last?.id
    }

    public func setBaseline(id: RevisionSummary.ID) {
        guard revisions.contains(where: { $0.id == id }) else { return }
        baselineRevisionID = id
        revisions = revisions.map { revision in
            var updated = revision
            updated.isBaseline = revision.id == id
            return updated
        }
    }

    public func setComparison(id: RevisionSummary.ID) {
        guard revisions.contains(where: { $0.id == id }) else { return }
        comparisonRevisionID = id
    }

    public func swapRevisions() {
        let baseline = baselineRevisionID
        if let comparison = comparisonRevisionID { setBaseline(id: comparison) }
        comparisonRevisionID = baseline
    }

    public func setOverlayOpacity(_ opacity: Double) {
        overlayOpacity = min(1, max(0, opacity))
    }

    public func setOverlayBlendMode(_ mode: RevisionOverlayBlendMode) { overlayBlendMode = mode }

    public func setBlinking(_ enabled: Bool) {
        // Reduce Motion turns the blink into a static comparison rather than a flashing one.
        isBlinking = prefersReducedMotion ? false : enabled
    }

    public func setSplitCanvasMode(_ mode: SplitCanvasMode) { splitCanvasMode = mode }

    public func setPageSyncEnabled(_ enabled: Bool) { isPageSyncEnabled = enabled }

    public func setZoomSyncEnabled(_ enabled: Bool) { isZoomSyncEnabled = enabled }

    public func acceptDiff(id: CompareDiffSummary.ID) {
        guard let index = diffs.firstIndex(where: { $0.id == id }) else { return }
        diffs[index].isAccepted = true
        diffs[index].promotedMarkupID = nextPromotedMarkupID()
    }

    /// BH-779: a promoted markup's identity comes from a running counter, not from the diff's
    /// array index, which shifts after a reject and made two accepted diffs share one id.
    private func nextPromotedMarkupID() -> UUID {
        promotedCount += 1
        return SampleFormatting.sampleID(3_000 + promotedCount)
    }

    public func rejectDiff(id: CompareDiffSummary.ID) {
        diffs.removeAll { $0.id == id }
    }

    public func acceptAllDiffs() {
        for index in diffs.indices where !diffs[index].isAccepted {
            diffs[index].isAccepted = true
            diffs[index].promotedMarkupID = nextPromotedMarkupID()
        }
    }
}
#endif
