import Foundation
import Observation

/// Presents the drawing canvas: viewport, visible markups, selection and snap feedback.
@MainActor
public protocol CanvasPresenting: ZenitPresenting {

    /// What the canvas is currently showing.
    var viewport: ViewportSnapshot { get }
    /// Markups intersecting the visible area, already filtered for layer and zone visibility.
    var visibleMarkups: [MarkupSummary] { get }
    /// Identities of the selected markups.
    var selectedMarkupIDs: Set<UUID> { get }
    /// Every selected markup, resolved from **all** markups the presenter knows — including
    /// ones on another page, on a hidden layer or filtered out of ``visibleMarkups``.
    ///
    /// This is "the selection" as the Inspector and every edit command mean it. A presenter
    /// that holds only the visible set inherits a default that falls back to it; one that
    /// knows the whole document should implement this (BH-279, IM-024).
    var resolvedSelectedMarkups: [MarkupSummary] { get }
    /// The winning snap candidate, or `nil` when nothing is snapping.
    var snapFeedback: SnapFeedbackSnapshot? { get }
    /// The scale in force at the cursor.
    var activeScale: ScaleSummary? { get }
    /// The Scale Region under the cursor, or `nil` for the page default.
    var activeScaleRegion: ScaleRegionSummary? { get }
    /// Whether the active page has vector content for Vector Snap.
    var isVectorSnapAvailable: Bool { get }
    /// How the window is split.
    var splitCanvasMode: SplitCanvasMode { get }
    /// How markups that fail the ledger filter are drawn.
    var filterBehavior: LedgerCanvasFilterBehavior { get }

    /// Sets the zoom factor, clamped to the supported range.
    func setZoom(_ zoom: Double)
    /// Fits the whole page in the viewport.
    func zoomToFit()
    /// Fits the page width in the viewport.
    func zoomToFitWidth()
    /// Scrolls and zooms so one markup fills a comfortable part of the viewport, then
    /// flashes it. The flash resolves to a static highlight under Reduce Motion.
    func zoomTo(markupID: UUID)
    /// Replaces or extends the selection.
    func select(markupIDs: Set<UUID>, additive: Bool)
    /// Clears the selection.
    func clearSelection()
    /// Reports a new cursor position in page space, or `nil` when the pointer leaves the page.
    func updateCursor(pagePoint: PDFPointValue?)
    /// Changes the Split Canvas layout.
    func setSplitCanvasMode(_ mode: SplitCanvasMode)
    /// Changes how filtered-out markups are drawn.
    func setFilterBehavior(_ behavior: LedgerCanvasFilterBehavior)

    /// Whether the coverage map is drawn over the page — the opt-in overlay that tints what has
    /// been measured so the gaps stand out. Off by default; the canvas host reads it and draws.
    var showsCoverageMap: Bool { get set }
}

extension CanvasPresenting {

    /// Presenters that predate the coverage map, and mocks that do not draw, honestly report
    /// "off" and ignore writes rather than pretending to show an overlay they cannot.
    public var showsCoverageMap: Bool {
        get { false }
        set { }
    }
}

extension CanvasPresenting {

    /// Default for presenters that only hold the visible set: the visible selected markups.
    public var resolvedSelectedMarkups: [MarkupSummary] { selectedMarkups }

    /// The selected markups **that are visible**, in the order they appear in
    /// ``visibleMarkups`` — what the canvas can draw handles around. Anything that means the
    /// whole selection (the Inspector, edit commands) reads ``resolvedSelectedMarkups``.
    public var selectedMarkups: [MarkupSummary] {
        visibleMarkups.filter { selectedMarkupIDs.contains($0.id) }
    }
}
