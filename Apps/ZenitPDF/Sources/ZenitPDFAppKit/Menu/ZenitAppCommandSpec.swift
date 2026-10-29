import AppKit
import ZPDFUIShell

// MARK: - The application command table (IM-183)
//
// Every ``ZenitAppCommand`` used to keep its title and shortcut in `ZenitMenuBar`, its
// enablement in `ProjectWindowController.validateMenuItem` and its action in
// `perform(app:)` — three switches in two files that had to be kept in step by hand. This file
// is the one place a command is described. The menu bar builds its rows from
// ``ZenitAppCommandTable/specs``, validation asks ``ZenitAppCommandTable/validate(_:item:state:)``
// and dispatch asks ``ZenitAppCommandTable/perform(_:controller:document:)``; none of the three
// carries per-command knowledge of its own any more.
//
// The shell's own commands (``ZPDFCommandID``) already have their table in `ZPDFUIShell`
// (``ZPDFCommandTable``); this is the application's counterpart for the commands that table
// cannot hold because it is frozen by the shell package.

/// A menu key equivalent: the key and the modifiers that go with it.
struct ZenitKeyEquivalent: Equatable {
    var key: String
    var modifiers: NSEvent.ModifierFlags

    init(_ key: String, _ modifiers: NSEvent.ModifierFlags) {
        self.key = key
        self.modifiers = modifiers
    }
}

/// Where in the menu bar a command's row goes.
///
/// A slot is a run of rows the builder places as a block, at a spot fixed by what is around it
/// (after Save As…, under Copy, at the foot of Tools). Rows inside one slot appear in
/// ``ZenitAppCommand`` declaration order, which is also the table's order.
enum ZenitAppCommandSlot: CaseIterable {
    /// File, straight after Save As….
    case fileAfterSaveAs
    /// File, straight after Export….
    case fileAfterExport
    /// File ▸ Export Drawing, the submenu of the four drawing exports (IM-250).
    case fileExportDrawing
    /// Edit, directly under Copy.
    case editAfterCopy
    /// Edit, the lock/hide block at its foot.
    case editSelection
    /// Tools, the first block below the table's own commands.
    case toolsCapture
    /// Tools, the second block: reading data out of the drawing.
    case toolsDrawingData
    /// Tools ▸ Job Templates, the submenu of the four template commands (IM-250).
    case toolsJobTemplates
    /// Measure, the block below the table's own commands.
    case measure
    /// Window, the tab-switching block (IM-182).
    case windowTabs
    /// View, above Hide Toolbar: the command palette and Workspaces (nl-ux).
    case viewExtras
    /// Edit, below the selection block: group, link, image (r2-markup).
    case editGroup
    /// Edit ▸ Arrange (r2-markup, NL-MARKUP-13).
    case editArrange
    /// Edit ▸ Align (r2-markup, NL-MARKUP-12).
    case editAlign
    /// File, directly under New (r2-platform, NL-PLAT-22).
    case fileAfterNew
    /// Tools, after the Job Templates submenu: packs (r2-platform, NL-PLAT-23).
    case toolsLibrary
    // L-02: the File, Tools and Measure menus had 41, 31 and 33 rows. Families that belong
    // together sit in a submenu of their own; every command and shortcut is still in the bar
    // (a key equivalent reaches a row inside a submenu), and still in the palette.
    /// File ▸ Indexed Drawings: the folder index (NL-DOCS-15).
    case fileIndexedDrawings
    /// File ▸ Review: review annotations, the Shared Review Folder, the review file and XFDF.
    case fileReview
    /// File ▸ Drawing Set: the set outputs and Combine, the same five the Navigator's ⋯ menu
    /// offers (L-03, R-071).
    case fileDrawingSet
    /// Tools ▸ Redaction: mark, apply to a copy, clear (NL-PDF-14).
    case toolsRedaction
    /// Measure ▸ Automation: the checks, detectors and the Takeoff Assistant.
    case measureAutomation

    /// The menu the slot sits in. `nil` for the Window menu, which is not a command group.
    var group: ZPDFCommandGroup? {
        switch self {
        case .fileAfterSaveAs, .fileAfterExport, .fileExportDrawing, .fileAfterNew,
             .fileIndexedDrawings, .fileReview, .fileDrawingSet: return .file
        case .editAfterCopy, .editSelection, .editGroup, .editArrange, .editAlign: return .edit
        case .toolsCapture, .toolsDrawingData, .toolsJobTemplates, .toolsLibrary, .toolsRedaction: return .tools
        case .measure, .measureAutomation: return .measure
        case .viewExtras: return .view
        case .windowTabs: return nil
        }
    }

    /// The title of the submenu row the slot's commands are grouped under, when they are.
    var submenuTitle: String? {
        switch self {
        case .fileExportDrawing:
            return NSLocalizedString("Export Drawing", comment: "File menu submenu holding the drawing exports")
        case .toolsJobTemplates:
            return NSLocalizedString("Job Templates", comment: "Tools menu submenu holding the job template commands")
        case .editArrange:
            return NSLocalizedString("Arrange", comment: "Edit menu submenu holding the draw-order commands")
        case .editAlign:
            return NSLocalizedString("Align", comment: "Edit menu submenu holding the align and distribute commands")
        case .fileIndexedDrawings:
            return NSLocalizedString("Indexed Drawings", comment: "File menu submenu holding the folder index commands")
        case .fileReview:
            return NSLocalizedString("Review", comment: "File menu submenu holding the review exchange commands")
        case .fileDrawingSet:
            return NSLocalizedString("Drawing Set", comment: "File menu submenu holding the drawing set outputs and Combine")
        case .toolsRedaction:
            return NSLocalizedString("Redaction", comment: "Tools menu submenu holding the redaction commands")
        case .measureAutomation:
            return NSLocalizedString("Automation", comment: "Measure menu submenu holding the checks, detectors and the Takeoff Assistant")
        default:
            return nil
        }
    }
}

/// The window state an application command's enablement is decided from.
///
/// A protocol, not the window controller, so the table's rules can be checked against every
/// state without opening a window. ``ZenitAppCommandWindowState`` answers it for a real window,
/// lazily, one property at a time, exactly as the old switch read them.
@MainActor
protocol ZenitAppCommandState {
    /// A document tab is in front.
    var hasActiveDocument: Bool { get }
    /// The document in front is a Quick PDF.
    var isQuickPDF: Bool { get }
    /// The document in front has its drawing loaded.
    var hasDrawing: Bool { get }
    /// The document in front has a search index to write recognised text into.
    var hasSearchIndex: Bool { get }
    /// The document in front has its takeoff core.
    var hasLoadedCore: Bool { get }
    /// The document in front has pages and at least one stamp preset in its Tool Library.
    var hasPagesAndStampPreset: Bool { get }
    /// At least one markup is selected on the canvas in front.
    var hasMarkupSelection: Bool { get }
    /// At least one selected markup is in a group (R-065). Defaults to ``hasMarkupSelection`` for
    /// a state that cannot tell; the window's own state answers it exactly.
    var hasGroupedMarkupSelection: Bool { get }
    /// Every selected markup is locked.
    var selectionIsLocked: Bool { get }
    /// At least one markup of the takeoff is hidden.
    var hasHiddenMarkups: Bool { get }
    /// How many document tabs the window holds.
    var tabCount: Int { get }
    /// A save is running on the document in front (CR-147).
    var isSaveActivityBusy: Bool { get }
    /// Tools ▸ Process PDF Files… has a run in progress (R-023).
    var isBatchProcessing: Bool { get }
    /// The canvas in front tints markups by author (T-016). Defaults to `false` for a state that
    /// cannot tell; the window's own state answers it exactly.
    var isTintingByAuthor: Bool { get }
}

extension ZenitAppCommandState {
    var hasGroupedMarkupSelection: Bool { hasMarkupSelection }
    var isTintingByAuthor: Bool { false }
}

/// When an application command's row is enabled.
enum ZenitAppCommandRule: CaseIterable {
    /// Always.
    case always
    /// A document tab is in front, loaded or not.
    case activeDocument
    /// The document in front has its takeoff core.
    case loadedCore
    /// The document in front has its drawing.
    case drawing
    /// The document in front is a Quick PDF with its drawing.
    case quickPDFWithDrawing
    /// There is a search index to write into.
    case searchIndex
    /// There is a stamp preset to batch and pages to put it on.
    case stampPresetAndPages
    /// At least one markup is selected.
    case markupSelection
    /// At least one selected markup is in a group: Ungroup (R-065).
    case groupedMarkupSelection
    /// At least one markup is hidden.
    case hiddenMarkups
    /// The window holds more than one tab.
    case severalTabs
    /// The document in front has its drawing and another tab is open: what Combine Open
    /// Drawings needs. The empty untitled start document has no drawing to combine into, and
    /// on it the command could only post a refusal nobody could act on (L-40).
    case drawingWithOtherTabs
    /// The document in front is a project (not a Quick PDF) with its drawing: what a shared
    /// review or a review file needs (R-029).
    case projectDrawing
    /// A Process PDF Files run is in progress (R-023).
    case batchProcessing

    @MainActor
    func isSatisfied(by state: any ZenitAppCommandState) -> Bool {
        switch self {
        case .always: return true
        case .activeDocument: return state.hasActiveDocument
        case .loadedCore: return state.hasLoadedCore
        case .drawing: return state.hasDrawing
        case .quickPDFWithDrawing: return state.isQuickPDF && state.hasDrawing
        case .searchIndex: return state.hasSearchIndex
        case .stampPresetAndPages: return state.hasPagesAndStampPreset
        case .markupSelection: return state.hasMarkupSelection
        case .groupedMarkupSelection: return state.hasGroupedMarkupSelection
        case .hiddenMarkups: return state.hasHiddenMarkups
        case .severalTabs: return state.tabCount > 1
        case .drawingWithOtherTabs: return state.hasDrawing && state.tabCount > 1
        case .projectDrawing: return !state.isQuickPDF && state.hasDrawing
        case .batchProcessing: return state.isBatchProcessing
        }
    }
}

