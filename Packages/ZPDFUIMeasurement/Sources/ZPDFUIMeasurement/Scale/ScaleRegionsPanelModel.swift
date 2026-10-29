import Foundation
import Observation
import ZPDFUIPresentation

/// The named colours a Scale Region outline can take: the one shared palette (W-075).
///
/// This used to be a third literal copy of the five entries, with a header asking to keep it in
/// step with the markup palette by hand.
public typealias ZenitRegionPalette = ZenitNamedPalette

/// A Scale Region being built: the polygon is drawn, the rest is not decided yet.
///
/// A draft is deliberately not a region. A region without a scale would be a region that
/// measures at *something*, and the only honest answers are "the page default" (in which case
/// it is not a region) or "a scale nobody has stated". So the draft holds an optional scale and
/// ``ScaleRegionsPanelModel/commitDraft()`` refuses while it is `nil`.
public struct ScaleRegionDraft: Hashable, Sendable, Identifiable {

    /// Identity of the region that will be created.
    public let id: UUID
    /// The polygon the person drew, in page space. The first point is not repeated.
    public var boundary: [PDFPointValue]
    /// The page the polygon was drawn on.
    public var pageID: PageDescriptor.ID
    /// That page's label, as the person reads it.
    public var pageLabel: String
    /// The proposed name.
    public var name: String
    /// The chosen palette entry's identifier.
    public var colorPaletteID: String
    /// Where the region will sit in the resolution order. Higher wins.
    public var priority: Int
    /// The scale that will apply inside the boundary, or `nil` while none has been assigned.
    public var scale: ScaleSummary?
    /// Whether the region is created locked.
    public var locked: Bool

    /// Creates a draft.
    public init(
        id: UUID = UUID(),
        boundary: [PDFPointValue],
        pageID: PageDescriptor.ID,
        pageLabel: String,
        name: String,
        colorPaletteID: String,
        priority: Int,
        scale: ScaleSummary? = nil,
        locked: Bool = false
    ) {
        self.id = id
        self.boundary = boundary
        self.pageID = pageID
        self.pageLabel = pageLabel
        self.name = name
        self.colorPaletteID = colorPaletteID
        self.priority = priority
        self.scale = scale
        self.locked = locked
    }

    /// The colour the draft will be created with.
    public var colorRGBA: ColorRGBA { ZenitRegionPalette.entry(for: colorPaletteID).color }

