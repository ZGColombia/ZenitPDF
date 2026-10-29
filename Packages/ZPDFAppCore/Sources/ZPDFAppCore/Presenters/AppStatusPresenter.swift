import Foundation
import Observation
import ZPDFContracts
import ZPDFSnapEngine
import ZPDFUIPresentation

/// `StatusPresenting`, producing the exact status-bar fields.
///
/// The line is six segments in a fixed order. English is the base language, so the shipped
/// line is those six segments in that order with the ` │ ` separator:
///
/// ```text
/// Page: 1 of 4 │ Scale: 1:100 @ 1.00 m │ Unit: m │ Snap: Vector, Markup │ Coord: (124.5, 331.0) │ Zoom: 145%
/// ```
///
/// Two things about that line are requirements rather than styling. `Snap:` names the
/// active sources **in words** — that is what satisfies the no-colour-only rule, so the
/// segment is never reduced to coloured dots. And a snap source that is switched off is
/// omitted rather than greyed, so the segment always reads as the truth about what will
/// happen on the next click.
@MainActor
@Observable
public final class AppStatusPresenter: StatusPresenting {

    public private(set) var snapshot: StatusBarSnapshot
    public private(set) var warnings: [AppWarning] = []

    /// Called when a snap toggle changes, so the session's snap settings follow.
    public var onSnapSettingsChange: (@MainActor (SnapSourceToggles) -> Void)?
    /// Called when reuse-tool is switched, so the Tool Library follows.
    public var onReuseToolChange: (@MainActor (Bool) -> Void)?
    /// Called when the tray dismisses one warning, so the list that *owns* the warnings drops it.
    ///
    /// ``warnings`` is a mirror of the document presenter's list (`AppCoreEnvironment` wires
    /// `document.onWarningsChange` to ``setWarnings(_:)``). Removing a warning here only, as the
    /// tray used to, hid it until the next post or refresh pushed the document's list back — with
    /// the dismissed warning still in it (S-029). When this is set, a dismissal goes to the document
    /// and comes back through ``setWarnings(_:)``; unset, the tray is its own list.
    public var onDismissWarning: (@MainActor (AppWarning.ID) -> Void)?
    /// ``onDismissWarning`` for the tray's "Dismiss All".
    public var onDismissAllWarnings: (@MainActor () -> Void)?

    private var units: DisplayUnitSelection
    private var localeIdentifier: String

    /// Creates a presenter.
    public init(
        units: DisplayUnitSelection = .metric,
        localeIdentifier: String = "en_US_POSIX",
        snapshot: StatusBarSnapshot = AppStatusPresenter.emptySnapshot
    ) {
        self.units = units
        self.localeIdentifier = localeIdentifier
        self.snapshot = snapshot
    }

    /// The bar with nothing open.
    public nonisolated static let emptySnapshot = StatusBarSnapshot(
        pageLabel: "",
        pageIndex: 0,
        pageCount: 0,
        pageDimensionsText: "",
        activeScaleDisplay: NSLocalizedString(
            "No scale",
            comment: "Status bar scale segment before the drawing has been calibrated"
        ),
        outputUnitSymbol: ZPDFUIPresentation.LengthUnit.metre.symbol,
        zoomDisplayString: "100%",
        geometryIndexStatus: .unavailable
    )

    // MARK: Intake

