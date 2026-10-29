import CoreGraphics
import Foundation
import ZPDFUIPresentation

/// The autosave names the project window uses.
///
/// AppKit persists divider positions and window frames by name. Collecting the names here
/// means the shell can guarantee they are unique and stable across builds — a renamed autosave
/// key silently throws away the user's layout, which is the kind of regression nobody files.
public enum ZPDFShellAutosaveName {

    /// Whether AppKit's own autosaves — the toolbar configuration, the project window's frame —
    /// may write to `UserDefaults.standard`.
    ///
    /// Only in the assembled application. Anywhere else (`swift test`, a preview) the standard
    /// domain belongs to the test runner, and an autosave there leaks state between runs:
    /// one run's toolbar or window frame decides the next, and `verify-test-tier-hygiene.sh`
    /// catches the key moving. The same structural rule the application tier's
    /// `ZenitProcessDefaults` applies to the layout store: decided by the bundle identifier, which
    /// a test process cannot forge, rather than by an opt-out a test has to remember.
    public static var appKitAutosavesEnabled: Bool {
        Bundle.main.bundleIdentifier == assembledBundleIdentifier
    }

    /// The assembled application's bundle identifier, `com.zenitgroup.zenitpdf`.
    public static let assembledBundleIdentifier = "com.zenitgroup.zenitpdf"

    /// The outer stacked split: content above, Quantity Ledger below.
    public static let outerSplit = "Zenit.ProjectWindow.OuterSplit"
    /// The inner side-by-side split: Navigator, canvas, Inspector.
    public static let contentSplit = "Zenit.ProjectWindow.ContentSplit"
    /// The project window frame.
    public static let projectWindow = "Zenit.ProjectWindow.Frame"
    /// The detached Quantity Ledger window frame.
    public static let detachedLedgerWindow = "Zenit.QuantityLedgerWindow.Frame"
    /// The main toolbar configuration.
    ///
    /// Versioned: the mockup-convergence pass changed the documented default set (v2), a
    /// later pass centred the drawing group between two flexible spaces (v3), and (v4) the
    /// 2026-09-23 mockup reordered the tool group, added the tool
    /// separator, the rounded workspace group and the author badge. `NSToolbar` autosave would
    /// otherwise keep every existing install on the old arrangement forever. Bumping the
    /// identifier adopts the new default once; a user's own customisations after that autosave
    /// normally.
    ///
    /// (v5) the window draws the top band itself and the `NSToolbar` is hidden: it holds the
    /// arrangement and runs the customization sheet. A v4 autosave could carry a visible toolbar
    /// and the expanded-style arrangement of a few hours' build; v5 starts every install from
    /// the band's default arrangement once.
    public static let toolbar = "Zenit.ProjectWindow.Toolbar.v5"

    /// Every name, for the uniqueness audit.
    public static let all: [String] = [
        outerSplit, contentSplit, projectWindow, detachedLedgerWindow, toolbar
    ]
}

/// A window frame as a plain value, so layout state stays `Codable` and `Sendable`.
public struct ZPDFWindowFrame: Codable, Hashable, Sendable {

    /// Left edge in screen coordinates.
    public var x: Double
    /// Bottom edge in screen coordinates.
    public var y: Double
    /// Frame width.
    public var width: Double
    /// Frame height.
    public var height: Double

    /// Creates a frame.
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Creates a frame from AppKit geometry.
    public init(_ rect: CGRect) {
        self.init(
            x: Double(rect.origin.x),
            y: Double(rect.origin.y),
            width: Double(rect.size.width),
            height: Double(rect.size.height)
        )
    }

    /// The AppKit rectangle.
    public var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

/// Everything about a project window's layout that survives a relaunch.
///
/// AppKit's own autosave covers divider positions once the panes exist. This value covers the
/// parts AppKit cannot know: which panes are collapsed, whether the Quantity Ledger is docked
/// or living in its own window, which Navigator page is showing, which Inspector sections are
/// open, and the last-used measurement and count tools the toolbar palettes remember.
public struct ProjectWindowLayoutState: Codable, Hashable, Sendable {

    /// Bumped whenever the stored shape changes incompatibly.
    ///
    /// Version 2 added ``isLedgerBarCollapsed`` and removed the Navigator's Bookmarks page.
    /// A version-1 blob no longer decodes and resolves to the shipped default, which is the
    /// documented recovery for every unreadable layout.
    public static let currentSchemaVersion = 2

