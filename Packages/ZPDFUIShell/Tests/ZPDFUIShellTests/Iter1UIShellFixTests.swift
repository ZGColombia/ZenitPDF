import AppKit
import CoreGraphics
import Foundation
import Observation
import SwiftUI
import Testing
@testable import ZPDFDesignSystem
import ZPDFUILedger
import ZPDFUIPresentation
@testable import ZPDFUIShell

// Regression tests for the quality loop's iteration-1 "uishell" list.
// Every test names its item and
// states what the old code produced. Windows are built off screen and never ordered in.

// MARK: - Fixtures

/// A canvas stand-in that can hold the keyboard.
@MainActor
private final class Iter1FocusableCanvas: NSViewController {
    final class FocusableView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    override func loadView() {
        let container = FocusableView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        container.translatesAutoresizingMaskIntoConstraints = false
        view = container
    }
}

/// A layout controller in a window that is laid out but never shown.
@MainActor
private func iter1Window(
    environment: ProjectShellEnvironment,
    key: String,
    canvas: NSViewController? = nil,
    store: ProjectWindowLayoutStore? = nil
) -> (ProjectWindowLayoutController, NSWindow) {
    var provider: (@MainActor () -> NSViewController)?
    if let canvas { provider = { canvas } }
    let layout = ProjectWindowLayoutController(
        environment: environment,
        store: store ?? ProjectWindowLayoutStore(defaults: ZPDFInMemoryDefaults(), key: key),
        canvasProvider: provider
    )
    layout.presentDetachedLedgerWindow = { _ in }
    layout.detachedLedgerAutosaveName = ""
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1_400, height: 900),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentViewController = layout
    window.setFrame(NSRect(x: 0, y: 0, width: 1_400, height: 900), display: false)
    window.layoutIfNeeded()
    layout.view.layoutSubtreeIfNeeded()
    return (layout, window)
}

@MainActor
private func iter1Markup(
    kind: MarkupKind = .polygon,
    measurementKind: MeasurementKind? = nil,
    fields: [MeasurementFieldSummary] = [],
    pageID: UUID = UUID()
) -> MarkupSummary {
    MarkupSummary(
        id: UUID(),
        kind: kind,
        measurementKind: measurementKind,
        subject: "Slab",
        label: "",
        pageLabel: "A-101",
        pageID: pageID,
        pageIndex: 0,
        author: "Test",
        colorRGBA: ColorRGBA(red: 0, green: 0.4, blue: 0.8, alpha: 1),
        measurementFields: fields,
        created: Date(timeIntervalSince1970: 0),
        modified: Date(timeIntervalSince1970: 0),
        boundsInPageSpace: PDFRectValue(x: 0, y: 0, width: 10, height: 10)
    )
}

private func area(_ squareMetres: String, shown text: String) -> MeasurementFieldSummary {
    MeasurementFieldSummary(
        field: .planArea,
        quantity: .squareMetres(Decimal(string: squareMetres)!),
        displayText: text,
        displayUnitSymbol: "m²"
    )
}

private func length(_ metres: String, shown text: String) -> MeasurementFieldSummary {
    MeasurementFieldSummary(
        field: .planLength,
        quantity: .metres(Decimal(string: metres)!),
        displayText: text,
        displayUnitSymbol: "m"
    )
}

/// Whether a semaphore was signalled, without waiting.
private func fired(_ semaphore: DispatchSemaphore) -> Bool {
    semaphore.wait(timeout: .now()) == .success
}

private func iter1Image(width: Int = 40, height: Int = 20) -> CGImage {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    )!
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

/// A canvas that turns the document to a markup's sheet when it zooms to it, as the shipping
/// `AppCanvasPresenter` does through `onRequestPage` — the page turn the shell never hears of.
@MainActor
private final class PagingCanvas: CanvasPresenting {
    let base: any CanvasPresenting
    let document: any DocumentPresenting
    var markupPages: [UUID: PageDescriptor.ID] = [:]

    init(base: any CanvasPresenting, document: any DocumentPresenting) {
        self.base = base
        self.document = document
    }

    var viewport: ViewportSnapshot { base.viewport }
    var visibleMarkups: [MarkupSummary] { base.visibleMarkups }
    var selectedMarkupIDs: Set<UUID> { base.selectedMarkupIDs }
    var snapFeedback: SnapFeedbackSnapshot? { base.snapFeedback }
    var activeScale: ScaleSummary? { base.activeScale }
    var activeScaleRegion: ScaleRegionSummary? { base.activeScaleRegion }
    var isVectorSnapAvailable: Bool { base.isVectorSnapAvailable }
    var splitCanvasMode: SplitCanvasMode { base.splitCanvasMode }
    var filterBehavior: LedgerCanvasFilterBehavior { base.filterBehavior }
    func setZoom(_ zoom: Double) { base.setZoom(zoom) }
    func zoomToFit() { base.zoomToFit() }
    func zoomToFitWidth() { base.zoomToFitWidth() }
    func zoomTo(markupID: UUID) {
        base.zoomTo(markupID: markupID)
        if let page = markupPages[markupID] { document.goToPage(id: page) }
    }
    func select(markupIDs: Set<UUID>, additive: Bool) { base.select(markupIDs: markupIDs, additive: additive) }
    func clearSelection() { base.clearSelection() }
    func updateCursor(pagePoint: PDFPointValue?) { base.updateCursor(pagePoint: pagePoint) }
    func setSplitCanvasMode(_ mode: SplitCanvasMode) { base.setSplitCanvasMode(mode) }
    func setFilterBehavior(_ behavior: LedgerCanvasFilterBehavior) { base.setFilterBehavior(behavior) }
}

@MainActor
@Suite("Iteration 1 — uishell fixes", .shellTierSerialised)
struct Iter1UIShellFixTests {

    // MARK: - K-02 / R-069 / R-074: canvas letter shortcuts

