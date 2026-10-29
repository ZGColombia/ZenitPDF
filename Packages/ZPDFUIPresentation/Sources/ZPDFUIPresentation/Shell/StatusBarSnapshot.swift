import Foundation

/// State of the background geometry index that feeds Vector Snap.
public enum GeometryIndexStatus: Codable, Hashable, Sendable {

    /// The page has no vector content, so Vector Snap cannot run on it.
    case unavailable
    /// The index is being built. `progress` is `0...1`.
    case building(progress: Double)
    /// The index is complete.
    case ready
    /// Indexing failed. The reason is already localized.
    case failed(reason: String)

    /// Whether Vector Snap can produce candidates right now.
    public var allowsVectorSnap: Bool {
        if case .ready = self { return true }
        return false
    }

    /// A localized status label for the status bar.
    public var displayName: String {
        switch self {
        case .unavailable:
            return NSLocalizedString("Vector Snap unavailable", comment: "Geometry index status on a page without vector content")
        case .building(let progress):
            let format = NSLocalizedString("Indexing %d%%", comment: "Geometry index status while building, with percent complete")
            // BH-791: a producer computing done / total with total == 0 hands NaN in, and
            // `Int(_:)` traps on it. Clamp to the documented 0...1 first.
            let clamped = progress.isFinite ? min(max(progress, 0), 1) : 0
            return String(format: format, Int((clamped * 100).rounded()))
        case .ready:
            return NSLocalizedString("Vector Snap ready", comment: "Geometry index status when complete")
        case .failed(let reason):
            let format = NSLocalizedString("Indexing failed: %@", comment: "Geometry index failure with reason")
            return String(format: format, reason)
        }
    }

    /// SF Symbol name so the state reads without colour.
    public var symbolName: String {
        switch self {
        case .unavailable: return "slash.circle"
        case .building: return "clock"
        case .ready: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        }
    }
}

/// Everything the status bar shows, as one atomic value.
///
/// Publishing the bar as a single snapshot keeps its fields consistent with one another;
/// a half-updated status bar is how a user ends up measuring against the wrong scale.
public struct StatusBarSnapshot: Codable, Hashable, Sendable {

    /// Page label of the active page, for example `"A-101"`.
    public var pageLabel: String
    /// Zero-based position of the active page in the document's page list (the set order),
    /// not its index in its own PDF, which a reorder leaves alone (ADR-0022).
    public var pageIndex: Int
    /// Number of pages in the active document.
    public var pageCount: Int
    /// Localized page size, for example `"841 × 594 mm"`.
    public var pageDimensionsText: String
    /// Ratio string of the scale in force, for example `"1:50"`.
    public var activeScaleDisplay: String
    /// Name of the Scale Region under the cursor, or `nil` for the page default.
    public var scaleRegionName: String?
    /// Symbol of the active output unit, for example `"m"`.
    public var outputUnitSymbol: String
    /// Cursor position in page space, or `nil` when the pointer is off the page.
    public var cursorPagePoint: PDFPointValue?
    /// Cursor position formatted in real-world units, or an empty string.
    public var cursorDisplayText: String
    /// Zoom rendered as a percentage string, for example `"125%"`.
    public var zoomDisplayString: String
    /// Whether Grid Snap is on.
    public var gridSnapEnabled: Bool
    /// Whether Vector Snap is on.
    public var vectorSnapEnabled: Bool
    /// Whether Markup Snap is on.
    public var markupSnapEnabled: Bool
    /// Whether the active tool stays selected after a markup is committed.
    public var reuseToolEnabled: Bool
    /// State of the geometry index for the active page.
    public var geometryIndexStatus: GeometryIndexStatus
    /// The name of the armed tool, for example `"Length"` or `"Callout"`.
    ///
    /// The rule for every tool: arming a tool must be
    /// visible and true — the toolbar shows which tool is active, **the status bar names
    /// it**, and the cursor changes. A lit chip over a canvas that is still in Select is
    /// the bug this segment makes impossible to hide.
    public var activeToolName: String
    /// A one-line, honest statement of what the armed tool will not do yet, or `nil`.
    ///
    /// "If a tool is not implemented yet, it must say so when armed rather than doing
    /// something else." This is where it says so.
    public var activeToolNote: String?