    /// Narrowest useful Navigator width.
    public static let minimumNavigatorWidth: Double = 180
    /// Widest Navigator width the shell will restore.
    public static let maximumNavigatorWidth: Double = 480
    /// Narrowest useful Inspector width: the width at which nothing the Inspector draws for a
    /// measurement is cut off — each of the four tab titles ("Comments", 64 pt in the selected
    /// weight) in its quarter of the strip, a card title such as "Polylength Measurement" beside
    /// the tile and the menu, and a Created/Modified date with its time.
    ///
    /// L-14: it was 240, from before the fourth tab (Tools) existed. At 240 a tab is 56 pt wide,
    /// so the Inspector read "Propert…", "Comm…", "Length Meas…" and "27 Sep 20…".
    public static let minimumInspectorWidth: Double = 300
    /// Widest Inspector width the shell will restore.
    public static let maximumInspectorWidth: Double = 560
    /// Shortest useful docked ledger height.
    public static let minimumLedgerHeight: Double = 120
    /// Tallest docked ledger height the shell will restore.
    public static let maximumLedgerHeight: Double = 900

    /// The schema this value was written with.
    public var schemaVersion: Int
    /// Navigator pane width in points.
    public var navigatorWidth: Double
    /// Inspector pane width in points.
    public var inspectorWidth: Double
    /// Docked Quantity Ledger height in points.
    public var ledgerHeight: Double
    /// Whether the Navigator is collapsed.
    public var isNavigatorCollapsed: Bool
    /// Whether the Inspector is collapsed.
    public var isInspectorCollapsed: Bool
    /// Whether the docked Quantity Ledger is collapsed.
    public var isLedgerCollapsed: Bool
    /// Whether the docked Quantity Ledger is collapsed to just its header bar, keeping the
    /// header visible so one click restores it to ``ledgerHeight``.
    public var isLedgerBarCollapsed: Bool
    /// Whether the Quantity Ledger is in its own window.
    public var isLedgerDetached: Bool
    /// Frame of the detached ledger window, when there has been one.
    public var detachedLedgerFrame: ZPDFWindowFrame?
    /// The Navigator page that was showing.
    public var navigatorSection: NavigatorSection
    /// The bottom pane tab that was showing — Quantities or History.
    ///
    /// Optional, and therefore additive: a version-2 blob written before the tab was persisted
    /// simply decodes it as `nil` and resolves to Quantities. A schema bump here would have
    /// thrown away every existing user's pane sizes to remember one enum, which is the wrong
    /// trade by a wide margin.
    public var bottomPaneTab: ZPDFBottomPaneTab?
    /// Whether View ▸ Hide Toolbar has collapsed the top band to its tab row.
    ///
    /// Optional and additive, like ``bottomPaneTab``: `nil` means shown, and a stored layout
    /// from before the band existed decodes unchanged.
    public var isTopBandHidden: Bool?
    /// Inspector sections that were expanded.
    public var expandedInspectorSections: Set<InspectorSection>
    /// The measurement tool the toolbar Measure palette re-arms on click.
    public var lastUsedMeasurementKind: MeasurementKind?
    /// The Tool Library count preset the toolbar Count palette re-arms on click.
    public var lastUsedCountPresetID: UUID?
    /// The style Text, Callout and the Shapes draw with (`ZenitToolbarModel.toolStyle`).
    ///
    /// Optional and additive, like ``bottomPaneTab``: `nil` is the default ink, and a layout
    /// stored before tool styles were remembered decodes unchanged.
    public var toolStyle: ToolStyleSelection?
    /// The shape the toolbar's Shapes palette re-arms on click (IM-141, R-081).
    ///
    /// Optional and additive, like ``bottomPaneTab``: a layout stored before the Shapes memory
    /// was kept decodes it as `nil`, and the palette starts from its Rectangle default.
    public var lastUsedShapeKind: MarkupKind?