    /// Old output: `handleKey(characters: "p", …, focus: currentToolSlotFocus())` → `false` and
    /// the active tool stayed `.select` — `performCommand` was never set outside tests, so every
    /// letter but A (served by the app canvas's own keyDown) was passed on and did nothing.
    @Test("K-02/R-069: the window's own router arms the letter tools with the canvas focused")
    func windowRouterArmsLetterTools() throws {
        let environment = ProjectShellEnvironment.mock()
        let canvas = Iter1FocusableCanvas()
        let (layout, window) = iter1Window(environment: environment, key: "it1.letters", canvas: canvas)
        defer { window.close() }
        #expect(window.makeFirstResponder(canvas.view))
        let focus = layout.currentToolSlotFocus()
        #expect(focus == .canvas)
        let router = layout.toolSlotRouter

        #expect(router.handleKey(characters: "p", modifiers: [], focus: focus))
        #expect(environment.toolbar.activeTool == .pan)
        #expect(router.handleKey(characters: "m", modifiers: [], focus: layout.currentToolSlotFocus()))
        #expect(environment.toolbar.activeTool == .measure)
        #expect(router.handleKey(characters: "z", modifiers: [], focus: layout.currentToolSlotFocus()))
        #expect(environment.toolbar.activeTool == .zoom)
        #expect(router.handleKey(characters: "s", modifiers: [], focus: layout.currentToolSlotFocus()))
        #expect(environment.toolbar.activeTool == .select)
        // A letter typed into text, or with focus elsewhere, is still a letter.
        #expect(!router.handleKey(characters: "p", modifiers: [], focus: .editingText))
        #expect(!router.handleKey(characters: "p", modifiers: [], focus: .elsewhere))
        #expect(environment.toolbar.activeTool == .select)
    }

    /// Old output: with a length in progress, `handleKey("2", …)` → `true` and slot 2 armed — the
    /// slot monitor runs before the canvas's keyDown, so a typed length (NL-MEASURE-18) could not
    /// start with a digit.
    @Test("K-02: mid-segment a digit starts a typed length instead of arming a tool slot")
    func digitsBelongToATypedLengthMidSegment() throws {
        let environment = ProjectShellEnvironment.mock()
        let (layout, window) = iter1Window(environment: environment, key: "it1.typed")
        defer { window.close() }
        let router = layout.toolSlotRouter
        let slot2 = try #require(router.preset(inSlot: 2))
        let before = environment.toolLibrary.activePresetID
        try #require(before != slot2.id, "slot 2 is not the armed preset yet")

        environment.measurement.activate(kind: .length)
        environment.measurement.placePoint(PDFPointValue(x: 10, y: 10))
        #expect(!router.handleKey(characters: "2", modifiers: [], focus: .canvas), "the digit goes on to the canvas")
        #expect(environment.toolLibrary.activePresetID == before)

        // With nothing in progress the digit is the slot again.
        environment.measurement.deactivate()
        #expect(router.handleKey(characters: "2", modifiers: [], focus: .canvas))
        #expect(environment.toolLibrary.activePresetID == slot2.id)
    }

    /// Every canvas tool key the router serves: the ten letters and a number slot.
    private static let toolKeys: [(characters: String, modifiers: ZPDFModifierFlags)] = [
        ("s", []), ("p", []), ("z", []), ("t", []), ("c", []), ("r", []), ("m", []), ("x", []),
        ("C", [.shift]), ("a", []), ("2", []),
    ]

    /// Iteration-1 re-fix. The canvas's claim stands in for a two-point pick (Calibrate, Verify
    /// Scale, the Split Area line, Curve an Edge): while it holds, no key may change the toolbar.
    ///
    /// Old output: the claim was asked only for A (`canvasOwnsAreaKey`), so `handleKey("p", …)`
    /// → `true` and `toolbar.activeTool` became `.pan` — likewise M, Z, S, T, C, R, X and ⇧C —
    /// while the canvas still sent the next click to the pick.
    @Test("K-02: while the canvas owns the keyboard no tool key changes the toolbar")
    func canvasClaimHoldsEveryToolKey() throws {
        let environment = ProjectShellEnvironment.mock()
        let (layout, window) = iter1Window(environment: environment, key: "it1r.pick")
        defer { window.close() }
        let router = layout.toolSlotRouter
        var inPick = true
        var asked: [String] = []
        layout.canvasOwnsToolKey = { characters, modifiers in
            asked.append(modifiers.contains(.shift) ? "⇧" + characters : characters)
            return inPick
        }
        let tool = environment.toolbar.activeTool
        let preset = environment.toolLibrary.activePresetID

        for key in Self.toolKeys {
            #expect(!router.handleKey(characters: key.characters, modifiers: key.modifiers, focus: .canvas),
                    "\(key.characters) goes on to the canvas")
            #expect(environment.toolbar.activeTool == tool, "\(key.characters) changed the tool")
            #expect(environment.toolLibrary.activePresetID == preset, "\(key.characters) armed a preset")
        }
        // The canvas is asked about every key, lower-cased, with its modifiers.
        #expect(asked == ["s", "p", "z", "t", "c", "r", "m", "x", "⇧c", "a", "2"])