/// What an application command does when it is chosen.
@MainActor
enum ZenitAppCommandAction {
    /// Runs only with a document in front; with none the command does nothing.
    case withDocument(@MainActor (ProjectWindowController, ZenitPDFProjectDocument) -> Void)
    /// Runs with or without a document in front — and with no project window at all, when the
    /// application delegate answers the row after the last window closed (T-009). The window
    /// controller is then `nil`, and whatever the command shows is presented app-modally.
    case documentOptional(@MainActor (ProjectWindowController?, ZenitPDFProjectDocument?) -> Void)

    var needsDocument: Bool {
        if case .withDocument = self { return true }
        return false
    }
}

/// Everything the application knows about one ``ZenitAppCommand``: its row, its enablement and
/// its action.
@MainActor
struct ZenitAppCommandSpec {
    let command: ZenitAppCommand
    /// Where the row goes.
    let slot: ZenitAppCommandSlot
    /// The row's title as built. ``stateTitle`` may rewrite it at validation time.
    let title: String
    /// The row's key equivalent, when it has one.
    let keyEquivalent: ZenitKeyEquivalent?
    /// Further chords for the same command, installed as hidden rows that keep their key
    /// equivalent (`allowsKeyEquivalentWhenHidden`), so two conventions both work.
    let hiddenKeyEquivalents: [ZenitKeyEquivalent]
    let toolTip: String?
    /// When the row is enabled.
    let rule: ZenitAppCommandRule
    /// Disabled while a save runs, because the action parks the main thread on the document
    /// activity (CR-147).
    let refusedWhileSaving: Bool
    /// A title that follows state — Lock/Unlock — applied when the row validates enabled.
    let stateTitle: (@MainActor (any ZenitAppCommandState) -> String)?
    /// Whether a toggle is on, shown as the row's checkmark (T-016): an overlay toggle with no
    /// state leaves the person unable to tell whether the next press turns it on or off (LT-12).
    let isOn: (@MainActor (any ZenitAppCommandState) -> Bool)?
    let action: ZenitAppCommandAction

    init(
        _ command: ZenitAppCommand,
        slot: ZenitAppCommandSlot,
        title: String,
        keyEquivalent: ZenitKeyEquivalent? = nil,
        hiddenKeyEquivalents: [ZenitKeyEquivalent] = [],
        toolTip: String? = nil,
        rule: ZenitAppCommandRule,
        refusedWhileSaving: Bool = false,
        stateTitle: (@MainActor (any ZenitAppCommandState) -> String)? = nil,
        isOn: (@MainActor (any ZenitAppCommandState) -> Bool)? = nil,
        action: ZenitAppCommandAction
    ) {
        self.command = command
        self.slot = slot
        self.title = title
        self.keyEquivalent = keyEquivalent
        self.hiddenKeyEquivalents = hiddenKeyEquivalents
        self.toolTip = toolTip
        self.rule = rule
        self.refusedWhileSaving = refusedWhileSaving
        self.stateTitle = stateTitle
        self.isOn = isOn
        self.action = action
    }
}

/// The table of application commands, and the three things read from it: the menu rows,
/// validation and dispatch.
@MainActor
enum ZenitAppCommandTable {

    /// One spec per ``ZenitAppCommand``, in declaration order.
    static let specs: [ZenitAppCommandSpec] = ZenitAppCommand.allCases.map { makeSpec($0) }

    private static let specsByCommand: [ZenitAppCommand: ZenitAppCommandSpec] =
        Dictionary(uniqueKeysWithValues: specs.map { ($0.command, $0) })

    /// The spec of one command. Total: ``makeSpec(_:)`` is an exhaustive switch.
    static func spec(for command: ZenitAppCommand) -> ZenitAppCommandSpec {
        specsByCommand[command] ?? makeSpec(command)
    }

    /// Where a command's row is in the menu bar, as a refusal or a note names it — "File ▸
    /// Review ▸ Connect Shared Review Folder…". Read from the table, so a row that moves into a
    /// submenu keeps every sentence that points at it true (L-02).
    static func menuPath(for command: ZenitAppCommand) -> String {
        let spec = spec(for: command)
        let menu = spec.slot.group?.displayName ?? NSLocalizedString("Window", comment: "Menu bar title")
        return ([menu] + [spec.slot.submenuTitle].compactMap { $0 } + [spec.title]).joined(separator: " ▸ ")
    }

    /// The specs whose rows go in one slot, in table order.
    static func specs(in slot: ZenitAppCommandSlot) -> [ZenitAppCommandSpec] {
        specs.filter { $0.slot == slot }
    }

    // MARK: Validation

    /// Whether a command's row is enabled in `state`; rewrites the row's title when the
    /// command's title follows state.
    static func validate(
        _ command: ZenitAppCommand,
        item: NSMenuItem?,
        state: any ZenitAppCommandState
    ) -> Bool {
        let spec = spec(for: command)
        // A toggle's checkmark says whether it is on — off on a disabled row (T-016).
        if let isOn = spec.isOn, let item {
            item.state = spec.rule.isSatisfied(by: state) && isOn(state) ? .on : .off
        }
        // The row says what it would do now, enabled or not (V-025). Set only once the row was
        // enabled, a Lock row disabled by deselecting kept "Unlock Selection" from the locked
        // selection before it — as the no-window path already knew (U-024).
        if let stateTitle = spec.stateTitle, let item {
            item.title = stateTitle(state)
        }
        // The doors that park the main thread on the document activity stay shut while a save
        // runs (CR-147); the row says so before anybody reaches the spoken refusal.
        if spec.refusedWhileSaving, state.isSaveActivityBusy { return false }
        return spec.rule.isSatisfied(by: state)
    }

    // MARK: Dispatch

    /// Runs a command for a window, or for no window (`controller` `nil`, T-009). A command that
    /// needs a document does nothing without one.
    static func perform(
        _ command: ZenitAppCommand,
        controller: ProjectWindowController?,
        document: ZenitPDFProjectDocument?
    ) {
        switch spec(for: command).action {
        case .withDocument(let run):
            guard let controller, let document else { return }
            run(controller, document)
        case .documentOptional(let run):
            run(controller, document)
        }
    }

    /// Whether a command's row is enabled when no project window answers it — the state after
    /// the last window closed, answered by the application delegate (T-009). Only the commands
    /// built to run without a document can be; every other row stays disabled, as before.
    ///
    /// A disabled row still says so truthfully (U-024): a toggle shows no checkmark (T-016) and a
    /// title that follows state shows its words for no document. The early return used to skip
    /// ``validate(_:item:state:)``, the one place that sets them, so after the last window closed
    /// View ▸ Tint Markups by Author stayed checked on a disabled row.
    static func validateWithoutWindow(_ command: ZenitAppCommand, item: NSMenuItem?) -> Bool {
        let state = ZenitAppCommandNoWindowState()
        let spec = spec(for: command)
        guard !spec.action.needsDocument else {
            if let item {
                if spec.isOn != nil { item.state = .off }
                if let stateTitle = spec.stateTitle { item.title = stateTitle(state) }
            }
            return false
        }
        return validate(command, item: item, state: state)
    }

    // MARK: The table