    /// Creates a layout state. Every parameter has the shipped default.
    public init(
        schemaVersion: Int = ProjectWindowLayoutState.currentSchemaVersion,
        // 270: the mockup's Navigator card is ~262 pt wide plus the 8 pt window gutter, which is
        // what four segment titles and a page card with its thumbnail need without truncating.
        navigatorWidth: Double = 270,
        inspectorWidth: Double = 300,
        ledgerHeight: Double = 240,
        isNavigatorCollapsed: Bool = false,
        isInspectorCollapsed: Bool = false,
        isLedgerCollapsed: Bool = false,
        isLedgerBarCollapsed: Bool = false,
        isLedgerDetached: Bool = false,
        detachedLedgerFrame: ZPDFWindowFrame? = nil,
        navigatorSection: NavigatorSection = .pages,
        bottomPaneTab: ZPDFBottomPaneTab? = nil,
        isTopBandHidden: Bool? = nil,
        expandedInspectorSections: Set<InspectorSection> = InspectorSection.defaultExpanded,
        lastUsedMeasurementKind: MeasurementKind? = .length,
        lastUsedCountPresetID: UUID? = nil,
        toolStyle: ToolStyleSelection? = nil,
        lastUsedShapeKind: MarkupKind? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.navigatorWidth = navigatorWidth
        self.inspectorWidth = inspectorWidth
        self.ledgerHeight = ledgerHeight
        self.isNavigatorCollapsed = isNavigatorCollapsed
        self.isInspectorCollapsed = isInspectorCollapsed
        self.isLedgerCollapsed = isLedgerCollapsed
        self.isLedgerBarCollapsed = isLedgerBarCollapsed
        self.isLedgerDetached = isLedgerDetached
        self.detachedLedgerFrame = detachedLedgerFrame
        self.navigatorSection = navigatorSection
        self.bottomPaneTab = bottomPaneTab
        self.isTopBandHidden = isTopBandHidden
        self.expandedInspectorSections = expandedInspectorSections
        self.lastUsedMeasurementKind = lastUsedMeasurementKind
        self.lastUsedCountPresetID = lastUsedCountPresetID
        self.toolStyle = toolStyle
        self.lastUsedShapeKind = lastUsedShapeKind
    }

    /// The shipped layout.
    public static let `default` = ProjectWindowLayoutState()

    /// What the application's project window opens with when nothing is stored yet.
    ///
    /// ``default`` with the Quantity Ledger starting as its bar — title, tabs, the summary chips
    /// and the bar's actions — which is how the 2026-09-23 main-window mockup shows it. The table
    /// is one click away (the bar's chevron) at ``ledgerHeight``, and a person's own choice is
    /// stored and restored from then on; only the first impression changes. A separate value,
    /// not a change to ``default``: the dimension fallbacks in ``normalized()`` and every layout
    /// test that drags the ledger divider are about the expanded pane.
    public static let firstLaunch = ProjectWindowLayoutState(isLedgerBarCollapsed: true)

    /// A copy with every stored dimension pulled back inside its supported range.
    ///
    /// A window restored onto a smaller display, or a corrupted defaults entry, must never be
    /// able to leave a pane at a width the user cannot drag back.
    public func normalized() -> ProjectWindowLayoutState {
        var copy = self
        copy.schemaVersion = Self.currentSchemaVersion
        copy.navigatorWidth = Self.clamp(
            navigatorWidth,
            Self.minimumNavigatorWidth,
            Self.maximumNavigatorWidth,
            fallback: Self.default.navigatorWidth
        )
        copy.inspectorWidth = Self.clamp(
            inspectorWidth,
            Self.minimumInspectorWidth,
            Self.maximumInspectorWidth,
            fallback: Self.default.inspectorWidth
        )
        copy.ledgerHeight = Self.clamp(
            ledgerHeight,
            Self.minimumLedgerHeight,
            Self.maximumLedgerHeight,
            fallback: Self.default.ledgerHeight
        )
        if let frame = detachedLedgerFrame, frame.width < 320 || frame.height < 160 {
            copy.detachedLedgerFrame = nil
        }
        // A detached ledger is never also collapsed in the dock: the dock slot is simply gone.
        if copy.isLedgerDetached {
            copy.isLedgerCollapsed = false
            copy.isLedgerBarCollapsed = false
        }
        // A fully hidden ledger has no header bar to be collapsed to.
        if copy.isLedgerCollapsed { copy.isLedgerBarCollapsed = false }
        // No rule for an empty Inspector section set (U-047). It used to be turned back into
        // `InspectorSection.defaultExpanded`, but an empty set only ever comes from the person
        // collapsing the last open section — a missing or unreadable value already fails the
        // synthesized decode and loads ``default`` — so collapsing Measurement reopened it on
        // the next tab switch or relaunch. "Everything collapsed" is kept like any other choice.
        return copy
    }

    private static func clamp(
        _ value: Double,
        _ lower: Double,
        _ upper: Double,
        fallback: Double
    ) -> Double {
        guard value.isFinite else { return fallback }
        return Swift.min(upper, Swift.max(lower, value))
    }
}
