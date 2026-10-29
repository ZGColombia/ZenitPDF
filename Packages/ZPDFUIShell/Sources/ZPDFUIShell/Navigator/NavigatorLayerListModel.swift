import Foundation
import Observation
import ZPDFUIPresentation

/// One document (PDF optional-content) layer row in the Navigator.
public struct NavigatorLayerRow: Identifiable, Hashable, Sendable {

    /// The layer's stable identity (`PDFLayerID.rawValue`), never its display name —
    /// two layers called "Walls" are two rows.
    public let id: String
    /// The display name.
    public let name: String
    /// The visibility in force: document default overridden by the project's setting.
    public let isVisible: Bool
    /// Whether the document's default configuration locks the layer.
    public let isLocked: Bool

    /// Creates a row.
    public init(id: String, name: String, isVisible: Bool, isLocked: Bool = false) {
        self.id = id
        self.name = name
        self.isVisible = isVisible
        self.isLocked = isLocked
    }
}

/// The Navigator's document-layer list state (gap 10 / S23).
///
/// The shell renders whatever rows the app tier applies and reports toggles through
/// ``onSetVisible`` — it never computes effective visibility itself, because the truth
/// (`/OCProperties` plus the project's overrides) lives behind the engine barrier in the
/// app tier. Until ``apply(rows:)`` is called, the Navigator falls back to the markup-derived
/// layer list, so a drawing without PDF layers loses nothing.
@MainActor
@Observable
public final class NavigatorLayerListModel {

    /// The document layers, in `/OCGs` order.
    public private(set) var rows: [NavigatorLayerRow] = []

    /// Raised when a visibility checkbox is toggled. The app tier updates the real
    /// visibility set, rebuilds the snap index, re-renders the canvas and calls
    /// ``apply(rows:)`` back with the new effective state.
    @ObservationIgnored
    public var onSetVisible: (@MainActor (_ layerID: String, _ visible: Bool) -> Void)?

    /// Feature 30: the layer measuring is locked to, or `nil`. Mirrored from the document
    /// model by the window wiring; the rows draw the lock marker from this.
    public private(set) var measureLockLayerID: String?

    /// Raised when the person locks measuring to a layer or lifts the lock.
    @ObservationIgnored
    public var onSetMeasureLock: (@MainActor (_ layerID: String?) -> Void)?

    // MARK: - Markup layers

    /// Markup layers the person has unticked, by name.
    ///
    /// **One set, on the environment, that the canvas reads.** Markup-layer visibility used to
    /// live in two independent `@State` sets — one in the layer outline under the page column,
    /// one in the Layers page — so unticking "Walls" in one place left it ticked in the other,
    /// and neither reached the canvas: the markups stayed on the drawing and the checkbox
    /// hid nothing at all (CR-112). A markup layer is a property of the document, not of
    /// whichever list happens to be on screen, so it belongs here beside the PDF layers.
    ///
    /// Names, not ids, because a markup layer *is* its name: it is derived by grouping
    /// ``MarkupSummary/layer`` over the loaded markups, and there is no `/OCG` behind it.
    public private(set) var hiddenMarkupLayers: Set<String> = []

    /// Whether a markup layer is drawn.
    public func isMarkupLayerVisible(_ layer: String) -> Bool {
        !hiddenMarkupLayers.contains(layer)
    }

    /// Shows or hides a markup layer. Unlike ``setVisible(_:layerID:)`` the state flips here
    /// and now: the shell owns markup visibility, and nothing behind the engine barrier has to
    /// agree first.
    public func setMarkupLayerVisible(_ visible: Bool, layer: String) {
        let wasVisible = isMarkupLayerVisible(layer)
        guard wasVisible != visible else { return }
        if visible {
            hiddenMarkupLayers.remove(layer)
        } else {
            hiddenMarkupLayers.insert(layer)
        }
    }

    /// Whether a markup should be drawn, given its layer.
    ///
    /// A markup with no layer is always drawn — there is no row that could hide it.
    public func drawsMarkup(onLayer layer: String?) -> Bool {
        guard let layer, !layer.isEmpty else { return true }
        return isMarkupLayerVisible(layer)
    }

    // MARK: - The markup-layer list both Navigator lists show

    /// Which page the remembered layer names below belong to.
    @ObservationIgnored
    private var listedLayerScope: NavigatorLayerScope?
    /// Every markup-layer name seen on the page on screen since it came on screen.
    ///
    /// **Deliberately not observed.** It is written from inside the two lists' `body`, and an
    /// observed write there is a render loop.
    @ObservationIgnored
    private var listedLayerNames: Set<String> = []

    /// The markup layers to list for the page on screen (IM-127, BH-818).
    ///
    /// The lists derive layers from the canvas's *visible* markups, which is all the presenter
    /// publishes — and that set excludes whatever a ledger filter with "hide non-matching" has
    /// taken off the canvas. Derived straight from it, a layer whose every markup was filtered
    /// out simply vanished from both lists, and with it the only checkbox that could show it
    /// again. A name seen on this page therefore stays listed, at a count of zero, until the
    /// page or the drawing changes.
    ///
    /// Names are ordered the way a person reads an alphabetical list — `localizedStandardCompare`,
    /// so "dörrar, fönster, Väggar" rather than code-point order's "Väggar, dörrar, fönster".
    public func markupLayers(
        in markups: [MarkupSummary],
        scope: NavigatorLayerScope
    ) -> [ZPDFLayerItem] {
        let current = NavigatorLayersList.layers(in: markups)
        if scope != listedLayerScope {
            listedLayerScope = scope
            listedLayerNames = []
        }
        let currentNames = Set(current.map(\.name))
        listedLayerNames.formUnion(currentNames)
        let remembered = listedLayerNames.subtracting(currentNames)
        guard !remembered.isEmpty else { return current }
        return (current + remembered.map { ZPDFLayerItem(name: $0, markupCount: 0) })
            .sorted(by: NavigatorLayersList.readingOrder)
    }

    /// Creates an empty model.
    public init() {}

    /// Installs the rows the Navigator shows.
    public func apply(rows: [NavigatorLayerRow]) {
        self.rows = rows
    }

    /// Reports a toggle. The row itself flips only when the app tier applies new rows,
    /// so the checkbox always shows the state actually in force.
    /// Reflects the document's lock state into the rows.
    public func applyMeasureLock(_ layerID: String?) {
        if measureLockLayerID != layerID { measureLockLayerID = layerID }
    }

    /// The row's request: lock measuring to this layer, or lift the lock with `nil`.
    public func setMeasureLock(_ layerID: String?) {
        onSetMeasureLock?(layerID)
    }

    public func setVisible(_ visible: Bool, layerID: String) {
        onSetVisible?(layerID, visible)
    }
}

/// The page a Navigator markup-layer list describes: one drawing, one page.
public struct NavigatorLayerScope: Hashable, Sendable {

    /// The drawing on screen.
    public let documentID: UUID?
    /// The page on screen.
    public let pageID: PageDescriptor.ID?

    /// Creates a scope.
    public init(documentID: UUID?, pageID: PageDescriptor.ID?) {
        self.documentID = documentID
        self.pageID = pageID
    }
}