    /// Rebuilds the bar from a document snapshot and the current viewport.
    ///
    /// One call rather than a setter per field: the bar is published as a single value
    /// precisely so a half-updated bar — the scale of the last page next to the label of
    /// this one — cannot be produced.
    public func adopt(
        document: DocumentSnapshot,
        viewport: ViewportSnapshot,
        scale: ScaleSummary?,
        scaleRegionName: String? = nil,
        geometryIndex: GeometryIndexStatus,
        snapToggles: SnapSourceToggles,
        reuseToolEnabled: Bool
    ) {
        units = document.units
        // The page's place in the set, not its PDF page index (ADR-0022: `index` is the page's
        // index in its own PDF and a reorder leaves it alone). The bar's "5 / 23", the
        // Navigator, the arrows and the typed-page field all count positions; publishing
        // `page.index` read "5" for PDF page 5 moved to the front of the set, and a combined
        // multi-drawing set restarts `index` per drawing (T-032).
        let position = document.pages.firstIndex { $0.id == viewport.pageID }
        let page = position.map { document.pages[$0] }
        snapshot = StatusBarSnapshot(
            pageLabel: page?.label ?? "",
            pageIndex: position ?? viewport.pageIndex,
            pageCount: document.pages.count,
            pageDimensionsText: page?.dimensionsText(
                units: units, userUnit: document.userUnit(onPage: viewport.pageID)
            ) ?? "",
            // In the document's locale and with its fraction (L-38), on this page's /UserUnit.
            activeScaleDisplay: scale.map {
                ScaleBridge.statusText(
                    for: $0,
                    units: units,
                    userUnit: document.userUnit(onPage: viewport.pageID),
                    localeIdentifier: document.ledger.formatter.localeIdentifier
                )
            } ?? Self.emptySnapshot.activeScaleDisplay,
            scaleRegionName: scaleRegionName,
            outputUnitSymbol: units.length.symbol,
            cursorPagePoint: viewport.cursorPagePoint,
            cursorDisplayText: Self.cursorText(viewport.cursorPagePoint),
            zoomDisplayString: viewport.zoomDisplayString,
            gridSnapEnabled: snapToggles.grid,
            vectorSnapEnabled: snapToggles.vector,
            markupSnapEnabled: snapToggles.markup,
            reuseToolEnabled: reuseToolEnabled,
            geometryIndexStatus: geometryIndex,
            // The armed tool is not part of the document snapshot, so it is carried
            // across rather than rebuilt: a scroll must not silently rename the tool.
            activeToolName: snapshot.activeToolName,
            activeToolNote: snapshot.activeToolNote
        )
        cursorPagePoint = viewport.cursorPagePoint
        cursorDisplayText = snapshot.cursorDisplayText
    }

    /// Updates only the cursor readout, which changes on every pointer move.
    ///
    /// Separate from ``adopt(document:viewport:scale:scaleRegionName:geometryIndex:snapToggles:reuseToolEnabled:)``
    /// because rebuilding six segments per mouse move to change one of them is the kind of
    /// waste that shows up as a dropped frame at 60 Hz.
    public func updateCursor(_ point: PDFPointValue?) {
        guard cursorPagePoint != point else { return }
        cursorPagePoint = point
        cursorDisplayText = Self.cursorText(point)
        // Still mirrored into the snapshot for the status bar that reads it today. Once
        // `StatusPresenting` declares `cursorDisplayText` and the bar's Coord segment reads it
        // (ZPDFUIPresentation/ZPDFUIShell half of IM-133), these two writes go, and a pointer
        // move stops invalidating every segment that reads `snapshot`.
        snapshot.cursorPagePoint = point
        snapshot.cursorDisplayText = cursorDisplayText
    }

    /// The pointer readout, observable on its own (IM-133).
    public private(set) var cursorDisplayText: String = ""
    /// The pointer position the readout describes.
    public private(set) var cursorPagePoint: PDFPointValue?

    /// Names the armed tool, and states what it will not do yet.
    ///
    /// Separate from the full ``adopt(document:viewport:scale:scaleRegionName:geometryIndex:snapToggles:reuseToolEnabled:)``
    /// pass for the same reason the cursor readout is: arming a tool must not rebuild six
    /// segments, and — more importantly — the tool name must survive the next document
    /// refresh rather than being reset to "Select" by it.
    public func setActiveTool(name: String, note: String?) {
        guard snapshot.activeToolName != name || snapshot.activeToolNote != note else { return }
        snapshot.activeToolName = name
        snapshot.activeToolNote = note
    }

    /// Replaces the armed tool's note without renaming the tool.
    ///
    /// A refusal is a note about the tool that is already armed — "a cutout must start
    /// inside an area measurement" — and it must not blank the tool's name to say so. The
    /// next arming replaces it, because ``setActiveTool(name:note:)`` writes both fields.
    public func setActiveToolNote(_ note: String?) {
        guard snapshot.activeToolNote != note else { return }
        snapshot.activeToolNote = note
    }

