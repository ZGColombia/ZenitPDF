import Foundation

/// How the canvas stacks pages.
public enum CanvasDisplayMode: String, Codable, Hashable, Sendable, CaseIterable {

    /// One page at a time.
    case single
    /// Vertically scrolling continuous pages.
    case continuous
    /// Two facing pages side by side.
    case twoUp

    /// A localized name for the view menu and the status bar.
    public var displayName: String {
        switch self {
        case .single: return NSLocalizedString("Single Page", comment: "Canvas page layout mode")
        case .continuous: return NSLocalizedString("Continuous", comment: "Canvas page layout mode")
        case .twoUp: return NSLocalizedString("Two Up", comment: "Canvas page layout mode")
        }
    }
}

/// How Split Canvas divides the window.
public enum SplitCanvasMode: String, Codable, Hashable, Sendable, CaseIterable {

    /// A single canvas fills the content area.
    case off
    /// Two canvases side by side.
    case vertical
    /// Two canvases stacked.
    case horizontal
    /// The second canvas lives in its own window.
    case detachedWindow

    /// A localized name for the Split Canvas control.
    public var displayName: String {
        switch self {
        case .off: return NSLocalizedString("Single Canvas", comment: "Split Canvas layout mode")
        case .vertical: return NSLocalizedString("Split Vertically", comment: "Split Canvas layout mode")
        case .horizontal: return NSLocalizedString("Split Horizontally", comment: "Split Canvas layout mode")
        case .detachedWindow: return NSLocalizedString("Detached Window", comment: "Split Canvas layout mode")
        }
    }
}

/// An immutable description of what the canvas is showing right now.
///
/// The measurement engine must never read a snapshot: zoom and backing scale exist here
/// only so that the view layer can size glyphs, hit-test tolerances and the loupe.
public struct ViewportSnapshot: Codable, Hashable, Sendable {

    /// Page currently under the cursor, or the first visible page when the pointer is outside.
    public var pageID: PageDescriptor.ID
    /// Zero-based index of ``pageID`` in the document.
    public var pageIndex: Int
    /// Zoom factor where `1.0` is 100 %. Zenit supports `0.05` through `64.0`.
    public var zoom: Double
    /// Rotation currently applied by the viewer on top of the page's own rotation.
    public var viewerRotation: PageRotation
    /// The part of the page that is on screen, in page space.
    public var visiblePageRect: PDFRectValue
    /// Cursor position in page space, or `nil` when the pointer is outside the page.
    public var cursorPagePoint: PDFPointValue?
    /// Backing scale factor of the display, `1.0` or `2.0` on current hardware.
    public var backingScaleFactor: Double
    /// How pages are stacked.
    public var displayMode: CanvasDisplayMode

    /// Creates a viewport snapshot.
    public init(
        pageID: PageDescriptor.ID,
        pageIndex: Int,
        zoom: Double,
        viewerRotation: PageRotation = .degrees0,
        visiblePageRect: PDFRectValue,
        cursorPagePoint: PDFPointValue? = nil,
        backingScaleFactor: Double = 2.0,
        displayMode: CanvasDisplayMode = .continuous
    ) {
        self.pageID = pageID
        self.pageIndex = pageIndex
        self.zoom = zoom
        self.viewerRotation = viewerRotation
        self.visiblePageRect = visiblePageRect
        self.cursorPagePoint = cursorPagePoint
        self.backingScaleFactor = backingScaleFactor
        self.displayMode = displayMode
    }

    /// The lowest zoom Zenit allows, 5 %.
    public static let minimumZoom: Double = 0.05
    /// The highest zoom Zenit allows, 6400 %.
    public static let maximumZoom: Double = 64.0

    /// Zoom rendered as a whole-percent string such as `"125%"`.
    public var zoomDisplayString: String {
        let percent = Int((zoom * 100).rounded())
        return String(
            format: NSLocalizedString("%d%%", comment: "Zoom percentage shown in the status bar"),
            percent
        )
    }

    /// Converts a distance in **view points** — the unit every canvas hit radius, handle gap
    /// and grab tolerance is designed in — into PDF points.
    ///
    /// IM-021: a screen-pixel helper that also divided by the backing scale shrank a 7-point
    /// vertex tolerance to 3.5 points on a Retina display while other tolerances divided by
    /// zoom alone. It was removed (R-144) so it cannot be picked up again; a tolerance named in
    /// points goes through this helper, which is the same on a 1× and a 2× display.
    public func pageDistance(forViewPoints points: Double) -> Double {
        guard zoom > 0, points.isFinite else { return 0 }
        return max(0, points / zoom)
    }
}
