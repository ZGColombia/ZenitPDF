import AppKit
import SwiftUI

/// Generic actions that already have a good SF Symbol.
///
/// Zenit only draws its own glyph when the system has no honest answer (see `ZPDFIconKind`).
/// Everything else stays on SF Symbols so the app inherits the platform's weight matching,
/// optical alignment and localisation.
public enum ZPDFSymbol: String, CaseIterable, Sendable, Hashable {
    case select
    case pan
    case text
    case callout
    case shapes
    case measure
    case toolLibrary
    case search
    case revisionCompare
    case revisionOverlay
    case splitCanvas
    case workspaces
    case projectZones
    case scaleRegions
    case quantityLedger
    case export
    case print
    case open
    case save
    case undo
    case redo
    case zoomIn
    case zoomOut
    case fitWidth
    case fitPage
    case actualSize
    case navigator
    case inspector
    case pages
    case bookmarks
    case layers
    case add
    case remove
    case delete
    case duplicate
    case lock
    case unlock
    case visible
    case hidden
    case settings
    case info
    case success
    case warning
    case error
    case disclosureClosed
    case disclosureOpen
    /// A chevron pointing at the leading edge. Used by the Inspector's ear, which restores a
    /// pane that arrives from the right: the chevron points the way the pane will travel.
    case chevronLeading
    /// A chevron pointing at the trailing edge. The Navigator's ear.
    case chevronTrailing
    /// A chevron pointing up. The bottom pane's ears, and Previous Page.
    case chevronUp
    /// A chevron pointing down. Next Page.
    case chevronDown
    case more
    case close
    case options

    // MARK: 2026-09-23 mockup chrome

    /// The Zoom tool in the tool group (click to zoom, drag a marquee).
    case zoomTool
    /// Filter a list (the ledger bar's Filter, the document search options).
    case filter
    /// Clear a text field.
    case clear
    /// The ledger's Per Sheet grouping toggle.
    case perSheet
    /// Edit several rows at once.
    case bulkEdit
    /// Move a pane into its own window.
    case detach
    /// The ledger's History tab.
    case history
    /// The author avatar's fallback when no initials can be formed.
    case person
    /// Horizontal sliders: a search's or list's options (sources, match case, whole words).
    case sliders
    /// The Text tool: a single capital "A", as the 2026-09-23 mockup draws it. `text` ("Aa")
    /// stays for text markup kinds in lists and badges.
    case textTool
    /// Four corner marks: fit the whole page into the view (the canvas bar's Fit Page).
    case viewfinder

    /// The SF Symbol name backing this action.
    public var systemName: String {
        switch self {
        case .select: return "cursorarrow"
        case .pan: return "hand.raised"
        case .text: return "textformat"
        case .callout: return "text.bubble"
        case .shapes: return "square.on.circle"
        case .measure: return "ruler"
        case .toolLibrary: return "square.grid.2x2"
        case .search: return "magnifyingglass"
        case .revisionCompare: return "rectangle.on.rectangle"
        case .revisionOverlay: return "square.stack"
        case .splitCanvas: return "square.split.2x1"
        case .workspaces: return "macwindow.on.rectangle"
        case .projectZones: return "square.dashed"
        case .scaleRegions: return "grid"
        case .quantityLedger: return "tablecells"
        case .export: return "square.and.arrow.up"
        case .print: return "printer"
        case .open: return "folder"
        case .save: return "arrow.down.doc"
        case .undo: return "arrow.uturn.backward"
        case .redo: return "arrow.uturn.forward"
        case .zoomIn: return "plus.magnifyingglass"
        case .zoomOut: return "minus.magnifyingglass"
        case .fitWidth: return "arrow.left.and.right"
        case .fitPage: return "arrow.up.left.and.arrow.down.right"
        case .actualSize: return "1.magnifyingglass"
        case .navigator: return "sidebar.left"
        case .inspector: return "sidebar.right"
        case .pages: return "doc.on.doc"
        case .bookmarks: return "bookmark"
        case .layers: return "square.3.layers.3d"
        case .add: return "plus"
        case .remove: return "minus"
        case .delete: return "trash"
        case .duplicate: return "plus.square.on.square"
        case .lock: return "lock"
        case .unlock: return "lock.open"
        case .visible: return "eye"
        case .hidden: return "eye.slash"
        case .settings: return "gearshape"
        case .info: return "info.circle"
        case .success: return "checkmark.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "exclamationmark.octagon"
        case .disclosureClosed: return "chevron.right"
        case .disclosureOpen: return "chevron.down"
        case .chevronLeading: return "chevron.left"
        case .chevronTrailing: return "chevron.right"
        case .chevronUp: return "chevron.up"
        case .chevronDown: return "chevron.down"
        case .more: return "ellipsis"
        case .close: return "xmark"
        case .options: return "line.3.horizontal"
        case .zoomTool: return "magnifyingglass"
        case .filter: return "line.3.horizontal.decrease"
        case .clear: return "xmark.circle.fill"
        case .perSheet: return "doc.text"
        case .bulkEdit: return "square.and.pencil"
        case .detach: return "macwindow.badge.plus"
        case .history: return "clock.arrow.circlepath"
        case .person: return "person.crop.circle"
        case .sliders: return "slider.horizontal.3"
        case .textTool: return "character"
        case .viewfinder: return "viewfinder"
        }
    }