        // The pick ends: the same keys are shortcuts again.
        inPick = false
        #expect(router.handleKey(characters: "p", modifiers: [], focus: .canvas))
        #expect(environment.toolbar.activeTool == .pan)
    }

    /// Iteration-1 re-fix, the fallback without the application's canvas: a Length with a point
    /// placed keeps every letter from a tool switch; a count group — which a switch commits
    /// (decided 2026-08-26) — keeps only A, its arc key, and leaves the number slots working.
    ///
    /// Old output: mid-Length `handleKey("c", …)` → `true`, `toolbar.activeTool` `.callout` —
    /// the shape the canvas would then have discarded — and `"t"` armed Text the same way.
    @Test("K-02: without a canvas, mid-shape letters stay with the drawing; a count keeps its switches")
    func fallbackHoldsLettersMidShape() throws {
        let environment = ProjectShellEnvironment.mock()
        let (layout, window) = iter1Window(environment: environment, key: "it1r.fallback")
        defer { window.close() }
        let router = layout.toolSlotRouter
        #expect(layout.canvasOwnsToolKey == nil)

        environment.measurement.activate(kind: .length)
        environment.measurement.placePoint(PDFPointValue(x: 10, y: 10))
        let tool = environment.toolbar.activeTool
        for key in Self.toolKeys {
            #expect(!router.handleKey(characters: key.characters, modifiers: key.modifiers, focus: .canvas),
                    "\(key.characters) goes on to the canvas mid-Length")
        }
        #expect(environment.toolbar.activeTool == tool)
        #expect(environment.measurement.activeKind == .length)
        #expect(environment.measurement.placedPoints.count == 1)

        // A count group: A is still the canvas's, every other key switches (and commits it).
        environment.measurement.deactivate()
        environment.measurement.activate(kind: .count)
        environment.measurement.placePoint(PDFPointValue(x: 10, y: 10))
        #expect(!router.handleKey(characters: "a", modifiers: [], focus: .canvas))
        let slot2 = try #require(router.preset(inSlot: 2))
        #expect(router.handleKey(characters: "2", modifiers: [], focus: .canvas))
        #expect(environment.toolLibrary.activePresetID == slot2.id)
        #expect(router.handleKey(characters: "p", modifiers: [], focus: .canvas))
        #expect(environment.toolbar.activeTool == .pan)
    }

    /// Old output: `environment.commands` and the router's `commandTable` were snapshots taken
    /// when the window opened, so a shortcut changed in Settings reached neither: the palette
    /// kept "P" and pressing the new key did nothing. `closeHelp` read `.standard`.
    @Test("R-074: a shortcut changed in Settings reaches an open window's hints, router and tab help")
    func shortcutOverridesReachOpenWindows() throws {
        let saved = ZPDFCommandTable.effective
        defer { ZPDFCommandTable.effective = saved }
        let environment = ProjectShellEnvironment.mock()
        let (layout, window) = iter1Window(environment: environment, key: "it1.overrides")
        defer { window.close() }

        var overrides = ZPDFShortcutOverrides()
        overrides.bindings[ZPDFCommandID.panTool.rawValue] = .some(.character("h", []))
        overrides.bindings[ZPDFCommandID.closeTab.rawValue] = .some(.character("w", [.command, .option]))
        ZPDFCommandTable.effective = ZPDFCommandTable.standard.applying(overrides)

        #expect(environment.commands.command(.panTool)?.binding?.displayString == "H")
        #expect(layout.toolSlotRouter.handleKey(characters: "h", modifiers: [], focus: .canvas))
        #expect(environment.toolbar.activeTool == .pan)
        #expect(!layout.toolSlotRouter.handleKey(characters: "p", modifiers: [], focus: .canvas), "P is free now")
        #expect(DocumentTabView.closeHelp.hasSuffix("(⌥⌘W)"))
        // A pinned table still pins.
        let pinned = ProjectShellEnvironment(
            document: environment.document, canvas: environment.canvas, ledger: environment.ledger,
            toolLibrary: environment.toolLibrary, search: environment.search, compare: environment.compare,
            measurement: environment.measurement, status: environment.status, commands: .standard
        )
        #expect(pinned.commands.command(.panTool)?.binding?.displayString == "P")
    }

    // MARK: - K-08: the layer as the cause

    @Test("K-08: Hidden and Locked say when the markup's layer is the cause, and step aside")
    func layerCauseIsShown() {
        let walls = UUID(), doors = UUID()
        let names: [UUID: String] = [walls: "Walls", doors: "Doors"]
        var hiddenByWalls = iter1Markup()
        hiddenByWalls.layerID = walls
        hiddenByWalls.hidden = true
        hiddenByWalls.layerHidden = true
        var lockedByDoors = iter1Markup()
        lockedByDoors.layerID = doors
        lockedByDoors.locked = true
        lockedByDoors.layerLocked = true
        let plain = iter1Markup()

        let one = InspectorSelectionSummary(markups: [hiddenByWalls])
        #expect(InspectorPanel.layerCause(.hidden, in: one, layerName: { names[$0] }) == "Hidden by layer Walls")
        #expect(InspectorPanel.layerCause(.locked, in: one, layerName: { names[$0] }) == nil)
        let hiddenRow = InspectorPanel.hiddenRowState(one, isWired: true, layerName: { names[$0] })
        #expect(hiddenRow.note == "Hidden by layer Walls")
        #expect(!hiddenRow.isEnabled, "the markup's own switch cannot lift its layer's flag")
        #expect(hiddenRow.disabledReason?.contains("hidden layer") == true)

        let locked = InspectorSelectionSummary(markups: [lockedByDoors, plain])
        let lockedRow = InspectorPanel.lockedRowState(locked, isWired: true, layerName: { names[$0] })
        #expect(lockedRow.note == "Locked by layer Doors")
        #expect(!lockedRow.isEnabled)

        var hiddenByDoors = iter1Markup()
        hiddenByDoors.layerID = doors
        hiddenByDoors.layerHidden = true
        let two = InspectorSelectionSummary(markups: [hiddenByWalls, hiddenByDoors])
        let both = InspectorPanel.layerCause(.hidden, in: two, layerName: { names[$0] })
        #expect(both?.hasPrefix("Hidden by layers ") == true)
        #expect(both?.contains("Walls") == true && both?.contains("Doors") == true)
        // A layer whose name is not known still says the layer is the cause.
        #expect(InspectorPanel.layerCause(.hidden, in: one, layerName: { _ in nil }) == "Hidden by its layer")

        // Nothing from a layer: the rows are as before, with no note.
        let free = InspectorSelectionSummary(markups: [plain])
        let freeLocked = InspectorPanel.lockedRowState(free, isWired: true, layerName: { names[$0] })
        #expect(freeLocked.note == nil && freeLocked.isEnabled)
        #expect(InspectorPanel.hiddenRowState(free, isWired: true, layerName: { names[$0] }).isEnabled)
        #expect(InspectorPanel.booleanAccessibilityValue(true, note: "Hidden by layer Walls") == "On, Hidden by layer Walls")
    }

    // MARK: - R-070: totals with grouping separators

    /// Old outputs: en_US "1,234.57" → nil (no Total row); en_US "12,345" at no decimals →
    /// "12350.600 m²"; de_DE "1.234,57" → nil; sv_SE → "1235,001 m" (no grouping, unlike the rows).
    @Test("R-070: a total of values of 1,000 or more matches the rows in en, de and sv")
    func totalsHandleGroupingSeparators() {
        let en = Locale(identifier: "en_US"), de = Locale(identifier: "de_DE"), sv = Locale(identifier: "sv_SE")
        // 1234.567 + 10 = 1244.567 → 1244.57 (two decimals, half away from zero).
        let enTwo = InspectorSelectionSummary(markups: [
            iter1Markup(fields: [area("1234.567", shown: "1,234.57")]),
            iter1Markup(fields: [area("10", shown: "10.00")])
        ])
        #expect(enTwo.measurementTotalText(.planArea, locale: en) == "1,244.57 m²")
        // 12345.4 + 5.2 = 12350.6 → 12351 (no decimals).
        let enWhole = InspectorSelectionSummary(markups: [
            iter1Markup(fields: [area("12345.4", shown: "12,345")]),
            iter1Markup(fields: [area("5.2", shown: "5")])
        ])
        #expect(enWhole.measurementTotalText(.planArea, locale: en) == "12,351 m²")
        let deTwo = InspectorSelectionSummary(markups: [
            iter1Markup(fields: [area("1234.567", shown: "1.234,57")]),
            iter1Markup(fields: [area("10", shown: "10,00")])
        ])
        #expect(deTwo.measurementTotalText(.planArea, locale: de) == "1.244,57 m²")
        // 1234.5674 + 0.4331 = 1235.0005 → 1235.001 (three decimals).
        let svThree = InspectorSelectionSummary(markups: [
            iter1Markup(fields: [length("1234.5674", shown: "1\u{00A0}234,567")]),
            iter1Markup(fields: [length("0.4331", shown: "0,433")])
        ])
        #expect(svThree.measurementTotalText(.planLength, locale: sv) == "1\u{00A0}235,001 m")
        // 1000.25 + 0.1 = 1000.35 → 1,000.350.
        let enThree = InspectorSelectionSummary(markups: [
            iter1Markup(fields: [length("1000.25", shown: "1,000.250")]),
            iter1Markup(fields: [length("0.1", shown: "0.100")])
        ])
        #expect(enThree.measurementTotalText(.planLength, locale: en) == "1,000.350 m")
        // Feet and inches still total nothing.
        let feet = InspectorSelectionSummary(markups: [
            iter1Markup(fields: [MeasurementFieldSummary(field: .planLength, quantity: .metres(1), displayText: "3' - 3 3/8\"", displayUnitSymbol: "ft")]),
            iter1Markup(fields: [MeasurementFieldSummary(field: .planLength, quantity: .metres(1), displayText: "3' - 3 3/8\"", displayUnitSymbol: "ft")])
        ])
        #expect(feet.measurementTotalText(.planLength, locale: en) == nil)
    }

    /// Old output: "132880,47 ft²" — the grouping comma of "12,345" was taken as the decimal mark.
    /// 12345 m² ÷ 0.09290304 = 132880.474… ft² → 132880.47.
    @Test("R-070: the restated value never takes a grouping separator for the decimal mark")
    func secondaryTextHandlesGrouping() {
        let summary = InspectorSelectionSummary(markups: [iter1Markup(fields: [area("12345", shown: "12,345")])])
        #expect(InspectorMarkupFormatting.secondaryText(for: .planArea, isTotal: false, in: summary, locale: Locale(identifier: "en_US")) == "132,880.47 ft²")
        let german = InspectorSelectionSummary(markups: [iter1Markup(fields: [area("12345", shown: "12.345")])])
        #expect(InspectorMarkupFormatting.secondaryText(for: .planArea, isTotal: false, in: german, locale: Locale(identifier: "de_DE")) == "132.880,47 ft²")
    }

    // MARK: - R-071: set actions on the active drawing's menu

    /// Old output: the items lived only in `NavigatorFileHeader`, which renders only with no tab
    /// summary — never in the application — so the active section's menu offered none of them.
    @Test("R-071: the active drawing's ⋯ menu lists the set outputs and Combine")
    func setActionsAreReachable() throws {
        let environment = ProjectShellEnvironment.mock()
        var ran: [NavigatorSetAction] = []
        environment.onExportArrangedSet = { ran.append(.exportArrangedSet) }
        environment.onLinkSheetReferences = { ran.append(.linkSheetReferences) }
        environment.onSetCompareReport = { ran.append(.setCompareReport) }
        environment.onSplitIntoSheets = { ran.append(.splitIntoSheets) }
        environment.onCombineOpenDrawings = { ran.append(.combineOpenDrawings) }
        environment.hasPreviousRevision = true
        let tabs = environment.document.tabs
        try #require(tabs.count > 1, "the sample opens more than one drawing, so Combine is offered")
        let sections = NavigatorDrawingSection.sections(tabs: tabs, activeID: environment.document.activeTabID, collapsed: [])
        let active = try #require(sections.first { $0.isActive })
        let back = try #require(sections.first { !$0.isActive })

        let offered = NavigatorDrawingSectionHeader.setActions(for: active, in: environment)
        #expect(offered == NavigatorSetAction.allCases)
        #expect(NavigatorDrawingSectionHeader.setActions(for: back, in: environment).isEmpty)
        for action in offered { action.perform(in: environment) }
        #expect(ran == NavigatorSetAction.allCases)

        // Without a revision there is nothing to compare with; unwired items are left out.
        environment.hasPreviousRevision = false
        environment.onSplitIntoSheets = nil
        #expect(NavigatorDrawingSectionHeader.setActions(for: active, in: environment)
            == [.exportArrangedSet, .linkSheetReferences, .combineOpenDrawings])
    }

    // MARK: - R-072: workspace recall with persistence live

    /// Old output: the recall's Navigator-page write raised a persist, which captured the live
    /// panes over the workspace — the Inspector came back open and the Navigator at 270 pt.
    @Test("R-072: recalling a workspace restores its pane widths and collapse flags")
    func workspaceRecallKeepsWidthsAndCollapse() async throws {
        let environment = ProjectShellEnvironment.mock()
        let store = ProjectWindowLayoutStore(defaults: ZPDFInMemoryDefaults(), key: "it1.workspace")
        let (layout, window) = iter1Window(environment: environment, key: "it1.workspace", store: store)
        defer { window.close() }
        layout.configure(window: window)
        // `configure` settles the launch layout on the next main-queue turn, and only then is a
        // layout persisted — which is the state the bug needs. Suspending lets that turn run.
        try await Task.sleep(for: .milliseconds(100))
        window.layoutIfNeeded()
        layout.view.layoutSubtreeIfNeeded()

        layout.revealNavigatorSection(.pages)
        layout.setInspectorVisible(false)
        var workspace = layout.workspaceLayoutSnapshot()
        #expect(workspace.isInspectorCollapsed)
        workspace.navigatorWidth = 330

        // Leave that arrangement: Inspector back, Navigator on Search.
        layout.setInspectorVisible(true)
        layout.revealNavigatorSection(.search)
        #expect(layout.isVisible(.inspector))
        layout.applyWorkspaceLayout(workspace)
        #expect(layout.layoutState.isInspectorCollapsed, "the workspace's collapse flag")
        #expect(!layout.isVisible(.inspector))
        #expect(layout.layoutState.navigatorWidth == 330, "the workspace's width, not the live one")
        #expect(layout.panelState.navigatorSection == .pages)
    }

    // MARK: - R-073: the lit Search chip closes Search

    /// Old output: every press of the chip, the workspace chip and the overflow row ran
    /// `perform(.find)`, which only reveals — the second press left Search open.
    @Test("R-073: the Search chip, its toolbar item and its overflow row all toggle Search")
    func searchChipToggles() throws {
        let environment = ProjectShellEnvironment.mock()
        let (layout, window) = iter1Window(environment: environment, key: "it1.searchchip")
        defer { window.close() }
        let builder = layout.toolbarBuilder
        if environment.isPanelOpen(.find) { environment.toolbar.run(.find) }
        #expect(!environment.isPanelOpen(.find))

        let item = try #require(builder.toolbar(NSToolbar(identifier: "it1"), itemForItemIdentifier: .zenitSearch, willBeInsertedIntoToolbar: true))
        let hosting = try #require(item.view as? NSHostingView<ZenitToolChip>)
        hosting.rootView.action()
        #expect(environment.isPanelOpen(.find))
        hosting.rootView.action()
        #expect(!environment.isPanelOpen(.find), "the lit chip is the way back")

        let menuForm = try #require(item.menuFormRepresentation)
        let target = try #require(menuForm.target as? NSObject)
        let action = try #require(menuForm.action)
        target.perform(action, with: menuForm)
        #expect(environment.isPanelOpen(.find))
        target.perform(action, with: menuForm)
        #expect(!environment.isPanelOpen(.find))
    }

    // MARK: - R-075: Navigator set facts are observable

    /// Old output: the tracker never fired — the three were plain stored properties on the
    /// non-observable environment, so the Restore list and the "No scale" badges went stale.
    @Test("R-075: writing removed sheets, unscaled pages or the revision flag re-renders readers")
    func navigatorSetFactsAreObserved() {
        let environment = ProjectShellEnvironment.mock()
        let writes: [(String, @MainActor () -> Void)] = [
            ("removedSheets", { environment.removedSheets = [NavigatorRemovedSheet(id: UUID(), title: "A-102")] }),
            ("unscaledPageIDs", { environment.unscaledPageIDs = [UUID()] }),
            ("hasPreviousRevision", { environment.hasPreviousRevision = true }),
            // S-049 (iteration 2): the refined bookmarks the app writes after an await.
            ("navigatorBookmarks", {
                environment.navigatorBookmarks = [NavigatorBookmark(id: "1", title: "Site Plan", pageID: nil)]
            })
        ]
        for (name, write) in writes {
            let changed = DispatchSemaphore(value: 0)
            withObservationTracking {
                _ = environment.removedSheets
                _ = environment.unscaledPageIDs
                _ = environment.hasPreviousRevision
                _ = environment.navigatorBookmarks
            } onChange: {
                changed.signal()
            }
            write()
            #expect(fired(changed), "\(name) did not reach its reader")
        }
    }

    // MARK: - R-076 / R-097: thumbnails

    /// Old output: `cachedCount == 0` — the second request returned at the stale in-flight entry
    /// and the old render was discarded by its generation check.
    @Test("R-076: a request made after invalidate() while the old render runs still fills")
    func requestAfterInvalidateFills() async throws {
        let loader = NavigatorThumbnailLoader()
        let page = UUID()
        var calls = 0
        var parked: CheckedContinuation<Void, Never>?
        loader.provider = { _, _ in
            calls += 1
            if calls == 1 {
                await withCheckedContinuation { parked = $0 }
            }
            return iter1Image()
        }
        let first = Task { @MainActor in await loader.request(pageID: page, pageIndex: 0) }
        for _ in 0..<200 where parked == nil { await Task.yield() }
        try #require(parked != nil, "the first render is in flight")

        loader.invalidate()
        await loader.request(pageID: page, pageIndex: 0)
        #expect(calls == 2, "the re-keyed row asked again")
        #expect(loader.cachedCount == 1)
        #expect(loader.image(for: page) != nil)

        parked?.resume()
        await first.value
        #expect(loader.image(for: page) != nil, "the stale render neither filled nor cleared the row")
    }

    /// Old output: `cachedBytes` counted only the source (40 × 20 × 4 = 3 200 bytes) and the
    /// turned copy (20 × 40 × 4 = 3 200 bytes) survived its source's eviction.
    @Test("R-097: derived thumbnails count against the budget and leave with their source")
    func derivedThumbnailsAreBudgeted() async throws {
        let loader = NavigatorThumbnailLoader(capacity: 1)
        loader.provider = { _, _ in iter1Image() }
        let first = UUID(), second = UUID()
        await loader.request(pageID: first, pageIndex: 0)
        let turned = PageDescriptor(
            id: first, index: 0, label: "1",
            mediaBox: PDFRectValue(x: 0, y: 0, width: 400, height: 200),
            cropBox: PDFRectValue(x: 0, y: 0, width: 400, height: 200),
            rotation: .degrees0, viewRotation: 90
        )
        let derived = try #require(loader.image(for: turned))
        #expect(derived.width == 20 && derived.height == 40)
        let source = 40 * 20 * 4
        #expect(loader.derivedCount == 1)
        #expect(loader.cachedBytes >= source + derived.bytesPerRow * derived.height)
        #expect(loader.derivedBytes == derived.bytesPerRow * derived.height)

        // A second page evicts the first render (capacity 1): its turned copy goes with it.
        await loader.request(pageID: second, pageIndex: 1)
        #expect(loader.image(for: first) == nil)
        #expect(loader.derivedCount == 0)
        #expect(loader.cachedBytes == iter1Image().bytesPerRow * 20)
    }

    // MARK: - R-077: ledger chips always narrow

    /// Old output: under a "Match any" root the Status chip rule was OR-ed in beside the person's
    /// rule — more rows — `isStatusChipActive` stayed false and a second click re-added it.
    @Test("R-077: a chip under a Match-any or negated filter narrows, and a second click restores")
    func chipsNarrowUnderAnyRoots() throws {
        let userRule = LedgerFilterRule(id: UUID(), column: .label, comparison: .contains, operand: .text("Wall"))
        for root in [
            LedgerFilterGroup(id: UUID(), conjunction: .any, rules: [userRule]),
            LedgerFilterGroup(id: UUID(), conjunction: .all, rules: [userRule], isNegated: true)
        ] {
            let chip = LedgerFilterRule(id: UUID(), column: .status, comparison: .isAnyOf, operand: .choices(["Open"]))
            let placed = LedgerPaneModel.placingChipRule(chip, in: root) { $0.column == .status && $0.comparison == .isAnyOf }
            #expect(placed.conjunction == .all && !placed.isNegated, "the chip sits in a Match-all wrapper")
            #expect(placed.rules == [chip])
            #expect(placed.groups == [root], "the person's own filter is untouched inside it")
            let removed = LedgerPaneModel.placingChipRule(nil, in: placed) { $0.column == .status && $0.comparison == .isAnyOf }
            #expect(removed == root, "the last chip off gives the person's filter back exactly")
        }
    }

    @Test("R-077: the pane's status and kind chips turn on and off under a Match-any filter")
    func paneChipsToggleUnderAny() throws {
        let (defaults, name) = try ShellScratchDefaults.make(prefix: "zenit.test.it1chips")
        defer { ShellScratchDefaults.discard(defaults, suiteName: name) }
        let environment = ProjectShellEnvironment.mock()
        let presenter = try #require(environment.ledger as? MockLedgerPresenter)
        let model = LedgerPaneModel(presenter: presenter, preferences: LedgerPanePreferences(defaults: defaults))
        let chip = try #require(model.statusCounts.first)
        let all = presenter.unfilteredRowCount
        let userRule = LedgerFilterRule(id: UUID(), column: .label, comparison: .isNotEmpty, operand: .none)
        let root = LedgerFilterGroup(id: UUID(), conjunction: .any, rules: [userRule])
        model.setFilter(root)
        let before = model.matchCount

        model.toggleStatusChip(chip.value)
        #expect(model.isStatusChipActive(chip.value))
        #expect(model.matchCount <= before, "a chip narrows")
        #expect(model.matchCount <= chip.count)
        model.toggleStatusChip(chip.value)
        #expect(!model.isStatusChipActive(chip.value))
        #expect(model.filter == root)

        model.toggleKindChip(.areas)
        #expect(model.activeKindChip == .areas)
        model.toggleKindChip(.areas)
        #expect(model.activeKindChip == nil)
        #expect(model.filter == root)
        #expect(model.matchCount == before && before <= all)
    }

    // MARK: - R-078: reveals turn the page through pageDidChange

    /// Old output: the Scale Regions draft drawn on the old sheet survived the reveal — the
    /// canvas turned the page, and nothing told the page-scoped panels.
    @Test("R-078: History, the Review List, the ledger row menu and the warning tray follow the page")
    func revealsRefreshPageScopedPanels() throws {
        let mocks = MockPresenters.makeEnvironment()
        let canvas = PagingCanvas(base: mocks.canvas, document: mocks.document)
        let environment = ProjectShellEnvironment(
            document: mocks.document, canvas: canvas, ledger: mocks.ledger, toolLibrary: mocks.toolLibrary,
            search: mocks.search, compare: mocks.compare, measurement: mocks.measurement, status: mocks.status
        )
        // The canvas's boundary tool, as the application wires it (ScaleRegionPageTurnTests).
        environment.scaleRegions.onBeginPolygon = {}
        environment.scaleRegions.onCancelPolygonDrawing = {}
        let pages = environment.document.pages
        try #require(pages.count >= 2)
        let (defaults, name) = try ShellScratchDefaults.make(prefix: "zenit.test.it1reveal")
        defer { ShellScratchDefaults.discard(defaults, suiteName: name) }
        let ledger = LedgerPaneModel(presenter: try #require(environment.ledger as? MockLedgerPresenter), preferences: LedgerPanePreferences(defaults: defaults))

        let reveals: [(String, @MainActor (UUID) -> Void)] = [
            ("environment", { environment.reveal(markupID: $0) }),
            ("History", { HistoryPaneContent.reveal(markupID: $0, environment: environment) }),
            ("Review List", { ReviewListPane(environment: environment).reveal($0) }),
            ("ledger row menu", { ledger.performRowMenuAction(.zoomTo, rows: [$0], environment: environment, explain: nil) }),
            ("warning tray", { id in
                WarningTrayView.show(
                    AppWarning(id: UUID(), severity: .warning, title: "Stale", message: "Check", source: "Test",
                               timestamp: Date(timeIntervalSince1970: 0), relatedMarkupID: id),
                    environment: environment
                )
            })
        ]
        for (label, reveal) in reveals {
            environment.goToPage(index: 0)
            let here = try #require(environment.document.currentPage)
            let there = try #require(pages.first { $0.id != here.id })
            #expect(environment.scaleRegions.beginRegion())
            #expect(environment.scaleRegions.completePolygon(
                [PDFPointValue(x: 100, y: 100), PDFPointValue(x: 400, y: 100), PDFPointValue(x: 400, y: 400)],
                pageID: here.id, pageLabel: here.label
            ))
            #expect(environment.scaleRegions.draft != nil)
            let markup = UUID()
            canvas.markupPages[markup] = there.id
            reveal(markup)
            #expect(environment.document.currentPageID == there.id, "\(label) turned the page")
            #expect(environment.scaleRegions.draft == nil, "\(label): the panel followed the page")
            environment.scaleRegions.cancelRegionCreation()
        }
    }

    // MARK: - R-079: the bars skip unchanged content

    /// Old behaviour: both bars read the whole snapshot, so a publish that changed only the zoom
    /// (every scroll and zoom frame) rebuilt the strip's five arrangements, and one that changed
    /// only a snap toggle or the pointer rebuilt the canvas bar's four.
    @Test("R-079: the strip ignores the zoom and page, the canvas bar everything but page and zoom")
    func barsSkipContentTheyDoNotShow() {
        let environment = ProjectShellEnvironment.mock()
        let base = environment.status.snapshot
        var zoomed = base
        zoomed.zoomDisplayString = "412%"
        zoomed.pageLabel = "S-201"
        zoomed.pageIndex = base.pageIndex + 1
        #expect(StatusBarView.shownSnapshot(zoomed) == StatusBarView.shownSnapshot(base))
        #expect(StatusStripRows(environment: environment, snapshot: StatusBarView.shownSnapshot(zoomed))
            == StatusStripRows(environment: environment, snapshot: StatusBarView.shownSnapshot(base)))
        var snapped = base
        snapped.gridSnapEnabled.toggle()
        #expect(StatusBarView.shownSnapshot(snapped) != StatusBarView.shownSnapshot(base), "the strip shows its toggles")

        var pointer = base
        pointer.cursorDisplayText = "(12.00, 4.00)"
        pointer.gridSnapEnabled.toggle()
        pointer.activeToolNote = "Click to place"
        #expect(CanvasTopBar.shownSnapshot(pointer) == CanvasTopBar.shownSnapshot(base))
        #expect(CanvasTopBarRows(environment: environment, undoState: nil, snapshot: CanvasTopBar.shownSnapshot(pointer))
            == CanvasTopBarRows(environment: environment, undoState: nil, snapshot: CanvasTopBar.shownSnapshot(base)))
        #expect(CanvasTopBar.shownSnapshot(zoomed) != CanvasTopBar.shownSnapshot(base), "the bar shows page and zoom")
        #expect(StatusBarDisplay.hasDocument(StatusBarView.shownSnapshot(base)) == StatusBarDisplay.hasDocument(base))
    }

    // MARK: - R-080: one commit per edit

    /// Old output: Return then blur committed "Beam" twice; the second, identical request changed
    /// nothing and raised "The change was not saved".
    @Test("R-080: a text row commits an edit once, and a re-seeded value is not an edit")
    func textRowCommitsOnce() {
        var gate = InspectorCommitGate()
        gate.reseed("Wall")
        let untouched = gate.commit("Wall")
        #expect(!untouched, "untouched text is not an edit")
        let onReturn = gate.commit("Beam")
        #expect(onReturn, "Return")
        let onBlur = gate.commit("Beam")
        #expect(!onBlur, "the blur that follows before the refresh lands")
        gate.reseed("Column")
        let reseeded = gate.commit("Column")
        #expect(!reseeded)
        let next = gate.commit("Beam")
        #expect(next)
    }

    // MARK: - R-081: Shapes memory persists

    /// Old output: `lastUsedShapeKind` came back `.rectangle` after a relaunch — the layout state
    /// had no field for it and init used the two-argument restore.
    @Test("R-081: the Shapes palette's last shape is stored, restored and old layouts still load")
    func shapesMemoryPersists() throws {
        let defaults = ZPDFInMemoryDefaults()
        let store = ProjectWindowLayoutStore(defaults: defaults, key: "it1.shapes")
        var stored = ProjectWindowLayoutState()
        stored.lastUsedShapeKind = .cloud
        store.save(stored)

        let environment = ProjectShellEnvironment.mock()
        let layout = ProjectWindowLayoutController(environment: environment, store: store)
        #expect(environment.toolbar.lastUsedShapeKind == .cloud)
        _ = layout.view
        environment.toolbar.activateShape(.ellipse)
        layout.captureLayoutState()
        #expect(layout.layoutState.lastUsedShapeKind == .ellipse)
        // A workspace carries no tool memory.
        let model = WorkspacesModel(store: ZenitWorkspaceStore(defaults: ZPDFInMemoryDefaults()))
        #expect(try #require(model.save(name: "Review", layout: layout.layoutState)).layout.lastUsedShapeKind == nil)

        // A blob written before the field existed decodes, with no shape.
        let data = try JSONEncoder().encode(ProjectWindowLayoutState())
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "lastUsedShapeKind")
        let old = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(ProjectWindowLayoutState.self, from: old)
        #expect(decoded.lastUsedShapeKind == nil)
        #expect(decoded.navigatorWidth == ProjectWindowLayoutState().navigatorWidth)
    }

    // MARK: - R-082: cached timestamp formatters

    @Test("R-082: the Inspector's timestamps reuse one formatter pair per locale and zone")
    func timestampFormattersAreCached() {
        let en = Locale(identifier: "en_US"), utc = TimeZone(identifier: "UTC")!
        let first = InspectorMarkupFormatting.timestampFormatters(locale: en, timeZone: utc)
        let again = InspectorMarkupFormatting.timestampFormatters(locale: en, timeZone: utc)
        #expect(first.day === again.day && first.clock === again.clock)
        let swedish = InspectorMarkupFormatting.timestampFormatters(locale: Locale(identifier: "sv_SE"), timeZone: utc)
        #expect(swedish.day !== first.day, "another locale builds its own pair")
        let parts = InspectorMarkupFormatting.dateAndTime(Date(timeIntervalSince1970: 0), locale: en, timeZone: utc)
        #expect(parts.date == "Jan 1, 1970")
        #expect(parts.time.hasPrefix("12:00"))
    }

    // MARK: - R-083: typography

    @Test("R-083: the type scale is read once and clamped")
    func typeScaleIsCachedAndClamped() {
        #expect(ZPDFTypography.scale(forPreferredBodySize: 13) == 1)
        #expect(ZPDFTypography.scale(forPreferredBodySize: 6) == 0.85)
        #expect(ZPDFTypography.scale(forPreferredBodySize: 60) == 2)
        #expect(ZPDFTypography.scale(forPreferredBodySize: 0) == 1)
        #expect(ZPDFTypography.dynamicTypeScale == ZPDFTypography.dynamicTypeScale)
        #expect(ZPDFTypography.scaledSize(ZPDFTypography.body) == (13 * ZPDFTypography.dynamicTypeScale).rounded())
    }

    // MARK: - R-084: one style-edit path

    /// Old output: the strip clamped opacity at 5 % and the Inspector at 0 %, through two copies
    /// of the same apply.
    @Test("R-084: the style strip and the Inspector send the same bulk edit through one path")
    func styleSurfacesShareOnePath() async throws {
        let environment = ProjectShellEnvironment.mock()
        let presenter = try #require(environment.ledger as? MockLedgerPresenter)
        let markups = Array(ZenitSampleProject.shared.markups.filter { !$0.locked }.prefix(2))
        let summary = InspectorSelectionSummary(markups: markups)
        let edit = MarkupStyleEdit(opacity: 0.5)
        let before = presenter.appliedBulkEdits.count

        MarkupStyleStrip(environment: environment).apply(edit, to: summary)
        InspectorPanel(environment: environment, panelState: ShellPanelState()).applyStyle(edit, to: summary)
        for _ in 0..<200 where presenter.appliedBulkEdits.count < before + 2 { await Task.yield() }
        let sent = presenter.appliedBulkEdits.suffix(2)
        try #require(sent.count == 2)
        #expect(sent.first?.style == edit && sent.last?.style == edit)
        #expect(sent.first?.markupIDs == sent.last?.markupIDs)
        #expect(InspectorStyleEditing.markupOpacityPercentRange == 5...100)
        #expect(InspectorStyleEditing.fillOpacityPercentRange == 0...100)
    }

    // MARK: - R-088: the divider is the gutter

    @Test("R-088: the chrome split's divider is the window gutter, a constant")
    func chromeSplitDividerIsTheGutter() {
        let split = ZPDFChromeSplitView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        #expect(split.dividerThickness == ZPDFWindowChrome.gutter)
    }

    // MARK: - R-091: one sheet identity rule

    @Test("R-091: the name editor's prefill and the sheet index's row split a sheet the same way")
    func sheetIdentitySplitIsShared() throws {
        let box = PDFRectValue(x: 0, y: 0, width: 100, height: 100)
        let named = PageDescriptor(
            id: UUID(), index: 4, label: "5", mediaBox: box, cropBox: box, rotation: .degrees0,
            sheetTitle: "A-101 · Ground Floor Plan", sheetNumber: "A-101", hasSheetIdentity: true
        )
        let split = try #require(NavigatorSheetNameEditor.splitSheetIdentity(named))
        #expect(split.number == "A-101" && split.title == "Ground Floor Plan")
        #expect(NavigatorSheetNameEditor.seed(for: named) == split)
        let row = NavigatorSheetIndex.row(for: named, position: 0)
        #expect(row.number == split.number && row.title == split.title)
        let repeated = PageDescriptor(
            id: UUID(), index: 0, label: "1", mediaBox: box, cropBox: box, rotation: .degrees0,
            sheetTitle: "S-201", sheetNumber: "S-201", hasSheetIdentity: true
        )
        #expect(NavigatorSheetNameEditor.splitSheetIdentity(repeated)?.title == "")
        let unnamed = PageDescriptor(id: UUID(), index: 0, label: "1", mediaBox: box, cropBox: box, rotation: .degrees0)
        #expect(NavigatorSheetNameEditor.splitSheetIdentity(unnamed) == nil)
    }

    // MARK: - R-093: the menu button's number is the card's

    /// Old output: "Page 5 options" on the first card of a reordered set — the PDF index.
    @Test("R-093: a page card's ⋯ button is announced with the card's set position")
    func pageMenuLabelUsesThePosition() {
        let box = PDFRectValue(x: 0, y: 0, width: 100, height: 100)
        let page = PageDescriptor(id: UUID(), index: 4, label: "5", mediaBox: box, cropBox: box, rotation: .degrees0)
        #expect(NavigatorPageAction.menuLabel(for: page, position: 0) == "Page 1 options")
        #expect(NavigatorPageAction.menuLabel(for: page, position: 0) == "Page \(NavigatorPageCard.title(for: page, position: 0)) options")
        #expect(NavigatorPageAction.menuLabel(for: page) == "Page 5 options", "no position known: the PDF index")
    }

    // MARK: - R-094: derivation field names

    /// Old output: "Plan area" — a camel-case split, English only, in another case than the rows.
    @Test("R-094: derivation rows use the quantity rows' field names")
    func derivationFieldNamesMatchRows() {
        #expect(InspectorDerivationSection.valueField(of: "value.planArea.si") == MeasurementField.planArea.displayName)
        #expect(InspectorDerivationSection.valueField(of: "value.trueLength.display") == MeasurementField.trueLength.displayName)
        #expect(InspectorDerivationSection.valueField(of: "value.netWallArea.si") == "Net Wall Area")
        #expect(InspectorDerivationSection.valueField(of: "value.truePerimeter.si") == "True Perimeter")
        #expect(InspectorDerivationSection.valueField(of: "value.someNewField.si") == "Some new field", "unknown keys still read")
    }

    // MARK: - R-095: Escape on the Zones page

    /// Old output: the Navigator stayed open — the panel's own Escape handler ended in
    /// `onClose?()`, which the Navigator never set.
    @Test("R-095: an idle Escape on the Zones page hides the Navigator, as on every other page")
    func zonesEscapeBacksOut() {
        let environment = ProjectShellEnvironment.mock()
        let (layout, window) = iter1Window(environment: environment, key: "it1.zones")
        defer { window.close() }
        layout.setNavigatorVisible(true)
        layout.revealNavigatorSection(.zones)
        #expect(layout.isVisible(.navigator))
        NavigatorZonesList.panel(environment: environment).handleExitCommand()
        #expect(!layout.isVisible(.navigator))

        // Mid-draft, Escape still cancels the draft first and leaves the Navigator alone.
        layout.setNavigatorVisible(true)
        environment.projectZones.beginZone()
        #expect(environment.projectZones.draft != nil || environment.projectZones.isAwaitingBoundary)
        NavigatorZonesList.panel(environment: environment).handleExitCommand()
        #expect(layout.isVisible(.navigator))
    }

    // MARK: - R-096: History does not follow the selection while it is off

    /// Old output: the tracker fired — the pane's body computed the toggle's disabled state from
    /// the canvas selection, so every canvas click re-ran it and re-diffed the trail.
    @Test("R-096: with Selected Markup off, a canvas click does not touch the History pane's body")
    func historyBodyIgnoresSelectionWhenOff() throws {
        let environment = ProjectShellEnvironment.mock()
        try #require(environment.ledger is any LedgerAuditPresenting, "the pane renders its trail, not the empty state")
        let pane = HistoryPaneContent(environment: environment)
        let changed = DispatchSemaphore(value: 0)
        withObservationTracking {
            _ = pane.body
        } onChange: {
            changed.signal()
        }
        let markup = try #require(ZenitSampleProject.shared.markups.first)
        environment.canvas.select(markupIDs: [markup.id], additive: false)
        #expect(!fired(changed), "a canvas click invalidated the History body")

        // The toggle itself still follows the selection.
        let toggleChanged = DispatchSemaphore(value: 0)
        let toggle = HistorySelectionFilterToggle(environment: environment, followsSelection: .constant(false))
        withObservationTracking {
            _ = toggle.body
        } onChange: {
            toggleChanged.signal()
        }
        environment.canvas.clearSelection()
        #expect(fired(toggleChanged))
    }
}