    /// Installs the geometry index state for the active page.
    ///
    /// The Vector Snap *setting* is left alone. A raster page used to flip the toggle off,
    /// and nothing ever flipped it back: one scanned sheet in a set switched Vector Snap off
    /// for every vector sheet after it, in the status bar, while the engine kept snapping to
    /// vectors (CR-9). Unavailability is displayed instead of enforced — ``snapSourceText(_:)``
    /// omits "Vector" and the index segment reads "Vector Snap unavailable" — and the setting
    /// is honoured again on the next page that can.
    public func updateGeometryIndex(_ status: GeometryIndexStatus) {
        snapshot.geometryIndexStatus = status
    }

    /// Replaces the warning tray, most serious first.
    public func setWarnings(_ warnings: [AppWarning]) {
        self.warnings = warnings.sorted { $0.severity > $1.severity }
    }

    // MARK: StatusPresenting

    public func setGridSnapEnabled(_ enabled: Bool) {
        snapshot.gridSnapEnabled = enabled
        onSnapSettingsChange?(toggles)
    }

    /// Turns Vector Snap on or off, refusing to turn it on when the page has no vector
    /// content — a switch that flips but does nothing is worse than one that will not flip.
    public func setVectorSnapEnabled(_ enabled: Bool) {
        guard snapshot.geometryIndexStatus.allowsVectorSnap || !enabled else { return }
        snapshot.vectorSnapEnabled = enabled
        onSnapSettingsChange?(toggles)
    }

    public func setMarkupSnapEnabled(_ enabled: Bool) {
        snapshot.markupSnapEnabled = enabled
        onSnapSettingsChange?(toggles)
    }

    public func setReuseToolEnabled(_ enabled: Bool) {
        snapshot.reuseToolEnabled = enabled
        onReuseToolChange?(enabled)
    }

    public func dismissWarning(id: AppWarning.ID) {
        if let onDismissWarning {
            onDismissWarning(id)
            return
        }
        warnings.removeAll { $0.id == id && $0.isDismissible }
    }

    public func dismissAllWarnings() {
        if let onDismissAllWarnings {
            onDismissAllWarnings()
            return
        }
        warnings.removeAll(where: \.isDismissible)
    }

    /// Puts the toggles back to what the engine actually holds, without raising
    /// ``onSnapSettingsChange`` — the engine is where the value came from.
    ///
    /// Used when a settings write is refused, so the status bar never keeps claiming a state
    /// the engine declined (BH-413).
    public func adoptSnapToggles(_ toggles: SnapSourceToggles) {
        snapshot.gridSnapEnabled = toggles.grid
        snapshot.vectorSnapEnabled = toggles.vector
        snapshot.markupSnapEnabled = toggles.markup
    }

    /// The snap sources currently switched on.
    public var toggles: SnapSourceToggles {
        SnapSourceToggles(
            grid: snapshot.gridSnapEnabled,
            vector: snapshot.vectorSnapEnabled,
            markup: snapshot.markupSnapEnabled
        )
    }

    // MARK: The line

    /// The whole status bar as one string, in its six segments and order.
    ///
    /// The views draw the segments separately — each is its own control, and the snap
    /// segment's names are clickable — but the assembled line is what a test asserts on and
    /// what a screen reader is given for the bar as a whole.
    public var statusLine: String { Self.line(snapshot) }

    /// Builds the line from a snapshot.
    ///
    /// `nonisolated`, because it is a pure function of a `Sendable` value: an exporter, a
    /// log line and a test can all build the same string without hopping to the main actor.
    public nonisolated static func line(_ snapshot: StatusBarSnapshot) -> String {
        segments(snapshot).joined(separator: " │ ")
    }