    /// One command's spec. An exhaustive switch, so a new ``ZenitAppCommand`` without a title,
    /// a rule and an action does not compile.
    private static func makeSpec(_ command: ZenitAppCommand) -> ZenitAppCommandSpec {
        switch command {
        case .createProject:
            return ZenitAppCommandSpec(
                command,
                slot: .fileAfterSaveAs,
                title: NSLocalizedString("Create Zenit PDF Project…", comment: "File menu command"),
                // Its own shortcut, and the one it shares, said where the command is (IM-249).
                keyEquivalent: ZenitKeyEquivalent("s", [.command, .option]),
                toolTip: NSLocalizedString(
                    "In a Quick PDF, ⌘S creates the project too.",
                    comment: "Tooltip of Create Zenit PDF Project"
                ),
                rule: .quickPDFWithDrawing,
                refusedWhileSaving: true,
                action: .withDocument { _, document in document.createProject() }
            )

        case .calibrateScale:
            return ZenitAppCommandSpec(
                command,
                slot: .measure,
                // "Set Scale…", the status strip's own word for this sheet: titled "Calibrate
                // Scale…" it sat under the shell's "Calibrate" (⇧C, the two-click pick) as a
                // near-identical twin (R-042).
                title: NSLocalizedString("Set Scale…", comment: "Measure menu command that opens the page scale sheet"),
                keyEquivalent: ZenitKeyEquivalent("k", [.command, .option]),
                rule: .drawing,
                // The calibration sheet: drawing ratio, one line, or separate X/Y (NL-MEASURE-01).
                action: .withDocument { controller, document in controller.presentPageScaleSheet(for: document) }
            )

        case .applyScaleToPages:
            return ZenitAppCommandSpec(
                command,
                slot: .measure,
                title: NSLocalizedString("Apply Scale to Pages…", comment: "Measure menu command: apply this page's scale to other pages"),
                toolTip: NSLocalizedString(
                    "Apply this page's scale to the rest of the set: pages of the same size, a range, the selected pages or all.",
                    comment: "Tooltip of Apply Scale to Pages"
                ),
                rule: .drawing,
                action: .withDocument { controller, document in controller.presentBulkScaleSheet(for: document) }
            )

        case .pageScales:
            return ZenitAppCommandSpec(
                command,
                slot: .measure,
                title: NSLocalizedString("Page Scales…", comment: "Measure menu command: every sheet's scale status"),
                toolTip: NSLocalizedString(
                    "Every sheet with its scale: set, proposed from its title block, or none.",
                    comment: "Tooltip of Page Scales"
                ),
                rule: .drawing,
                action: .withDocument { controller, document in controller.presentPageScalesSheet(for: document) }
            )

        case .findScaleRegions:
            return ZenitAppCommandSpec(
                command,
                slot: .measure,
                title: NSLocalizedString("Find Scale Regions on This Sheet", comment: "Measure menu command: propose Scale Regions for details drawn at another scale"),
                toolTip: NSLocalizedString(
                    "Looks for viewports and printed viewport titles at a scale other than the sheet's and proposes a Scale Region for each. Nothing changes until you add one.",
                    comment: "Tooltip of Find Scale Regions on This Sheet"
                ),
                rule: .drawing,
                action: .withDocument { controller, document in controller.beginFindScaleRegions(for: document) }
            )

        case .verifyScale:
            return ZenitAppCommandSpec(
                command,
                slot: .measure,
                title: NSLocalizedString("Verify Scale…", comment: "Measure menu command: check the scale against a second stated dimension"),
                toolTip: NSLocalizedString(
                    "Click both ends of a dimension the drawing states and see how far the scale is from it.",
                    comment: "Tooltip of Verify Scale"
                ),
                rule: .drawing,
                action: .withDocument { controller, document in controller.beginVerifyScale(for: document) }
            )

        case .splitArea:
            return ZenitAppCommandSpec(
                command,
                slot: .measure,
                title: NSLocalizedString("Split Area", comment: "Measure menu command: divide the selected area along a line"),
                toolTip: NSLocalizedString(
                    "Select one area, then click the two ends of the dividing line. One undo puts it back.",
                    comment: "Tooltip of Split Area"
                ),
                rule: .markupSelection,
                action: .withDocument { controller, document in controller.beginSplitArea(for: document) }
            )

        case .continueMeasurement:
            return ZenitAppCommandSpec(
                command,
                slot: .measure,
                title: NSLocalizedString("Continue Measurement", comment: "Measure menu command: add points to the selected polylength or count"),
                toolTip: NSLocalizedString(
                    "Adds points to the selected polylength or count; it stays the same row.",
                    comment: "Tooltip of Continue Measurement"
                ),
                rule: .markupSelection,
                action: .withDocument { controller, document in controller.beginContinueMeasurement(for: document) }
            )

        case .mergeAreas:
            return ZenitAppCommandSpec(
                command,
                slot: .measure,
                title: NSLocalizedString("Merge Areas", comment: "Measure menu command: union the selected areas into one"),
                toolTip: NSLocalizedString(
                    "Joins the selected areas of one subject into the first of them; overlaps count once.",
                    comment: "Tooltip of Merge Areas"
                ),
                rule: .markupSelection,
                action: .withDocument { _, document in
                    Task { @MainActor in await AreaSplitFlow.merge(document) }
                }
            )

        case .numberCountMarks:
            return ZenitAppCommandSpec(
                command,
                slot: .measure,
                title: NSLocalizedString("Number Count Marks", comment: "Measure menu command: show running numbers beside the selected counts' marks"),
                toolTip: NSLocalizedString(
                    "Shows 1, 2, 3… beside the selected counts' marks in the order they were placed, or removes the numbers. The count does not change.",
                    comment: "Tooltip of Number Count Marks"
                ),
                rule: .markupSelection,
                action: .withDocument { controller, document in controller.toggleCountNumbering(for: document) }
            )

        case .precisionMagnifier:
            return ZenitAppCommandSpec(
                command,
                slot: .measure,
                title: NSLocalizedString("Show Precision Magnifier", comment: "Measure menu command: magnify the sheet under the pointer while placing points"),
                keyEquivalent: ZenitKeyEquivalent("m", [.command, .shift]),
                toolTip: NSLocalizedString(
                    "While a measuring tool or a calibration places points, a magnifier follows the pointer with the snap and the coordinate.",
                    comment: "Tooltip of Precision Magnifier"
                ),
                rule: .drawing,
                stateTitle: { _ in
                    CanvasLoupe.isEnabled()
                        ? NSLocalizedString("Hide Precision Magnifier", comment: "Measure menu command: turn the magnifier off")
                        : NSLocalizedString("Show Precision Magnifier", comment: "Measure menu command: magnify the sheet under the pointer while placing points")
                },
                action: .withDocument { controller, document in
                    CanvasLoupe.setEnabled(!CanvasLoupe.isEnabled())
                    controller.canvasController(for: document)?.updateLoupe(at: nil)
                }
            )

        case .recalculateStale:
            return ZenitAppCommandSpec(
                command,
                slot: .measure,
                title: NSLocalizedString("Recalculate Stale Measurements", comment: "Measure menu command: bring values kept under an older scale to the current one"),
                toolTip: NSLocalizedString(
                    "Measurements whose values were kept when a scale changed are recalculated at the current scale. One undo puts them back.",
                    comment: "Tooltip of Recalculate Stale Measurements"
                ),
                rule: .drawing,
                action: .withDocument { _, document in ProjectWindowController.recalculateStale(for: document) }
            )

        case .drawFenceLine:
            return ZenitAppCommandSpec(
                command,
                slot: .measure,
                title: NSLocalizedString("Draw Fence Line", comment: "Measure menu command: draw a line across an opening for auto-trace"),
                toolTip: NSLocalizedString(
                    "Click both sides of a door or opening. ⌥-click tracing then treats the line as a wall, and says so.",
                    comment: "Tooltip of Draw Fence Line"
                ),
                rule: .drawing,
                action: .withDocument { controller, document in controller.beginFenceLine(for: document) }
            )

        case .clearFenceLines:
            return ZenitAppCommandSpec(
                command,
                slot: .measure,
                title: NSLocalizedString("Clear Fence Lines", comment: "Measure menu command: remove the fence lines on this page"),
                rule: .drawing,
                action: .withDocument { controller, document in controller.clearFenceLines(for: document) }
            )

        case .curveEdge:
            return ZenitAppCommandSpec(
                command,
                slot: .measure,
                title: NSLocalizedString("Curve an Edge", comment: "Measure menu command: bend an edge of the selected measurement into an arc"),
                toolTip: NSLocalizedString(
                    "Click an edge of the selected polylength or area, then the point the curve passes through. The arc is measured exactly.",
                    comment: "Tooltip of Curve an Edge"
                ),
                rule: .markupSelection,
                action: .withDocument { controller, document in controller.beginCurveEdge(for: document) }
            )

        case .readScannedText:
            // The OCR run sheet had no entry point anywhere in the application: `OCRService`,
            // `OCRRunModel` and `OCRRunSheet` were all finished and tested, and no menu item,
            // toolbar button or shortcut could start one. This is it.
            return ZenitAppCommandSpec(
                command,
                slot: .toolsCapture,
                title: NSLocalizedString(
                    "Read Text from Scanned Pages…",
                    comment: "Tools menu command that opens the OCR run sheet"
                ),
                // Available exactly when there is an index to write into. Offering the sheet
                // over a drawing with no index would end in a run that recognises pages nothing
                // can search.
                rule: .searchIndex,
                action: .withDocument { controller, document in controller.presentOCRRun(for: document) }
            )

        case .importLedgerJSON:
            // The read half of the interchange format. `ZenitJSONExporter` reached the export
            // dialog on 2026-08-24 and `ZenitJSONImporter` reached nothing at all — no caller in
            // any tier. It sits directly under Export… because the two are one
            // feature: a format with a writer and no reader is a format nobody can check.
            return ZenitAppCommandSpec(
                command,
                slot: .fileAfterExport,
                title: NSLocalizedString(
                    "Import Zenit JSON…",
                    comment: "File menu command that reads a .zpdfjson ledger export back"
                ),
                // Always available, unlike Export…, which needs a ledger to write. Reviewing a
                // file that arrived by e-mail is a reasonable thing to do with no project open,
                // and the reconciliation half simply reports that there was nothing to compare
                // against — a disabled menu item would leave the person nowhere to go.
                rule: .always,
                // The one application command that does not need a document.
                action: .documentOptional { controller, document in
                    ProjectWindowController.importLedgerJSON(for: document, window: controller?.window)
                }
            )

        case .exportMeasurementOverlay:
            // The menu route to `ZenitOverlayExporter`: the drawing's measurements as a
            // `.zpdfoverlay`, through `MeasurementOverlayTransfer`.
            return ZenitAppCommandSpec(
                command,
                slot: .fileAfterExport,
                title: NSLocalizedString(
                    "Export Measurements Overlay…",
                    comment: "File menu command that writes the drawing's measurements as a .zpdfoverlay"
                ),
                rule: .drawing,
                action: .withDocument { controller, document in
                    MeasurementOverlayTransfer.export(document: document, window: controller.window)
                }
            )

        case .importMeasurementOverlay:
            // Its reader. Needs the drawing in front: an overlay is only ever imported onto the
            // drawing it was measured on, and the digest check needs that drawing's bytes.
            return ZenitAppCommandSpec(
                command,
                slot: .fileAfterExport,
                title: NSLocalizedString(
                    "Import Measurements Overlay…",
                    comment: "File menu command that redraws a .zpdfoverlay made on the same drawing"
                ),
                rule: .drawing,
                action: .withDocument { controller, document in
                    MeasurementOverlayTransfer.importOverlay(document: document, window: controller.window)
                }
            )

        case .importReviewAnnotations:
            // NL-COLLAB-08. The drawing's own annotations were rendered and counted and never
            // adopted; a consultant's marked-up PDF could not become Zenit markups at all.
            return ZenitAppCommandSpec(
                command,
                slot: .fileReview,
                title: NSLocalizedString(
                    "Import Review Annotations…",
                    comment: "File menu command that turns a reviewer's PDF annotations into markups"
                ),
                rule: .drawing,
                action: .withDocument { controller, document in
                    ReviewAnnotationImportFlow.run(document: document, window: controller.window)
                }
            )

        case .importSpreadsheetChanges:
            // NL-PLAT-07: the way back from a spreadsheet. Needs the takeoff core: the review
            // compares the workbook with the ledger on screen and the apply is a command batch.
            return ZenitAppCommandSpec(
                command,
                slot: .fileAfterExport,
                title: NSLocalizedString(
                    "Import Spreadsheet Changes…",
                    comment: "File menu command that reads an edited ledger workbook back for review"
                ),
                rule: .loadedCore,
                action: .withDocument { controller, document in
                    SpreadsheetRoundTrip.importChanges(document: document, window: controller.window)
                }
            )

        case .connectSharedReview:
            // NL-COLLAB-12, ADR-0026: review together through a folder, no server.
            // `.drawing`, not `.projectDrawing`, on purpose (R-029, S-016): on a Quick PDF the row
            // stays enabled so choosing it says, before any panel, that a shared review needs a
            // project. Export and Import Review File follow the same rule; Sync, Disconnect and
            // Share Review File, which have nothing to explain, are disabled there instead.
            return ZenitAppCommandSpec(
                command,
                slot: .fileReview,
                title: NSLocalizedString(
                    "Connect Shared Review Folder…",
                    comment: "File menu command that connects the project to a shared review folder"
                ),
                rule: .drawing,
                action: .withDocument { controller, document in
                    SharedReviewCommands.connect(document: document, window: controller.window)
                }
            )

        case .syncSharedReview:
            return ZenitAppCommandSpec(
                command,
                slot: .fileReview,
                title: NSLocalizedString(
                    "Sync Shared Review",
                    comment: "File menu command that shares this project's review changes and applies everyone else's"
                ),
                rule: .projectDrawing,
                action: .withDocument { _, document in
                    Task { @MainActor in _ = await SharedReviewCommands.syncNow(document: document) }
                }
            )

        case .disconnectSharedReview:
            return ZenitAppCommandSpec(
                command,
                slot: .fileReview,
                title: NSLocalizedString(
                    "Disconnect Shared Review Folder",
                    comment: "File menu command that stops syncing the project with its shared review folder"
                ),
                rule: .projectDrawing,
                action: .withDocument { _, document in
                    Task { @MainActor in await SharedReviewCommands.disconnect(document: document) }
                }
            )

        case .exportReviewFile:
            // Enabled on a Quick PDF on purpose, to refuse in words before its panel (S-016; see
            // Connect Shared Review Folder).
            return ZenitAppCommandSpec(
                command,
                slot: .fileReview,
                title: NSLocalizedString("Export Review File…", comment: "File menu command: every markup and reply as a .zpdfreview"),
                rule: .drawing,
                action: .withDocument { controller, document in ReviewFileFlow.export(document: document, window: controller.window) }
            )

        case .importReviewFile:
            // Enabled on a Quick PDF on purpose, to refuse in words before its panel (S-016; see
            // Connect Shared Review Folder).
            return ZenitAppCommandSpec(
                command,
                slot: .fileReview,
                title: NSLocalizedString("Import Review File…", comment: "File menu command: merge a .zpdfreview from another copy of the project"),
                rule: .drawing,
                action: .withDocument { controller, document in ReviewFileFlow.importFile(document: document, window: controller.window) }
            )

        case .shareReviewFile:
            return ZenitAppCommandSpec(
                command,
                slot: .fileReview,
                title: NSLocalizedString("Share Review File…", comment: "File menu command: send the review file with AirDrop, Mail or Messages"),
                rule: .projectDrawing,
                action: .withDocument { controller, document in ReviewFileFlow.share(document: document, window: controller.window) }
            )

        case .exportXFDF:
            return ZenitAppCommandSpec(
                command,
                slot: .fileReview,
                title: NSLocalizedString("Export Review as XFDF…", comment: "File menu command: the review as an XFDF file"),
                rule: .drawing,
                action: .withDocument { controller, document in ReviewXFDFFlow.export(document: document, window: controller.window) }
            )

        case .importXFDF:
            return ZenitAppCommandSpec(
                command,
                slot: .fileReview,
                title: NSLocalizedString("Import XFDF…", comment: "File menu command: read an XFDF made on this drawing"),
                rule: .drawing,
                action: .withDocument { controller, document in ReviewXFDFFlow.importFile(document: document, window: controller.window) }
            )

        case .reviewList:
            // NL-COLLAB-04: clouds, callouts and text boxes were in no list at all.
            return ZenitAppCommandSpec(
                command,
                slot: .viewExtras,
                title: NSLocalizedString("Review List", comment: "View menu command: every markup in one filterable list"),
                // The list is the takeoff's: while a drawing is still opening there is none, and
                // an enabled row did nothing (T-018).
                rule: .loadedCore,
                action: .withDocument { controller, document in
                    ReviewListWindow.present(for: controller, document: document)
                }
            )

        case .tintByAuthor:
            // NL-COLLAB-06: "who drew what" on a busy sheet, without touching anyone's colours.
            return ZenitAppCommandSpec(
                command,
                slot: .viewExtras,
                title: NSLocalizedString("Tint Markups by Author", comment: "View menu command: draw each markup in its author's colour"),
                rule: .drawing,
                // A checkmark while the tint is on (T-016), as Split Canvas and Revision Overlay
                // carry one.
                isOn: { $0.isTintingByAuthor },
                action: .withDocument { _, document in AuthorTint.toggle(document: document) }
            )

        case .shareLastExport:
            // NL-PLAT-10 (r2-platform): the system share picker needs no entitlement and no server.
            return ZenitAppCommandSpec(
                command,
                slot: .fileAfterExport,
                title: NSLocalizedString("Share Last Export…", comment: "File menu command: share the file the last export wrote"),
                // Its refusal is spoken in the takeoff's tray, which does not exist while the
                // drawing opens; nothing can have been exported by then either (T-018).
                rule: .loadedCore,
                action: .withDocument { controller, document in ShareExport.share(document: document, window: controller.window) }
            )

        case .newFromTemplate:
            return ZenitAppCommandSpec(
                command,
                slot: .fileAfterNew,
                title: NSLocalizedString("New from Template…", comment: "File menu command: start a takeoff from a job template"),
                rule: .always,
                action: .documentOptional { controller, _ in NewFromTemplate.run(window: controller?.window) }
            )

        case .indexDrawingFolder:
            // NL-DOCS-15: closed drawings, searchable. Needs nothing open.
            return ZenitAppCommandSpec(
                command,
                slot: .fileIndexedDrawings,
                title: NSLocalizedString("Index a Folder of Drawings…", comment: "File menu command: make the text of every PDF in a folder searchable"),
                toolTip: NSLocalizedString(
                    "Read the text of every PDF in a folder, so Search Indexed Drawings… finds it without opening the files.",
                    comment: "Index a Folder of Drawings tool tip"
                ),
                rule: .always,
                action: .documentOptional { controller, document in FolderIndexCommand.chooseAndIndex(controller: controller, document: document) }
            )

        case .searchDrawingFolder:
            return ZenitAppCommandSpec(
                command,
                slot: .fileIndexedDrawings,
                title: NSLocalizedString("Search Indexed Drawings…", comment: "File menu command: search the indexed folder of drawings"),
                rule: .always,
                action: .documentOptional { controller, document in FolderIndexCommand.presentSearch(controller: controller, document: document) }
            )

        case .forgetDrawingFolder:
            return ZenitAppCommandSpec(
                command,
                slot: .fileIndexedDrawings,
                title: NSLocalizedString("Forget Indexed Folder", comment: "File menu command: delete the folder index and give back its access"),
                rule: .always,
                action: .documentOptional { controller, document in FolderIndexCommand.forget(document: document, window: controller?.window) }
            )

        case .installPack:
            return ZenitAppCommandSpec(
                command,
                slot: .toolsLibrary,
                title: NSLocalizedString("Install Pack…", comment: "Tools menu command: install a pack of tool sets, templates and profiles"),
                rule: .always,
                action: .documentOptional { controller, document in ZenitPackFlow.chooseAndReview(document: document, window: controller?.window) }
            )

        case .createPack:
            return ZenitAppCommandSpec(
                command,
                slot: .toolsLibrary,
                title: NSLocalizedString("Create Pack…", comment: "Tools menu command: pack the person's templates, profiles and tools"),
                rule: .always,
                action: .documentOptional { controller, document in ZenitPackFlow.createPack(document: document, window: controller?.window) }
            )

        case .sendProject:
            // NL-PLAT-10: hand-off without a server. Refuses, with a note, on a Quick PDF or with
            // unsaved changes rather than sending something the person did not mean to send.
            return ZenitAppCommandSpec(
                command,
                slot: .fileAfterExport,
                title: NSLocalizedString("Send Project…", comment: "File menu command that writes the project as one zip for a colleague"),
                // The refusal is posted to the takeoff, so a project still opening has nowhere
                // to say it: the row waits for the loaded takeoff (U-022, as T-018 did for others).
                rule: .loadedCore,
                action: .withDocument { controller, document in SendProject.send(document: document, window: controller.window) }
            )

        case .saveExportProfile:
            return ZenitAppCommandSpec(
                command,
                slot: .fileAfterExport,
                title: NSLocalizedString("Save Columns as Export Profile…", comment: "File menu command that writes the ledger columns as an export profile"),
                rule: .loadedCore,
                action: .withDocument { controller, document in ExportProfiles.saveColumnsAsProfile(document: document, window: controller.window) }
            )

        case .exportWithProfile:
            return ZenitAppCommandSpec(
                command,
                slot: .fileAfterExport,
                title: NSLocalizedString("Export with Profile…", comment: "File menu command that exports the ledger through an export profile"),
                rule: .loadedCore,
                action: .withDocument { controller, document in ExportProfiles.exportWithProfile(document: document, window: controller.window) }
            )

        case .batchApply:
            // The same stamp on every sheet with one click.
            return ZenitAppCommandSpec(
                command,
                slot: .toolsCapture,
                title: NSLocalizedString(
                    "Batch Stamp…",
                    comment: "Tools menu command that opens the scoped batch apply sheet"
                ),
                // Enabled exactly when there is a stamp preset to batch and pages to put it
                // on. A sheet that opens over an empty Tool Library is a dead end with a scope
                // picker on it.
                rule: .stampPresetAndPages,
                action: .withDocument { controller, document in controller.presentBatchApply(for: document) }
            )

        case .copySnippet:
            // ADR-0006's ten-second path. `⌘⇧C`, next to Copy, because "select the two
            // measurements and copy the picture" is one gesture away from "select and copy".
            // The caption is `.compact` and on: a dimensioned image travelling without its scale
            // is the risk the whole feature carries (ADR-0006 §2).
            return ZenitAppCommandSpec(
                command,
                slot: .editAfterCopy,
                title: NSLocalizedString(
                    "Copy Snippet",
                    comment: "Edit menu command: the selected markups as a captioned image on the pasteboard"
                ),
                keyEquivalent: ZenitKeyEquivalent("c", [.command, .shift]),
                toolTip: NSLocalizedString(
                    "Copy the selected measurements as an image with their values, ready to paste into mail.",
                    comment: "Copy Snippet tool tip"
                ),
                // A snippet is of something. With nothing selected the command would have no
                // region, and ADR-0006 refuses rather than guessing at one — so the menu says so
                // before the click. Tools ▸ Snippet of Region… is the door for "I have not
                // selected anything".
                rule: .markupSelection,
                action: .withDocument { controller, document in controller.copySnippet(for: document) }
            )

        case .exportSnippet:
            // The same picture, saved rather than pasted.
            return ZenitAppCommandSpec(
                command,
                slot: .fileAfterExport,
                title: NSLocalizedString(
                    "Export Snippet…",
                    comment: "File menu command: save the selected markups as an image file"
                ),
                rule: .markupSelection,
                action: .withDocument { controller, document in controller.exportSnippet(for: document) }
            )

        case .shareSnippet:
            // NL-PDF-21: dragged to the Finder as a PNG, or through the sharing picker.
            return ZenitAppCommandSpec(
                command,
                slot: .fileAfterExport,
                title: NSLocalizedString(
                    "Share Snippet…",
                    comment: "File menu command: the selected markups as a picture to drag out or share"
                ),
                toolTip: NSLocalizedString(
                    "The selected measurements as a picture with their values: drag it to the Finder or another app, or share it.",
                    comment: "Share Snippet tool tip"
                ),
                rule: .markupSelection,
                action: .withDocument { controller, document in controller.shareSnippet(for: document) }
            )

        case .createPDFFromDocuments:
            // NL-PDF-18: needs no drawing — it makes one.
            return ZenitAppCommandSpec(
                command,
                slot: .fileAfterExport,
                title: NSLocalizedString(
                    "New PDF from Documents…",
                    comment: "File menu command: turn Word, rich-text, web or text documents into a PDF"
                ),
                toolTip: NSLocalizedString(
                    "Lay out Word, OpenDocument, rich-text, web or plain-text documents as one PDF on this Mac, then open it.",
                    comment: "New PDF from Documents tool tip"
                ),
                rule: .always,
                action: .documentOptional { controller, _ in CreatePDFFromDocuments.run(window: controller?.window) }
            )

        case .setUpPrintToZenit:
            return ZenitAppCommandSpec(
                command,
                slot: .fileAfterExport,
                title: NSLocalizedString(
                    "Set Up “Print to Zenit PDF”…",
                    comment: "File menu command: add Zenit PDF to the print dialog's PDF menu"
                ),
                toolTip: NSLocalizedString(
                    "Adds Zenit PDF to the PDF menu of every print dialog, so any application's print job opens here.",
                    comment: "Set Up Print to Zenit PDF tool tip"
                ),
                rule: .always,
                action: .documentOptional { controller, _ in CreatePDFFromDocuments.setUpPrintService(window: controller?.window) }
            )

        case .snippetRegion:
            // The drawn-rectangle half of ADR-0006 §1.
            return ZenitAppCommandSpec(
                command,
                slot: .toolsCapture,
                title: NSLocalizedString(
                    "Snippet of Region…",
                    comment: "Tools menu command: drag a rectangle and copy it as an image"
                ),
                rule: .drawing,
                action: .withDocument { controller, document in controller.beginSnippetRegion(for: document) }
            )

        // The drawing exports: separate rows rather than one row with a
        // format popup, because they answer different questions — send them what I printed,
        // let them edit my markups, give them the drawing back — and a popup makes the person
        // open a dialogue to find that out. Each is of the whole set, so neither an empty
        // selection nor an empty ledger refuses it: a clean PDF of a drawing nobody has
        // measured yet is a legitimate thing to ask for.
        case .exportFlattenedPDF:
            return ZenitAppCommandSpec(
                command,
                slot: .fileExportDrawing,
                title: NSLocalizedString(
                    "Export Marked PDF…",
                    comment: "File menu command: the drawing with the markups drawn into the page"
                ),
                toolTip: NSLocalizedString(
                    "The drawing with your markups drawn into it, exactly as it prints. Anyone can open it; nobody can edit the markups.",
                    comment: "Export Marked PDF tool tip"
                ),
                rule: .drawing,
                action: .withDocument { controller, document in controller.exportDrawing(.flattened, for: document) }
            )

        case .exportAnnotatedPDF:
            return ZenitAppCommandSpec(
                command,
                slot: .fileExportDrawing,
                title: NSLocalizedString(
                    "Export Annotated PDF…",
                    comment: "File menu command: the markups as editable PDF annotations"
                ),
                toolTip: NSLocalizedString(
                    "The drawing with your markups as PDF annotations, so another reader can select and edit them.",
                    comment: "Export Annotated PDF tool tip"
                ),
                rule: .drawing,
                action: .withDocument { controller, document in controller.exportAnnotatedDrawing(for: document) }
            )

        case .exportCleanPDF:
            return ZenitAppCommandSpec(
                command,
                slot: .fileExportDrawing,
                title: NSLocalizedString(
                    "Export Clean PDF…",
                    comment: "File menu command: the drawing with no Zenit markups"
                ),
                toolTip: NSLocalizedString(
                    "The drawing with none of your markups on it.",
                    comment: "Export Clean PDF tool tip"
                ),
                rule: .drawing,
                action: .withDocument { controller, document in controller.exportDrawing(.clean, for: document) }
            )

        case .exportLayeredPDF:
            return ZenitAppCommandSpec(
                command,
                slot: .fileExportDrawing,
                title: NSLocalizedString(
                    "Export with Markups as a PDF Layer…",
                    comment: "File menu command: the drawing untouched, markups on a switchable layer"
                ),
                toolTip: NSLocalizedString(
                    "The drawing byte for byte, with your markups added as a layer any reader can switch off.",
                    comment: "Export layered PDF tool tip"
                ),
                rule: .drawing,
                action: .withDocument { controller, document in controller.exportLayeredDrawing(for: document) }
            )

        case .optimizeCopy:
            return ZenitAppCommandSpec(
                command,
                slot: .fileExportDrawing,
                title: NSLocalizedString(
                    "Optimize or Protect a Copy…",
                    comment: "File menu command: a smaller, cleaned or password-protected copy of the drawing"
                ),
                toolTip: NSLocalizedString(
                    "Save a copy of the drawing that is smaller, has scripts and attachments removed, or needs a password. The drawing itself is not changed.",
                    comment: "Optimize copy tool tip"
                ),
                rule: .drawing,
                action: .withDocument { controller, document in controller.optimizeCopy(for: document) }
            )

        case .saveSearchableCopy:
            return ZenitAppCommandSpec(
                command,
                slot: .fileExportDrawing,
                title: NSLocalizedString(
                    "Save Searchable Copy…",
                    comment: "File menu command: a copy of the drawing with the recognised text as an invisible layer"
                ),
                toolTip: NSLocalizedString(
                    "Save a copy of the drawing whose recognised text any PDF reader can search and select. It looks exactly like the drawing.",
                    comment: "Save Searchable Copy tool tip"
                ),
                rule: .searchIndex,
                action: .withDocument { controller, document in controller.saveSearchableCopy(for: document) }
            )

        case .batchHeaderFooter:
            return ZenitAppCommandSpec(
                command,
                slot: .toolsCapture,
                title: NSLocalizedString(
                    "Batch Header, Footer or Sheet Number…",
                    comment: "Tools menu command: the same line of text, with per-sheet fields, on every sheet in scope"
                ),
                toolTip: NSLocalizedString(
                    "Put a header, a footer or a sheet number on every sheet you choose, as one action you can undo.",
                    comment: "Batch header/footer tool tip"
                ),
                rule: .loadedCore,
                action: .withDocument { controller, document in controller.presentHeaderFooterBatch(for: document) }
            )

        case .newSignatureStamp:
            return ZenitAppCommandSpec(
                command,
                slot: .toolsCapture,
                title: NSLocalizedString(
                    "New Signature Stamp from Image…",
                    comment: "Tools menu command: a photographed signature becomes a stamp tool"
                ),
                toolTip: NSLocalizedString(
                    "Trace a photo or scan of a handwritten signature into a stamp tool. It is an image of a signature, not a digital signature.",
                    comment: "New Signature Stamp tool tip"
                ),
                rule: .loadedCore,
                action: .withDocument { controller, document in SignatureImageStamp.run(document: document, window: controller.window) }
            )

        case .cleanUpScans:
            return ZenitAppCommandSpec(
                command,
                slot: .toolsCapture,
                title: NSLocalizedString(
                    "Clean Up Scanned Sheets…",
                    comment: "Tools menu command: straighten, rectify, trim and enhance scanned sheets into a new PDF"
                ),
                toolTip: NSLocalizedString(
                    "Straighten, rectify, trim, turn and enhance scanned or photographed sheets into a new PDF, each at its own paper size. The drawing itself is not changed.",
                    comment: "Clean Up Scanned Sheets tool tip"
                ),
                rule: .drawing,
                action: .withDocument { controller, document in ScanCleanupCommand.present(document: document, window: controller.window) }
            )

        case .markRedaction:
            return ZenitAppCommandSpec(
                command,
                slot: .toolsRedaction,
                title: NSLocalizedString("Mark Area for Redaction", comment: "Tools menu command: drag a box over something to remove"),
                toolTip: NSLocalizedString(
                    "Drag a box over what must be removed from a copy of the drawing. Marks are not saved and never enter the ledger.",
                    comment: "Mark Area for Redaction tool tip"
                ),
                rule: .drawing,
                action: .withDocument { controller, document in controller.beginRedactionMark(for: document) }
            )

        case .applyRedactions:
            return ZenitAppCommandSpec(
                command,
                slot: .toolsRedaction,
                title: NSLocalizedString("Apply Redactions to a Copy…", comment: "Tools menu command: write a copy with the marked areas removed"),
                toolTip: NSLocalizedString(
                    "Write a new PDF with everything under the boxes removed for good, checked before it is kept.",
                    comment: "Apply Redactions tool tip"
                ),
                rule: .drawing,
                action: .withDocument { controller, document in controller.applyRedactions(for: document) }
            )

        case .clearRedactionMarks:
            return ZenitAppCommandSpec(
                command,
                slot: .toolsRedaction,
                title: NSLocalizedString("Clear Redaction Marks", comment: "Tools menu command: forget the marked redaction areas"),
                rule: .drawing,
                action: .withDocument { controller, document in controller.clearRedactionMarks(for: document) }
            )

        case .fillFormFields:
            return ZenitAppCommandSpec(
                command,
                slot: .toolsDrawingData,
                title: NSLocalizedString("Fill Form Fields…", comment: "Tools menu command: fill the drawing's form fields into a new file"),
                toolTip: NSLocalizedString(
                    "Fill the PDF's own form fields — an RFI, a transmittal — and save a filled copy. The drawing itself is not changed.",
                    comment: "Fill Form Fields tool tip"
                ),
                rule: .drawing,
                action: .withDocument { controller, document in FormFill.present(document: document, window: controller.window) }
            )

        case .processPDFFiles:
            // NL-PDF-19: files that are not open — no drawing needed.
            return ZenitAppCommandSpec(
                command,
                slot: .toolsCapture,
                title: NSLocalizedString("Process PDF Files…", comment: "Tools menu command: run steps over a folder of PDFs"),
                toolTip: NSLocalizedString(
                    "Make searchable, reduce size, clean or protect a whole folder of PDFs into another folder, with a report per file.",
                    comment: "Process PDF Files tool tip"
                ),
                rule: .always,
                action: .documentOptional { controller, document in BatchFileCommand.present(controller: controller, document: document) }
            )

        case .stopProcessingPDFFiles:
            return ZenitAppCommandSpec(
                command,
                slot: .toolsCapture,
                title: NSLocalizedString("Stop Processing PDF Files", comment: "Tools menu command: stop the running batch"),
                // Enabled only while a run is in progress: there is nothing to stop otherwise.
                rule: .batchProcessing,
                action: .documentOptional { _, _ in BatchFileCommand.stop() }
            )

        case .signDrawingCopy:
            return ZenitAppCommandSpec(
                command,
                slot: .fileExportDrawing,
                title: NSLocalizedString(
                    "Sign a Copy with a Certificate…",
                    comment: "File menu command: a copy of the drawing digitally signed with a keychain certificate"
                ),
                toolTip: NSLocalizedString(
                    "Save a copy of the drawing signed with a certificate from your keychain. Nothing is sent anywhere.",
                    comment: "Sign copy tool tip"
                ),
                rule: .drawing,
                action: .withDocument { controller, document in controller.signDrawingCopy(for: document) }
            )

        case .saveMarkupsIntoPDF:
            return ZenitAppCommandSpec(
                command,
                slot: .fileAfterSaveAs,
                title: NSLocalizedString(
                    "Save Markups into PDF…",
                    comment: "File menu command: append the markups and the takeoff to the PDF, after a confirmation"
                ),
                toolTip: NSLocalizedString(
                    "Add your markups to the PDF as annotations any reader shows, with the takeoff inside. The original drawing stays unchanged at the start of the file.",
                    comment: "Save Markups into PDF tool tip"
                ),
                rule: .drawing,
                action: .withDocument { controller, document in controller.saveMarkupsIntoPDF(for: document) }
            )

        // Feature 18 — the whole rig as a named template, and back.
        case .saveJobTemplate:
            return ZenitAppCommandSpec(
                command,
                slot: .toolsJobTemplates,
                title: NSLocalizedString(
                    "Save as Job Template…",
                    comment: "Tools menu command: capture presets, subjects, colours, columns and units"
                ),
                // The rig lives on the open document's presenters.
                rule: .loadedCore,
                action: .withDocument { controller, document in controller.saveJobTemplate(for: document) }
            )

        case .applyJobTemplate:
            return ZenitAppCommandSpec(
                command,
                slot: .toolsJobTemplates,
                title: NSLocalizedString(
                    "Apply Job Template…",
                    comment: "Tools menu command: apply a stored job template to this project"
                ),
                rule: .loadedCore,
                action: .withDocument { controller, document in controller.applyJobTemplate(for: document) }
            )

        case .exportJobTemplate:
            return ZenitAppCommandSpec(
                command,
                slot: .toolsJobTemplates,
                title: NSLocalizedString(
                    "Export Job Template…",
                    comment: "Tools menu command: one template as a .zpdftemplate file"
                ),
                // The template library is per-user: it needs no document (U-023). The panels sheet
                // on the window when there is one and run on their own when there is not, as
                // Install Pack… and Create Pack… do.
                rule: .always,
                action: .documentOptional { controller, document in
                    ProjectWindowController.exportJobTemplate(document: document, window: controller?.window)
                }
            )

        case .importJobTemplate:
            return ZenitAppCommandSpec(
                command,
                slot: .toolsJobTemplates,
                title: NSLocalizedString(
                    "Import Job Template…",
                    comment: "Tools menu command: read a .zpdftemplate file into the library"
                ),
                rule: .always,
                action: .documentOptional { controller, document in
                    ProjectWindowController.importJobTemplate(document: document, window: controller?.window)
                }
            )

        case .checkDrawnDimensions:
            return ZenitAppCommandSpec(
                command,
                slot: .measureAutomation,
                title: NSLocalizedString(
                    "Check Against Drawn Dimensions",
                    comment: "Measure menu command: compare measurements with the dimensions printed on the sheet"
                ),
                rule: .drawing,
                action: .withDocument { controller, document in controller.checkDrawnDimensions(for: document) }
            )

        case .importTableFromDrawing:
            return ZenitAppCommandSpec(
                command,
                slot: .toolsDrawingData,
                title: NSLocalizedString(
                    "Import Table from Drawing…",
                    comment: "Tools menu command: read a printed schedule as ledger rows"
                ),
                rule: .drawing,
                action: .withDocument { controller, document in controller.beginTableImport(for: document) }
            )

        case .createSymbolSchedule:
            return ZenitAppCommandSpec(
                command,
                slot: .measureAutomation,
                title: NSLocalizedString(
                    "Create Symbol Schedule…",
                    comment: "Measure menu command: count matching symbols from one boxed example"
                ),
                rule: .drawing,
                action: .withDocument { controller, document in controller.beginSymbolSchedule(for: document) }
            )

        case .autoTraceOptions:
            return ZenitAppCommandSpec(
                command,
                slot: .measureAutomation,
                title: NSLocalizedString(
                    "Auto-Trace Options…",
                    comment: "Measure menu command: choose what one-click auto-trace leaves out"
                ),
                rule: .drawing,
                action: .withDocument { controller, document in controller.showAutoTraceOptions(for: document) }
            )

        case .findLibrarySymbols:
            return ZenitAppCommandSpec(
                command,
                slot: .measureAutomation,
                title: NSLocalizedString(
                    "Find Library Symbols on This Page…",
                    comment: "Measure menu command: search the page for every symbol saved in the local library"
                ),
                rule: .drawing,
                action: .withDocument { controller, document in controller.findLibrarySymbols(for: document) }
            )

        case .findGeometry:
            return ZenitAppCommandSpec(
                command,
                slot: .measureAutomation,
                title: NSLocalizedString(
                    "Find Geometry…",
                    comment: "Measure menu command: search the page for circles, lines of a length or parallel pairs"
                ),
                rule: .drawing,
                action: .withDocument { controller, document in controller.beginGeometryQuery(for: document) }
            )

        case .findWalls:
            return ZenitAppCommandSpec(
                command,
                slot: .measureAutomation,
                title: NSLocalizedString("Find Walls on This Page…", comment: "Measure menu command: propose wall centrelines by thickness"),
                toolTip: NSLocalizedString("Finds the wall thicknesses on a calibrated sheet and proposes each class's centreline length. Nothing is added until you tick it.", comment: "Find Walls tool tip"),
                rule: .drawing,
                action: .withDocument { controller, document in controller.findWalls(for: document) }
            )

        case .findRepeatedSheets:
            return ZenitAppCommandSpec(
                command,
                slot: .measureAutomation,
                title: NSLocalizedString("Find Repeated Sheets…", comment: "Measure menu command: find sheets that are the same drawing"),
                toolTip: NSLocalizedString("Finds sheets drawn alike — a typical floor — so you measure one and apply it ×N.", comment: "Find Repeated Sheets tool tip"),
                rule: .drawing,
                action: .withDocument { controller, document in controller.findRepeatedSheets(for: document) }
            )

        case .prepareSet:
            return ZenitAppCommandSpec(
                command,
                slot: .measureAutomation,
                title: NSLocalizedString("Prepare This Set…", comment: "Measure menu command: run the Takeoff Assistant over every sheet"),
                toolTip: NSLocalizedString("Reads every sheet for its name, scale and rooms and files them as proposals to review. Nothing is changed.", comment: "Prepare This Set tool tip"),
                rule: .drawing,
                action: .withDocument { controller, document in controller.prepareSet(for: document) }
            )

        case .assistantInbox:
            return ZenitAppCommandSpec(
                command,
                slot: .measureAutomation,
                title: NSLocalizedString("Takeoff Assistant Inbox", comment: "Measure menu command: the Takeoff Assistant's proposals"),
                rule: .loadedCore,
                action: .withDocument { controller, document in controller.showAssistantInbox(for: document) }
            )

        case .detectRooms:
            return ZenitAppCommandSpec(
                command,
                slot: .measureAutomation,
                title: NSLocalizedString(
                    "Detect Rooms on This Page…",
                    comment: "Measure menu command: propose every room on the page as a named area"
                ),
                rule: .drawing,
                action: .withDocument { controller, document in controller.detectRooms(for: document) }
            )

        case .nameSheetsFromTitleBlock:
            return ZenitAppCommandSpec(
                command,
                slot: .toolsDrawingData,
                title: NSLocalizedString(
                    "Name Sheets from Title Block…",
                    comment: "Tools menu command: read every sheet's number and title from its title block"
                ),
                rule: .drawing,
                action: .withDocument { controller, document in controller.beginSheetNaming(for: document) }
            )

        // L-03: the five drawing-set items of the Navigator's ⋯ menu (R-071), in the menu bar as
        // well. Each runs the window shell's own hook — the one implementation the card menu
        // runs — so the two doors cannot drift apart. A precondition the flow cannot meet is
        // said by the flow (no earlier revision, no project to combine into).
        case .exportArrangedSet:
            return ZenitAppCommandSpec(
                command,
                slot: .fileDrawingSet,
                title: NSLocalizedString("Export Arranged Set…", comment: "Navigator file menu: write the set, as arranged, to a new PDF"),
                rule: .drawing,
                action: .withDocument { controller, document in controller.windowShell(for: document)?.onExportArrangedSet?() }
            )
        case .linkSheetReferences:
            return ZenitAppCommandSpec(
                command,
                slot: .fileDrawingSet,
                title: NSLocalizedString("Link Sheet References…", comment: "Navigator file menu: link every sheet reference in the set to its sheet"),
                rule: .loadedCore,
                action: .withDocument { controller, document in controller.windowShell(for: document)?.onLinkSheetReferences?() }
            )
        // L-57/L-93: the one door to a revision that is not an ⌥ drop from Finder. It sits in
        // the set's own submenu, before the report that needs it.
        case .addRevision:
            return ZenitAppCommandSpec(
                command,
                slot: .fileDrawingSet,
                title: NSLocalizedString("Add Revision…", comment: "File ▸ Drawing Set: choose the revised PDF of this drawing and add it as a revision"),
                toolTip: NSLocalizedString(
                    "Choose the revised PDF of this drawing, for Revision Compare, Revision Overlay and the Set Compare Report.",
                    comment: "Tooltip of File ▸ Drawing Set ▸ Add Revision…"
                ),
                rule: .drawing,
                action: .withDocument { controller, document in
                    AddRevisionCommand.choose(document: document, sheetedOn: controller.window)
                }
            )
        case .setCompareReport:
            return ZenitAppCommandSpec(
                command,
                slot: .fileDrawingSet,
                title: NSLocalizedString("Set Compare Report…", comment: "Navigator file menu: compare every sheet with the newest revision and write a report"),
                rule: .drawing,
                action: .withDocument { controller, document in controller.windowShell(for: document)?.onSetCompareReport?() }
            )
        case .splitIntoSheets:
            return ZenitAppCommandSpec(
                command,
                slot: .fileDrawingSet,
                title: NSLocalizedString("Split into Sheets…", comment: "Navigator file menu: write one PDF per sheet, named by sheet number"),
                rule: .drawing,
                action: .withDocument { controller, document in controller.windowShell(for: document)?.onSplitIntoSheets?() }
            )
        case .combineOpenDrawings:
            return ZenitAppCommandSpec(
                command,
                slot: .fileDrawingSet,
                title: NSLocalizedString(
                    "Combine Open Drawings into This Project…",
                    comment: "Navigator file menu: add every other open drawing, with its takeoff, to this project"
                ),
                rule: .drawingWithOtherTabs,
                action: .withDocument { controller, document in controller.windowShell(for: document)?.onCombineOpenDrawings?() }
            )

        // Lock and hide through the command bus (IM-023): at the end of Edit, each one undoable
        // and audited.
        case .toggleLockSelection:
            return ZenitAppCommandSpec(
                command,
                slot: .editSelection,
                title: NSLocalizedString("Lock Selection", comment: "Edit menu command: lock or unlock the selected markups"),
                rule: .markupSelection,
                stateTitle: { state in
                    state.selectionIsLocked
                        ? NSLocalizedString("Unlock Selection", comment: "Edit menu command: unlock the selected markups")
                        : NSLocalizedString("Lock Selection", comment: "Edit menu command: lock or unlock the selected markups")
                },
                action: .withDocument { controller, document in
                    controller.applyLockOrHide(
                        for: document,
                        lock: !((document.core).map(ProjectWindowController.selectionIsLocked) ?? false)
                    )
                }
            )

        case .hideSelection:
            return ZenitAppCommandSpec(
                command,
                slot: .editSelection,
                title: NSLocalizedString("Hide Selection", comment: "Edit menu command: hide the selected markups"),
                rule: .markupSelection,
                action: .withDocument { controller, document in controller.applyLockOrHide(for: document, hide: true) }
            )

        case .showHiddenMarkups:
            return ZenitAppCommandSpec(
                command,
                slot: .editSelection,
                title: NSLocalizedString(
                    "Show Hidden Markups",
                    comment: "Edit menu command: show every hidden markup on this page"
                ),
                rule: .hiddenMarkups,
                action: .withDocument { controller, document in controller.showHiddenMarkups(in: document) }
            )

        // NL-UX-20: one document, several windows, one undo stack. ⌃⌘N, because ⌥⌘N is the
        // Navigator's and ⌘N is New (`ShortcutChordUniquenessTests` holds the chord to itself).
        case .newWindowForProject:
            return ZenitAppCommandSpec(
                command,
                slot: .windowTabs,
                title: NSLocalizedString("New Window for Project", comment: "Window menu command: a second window on the document in front"),
                keyEquivalent: ZenitKeyEquivalent("n", [.command, .control]),
                toolTip: NSLocalizedString(
                    "Opens this drawing in another window with its own sheet, zoom and selection. Edits, undo and saving are shared.",
                    comment: "New Window for Project tool tip"
                ),
                rule: .loadedCore,
                action: .withDocument { controller, document in
                    Task { @MainActor in await controller.openNewWindow(for: document) }
                }
            )

        // Documents are tabs inside one window, which AppKit's own list cannot see: a way to
        // move between them from the keyboard and the menu (IM-182). ⌘⇧] and ⌘⇧[ on the
        // visible rows, ⌃⇥ and ⌃⇧⇥ on hidden twins so both conventions work.
        case .showNextTab:
            return ZenitAppCommandSpec(
                command,
                slot: .windowTabs,
                title: NSLocalizedString("Show Next Tab", comment: "Window menu command"),
                keyEquivalent: ZenitKeyEquivalent("}", [.command]),
                hiddenKeyEquivalents: [ZenitKeyEquivalent("\t", [.control])],
                rule: .severalTabs,
                action: .withDocument { controller, _ in controller.activateAdjacentTab(offset: 1) }
            )

        case .makeDrawingAnnotationsEditable:
            return ZenitAppCommandSpec(
                command,
                slot: .toolsDrawingData,
                title: NSLocalizedString(
                    "Make Drawing Annotations Editable…",
                    comment: "Tools menu command: turn the drawing's own PDF annotations into Zenit markups"
                ),
                toolTip: NSLocalizedString(
                    "Marks already in the drawing become markups you can select, recolour and edit. You review them first; the originals are hidden, never deleted.",
                    comment: "Make Drawing Annotations Editable tool tip"
                ),
                rule: .drawing,
                action: .withDocument { controller, document in
                    Task { @MainActor in
                        await DrawingAnnotationAdoption.run(document: document, window: controller.window)
                    }
                }
            )

        case .selectSameSubject:
            return ZenitAppCommandSpec(
                command,
                slot: .editSelection,
                title: NSLocalizedString("Select Same Subject on Page", comment: "Edit menu command: select every markup with the selection's subject on this page"),
                rule: .markupSelection,
                action: .withDocument { controller, document in controller.selectSimilar(.subject, scope: nil, in: document) }
            )

        case .selectSameKind:
            return ZenitAppCommandSpec(
                command,
                slot: .editSelection,
                title: NSLocalizedString("Select Same Kind on Page", comment: "Edit menu command: select every markup of the selection's kind on this page"),
                rule: .markupSelection,
                action: .withDocument { controller, document in controller.selectSimilar(.kind, scope: nil, in: document) }
            )

        case .selectAllInDocument:
            return ZenitAppCommandSpec(
                command,
                slot: .editSelection,
                title: NSLocalizedString("Select All in Document", comment: "Edit menu command: select every visible markup on every page"),
                keyEquivalent: ZenitKeyEquivalent("a", [.command, .option]),
                rule: .loadedCore,
                action: .withDocument { controller, document in controller.selectSimilar(.any, scope: .document, in: document) }
            )

        case .copyStyle:
            return ZenitAppCommandSpec(
                command,
                slot: .editSelection,
                title: NSLocalizedString("Copy Style", comment: "Edit menu command: copy the selected markup's appearance"),
                keyEquivalent: ZenitKeyEquivalent("c", [.command, .option]),
                rule: .markupSelection,
                action: .withDocument { _, document in
                    guard let core = document.core else { return }
                    StyleClipboard.copy(from: core)
                }
            )

        case .pasteStyle:
            return ZenitAppCommandSpec(
                command,
                slot: .editSelection,
                title: NSLocalizedString("Paste Style", comment: "Edit menu command: give the copied appearance to the selection"),
                keyEquivalent: ZenitKeyEquivalent("v", [.command, .option]),
                rule: .markupSelection,
                action: .withDocument { _, document in
                    guard let core = document.core else { return }
                    Task { @MainActor in
                        // A refusal (a locked markup in the selection) is said in the warning
                        // tray, as every refused canvas or Inspector edit is.
                        if let receipt = await StyleClipboard.paste(into: core), let failure = receipt.failureDescription {
                            ZenitPDFProjectDocument.reportRefusedEdit(StyleClipboard.Refusal(message: failure), core: core)
                        }
                    }
                }
            )

        case .pasteInPlace:
            return ZenitAppCommandSpec(
                command,
                slot: .editAfterCopy,
                title: NSLocalizedString("Paste in Place", comment: "Edit menu command: paste copied markups at their own page position"),
                keyEquivalent: ZenitKeyEquivalent("v", [.command, .option, .shift]),
                rule: .loadedCore,
                action: .withDocument { controller, document in
                    guard let canvas = controller.canvasController(for: document) else { return }
                    Task { @MainActor in _ = await canvas.pasteMarkups(placement: .inPlace) }
                }
            )

        case .duplicateMarkups:
            return ZenitAppCommandSpec(
                command,
                slot: .editAfterCopy,
                title: NSLocalizedString("Duplicate Markups", comment: "Edit menu command: copy the selected markups beside themselves"),
                keyEquivalent: ZenitKeyEquivalent("d", [.command]),
                rule: .markupSelection,
                action: .withDocument { controller, document in
                    guard let canvas = controller.canvasController(for: document) else { return }
                    Task { @MainActor in _ = await canvas.duplicateSelectedMarkups() }
                }
            )

        case .pasteToPages:
            return ZenitAppCommandSpec(
                command,
                slot: .editAfterCopy,
                title: NSLocalizedString("Paste to Selected Pages", comment: "Edit menu command: paste copied markups onto every page selected in the Navigator"),
                toolTip: NSLocalizedString(
                    "Select pages in the Navigator first. The markups land at the same position on each, as one step you can undo.",
                    comment: "Paste to Selected Pages tool tip"
                ),
                rule: .loadedCore,
                action: .withDocument { controller, document in
                    guard let canvas = controller.canvasController(for: document) else { return }
                    Task { @MainActor in _ = await canvas.pasteMarkupsToSelectedPages() }
                }
            )

        case .groupMarkups, .ungroupMarkups, .editMarkupLink, .insertImage,
             .bringToFront, .bringForward, .sendBackward, .sendToBack,
             .alignLeft, .alignCentres, .alignRight, .alignTop, .alignMiddles, .alignBottom,
             .distributeHorizontally, .distributeVertically, .makeSameWidth, .makeSameHeight:
            return MarkupRound2MenuSpecs.spec(for: command)

        case .commandPalette:
            return ZenitAppCommandSpec(
                command,
                slot: .viewExtras,
                title: NSLocalizedString("Command Palette…", comment: "View menu command: open the command palette"),
                keyEquivalent: ZenitKeyEquivalent("p", [.command, .shift]),
                toolTip: NSLocalizedString(
                    "Type the name of any command, tool, page or subject and press Return.",
                    comment: "Command Palette menu tool tip"
                ),
                // The palette is the shell's, which a drawing still opening has not got (T-018).
                rule: .loadedCore,
                action: .withDocument { controller, document in controller.presentCommandPalette(for: document) }
            )

        case .showPreviousTab:
            return ZenitAppCommandSpec(
                command,
                slot: .windowTabs,
                title: NSLocalizedString("Show Previous Tab", comment: "Window menu command"),
                keyEquivalent: ZenitKeyEquivalent("{", [.command]),
                hiddenKeyEquivalents: [ZenitKeyEquivalent("\t", [.control, .shift])],
                rule: .severalTabs,
                action: .withDocument { controller, _ in controller.activateAdjacentTab(offset: -1) }
            )
        }
    }
}