    /// Axis-aligned bounds of ``boundary``, or `nil` for an empty polygon.
    public var boundsInPageSpace: PDFRectValue? {
        guard let first = boundary.first else { return nil }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in boundary.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        return PDFRectValue(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// Everything the app tier needs to create one region. The panel never touches a store.
public struct ScaleRegionCreation: Hashable, Sendable {

    /// Identity to create the region under.
    public let id: UUID
    /// The page the region lives on.
    public let pageID: PageDescriptor.ID
    /// The polygon in page space.
    public let boundary: [PDFPointValue]
    /// The region's name.
    public let name: String
    /// The scale that applies inside the boundary. Never `nil` — see ``ScaleRegionDraft``.
    public let scale: ScaleSummary
    /// Resolution order; higher wins.
    public let priority: Int
    /// Whether the region is created locked.
    public let locked: Bool
    /// Outline colour.
    public let colorRGBA: ColorRGBA

    /// Creates a creation request.
    public init(
        id: UUID,
        pageID: PageDescriptor.ID,
        boundary: [PDFPointValue],
        name: String,
        scale: ScaleSummary,
        priority: Int,
        locked: Bool,
        colorRGBA: ColorRGBA
    ) {
        self.id = id
        self.pageID = pageID
        self.boundary = boundary
        self.name = name
        self.scale = scale
        self.priority = priority
        self.locked = locked
        self.colorRGBA = colorRGBA
    }
}

/// Why the panel would not do what was asked.
///
/// Every refusal carries a sentence, because a control that declines in silence is the defect
/// this panel exists to prevent.
public enum ScaleRegionRefusal: Hashable, Sendable {

    /// No polygon has been drawn yet.
    case noPolygonDrawn
    /// Fewer than three points cannot bound an area.
    case polygonTooFewPoints(count: Int)
    /// The polygon has no extent in one direction, so it encloses nothing.
    case polygonHasNoExtent
    /// The name is blank.
    case nameEmpty
    /// Another region on the page already has that name.
    case nameTaken(String)
    /// No scale has been assigned to the draft.
    case scaleNotAssigned
    /// A locked region refuses the edit until it is unlocked.
    case regionLocked(name: String)
    /// The region named is not on this page's list.
    case unknownRegion
    /// The region still measures markups, so deleting it would silently re-measure them.
    case regionInUse(name: String, markupCount: Int)
    /// A markup is waiting for a crossing decision, and there can only be one at a time.
    case crossingPending
    /// Continue was pressed with no outcome chosen.
    case crossingUnresolved
    /// The chosen outcome is not one this crossing offers.
    case crossingOutcomeNotOffered
    /// The core rejected the boundary. Its own sentence is carried through.
    case rejectedByCore(String)

    /// The sentence shown in the panel and spoken by VoiceOver.
    public var message: String {
        switch self {
        case .noPolygonDrawn:
            return NSLocalizedString(
                "Draw the region boundary on the page first.",
                comment: "Scale Region refusal: nothing drawn yet"
            )
        case let .polygonTooFewPoints(count):
            return String(
                format: NSLocalizedString(
                    "A Scale Region needs at least three points; this one has %d.",
                    comment: "Scale Region refusal: too few points"
                ),
                count
            )
        case .polygonHasNoExtent:
            return NSLocalizedString(
                "That boundary encloses no area. Redraw it.",
                comment: "Scale Region refusal: degenerate polygon"
            )
        case .nameEmpty:
            return NSLocalizedString(
                "Give the region a name.",
                comment: "Scale Region refusal: blank name"
            )
        case let .nameTaken(name):
            return String(
                format: NSLocalizedString(
                    "“%@” is already the name of another region on this page.",
                    comment: "Scale Region refusal: duplicate name"
                ),
                name
            )
        case .scaleNotAssigned:
            return NSLocalizedString(
                "Assign a scale before creating the region. Zenit will not guess one.",
                comment: "Scale Region refusal: no scale assigned"
            )
        case let .regionLocked(name):
            return String(
                format: NSLocalizedString(
                    "“%@” is locked. Unlock it before changing it.",
                    comment: "Scale Region refusal: locked region"
                ),
                name
            )
        case .unknownRegion:
            return NSLocalizedString(
                "That region is no longer on this page.",
                comment: "Scale Region refusal: stale region identity"
            )
        case let .regionInUse(name, markupCount):
            // The count and every word that agrees with it are one pluralised clause (T-062):
            // "the scale behind 1 measurements. Move them out … their numbers" was the singular.
            let clause = LocalizedPlural.string(
                "the scale behind %lld measurements. Move them out before deleting it, or their numbers change without anyone deciding to.",
                count: markupCount,
                one: NSLocalizedString(
                    "the scale behind %lld measurement. Move it out before deleting the region, or its number changes without anyone deciding to.",
                    comment: "Scale Region refusal clause: the region still measures one markup"
                ),
                other: NSLocalizedString(
                    "the scale behind %lld measurements. Move them out before deleting it, or their numbers change without anyone deciding to.",
                    comment: "Scale Region refusal clause: the region still measures several markups"
                )
            )
            return String(
                format: NSLocalizedString(
                    "“%1$@” is %2$@",
                    comment: "Scale Region refusal: the region still measures markups; region name, 'the scale behind 3 measurements. …'"
                ),
                name,
                clause
            )
        case .crossingPending:
            return NSLocalizedString(
                "Finish deciding how the measurement that crosses two regions is handled first.",
                comment: "Scale Region refusal: a crossing decision is outstanding"
            )
        case .crossingUnresolved:
            return NSLocalizedString(
                "Choose one of the outcomes first.",
                comment: "Scale Region refusal: no crossing outcome chosen"
            )
        case .crossingOutcomeNotOffered:
            return NSLocalizedString(
                "That outcome is not available for this measurement.",
                comment: "Scale Region refusal: outcome not offered"
            )
        case let .rejectedByCore(reason):
            return reason
        }
    }
}

/// The controller behind ``ScaleRegionsPanel``: what regions exist on the page, how one is
/// created from a drawn polygon, and how a markup that crosses two of them is resolved.
///
/// # What this object refuses to do
///
/// Three things, and they are the reason it exists rather than the panel binding straight to a
/// presenter:
///
/// 1. **It never invents a scale.** A draft without an assigned scale cannot be committed, and
///    the refusal says so. The rule — the app must never quietly pick the wrong scale —
///    is enforced at the only seam where a region can come into existence.
/// 2. **It never resolves an overlap.** Overlaps are reported by the core through
///    ``setOverlaps(_:)``; the panel's only overlap action reveals the shared area so the person
///    can fix it. There is no code path here that turns an overlap into a chosen scale.
/// 3. **It never preselects a crossing outcome.** ``chosenCrossingResolution`` starts `nil`,
///    ``confirmCrossing()`` refuses while it is `nil`, and an outcome the crossing does not
///    offer — `splitAtBoundary` on a count group, a region that is not one of the candidates —
///    is rejected rather than applied.
///
/// The model owns no store. Everything that mutates the document leaves through one of the
/// `on…` hooks, which the app tier services through the document command bus.
@MainActor
@Observable
public final class ScaleRegionsPanelModel {

    // MARK: - State

    /// Every region on the page being shown, in whatever order the core supplied.
    public private(set) var regions: [ScaleRegionSummary]
    /// The scale that applies outside every region, or `nil` when the page is uncalibrated.
    public private(set) var pageDefaultScale: ScaleSummary?
    /// Scales already defined in the project, offered when a draft is given its scale.
    /// A scale the estimator measured earlier is evidence; one the panel invented would not be.
    public private(set) var availableScales: [ScaleSummary] = []
    /// Overlaps as reported by the core. Empty is the normal case.
    public private(set) var overlaps: [ScaleRegionOverlap]
    /// How many markups each region is currently the scale for, as the core last counted them.
    public private(set) var markupCounts: [UUID: Int] = [:]
    /// The markup waiting for a crossing decision, or `nil`.
    public private(set) var crossing: ScaleRegionCrossing?
    /// The outcome the person has picked for ``crossing``. Nothing is preselected.
    public private(set) var chosenCrossingResolution: ScaleRegionCrossingResolution?
    /// The region highlighted in the list.
    public var selection: UUID?
    /// The region being created, or `nil` when nothing is being drawn.
    public private(set) var draft: ScaleRegionDraft?
    /// Whether the canvas has been asked for a polygon and none has arrived yet.
    public private(set) var isAwaitingPolygon: Bool = false
    /// The most recent refusal, or `nil` when the last action was accepted.
    public private(set) var refusal: ScaleRegionRefusal? {
        didSet { if case .regionInUse = refusal {} else { refusedRegionID = nil } }
    }
    /// The region a `regionInUse` refusal is about, for its Show Measurements action.
    public private(set) var refusedRegionID: UUID?

    /// Whether the current refusal offers Show Measurements.
    public var canRevealRefusedMarkups: Bool { refusedRegionID != nil && onRevealMarkups != nil }

    /// Runs the refusal's Show Measurements action.
    @discardableResult
    public func revealRefusedMarkups() -> Bool {
        guard let refusedRegionID, let onRevealMarkups else { return false }
        onRevealMarkups(refusedRegionID)
        return true
    }

    /// Whether a boundary capture has been started and not yet finished with.
    ///
    /// Stays true across ``completePolygon(_:pageID:pageLabel:)``, which is the whole point:
    /// `isAwaitingPolygon` goes false the moment the boundary lands, and cancelling after that
    /// used to skip the disarm entirely. Finding CR-187.
    private var hasArmedCapture = false
    /// The page the capture was armed on, so a page turn can tell whether it is still relevant.
    private var capturePageID: PageDescriptor.ID?
    /// The page the panel is showing, once a caller has said which one it is.
    private var currentPageID: PageDescriptor.ID?
    /// The draft handed to ``onCreateRegion`` whose region has not appeared yet.
    ///
    /// The core answers a create asynchronously, after ``commitDraft()`` has closed the editor.
    /// A refusal used to arrive with the draft already gone, so the boundary the person drew
    /// was lost with it (T-056); ``rejectDraft(reason:)`` puts this one back instead.
    private var submittedDraft: ScaleRegionDraft?

    // MARK: - Hooks the app tier services

    /// Arms the polygon tool on the canvas. Until this is set, "Add Scale Region" refuses
    /// rather than opening a draft nothing can fill in.
    public var onBeginPolygon: (@MainActor () -> Void)?

    /// Raised when the person cancels polygon drawing from the panel, so the canvas
    /// disarms the tool too (LT-36's cancel half; see LT-35 for the zone twin).
    public var onCancelPolygonDrawing: (@MainActor () -> Void)?
    /// Creates the region. The app tier turns this into a document command with an undo inverse.
    public var onCreateRegion: (@MainActor (ScaleRegionCreation) -> Void)?
    /// Renames an existing region.
    public var onRenameRegion: (@MainActor (_ regionID: UUID, _ name: String) -> Void)?
    /// Opens calibration for one region, so its scale can be measured rather than typed.
    public var onCalibrateRegion: (@MainActor (_ regionID: UUID) -> Void)?
    /// Opens calibration for the draft, before the region exists.
    public var onCalibrateDraft: (@MainActor (ScaleRegionDraft) -> Void)?
    /// Assigns an existing scale to a region.
    public var onAssignScale: (@MainActor (_ regionID: UUID, _ scale: ScaleSummary) -> Void)?
    /// Writes a new resolution order, highest priority first.
    public var onReorderRegions: (@MainActor (_ orderedIDs: [UUID]) -> Void)?
    /// Locks or unlocks a region.
    public var onSetLocked: (@MainActor (_ regionID: UUID, _ locked: Bool) -> Void)?
    /// Deletes a region that is locked out of nothing and measures nothing.
    public var onDeleteRegion: (@MainActor (_ regionID: UUID) -> Void)?
    /// Shows or hides a region outline.
    public var onSetVisible: (@MainActor (_ regionID: UUID, _ visible: Bool) -> Void)?
    /// Scrolls the canvas to the shared area of an overlap. Reveals it; never resolves it.
    public var onRevealOverlap: (@MainActor (ScaleRegionOverlap) -> Void)?
    /// Selects and reveals the markups a region is the scale for, so a refused delete leads to
    /// the measurements that have to move rather than to a dead end (IM-209).
    public var onRevealMarkups: (@MainActor (_ regionID: UUID) -> Void)?
    /// Applies one of the three legal crossing outcomes.
    public var onResolveCrossing: (@MainActor (_ crossingID: UUID, _ outcome: ScaleRegionCrossingResolution) -> Void)?

    /// Creates the model.
    public init(
        regions: [ScaleRegionSummary] = [],
        pageDefaultScale: ScaleSummary? = nil,
        overlaps: [ScaleRegionOverlap] = []
    ) {
        self.regions = regions
        self.pageDefaultScale = pageDefaultScale
        self.overlaps = overlaps
    }

    // MARK: - Reading

    /// The regions in resolution order, highest priority first, ties broken by name so the
    /// list is stable between runs. The same order the panel's rows are drawn in
    /// (``ScaleRegionSummary/inResolutionOrder(_:)``), which is what makes Raise/Lower move the
    /// region on the row that was clicked (U-075).
    public var ordered: [ScaleRegionSummary] {
        ScaleRegionSummary.inResolutionOrder(regions)
    }

    /// One region by identity.
    public func region(_ id: UUID) -> ScaleRegionSummary? {
        regions.first { $0.id == id }
    }

    /// Whether a markup is waiting for a crossing decision.
    public var isAwaitingCrossingDecision: Bool { crossing != nil }

    /// The colours a new region can take, least-used first so two regions rarely match.
    public var availableColors: [ZenitRegionPalette.Entry] {
        let used = Set(regions.map(\.colorRGBA))
        let unused = ZenitRegionPalette.entries.filter { !used.contains($0.color) }
        return unused.isEmpty ? ZenitRegionPalette.entries : unused
    }

    // MARK: - Applying core state

    /// Replaces the region list. Called after every refresh; the core is the authority.
    ///
    /// - Parameters:
    ///   - regions: the regions on the page being shown.
    ///   - pageID: the page they belong to. Pass it whenever the caller knows: it is the only
    ///     signal that survives a turn to a page that has no regions yet. When it is omitted the
    ///     page is inferred from the regions themselves, which works for every page that has at
    ///     least one.
    ///
    /// A stale **selection** was already cleared here. A stale **draft** was not, and a draft is
    /// the more dangerous of the two: a boundary drawn on page 3 survived a turn to page 4, and
    /// Create then emitted page 3's `pageID` while the duplicate-name check ran against page 4's
    /// names. Finding CR-179.
    public func setRegions(_ regions: [ScaleRegionSummary], pageID: PageDescriptor.ID? = nil) {
        self.regions = regions
        // The created region has arrived: the submitted draft became it.
        if let submittedDraft, regions.contains(where: { $0.id == submittedDraft.id }) {
            self.submittedDraft = nil
        }
        if let selection, !regions.contains(where: { $0.id == selection }) { self.selection = nil }
        if let renamingRegionID, !regions.contains(where: { $0.id == renamingRegionID }) {
            self.renamingRegionID = nil
        }
        discardDraftIfNotOn(page: pageID ?? Self.commonPageID(of: regions))
    }

    /// Tells the panel which page it is showing, for a page that carries no regions.
    ///
    /// ``setRegions(_:pageID:)`` covers the ordinary refresh. This exists so a host that turns to
    /// an empty page — where there are no regions to infer a page from — can still say so.
    public func setCurrentPage(_ pageID: PageDescriptor.ID?) {
        discardDraftIfNotOn(page: pageID)
    }

    /// Throws away a draft that belongs to a different page, and disarms the canvas with it.
    private func discardDraftIfNotOn(page pageID: PageDescriptor.ID?) {
        guard let pageID else { return }
        currentPageID = pageID
        if let submittedDraft, submittedDraft.pageID != pageID { self.submittedDraft = nil }
        if let draft, draft.pageID != pageID {
            self.draft = nil
            refusal = nil
            isAwaitingPolygon = false
            hasArmedCapture = false
            onCancelPolygonDrawing?()
            return
        }
        // A capture armed on the page we just left is not waiting for anything any more.
        if isAwaitingPolygon, let armedOn = capturePageID, armedOn != pageID {
            isAwaitingPolygon = false
            hasArmedCapture = false
            capturePageID = nil
            onCancelPolygonDrawing?()
        }
    }

    /// The page every region in a list belongs to, or `nil` when the list is empty or mixed.
    private static func commonPageID(of regions: [ScaleRegionSummary]) -> PageDescriptor.ID? {
        guard let first = regions.first?.pageID else { return nil }
        return regions.allSatisfy { $0.pageID == first } ? first : nil
    }

    /// Sets the scale that applies outside every region.
    public func setPageDefaultScale(_ scale: ScaleSummary?) {
        pageDefaultScale = scale
    }

    /// Sets the scales a draft may be given without calibrating again.
    public func setAvailableScales(_ scales: [ScaleSummary]) {
        availableScales = scales
    }

    /// Reports the overlaps the core found.
    ///
    /// The panel has no overlap detector of its own, deliberately: the R-tree, the epsilon and
    /// the containment test all live in the geometry package, and a second, weaker test in the
    /// UI would be free to disagree with the one that decides measurements.
    public func setOverlaps(_ overlaps: [ScaleRegionOverlap]) {
        self.overlaps = overlaps
    }

    /// Reports how many markups each region is the scale for.
    ///
    /// The panel does not count anything itself; the number decides whether a deletion is
    /// refused, and a count derived from what the panel happens to have rendered would be a
    /// different number from the one the ledger totals.
    public func setMarkupCounts(_ counts: [UUID: Int]) {
        markupCounts = counts
    }

    /// How many markups a region measures.
    public func markupCount(of regionID: UUID) -> Int { markupCounts[regionID] ?? 0 }

    // MARK: - Creating a region

    /// Asks the canvas for a boundary polygon.
    ///
    /// Refused while a crossing decision is outstanding: two "which scale?" questions on screen
    /// at once is how the wrong one gets answered.
    @discardableResult
    public func beginRegion() -> Bool {
        guard crossing == nil else { return refuse(.crossingPending) }
        guard let onBeginPolygon else { return refuse(.noPolygonDrawn) }
        refusal = nil
        draft = nil
        // A new boundary supersedes a create still waiting for the core's answer.
        submittedDraft = nil
        isAwaitingPolygon = true
        hasArmedCapture = true
        capturePageID = currentPageID
        onBeginPolygon()
        return true
    }

    /// Stops waiting for a polygon and throws away any draft. Escape routes here.
    ///
    /// The disarm fires whenever a capture was started for this draft, not only while the
    /// canvas is still waiting for the boundary. Cancelling *after* drawing it — the ordinary
    /// case, because the draft editor is where the Cancel button lives — used to leave the
    /// boundary tool armed in the toolbar and the status bar still instructing, with no draft
    /// left for either of them to be about. Finding CR-187.
    public func cancelRegionCreation() {
        let hadCapture = isAwaitingPolygon || hasArmedCapture
        isAwaitingPolygon = false
        hasArmedCapture = false
        capturePageID = nil
        draft = nil
        refusal = nil
        if hadCapture { onCancelPolygonDrawing?() }
    }

    /// Accepts the polygon the canvas produced and opens a draft over it.
    ///
    /// The draft is named and coloured for the person, but its scale stays empty: a region is a
    /// statement that *this* part of the sheet is drawn at *that* scale, and only they can make
    /// it.
    @discardableResult
    public func completePolygon(
        _ boundary: [PDFPointValue],
        pageID: PageDescriptor.ID,
        pageLabel: String
    ) -> Bool {
        isAwaitingPolygon = false
        // The capture is not finished — it has produced a boundary and is now waiting on the
        // draft editor — so the armed flag stays up until the draft is committed or cancelled.
        capturePageID = pageID
        currentPageID = pageID
        guard boundary.count >= 3 else { return refuse(.polygonTooFewPoints(count: boundary.count)) }
        let candidate = ScaleRegionDraft(
            boundary: boundary,
            pageID: pageID,
            pageLabel: pageLabel,
            name: suggestedName(),
            colorPaletteID: availableColors[0].id,
            priority: (regions.map(\.priority).max() ?? 0) + 1
        )
        guard let bounds = candidate.boundsInPageSpace, bounds.size.width > 0, bounds.size.height > 0 else {
            return refuse(.polygonHasNoExtent)
        }
        refusal = nil
        draft = candidate
        return true
    }

    /// Renames the draft.
    public func setDraftName(_ name: String) {
        guard draft != nil else { return }
        draft?.name = name
        refusal = nil
    }

    /// Recolours the draft.
    public func setDraftColor(paletteID: String) {
        guard draft != nil else { return }
        draft?.colorPaletteID = ZenitRegionPalette.entry(for: paletteID).id
    }

    /// Creates the draft locked or unlocked.
    public func setDraftLocked(_ locked: Bool) {
        guard draft != nil else { return }
        draft?.locked = locked
    }

    /// Assigns the scale the draft will carry. This is the step that makes it committable.
    public func assignDraftScale(_ scale: ScaleSummary?) {
        guard draft != nil else { return }
        draft?.scale = scale
        if scale != nil, refusal == .scaleNotAssigned { refusal = nil }
    }

    /// Whether ``commitDraft()`` would succeed right now, so the button can be disabled for a
    /// reason the panel also states in words.
    public var canCommitDraft: Bool { draftProblem == nil }

    /// Why the draft cannot be created right now, or `nil` when it can.
    ///
    /// The button state, the sentence beside it and ``commitDraft()`` all read this, so the
    /// disabled button and the sentence explaining it cannot disagree (IM-112).
    public var draftProblem: ScaleRegionRefusal? {
        guard let draft else { return .noPolygonDrawn }
        if draft.scale == nil { return .scaleNotAssigned }
        return nameProblem(draft.name, excluding: nil)
    }

    /// Whether `name` can be a region name on this page, ignoring the region `excluding`.
    ///
    /// Trimmed, and compared without regard to case or diacritics, so `Level 1` and
    /// ` level 1 ` are the same name. The rule used to be written four times, case-sensitively,
    /// in create, the create button, rename and the draft sentence (IM-112).
    public func nameProblem(_ name: String, excluding regionID: UUID?) -> ScaleRegionRefusal? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .nameEmpty }
        let clash = regions.contains { region in
            region.id != regionID
                && region.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    .compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == .orderedSame
        }
        return clash ? .nameTaken(trimmed) : nil
    }

    /// Creates the region, or refuses and says why.
    @discardableResult
    public func commitDraft() -> Bool {
        guard let draft else { return refuse(.noPolygonDrawn) }
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = nameProblem(name, excluding: nil) { return refuse(problem) }
        guard let scale = draft.scale else { return refuse(.scaleNotAssigned) }
        guard let onCreateRegion else { return refuse(.rejectedByCore(Self.notWiredMessage)) }
        refusal = nil
        onCreateRegion(
            ScaleRegionCreation(
                id: draft.id,
                pageID: draft.pageID,
                boundary: draft.boundary,
                name: name,
                scale: scale,
                priority: draft.priority,
                locked: draft.locked,
                colorRGBA: draft.colorRGBA
            )
        )
        selection = draft.id
        submittedDraft = draft
        self.draft = nil
        // The capture ended in a region rather than in a cancel, so the canvas disarms itself
        // through the creation path and must not also be told the drawing was abandoned.
        hasArmedCapture = false
        capturePageID = nil
        return true
    }

    /// Opens calibration for the draft, so its scale is measured on the drawing rather than
    /// borrowed from somewhere else on the sheet.
    @discardableResult
    public func calibrateDraft() -> Bool {
        guard let draft else { return refuse(.noPolygonDrawn) }
        guard let onCalibrateDraft else { return refuse(.rejectedByCore(Self.notWiredMessage)) }
        refusal = nil
        onCalibrateDraft(draft)
        return true
    }

    /// Records a rejection the core made after the panel had already accepted the draft —
    /// a self-intersecting boundary, for instance, which only the geometry package can see.
    ///
    /// A refused create puts the submitted draft back in the editor — boundary, name, colour and
    /// scale — so the person can pick another scale instead of drawing the boundary again
    /// (T-056). A refusal of some other edit leaves the draft state alone.
    public func rejectDraft(reason: String) {
        if draft == nil, let submitted = submittedDraft,
           !regions.contains(where: { $0.id == submitted.id }),
           currentPageID.map({ $0 == submitted.pageID }) ?? true {
            draft = submitted
            if selection == submitted.id { selection = nil }
            hasArmedCapture = true
            capturePageID = submitted.pageID
        }
        submittedDraft = nil
        _ = refuse(.rejectedByCore(reason))
    }

    // MARK: - Editing an existing region

    /// Renames a region. A locked region refuses, and so does a panel with no rename hook —
    /// accepting a rename nothing will store would be a silent no-op.
    @discardableResult
    public func rename(regionID: UUID, to name: String) -> Bool {
        guard let region = region(regionID) else { return refuse(.unknownRegion) }
        guard !region.locked else { return refuse(.regionLocked(name: region.name)) }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = nameProblem(trimmed, excluding: regionID) { return refuse(problem) }
        guard let onRenameRegion else { return refuse(.rejectedByCore(Self.notWiredMessage)) }
        refusal = nil
        onRenameRegion(regionID, trimmed)
        return true
    }

    // MARK: - Renaming in the row (S-091)

    /// The region whose name is open for editing in its row, or `nil`.
    public private(set) var renamingRegionID: UUID?
    /// The text in the row's rename field.
    public var renameDraft: String = ""

    /// Opens a region's name for editing in its row. A locked region refuses, as every other
    /// edit to it does.
    @discardableResult
    public func beginRename(regionID: UUID) -> Bool {
        guard let region = region(regionID) else { return refuse(.unknownRegion) }
        guard !region.locked else { return refuse(.regionLocked(name: region.name)) }
        refusal = nil
        renamingRegionID = regionID
        renameDraft = region.name
        return true
    }

    /// Commits the row's rename. Unchanged text closes the field without an edit; a refused
    /// name keeps the field open with the refusal stated.
    @discardableResult
    public func commitRename() -> Bool {
        guard let regionID = renamingRegionID, let region = region(regionID) else {
            renamingRegionID = nil
            return false
        }
        if renameDraft.trimmingCharacters(in: .whitespacesAndNewlines) == region.name {
            renamingRegionID = nil
            refusal = nil
            return true
        }
        guard rename(regionID: regionID, to: renameDraft) else { return false }
        renamingRegionID = nil
        return true
    }

    /// Closes the rename field without an edit.
    public func cancelRename() {
        renamingRegionID = nil
        refusal = nil
    }

    /// Assigns a scale to an existing region. A locked region refuses, and so does a panel
    /// with no assign hook.
    @discardableResult
    public func assignScale(_ scale: ScaleSummary, to regionID: UUID) -> Bool {
        guard let region = region(regionID) else { return refuse(.unknownRegion) }
        guard !region.locked else { return refuse(.regionLocked(name: region.name)) }
        guard let onAssignScale else { return refuse(.rejectedByCore(Self.notWiredMessage)) }
        refusal = nil
        onAssignScale(regionID, scale)
        return true
    }

    /// Opens calibration for one region. A locked region refuses.
    @discardableResult
    public func editScale(regionID: UUID) -> Bool {
        guard let region = region(regionID) else { return refuse(.unknownRegion) }
        guard !region.locked else { return refuse(.regionLocked(name: region.name)) }
        refusal = nil
        onCalibrateRegion?(regionID)
        return true
    }

    /// Locks or unlocks a region. Never refused: this is the way out of every other refusal.
    public func setLocked(_ locked: Bool, regionID: UUID) {
        guard region(regionID) != nil else { _ = refuse(.unknownRegion); return }
        refusal = nil
        onSetLocked?(regionID, locked)
    }

    /// Deletes a region, refusing while it is locked or while it still measures something.
    ///
    /// The second refusal is the one that matters. Deleting a region does not delete the
    /// measurements inside it — it re-measures them at the page scale, which changes numbers
    /// an estimator has already read. Project Zones refuse the same way for the same reason;
    /// there the loss is a grouping, here it is a quantity.
    @discardableResult
    public func delete(regionID: UUID) -> Bool {
        guard let region = region(regionID) else { return refuse(.unknownRegion) }
        guard !region.locked else { return refuse(.regionLocked(name: region.name)) }
        let count = markupCount(of: regionID)
        guard count == 0 else {
            refusedRegionID = regionID
            return refuse(.regionInUse(name: region.name, markupCount: count))
        }
        guard let onDeleteRegion else { return refuse(.rejectedByCore(Self.notWiredMessage)) }
        refusal = nil
        onDeleteRegion(regionID)
        if selection == regionID { selection = nil }
        return true
    }

    /// Shows or hides one region outline. Allowed on a locked region: visibility is a view
    /// choice, not an edit to the region.
    public func setVisible(_ visible: Bool, regionID: UUID) {
        guard region(regionID) != nil else { _ = refuse(.unknownRegion); return }
        refusal = nil
        onSetVisible?(regionID, visible)
    }

    /// Moves a region `delta` places through the resolution order and publishes the whole new
    /// order, highest priority first.
    ///
    /// The whole order is emitted rather than one changed priority because priorities are only
    /// meaningful relative to each other; writing one of them and leaving the rest is how two
    /// regions end up tied, which the resolver reports as ambiguous rather than guessing.
    /// A locked region's place in the order is part of what the lock protects.
    ///
    /// Two moves are refused, not one. Moving a locked region is the obvious case. Moving an
    /// *unlocked* region past a locked one is the case that was missed: priority only means
    /// anything relative to the other regions, so a region jumping over a locked one changes
    /// which scale the locked region wins with, without anybody unlocking anything and without
    /// the locked row appearing to move. Finding CR-178.
    @discardableResult
    public func movePriority(regionID: UUID, by delta: Int) -> Bool {
        var order = ordered
        guard let index = order.firstIndex(where: { $0.id == regionID }) else {
            return refuse(.unknownRegion)
        }
        let moved = order[index]
        guard !moved.locked else { return refuse(.regionLocked(name: moved.name)) }
        let destination = index + delta
        guard destination >= 0, destination < order.count, delta != 0 else { return false }

        let span = min(index, destination)...max(index, destination)
        if let blocked = order[span].first(where: { $0.locked }) {
            return refuse(.regionLocked(name: blocked.name))
        }

        refusal = nil
        order.remove(at: index)
        order.insert(moved, at: destination)
        let orderedIDs = order.map(\.id)
        applyLocalOrder(orderedIDs)
        onReorderRegions?(orderedIDs)
        return true
    }

    /// Mirrors a new order onto the local copies so the list re-sorts before the core answers.
    /// The core's next ``setRegions(_:pageID:)`` is still the authority.
    ///
    /// A locked region keeps the exact priority the core gave it. The unlocked ones are numbered
    /// downwards around those fixed points, each strictly below the one above it, so the list
    /// re-sorts into the requested order without a single locked number being rewritten and
    /// without two regions ever landing on the same value.
    private func applyLocalOrder(_ orderedIDs: [UUID]) {
        // Start above everything present, so the first unlocked region can always be given a
        // value greater than the one below it and lower than nothing.
        var ceiling = (regions.map(\.priority).max() ?? 0) + orderedIDs.count + 1
        for id in orderedIDs {
            guard let index = regions.firstIndex(where: { $0.id == id }) else { continue }
            if regions[index].locked, regions[index].priority < ceiling {
                ceiling = regions[index].priority
                continue
            }
            ceiling -= 1
            regions[index].priority = ceiling
        }
    }

    // MARK: - Overlaps

    /// Reveals the shared area of an overlap so the person can redraw one of the two regions.
    ///
    /// This is the panel's *only* overlap action, on purpose. Picking a winner here would be
    /// the app choosing a scale, which is the one thing it must never do.
    public func revealOverlap(_ overlap: ScaleRegionOverlap) {
        refusal = nil
        selection = overlap.second
        onRevealOverlap?(overlap)
    }

    // MARK: - Crossings

    /// Puts a crossing decision in front of the person. Nothing is preselected.
    public func present(crossing: ScaleRegionCrossing) {
        self.crossing = crossing
        chosenCrossingResolution = nil
        refusal = nil
        isAwaitingPolygon = false
    }

    /// Picks one of the offered outcomes, without applying it.
    ///
    /// An outcome the crossing does not offer is refused — `splitAtBoundary` for a count group,
    /// or a region that is not one of the candidates. Without this check the panel could ask the
    /// core to cut a geometry that cannot be cut.
    @discardableResult
    public func chooseCrossingResolution(_ resolution: ScaleRegionCrossingResolution) -> Bool {
        guard let crossing else { return refuse(.crossingUnresolved) }
        guard crossing.offeredResolutions.contains(resolution) else {
            return refuse(.crossingOutcomeNotOffered)
        }
        refusal = nil
        chosenCrossingResolution = resolution
        return true
    }

    /// Applies the chosen outcome. Refuses while nothing is chosen.
    @discardableResult
    public func confirmCrossing() -> Bool {
        guard let crossing else { return refuse(.crossingUnresolved) }
        guard let chosen = chosenCrossingResolution else { return refuse(.crossingUnresolved) }
        refusal = nil
        onResolveCrossing?(crossing.id, chosen)
        self.crossing = nil
        chosenCrossingResolution = nil
        return true
    }

    /// Backs out of the crossing prompt.
    ///
    /// Escape is not a fourth outcome. Leaving the question unanswered means the measurement is
    /// not created, which is exactly ``ScaleRegionCrossingResolution/block`` — so that is what
    /// is applied, and the person is left with a drawing that gained nothing rather than a
    /// measurement whose scale nobody chose.
    public func cancelCrossing() {
        guard let crossing else { return }
        refusal = nil
        chosenCrossingResolution = nil
        self.crossing = nil
        onResolveCrossing?(crossing.id, .block)
    }

    // MARK: - Private

    private static let notWiredMessage = NSLocalizedString(
        "This document cannot store Scale Regions yet.",
        comment: "Scale Region refusal shown when the panel has no document behind it"
    )

    @discardableResult
    private func refuse(_ reason: ScaleRegionRefusal) -> Bool {
        refusal = reason
        return false
    }

    /// "Scale Region 3" — the first number whose name ``nameProblem(_:excluding:)`` accepts.
    ///
    /// The loop asks the same rule the Create button reads. It used to skip exact matches only,
    /// so beside a region named `scale region 2` or `Scale Region 2 ` the draft was offered
    /// `Scale Region 2`, which the case- and whitespace-blind rule then called taken, and Create
    /// started disabled on the default name (R-147).
    private func suggestedName() -> String {
        let format = NSLocalizedString(
            "Scale Region %d",
            comment: "Default name for a newly drawn Scale Region, with its number"
        )
        var number = regions.count + 1
        var candidate = String(format: format, number)
        while nameProblem(candidate, excluding: nil) != nil {
            number += 1
            candidate = String(format: format, number)
        }
        return candidate
    }
}