    /// The six segments, in reference order.
    public nonisolated static func segments(_ snapshot: StatusBarSnapshot) -> [String] {
        [
            String(
                format: NSLocalizedString(
                    "Page: %1$d of %2$d",
                    comment: "Status bar segment: one-based page number and page count"
                ),
                snapshot.pageCount == 0 ? 0 : snapshot.pageIndex + 1,
                snapshot.pageCount
            ),
            String(
                format: NSLocalizedString(
                    "Scale: %@",
                    comment: "Status bar segment: the scale in force"
                ),
                snapshot.scaleIndicatorText
            ),
            String(
                format: NSLocalizedString(
                    "Unit: %@",
                    comment: "Status bar segment: the output unit symbol"
                ),
                snapshot.outputUnitSymbol
            ),
            String(
                format: NSLocalizedString(
                    "Snap: %@",
                    comment: "Status bar segment: the active snap sources, named"
                ),
                snapSourceText(snapshot)
            ),
            String(
                format: NSLocalizedString(
                    "Coord: %@",
                    comment: "Status bar segment: the cursor position in page space"
                ),
                snapshot.cursorDisplayText.isEmpty ? "—" : snapshot.cursorDisplayText
            ),
            String(
                format: NSLocalizedString(
                    "Zoom: %@",
                    comment: "Status bar segment: the zoom percentage"
                ),
                snapshot.zoomDisplayString
            )
        ]
    }

    /// The active snap sources, named and comma-separated, or "Off" when none is on.
    ///
    /// Named rather than coloured: this text *is* the accessibility affordance for the
    /// snap state, so it can never become an icon row.
    public nonisolated static func snapSourceText(_ snapshot: StatusBarSnapshot) -> String {
        var names: [String] = []
        if snapshot.vectorSnapEnabled, snapshot.geometryIndexStatus.allowsVectorSnap {
            names.append(NSLocalizedString("Vector", comment: "Snap source name: PDF vector geometry"))
        }
        if snapshot.markupSnapEnabled {
            names.append(NSLocalizedString("Markup", comment: "Snap source name: existing markups"))
        }
        if snapshot.gridSnapEnabled {
            names.append(NSLocalizedString("Grid", comment: "Snap source name: the synthetic grid"))
        }
        guard !names.isEmpty else {
            return NSLocalizedString("Off", comment: "Status bar snap segment when no source is enabled")
        }
        return names.joined(separator: ", ")
    }

    /// `"(124.5, 331.0)"` — the cursor in page points, one decimal, monospaced digits.
    ///
    /// Page points rather than real-world units, matching the reference: the coordinate
    /// segment tells the user where they are on the sheet, and it has to keep working on a
    /// drawing that has not been calibrated yet.
    public nonisolated static func cursorText(_ point: PDFPointValue?) -> String {
        guard let point else { return "" }
        return String(format: "(%.1f, %.1f)", point.x, point.y)
    }
}

/// Which snap sources the status bar has switched on.
///
/// Three named booleans rather than a `SnapSettings`, because the status bar owns exactly
/// these three switches; tolerance, hysteresis and the priority table are settings, not
/// status. ``snapKinds(base:)`` turns them back into the engine's enabled-kind set.
public struct SnapSourceToggles: Hashable, Sendable {

    /// Grid Snap.
    public var grid: Bool
    /// Vector Snap: endpoints, midpoints, intersections and the rest of the PDF geometry.
    public var vector: Bool
    /// Markup Snap: vertices, edges and centres of existing markups.
    public var markup: Bool

    /// Creates a toggle set.
    public init(grid: Bool = false, vector: Bool = true, markup: Bool = true) {
        self.grid = grid
        self.vector = vector
        self.markup = markup
    }

    /// The engine's enabled-kind set for these toggles.
    ///
    /// Derived from `SnapKind.requiresVectorContent` rather than from a hand-written list,
    /// so a snap kind added to the contract lands in the right group automatically instead
    /// of being silently unreachable.
    public func snapKinds(base: Set<SnapKind> = SnapSettings.default.enabledKinds) -> Set<SnapKind> {
        var kinds = base
        for kind in SnapKind.allCases {
            let enabled: Bool
            switch kind {
            case .grid, .angleIncrement:
                enabled = grid || kind == .angleIncrement
            case .markupVertex, .markupEdge, .markupCenter:
                enabled = markup
            case .zoneBoundary, .calibrationPoint, .parallelGuide:
                enabled = true
            default:
                // Derived, as the comment above promises. A hand-written `vector` here gated the
                // next non-vector kind added to the contract on Vector Snap — off on every
                // scanned sheet while the status bar said it was on (BH-453).
                enabled = kind.requiresVectorContent ? vector : true
            }
            if enabled { kinds.insert(kind) } else { kinds.remove(kind) }
        }
        return kinds
    }
}