// MARK: - The window's answer to the rules

/// ``ZenitAppCommandState`` for a real window: each property reads the window's front document
/// when asked, never before.
@MainActor
struct ZenitAppCommandWindowState: ZenitAppCommandState {
    let controller: ProjectWindowController

    private var document: ZenitPDFProjectDocument? { controller.activeDocument }

    var hasActiveDocument: Bool { document != nil }
    var isQuickPDF: Bool { document?.mode == .quickPDF }
    var hasDrawing: Bool { document?.drawing != nil }
    var hasSearchIndex: Bool { document?.searchIndex != nil }
    var hasLoadedCore: Bool { document?.core != nil }
    var hasPagesAndStampPreset: Bool {
        guard let core = document?.core else { return false }
        return !core.snapshot.pages.isEmpty
            && core.toolLibrary.presets.contains { $0.stamp != nil }
    }
    var hasMarkupSelection: Bool { !(document?.core?.canvas.selectedMarkupIDs.isEmpty ?? true) }
    var hasGroupedMarkupSelection: Bool {
        guard let core = document?.core else { return false }
        return core.selectionHasGroup(core.canvas.selectedMarkupIDs)
    }
    var selectionIsLocked: Bool {
        guard let core = document?.core else { return false }
        return ProjectWindowController.selectionIsLocked(core)
    }
    var hasHiddenMarkups: Bool { document?.core?.snapshot.markups.contains(where: \.hidden) ?? false }
    var tabCount: Int { controller.documents.count }
    var isSaveActivityBusy: Bool { document?.isSaveActivityBusy ?? false }
    var isBatchProcessing: Bool { BatchFileCommand.isRunning }
    var isTintingByAuthor: Bool { document?.core?.canvas.tintsByAuthor ?? false }
}

