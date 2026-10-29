import Foundation
import Observation

/// The panel state SwiftUI binds to and the layout controller persists.
///
/// Pane sizes live in AppKit's autosave; *which page a pane is showing* does not, and it is the
/// part users notice: reopening a window on Pages when you were working in Zones is a small,
/// constant irritation.
@MainActor
@Observable
public final class ShellPanelState {

    /// The Navigator page on screen.
    public var navigatorSection: NavigatorSection {
        didSet { if navigatorSection != oldValue { onChange?() } }
    }

    /// The Inspector sections that are open.
    public var expandedInspectorSections: Set<InspectorSection> {
        didSet { if expandedInspectorSections != oldValue { onChange?() } }
    }

    /// Whether the Quantity Ledger is currently in its own window.
    ///
    /// The layout controller owns the fact; this is the observable mirror the ledger pane reads,
    /// so its dock control is labelled for what it will actually do.
    public var isLedgerDetached: Bool {
        didSet { if isLedgerDetached != oldValue { onChange?() } }
    }

    /// Which tab of the bottom pane is showing.
    ///
    /// Owned here rather than by the pane's own `@State` because *Show History* has to open the
    /// pane **on** History. A tab only the pane's segmented control can reach is not a surface a
    /// menu item, or an ear, can serve.
    public var bottomPaneTab: ZPDFBottomPaneTab {
        didSet { if bottomPaneTab != oldValue { onChange?() } }
    }

    /// The Inspector page on screen: Markup, Properties, Comments or Tools.
    ///
    /// Held here rather than in the Inspector's own `@State` (L-90) so that the page a click
    /// chose is a fact the shell — and a test — can read, as the Navigator page and the bottom
    /// pane's tab already are. Not persisted: a window opens on ``InspectorTab/initial``.
    public var inspectorTab: InspectorTab = .initial

    /// The closable surfaces currently on screen.
    ///
    /// Written by ``ProjectWindowLayoutController`` after every collapse, reveal, detach and
    /// tab change; read by the ears, by the toolbar chips and by the View menu's title flip.
    /// Not persisted — the pane collapse flags in ``ProjectWindowLayoutState`` are the record;
    /// this is the observable mirror SwiftUI redraws from, which is why it raises no change.
    public internal(set) var visibleSurfaces: Set<ZPDFClosableSurface> = Set(ZPDFClosableSurface.allCases)

    /// The surfaces whose ear is showing: the ones whose *pane* is gone, which is not the same
    /// as the ones that are not visible. History is not visible while the bottom pane shows
    /// Quantities, but it needs no ear — its tab is right there. It needs one exactly when the
    /// bottom pane itself is closed, and then so does the Quantity Ledger.
    public internal(set) var earSurfaces: Set<ZPDFClosableSurface> = []

    /// Whether one closable surface is on screen.
    public func isVisible(_ surface: ZPDFClosableSurface) -> Bool {
        visibleSurfaces.contains(surface)
    }

    /// Whether one closable surface is showing its ear.
    public func showsEar(for surface: ZPDFClosableSurface) -> Bool {
        earSurfaces.contains(surface)
    }

    /// Whether the docked Quantity Ledger is collapsed to just its header bar.
    ///
    /// A one-click workflow for the summary list: clicking the header chip or the chevron
    /// collapses the pane to its header and restores it to its previous height. The layout controller owns the split
    /// mechanics; this is the observable mirror the pane view reads.
    public var isLedgerCollapsedToBar: Bool {
        didSet { if isLedgerCollapsedToBar != oldValue { onChange?() } }
    }

    /// Whether ⌘F has asked the search field to take the keyboard and the Search page has not
    /// yet done so (IM-132). Observable, so a Search page already on screen reacts; not
    /// persisted, and raising it writes nothing.
    public private(set) var hasPendingSearchFieldFocus = false

    /// Asks the Search page to put the caret in its field.
    public func requestSearchFieldFocus() {
        hasPendingSearchFieldFocus = true
    }

    /// Takes the outstanding focus request, if there is one. The page calls this once it can
    /// honour it, so one ⌘F focuses the field once.
    @discardableResult
    public func takeSearchFieldFocusRequest() -> Bool {
        guard hasPendingSearchFieldFocus else { return false }
        hasPendingSearchFieldFocus = false
        return true
    }

    /// Raised after any persistable change, so the owner can write the layout state.
    @ObservationIgnored
    public var onChange: (@MainActor () -> Void)?

    /// Creates panel state from a stored layout.
    public init(
        navigatorSection: NavigatorSection = .pages,
        expandedInspectorSections: Set<InspectorSection> = InspectorSection.defaultExpanded,
        isLedgerDetached: Bool = false,
        isLedgerCollapsedToBar: Bool = false,
        bottomPaneTab: ZPDFBottomPaneTab = .quantities
    ) {
        self.navigatorSection = navigatorSection
        self.expandedInspectorSections = expandedInspectorSections
        self.isLedgerDetached = isLedgerDetached
        self.isLedgerCollapsedToBar = isLedgerCollapsedToBar
        self.bottomPaneTab = bottomPaneTab
    }

    /// Whether one Inspector section is open.
    public func isExpanded(_ section: InspectorSection) -> Bool {
        expandedInspectorSections.contains(section)
    }

    /// Opens or closes one Inspector section.
    public func setExpanded(_ expanded: Bool, section: InspectorSection) {
        if expanded {
            expandedInspectorSections.insert(section)
        } else {
            expandedInspectorSections.remove(section)
        }
    }
}