    /// VoiceOver description for the action.
    public var accessibilityLabel: String {
        switch self {
        case .select: return NSLocalizedString("Select", comment: "Tool: select and edit markup")
        case .pan: return NSLocalizedString("Pan", comment: "Tool: pan the canvas")
        case .text: return NSLocalizedString("Text", comment: "Tool: add a text markup")
        case .callout: return NSLocalizedString("Callout", comment: "Tool: add a callout markup")
        case .shapes: return NSLocalizedString("Shapes", comment: "Tool group: shape markups")
        case .measure: return NSLocalizedString("Measure", comment: "Tool group: measurement tools")
        case .toolLibrary: return NSLocalizedString("Tool Library", comment: "Panel: saved tool presets")
        case .search: return NSLocalizedString("Search", comment: "Action: search the document")
        case .revisionCompare: return NSLocalizedString("Revision Compare", comment: "Feature: compare two revisions side by side")
        case .revisionOverlay: return NSLocalizedString("Revision Overlay", comment: "Feature: overlay two revisions")
        case .splitCanvas: return NSLocalizedString("Split Canvas", comment: "Feature: split the canvas into panes")
        case .workspaces: return NSLocalizedString("Workspaces", comment: "Feature: saved window layouts")
        case .projectZones: return NSLocalizedString("Project Zones", comment: "Feature: named regions of a project")
        case .scaleRegions: return NSLocalizedString("Scale Regions", comment: "Feature: per-region drawing scales")
        case .quantityLedger: return NSLocalizedString("Quantity Ledger", comment: "Panel: the takeoff quantity table")
        case .export: return NSLocalizedString("Export", comment: "Action: export the document or data")
        case .print: return NSLocalizedString("Print", comment: "Action: print the document")
        case .open: return NSLocalizedString("Open", comment: "Action: open a document")
        case .save: return NSLocalizedString("Save", comment: "Action: save the document")
        case .undo: return NSLocalizedString("Undo", comment: "Action: undo the last change")
        case .redo: return NSLocalizedString("Redo", comment: "Action: redo the last undone change")
        case .zoomIn: return NSLocalizedString("Zoom In", comment: "Action: increase zoom")
        case .zoomOut: return NSLocalizedString("Zoom Out", comment: "Action: decrease zoom")
        case .fitWidth: return NSLocalizedString("Fit Width", comment: "Action: fit the page width")
        case .fitPage: return NSLocalizedString("Fit Page", comment: "Action: fit the whole page")
        case .actualSize: return NSLocalizedString("Actual Size", comment: "Action: zoom to 100 percent")
        case .navigator: return NSLocalizedString("Navigator", comment: "Panel: the left sidebar")
        case .inspector: return NSLocalizedString("Inspector", comment: "Panel: the right sidebar")
        case .pages: return NSLocalizedString("Pages", comment: "Navigator section: page thumbnails")
        case .bookmarks: return NSLocalizedString("Bookmarks", comment: "Navigator section: bookmarks")
        case .layers: return NSLocalizedString("Layers", comment: "Navigator section: layers")
        case .add: return NSLocalizedString("Add", comment: "Action: add an item")
        case .remove: return NSLocalizedString("Remove", comment: "Action: remove an item")
        case .delete: return NSLocalizedString("Delete", comment: "Action: delete an item")
        case .duplicate: return NSLocalizedString("Duplicate", comment: "Action: duplicate an item")
        case .lock: return NSLocalizedString("Lock", comment: "Action: lock an item against editing")
        case .unlock: return NSLocalizedString("Unlock", comment: "Action: unlock an item for editing")
        case .visible: return NSLocalizedString("Visible", comment: "State: the item is shown")
        case .hidden: return NSLocalizedString("Hidden", comment: "State: the item is hidden")
        case .settings: return NSLocalizedString("Settings", comment: "Action: open settings")
        case .info: return NSLocalizedString("Information", comment: "Status: informational")
        case .success: return NSLocalizedString("Valid", comment: "Status: the value is valid")
        case .warning: return NSLocalizedString("Warning", comment: "Status: needs attention")
        case .error: return NSLocalizedString("Error", comment: "Status: blocking problem")
        case .chevronLeading: return NSLocalizedString("Show the pane on the left", comment: "Direction: a pane arrives from the right edge")
        case .chevronTrailing: return NSLocalizedString("Show the pane on the right", comment: "Direction: a pane arrives from the left edge")
        // BH-507: the glyph serves the bottom pane's ear and Previous Page, so its own label
        // must be true for both; the ear speaks its pane's name itself.
        case .chevronUp: return NSLocalizedString("Previous page", comment: "Direction: back through the document; also the arrow on the bottom pane's ear")
        case .chevronDown: return NSLocalizedString("Next page", comment: "Direction: forward through the document")
        case .disclosureClosed: return NSLocalizedString("Expand", comment: "Action: expand a collapsed section")
        case .disclosureOpen: return NSLocalizedString("Collapse", comment: "Action: collapse an expanded section")
        case .more: return NSLocalizedString("More Actions", comment: "Action: show the overflow menu")
        case .close: return NSLocalizedString("Close", comment: "Action: close a panel, tab or window")
        case .options: return NSLocalizedString("Options", comment: "Action: show a pane's options menu")
        case .zoomTool: return NSLocalizedString("Zoom", comment: "Tool: zoom the canvas by clicking or dragging")
        case .filter: return NSLocalizedString("Filter", comment: "Action: filter a list")
        case .clear: return NSLocalizedString("Clear", comment: "Action: clear a text field")
        case .perSheet: return NSLocalizedString("Per Sheet", comment: "Action: group quantities by sheet")
        case .bulkEdit: return NSLocalizedString("Bulk Edit", comment: "Action: edit several rows at once")
        case .detach: return NSLocalizedString("Detach", comment: "Action: move a pane into its own window")
        case .history: return NSLocalizedString("History", comment: "Tab: the change history")
        case .person: return NSLocalizedString("Author", comment: "Glyph: a person, the author of a markup")
        case .sliders: return NSLocalizedString("Search Options", comment: "Glyph: sliders, the options of a search or list")
        case .textTool: return NSLocalizedString("Text", comment: "Tool: add a text markup")
        case .viewfinder: return NSLocalizedString("Fit Page", comment: "Action: fit the whole page")
        }
    }

    /// A SwiftUI image for the symbol. Decorative by default — the enclosing control carries
    /// the accessibility label so VoiceOver does not announce the same thing twice.
    public var image: Image {
        Image(systemName: systemName)
    }

    /// A template `NSImage` for AppKit surfaces.
    ///
    /// Returns `nil` only if the running system does not vend this symbol, which lets callers
    /// fall back to a text-only control rather than showing an empty button.
    @MainActor
    public func nsImage(pointSize: CGFloat = ZPDFSpacing.Control.icon, weight: NSFont.Weight = .regular) -> NSImage? {
        guard let base = NSImage(systemSymbolName: systemName, accessibilityDescription: accessibilityLabel) else {
            return nil
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        let configured = base.withSymbolConfiguration(configuration) ?? base
        configured.isTemplate = true
        configured.accessibilityDescription = accessibilityLabel
        return configured
    }
}