/// The state with no project window at all (T-009): no document, no tab, no selection. Only a
/// running batch is still true, since it belongs to no window.
@MainActor
struct ZenitAppCommandNoWindowState: ZenitAppCommandState {
    var hasActiveDocument: Bool { false }
    var isQuickPDF: Bool { false }
    var hasDrawing: Bool { false }
    var hasSearchIndex: Bool { false }
    var hasLoadedCore: Bool { false }
    var hasPagesAndStampPreset: Bool { false }
    var hasMarkupSelection: Bool { false }
    var selectionIsLocked: Bool { false }
    var hasHiddenMarkups: Bool { false }
    var tabCount: Int { 0 }
    var isSaveActivityBusy: Bool { false }
    var isBatchProcessing: Bool { BatchFileCommand.isRunning }
}

// MARK: - The document's own actions

/// The rules `ZenitPDFProjectDocument.validateUserInterfaceItem` applies to AppKit's document
/// selectors (Save, Save As, Duplicate, Revert, Print, Browse Versions…), read into one table
/// beside the application commands so the menu's enablement rules live in one file.
///
/// The rows are standard selectors routed to `NSDocument`, not ``ZenitAppCommand``s, so they
/// are a table of their own: each entry says which of three conditions disables its selector.
@MainActor
enum ZenitDocumentActionTable {