    /// Creates a status bar snapshot.
    public init(
        pageLabel: String,
        pageIndex: Int,
        pageCount: Int,
        pageDimensionsText: String,
        activeScaleDisplay: String,
        scaleRegionName: String? = nil,
        outputUnitSymbol: String,
        cursorPagePoint: PDFPointValue? = nil,
        cursorDisplayText: String = "",
        zoomDisplayString: String,
        gridSnapEnabled: Bool = false,
        vectorSnapEnabled: Bool = true,
        markupSnapEnabled: Bool = true,
        reuseToolEnabled: Bool = false,
        geometryIndexStatus: GeometryIndexStatus = .ready,
        activeToolName: String = NSLocalizedString("Select", comment: "Armed tool name"),
        activeToolNote: String? = nil
    ) {
        self.pageLabel = pageLabel
        self.pageIndex = pageIndex
        self.pageCount = pageCount
        self.pageDimensionsText = pageDimensionsText
        self.activeScaleDisplay = activeScaleDisplay
        self.scaleRegionName = scaleRegionName
        self.outputUnitSymbol = outputUnitSymbol
        self.cursorPagePoint = cursorPagePoint
        self.cursorDisplayText = cursorDisplayText
        self.zoomDisplayString = zoomDisplayString
        self.gridSnapEnabled = gridSnapEnabled
        self.vectorSnapEnabled = vectorSnapEnabled
        self.markupSnapEnabled = markupSnapEnabled
        self.reuseToolEnabled = reuseToolEnabled
        self.geometryIndexStatus = geometryIndexStatus
        self.activeToolName = activeToolName
        self.activeToolNote = activeToolNote
    }

    /// The Tool segment's text: the armed tool's name, plus its limitation when it has one.
    public var toolIndicatorText: String {
        toolIndicatorText(namedBy: activeToolName, note: activeToolNote)
    }

    /// The Tool segment's text with the name — and optionally the note — supplied by the caller.
    ///
    /// Apply and Place disarm both drawing families, so ``activeToolName`` is still the name of
    /// whatever tool was armed before, which is not what the next click does. The shell substitutes ``ArmedToolState/indicatorText`` there. It goes through this
    /// method rather than assembling its own string so there is exactly one format for
    /// "name, then the qualifier", and the two cannot start printing different dashes.
    ///
    /// A `nil` note means "no qualifier" — not "whatever the previous tool said", which is
    /// what it used to fall back to (BH-792). ``toolIndicatorText`` passes the current note
    /// explicitly.
    public func toolIndicatorText(namedBy name: String, note: String? = nil) -> String {
        let qualifier = note
        guard let qualifier, !qualifier.isEmpty else { return name }
        let format = NSLocalizedString(
            "%1$@ — %2$@",
            comment: "Status bar tool segment: armed tool name, then what it cannot do yet"
        )
        return String(format: format, name, qualifier)
    }

    /// A localized `"A-101, 1 of 3"` page indicator.
    public var pageIndicatorText: String {
        let format = NSLocalizedString(
            "%1$@ · %2$d of %3$d",
            comment: "Status bar page indicator: page label, one-based index, page count"
        )
        return String(format: format, pageLabel, pageIndex + 1, pageCount)
    }

    /// A localized scale indicator that names the region when one is in force.
    public var scaleIndicatorText: String {
        guard let scaleRegionName else { return activeScaleDisplay }
        let format = NSLocalizedString(
            "%1$@ · %2$@",
            comment: "Status bar scale indicator: ratio string, Scale Region name"
        )
        return String(format: format, activeScaleDisplay, scaleRegionName)
    }
}