    struct Entry {
        let action: Selector
        /// Parks the main thread on the document activity, so it is disabled while a save runs
        /// (CR-147), with a tooltip that says why (IM-177), and disabled with nothing loaded —
        /// the untitled launch window, or a drawing still opening — because there is nothing to
        /// save, print or duplicate (CR-161).
        let isSaveActivityDoor: Bool
        /// Would call `read(from:ofType:)`, which only records a URL once a session exists, and
        /// AppKit would then mark the unsaved takeoff clean (BH-355). Disabled while a session
        /// exists; the takeoff's own ⌘Z and History are the way back.
        let isRevert: Bool
    }

    static let entries: [Entry] = [
        Entry(action: #selector(NSDocument.save(_:)), isSaveActivityDoor: true, isRevert: false),
        Entry(action: #selector(NSDocument.saveAs(_:)), isSaveActivityDoor: true, isRevert: false),
        Entry(action: #selector(NSDocument.saveTo(_:)), isSaveActivityDoor: true, isRevert: false),
        Entry(action: #selector(NSDocument.duplicate(_:)), isSaveActivityDoor: true, isRevert: false),
        Entry(action: #selector(NSDocument.move(_:)), isSaveActivityDoor: true, isRevert: false),
        Entry(action: #selector(NSDocument.rename(_:)), isSaveActivityDoor: true, isRevert: false),
        Entry(action: #selector(NSDocument.revertToSaved(_:)), isSaveActivityDoor: true, isRevert: true),
        Entry(action: #selector(NSDocument.printDocument(_:)), isSaveActivityDoor: true, isRevert: false),
        Entry(action: #selector(NSDocument.browseVersions(_:)), isSaveActivityDoor: false, isRevert: true),
    ]

    /// The actions that park the main thread on the document activity, in table order.
    static let saveActivityActions: [Selector] = entries.filter(\.isSaveActivityDoor).map(\.action)

    /// The actions refused while a session exists, in table order.
    static let revertActions: [Selector] = entries.filter(\.isRevert).map(\.action)

    /// The table's verdict on one document row, or `nil` when it has no opinion and AppKit's
    /// own answer stands. Sets the save-activity rows' tooltip as a side effect, exactly as the
    /// document did.
    ///
    /// The state arguments are autoclosures so a row the table has no rule for reads nothing.
    /// `isPrintInPreparation` says the activity is held by a print rather than a save (R-045),
    /// so the tooltip names the real reason (S-017).
    static func validate(
        _ item: any NSValidatedUserInterfaceItem,
        hasSession: @autoclosure () -> Bool,
        isSaveActivityBusy: @autoclosure () -> Bool,
        isPrintInPreparation: @autoclosure () -> Bool = false,
        hasDrawing: @autoclosure () -> Bool
    ) -> Bool? {
        guard let action = item.action else { return nil }
        if revertActions.contains(action), hasSession() {
            return false
        }
        if saveActivityActions.contains(action) {
            let busy = isSaveActivityBusy()
            // Disabled with a reason, not only greyed out (IM-177).
            (item as? NSMenuItem)?.toolTip = !busy
                ? nil
                : isPrintInPreparation()
                    ? NSLocalizedString("A print is being prepared — available when it finishes.", comment: "Tooltip on a menu item disabled while a print is being prepared")
                    : NSLocalizedString("Saving… available when the save finishes", comment: "Tooltip on a menu item disabled while a save runs")
            if busy { return false }
            if !hasDrawing() { return false }
        }
        return nil
    }
}
