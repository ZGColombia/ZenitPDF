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

// Regression tests for the quality loop's iteration-2 "uishell" list.
// Every test names its item and
// states what the old code produced. Windows are built off screen and never ordered in.

// MARK: - Fixtures

/// A layout controller in a window that is laid out but never shown.
@MainActor
private func iter2Window(
    environment: ProjectShellEnvironment,
    key: String,
    store: ProjectWindowLayoutStore? = nil
) -> (ProjectWindowLayoutController, NSWindow) {
    let layout = ProjectWindowLayoutController(
        environment: environment,
        store: store ?? ProjectWindowLayoutStore(defaults: ZPDFInMemoryDefaults(), key: key)
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
private func iter2Markup(
    kind: MarkupKind = .rectangle,
    fill: ColorRGBA? = nil,
    on page: PageDescriptor? = nil
) -> MarkupSummary {
    MarkupSummary(
        id: UUID(),
        kind: kind,
        subject: "Note",
        label: "",
        pageLabel: page?.label ?? "1",
        pageID: page?.id ?? UUID(),
        pageIndex: page?.index ?? 0,
        author: "Test",
        colorRGBA: ColorRGBA(red: 0.8, green: 0.1, blue: 0.1, alpha: 1),
        created: Date(timeIntervalSince1970: 0),
        modified: Date(timeIntervalSince1970: 0),
        boundsInPageSpace: PDFRectValue(x: 0, y: 0, width: 10, height: 10),
        fillRGBA: fill
    )
}

private func iter2Page(
    index: Int,
    label: String,
    sheetNumber: String? = nil,
    sheetTitle: String? = nil
) -> PageDescriptor {
    let box = PDFRectValue(x: 0, y: 0, width: 400, height: 300)
    return PageDescriptor(
        id: UUID(), index: index, label: label, mediaBox: box, cropBox: box, rotation: .degrees0,
        sheetTitle: sheetTitle, sheetNumber: sheetNumber, hasSheetIdentity: sheetNumber != nil
    )
}

private func iter2Image(width: Int, height: Int) -> CGImage {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    )!
    context.setFillColor(CGColor(red: 0, green: 0.4, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

/// Runs the main run loop in its default mode for a moment — where a default-mode perform
/// fires once event tracking is over. Synchronous, because `RunLoop.run` is not available from
/// an async context.
@MainActor
private func iter2SpinDefaultRunLoop(seconds: TimeInterval) {
    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(seconds))
}

/// A defaults store that counts its writes.
private final class Iter2CountingDefaults: ZPDFDefaultsStoring {
    private var storage: [String: Data] = [:]
    private(set) var writes = 0

    func persistedData(forKey key: String) -> Data? { storage[key] }

    func setPersistedData(_ data: Data?, forKey key: String) {
        writes += 1
        storage[key] = data
    }
}

@MainActor
@Suite("Iteration 2 — uishell fixes", .shellTierSerialised)
struct Iter2UIShellFixTests {

    // MARK: - C-05: the ledger outline's own choices are reachable

    /// Old output: `host.rounding` stayed `.exact` (the controller's default) after the pane was
    /// built with three decimals and after `setSubtotalRounding(.oneDigit)` — the model wrote
    /// the controller directly, so the chips' rounding mirror never moved. Expand All, Collapse
    /// All and Show Group Subtotals had no caller at all.
    @Test("C-05: rounding goes through the host; expand, collapse and subtotals are wired and remembered")
    func ledgerOutlineChoicesAreReachable() throws {
        let (defaults, name) = try ShellScratchDefaults.make(prefix: "zenit.test.it2outline")
        defer { ShellScratchDefaults.discard(defaults, suiteName: name) }
        let preferences = LedgerPanePreferences(defaults: defaults)
        let model = LedgerPaneModel(presenter: MockLedgerPresenter(), preferences: preferences, subtotalRounding: .threeDigits)
        #expect(model.host.rounding == .threeDigits)
        model.setSubtotalRounding(.oneDigit)
        #expect(model.host.rounding == .oneDigit)
        #expect(model.host.controller.rounding == .oneDigit)

        #expect(model.showsSubtotals)
        model.setShowsSubtotals(false)
        #expect(!model.host.showsSubtotals && !model.host.controller.showsSubtotals)
        let reopened = LedgerPaneModel(presenter: MockLedgerPresenter(), preferences: LedgerPanePreferences(defaults: defaults))
        #expect(!reopened.showsSubtotals, "the choice survives a relaunch")

        try #require(!model.groupingColumns.isEmpty, "the pane opens grouped")
        // Loaded, never shown: the table builds its plan only with its view.
        model.host.controller.loadViewIfNeeded()
        model.refresh()
        let paths = model.host.controller.plan.allPaths
        try #require(!paths.isEmpty)
        model.collapseAllGroups()
        #expect(model.host.controller.collapsedGroupPaths == paths)
        #expect(preferences.collapsedGroupPaths == paths, "the collapsed set is persisted")
        model.expandAllGroups()
        #expect(model.host.controller.collapsedGroupPaths.isEmpty)
        #expect(preferences.collapsedGroupPaths.isEmpty)
    }

    // MARK: - S-043: a chip's count, total and click agree

    /// Old output: `Lengths 3` beside a total of four rows — `.arcLength` was not a length kind —
    /// and a click that showed four rows.
    @Test("S-043: the chip's count is the rows in its total, from the totals' own counts")
    func chipCountIsTheRowsInItsTotal() throws {
        let totals = LedgerTotals(
            rowCount: 5,
            quantities: [.planLength: DecimalQuantity(value: 12, dimension: .length)],
            displayValues: [.planLength: "12 m"],
            valueCounts: [.planLength: 4, .planArea: 0]
        )
        let kinds: [MeasurementKind: Int] = [.length: 3, .arcLength: 1, .perimeter: 1]
        let summary = LedgerSummary(totals: totals, rowCount: 5, kindCounts: kinds)
        #expect(summary.chip(.lengths)?.rowCount == 4)
        #expect(summary.chip(.lengths)?.badge == "4")
        #expect(summary.chip(.areas)?.rowCount == 0, "no row filled Plan Area")
        // A presenter whose totals do not count falls back to kinds — Arc Length included.
        let uncounted = LedgerSummary(
            totals: LedgerTotals(rowCount: 5, quantities: totals.quantities, displayValues: totals.displayValues),
            rowCount: 5, kindCounts: kinds
        )
        #expect(uncounted.chip(.lengths)?.rowCount == 4)
    }

    @Test("S-043: over the mock presenter each chip's count equals the rows its click shows")
    func chipCountMatchesItsFilter() throws {
        let (defaults, name) = try ShellScratchDefaults.make(prefix: "zenit.test.it2chips")
        defer { ShellScratchDefaults.discard(defaults, suiteName: name) }
        let presenter = MockLedgerPresenter()
        let model = LedgerPaneModel(presenter: presenter, preferences: LedgerPanePreferences(defaults: defaults))
        let summary = LedgerSummary(
            totals: presenter.grandTotals,
            rowCount: presenter.rowCount,
            kindCounts: presenter.rowCountsByMeasurementKind
        )
        var checked = 0
        for kind in [LedgerSummary.Kind.areas, .lengths, .counts] {
            guard let count = summary.chip(kind)?.rowCount, count > 0 else { continue }
            model.toggleKindChip(kind)
            #expect(model.activeKindChip == kind)
            #expect(model.matchCount == count, "\(kind): the chip says \(count), its click shows \(model.matchCount)")
            model.toggleKindChip(kind)
            checked += 1
        }
        #expect(checked > 0, "the sample has measured rows")
    }

    // MARK: - S-044: turned thumbnails keep their own budget

    /// Old output: `derivedCount == 1` — with the renders at the shared budget, each turned copy
    /// evicted the one before, and every body pass re-derived the rows on screen.
    @Test("S-044: three turned pages stay cached with the render cache full")
    func turnedThumbnailsSurviveAFullCache() async throws {
        let loader = NavigatorThumbnailLoader()
        let sample = iter2Image(width: 480, height: 680)
        loader.setProvider({ _, _ in sample }, identity: "doc")
        var ids: [UUID] = []
        for index in 0..<30 {
            let id = UUID()
            ids.append(id)
            await loader.request(pageID: id, pageIndex: index)
        }
        let perImage = NavigatorThumbnailLoader.byteCost(of: sample)
        #expect(loader.cachedCount < 30, "the renders reached their budget")
        #expect(loader.cachedBytes <= loader.byteBudget)
        let turned = ids.suffix(3).map { id in
            PageDescriptor(
                id: id, index: 0, label: "1",
                mediaBox: PDFRectValue(x: 0, y: 0, width: 480, height: 680),
                cropBox: PDFRectValue(x: 0, y: 0, width: 480, height: 680),
                rotation: .degrees0, viewRotation: 90
            )
        }
        let first = turned.compactMap { loader.image(for: $0) }
        try #require(first.count == 3)
        #expect(loader.derivedCount == 3)
        #expect(loader.derivedBytes == 3 * perImage)
        // A second body pass reads the cached copies — the same bitmaps, nothing re-derived.
        for (page, image) in zip(turned, first) {
            #expect(loader.image(for: page) === image)
        }
        #expect(loader.derivedBytes <= loader.derivedByteBudget)
        #expect(loader.cachedBytes <= loader.byteBudget + loader.derivedByteBudget)
    }

    // MARK: - S-045: Zoom to Selection turns to the selection's sheet

    /// Old output: `currentPageID` stayed on the first sheet and the app was asked to fit a
    /// selection its canvas did not hold — nothing happened.
    @Test("S-045: Zoom to Selection from the ledger and the Inspector turns to the rows' sheet")
    func zoomToSelectionTurnsToTheSheet() throws {
        let mocks = MockPresenters.makeEnvironment()
        let environment = ProjectShellEnvironment(
            document: mocks.document, canvas: mocks.canvas, ledger: mocks.ledger, toolLibrary: mocks.toolLibrary,
            search: mocks.search, compare: mocks.compare, measurement: mocks.measurement, status: mocks.status
        )
        var forwarded: [ZPDFCommandID] = []
        environment.externalCommandHandler = { forwarded.append($0) }
        let byPage = Dictionary(grouping: mocks.canvas.allMarkups, by: \.pageID)
        let pages = environment.document.pages
        environment.goToPage(index: 0)
        let home = try #require(environment.document.currentPageID)
        let others = pages.map(\.id).filter { $0 != home && (byPage[$0]?.count ?? 0) >= 1 }
        let there = try #require(others.first, "the sample has markups on a second sheet")
        let rows = Set(try #require(byPage[there]).map(\.id))

        // The Inspector's route: the command.
        mocks.canvas.select(markupIDs: rows, additive: false)
        environment.perform(.zoomToSelection)
        #expect(environment.document.currentPageID == there)
        #expect(forwarded == [.zoomToSelection])

        // The ledger's multi-row Zoom To.
        environment.goToPage(index: 0)
        let (defaults, name) = try ShellScratchDefaults.make(prefix: "zenit.test.it2zoom")
        defer { ShellScratchDefaults.discard(defaults, suiteName: name) }
        let ledger = LedgerPaneModel(presenter: try #require(mocks.ledger as? MockLedgerPresenter), preferences: LedgerPanePreferences(defaults: defaults))
        let two = Set(try #require(byPage[there]).prefix(2).map(\.id))
        ledger.performRowMenuAction(.zoomTo, rows: two.count > 1 ? two : rows, environment: environment, explain: nil)
        #expect(environment.document.currentPageID == there)

        // On the sheet already: fitted where it is, no turn.
        forwarded = []
        environment.perform(.zoomToSelection)
        #expect(environment.document.currentPageID == there)
        #expect(forwarded == [.zoomToSelection])
    }

    @Test("S-045: a selection over several sheets fits on the sheet on screen, else the first; the help says so")
    func zoomToSelectionOverSeveralSheets() throws {
        let environment = ProjectShellEnvironment.mock()
        let pages = environment.document.pages
        try #require(pages.count >= 3)
        environment.goToPage(index: 0)
        let a = iter2Markup(on: pages[1]), b = iter2Markup(on: pages[2])
        #expect(environment.selectionPlacement(of: [a, b]) == .severalSheets(count: 2, target: pages[1].id))
        #expect(environment.selectionPlacement(of: [b]) == .otherSheet(pages[2].id))
        #expect(environment.selectionPlacement(of: []) == .none)
        let help = InspectorPanel.zoomToSelectionHelp(InspectorSelectionSummary(markups: [a, b]), environment: environment)
        #expect(help.contains("2 sheets"), "\(help)")
        environment.goToPage(index: 2)
        #expect(environment.selectionPlacement(of: [a, b]) == .severalSheets(count: 2, target: pages[2].id))
        #expect(environment.selectionPlacement(of: [b]) == .currentSheet)
        let here = InspectorPanel.zoomToSelectionHelp(InspectorSelectionSummary(markups: [a, b]), environment: environment)
        #expect(here.contains("this sheet"), "\(here)")
    }

    // MARK: - S-046: an asynchronous page turn still refreshes the page-scoped panels

    /// Old output: `scaleRegions.draft != nil` — a turn that landed after `turningPage` returned
    /// (the search hit whose rectangles resolve later) reached nothing in the shell.
    @Test("S-046: a page turn made straight on the document refreshes the Scale Regions panel")
    func pageTurnsAreFollowed() async throws {
        let environment = ProjectShellEnvironment.mock()
        environment.scaleRegions.onBeginPolygon = {}
        environment.scaleRegions.onCancelPolygonDrawing = {}
        let pages = environment.document.pages
        try #require(pages.count >= 2)
        environment.goToPage(index: 0)
        let here = try #require(environment.document.currentPage)
        #expect(environment.scaleRegions.beginRegion())
        #expect(environment.scaleRegions.completePolygon(
            [PDFPointValue(x: 100, y: 100), PDFPointValue(x: 400, y: 100), PDFPointValue(x: 400, y: 400)],
            pageID: here.id, pageLabel: here.label
        ))
        #expect(environment.scaleRegions.draft != nil)

        // As `AppSearchPresenter.selectHit` does after its bounds lookup: no `turningPage`.
        environment.document.goToPage(id: pages[1].id)
        for _ in 0..<200 where environment.scaleRegions.draft != nil { await Task.yield() }
        #expect(environment.scaleRegions.draft == nil, "the panel followed the page")

        // And again for the next turn: the observer re-arms.
        #expect(environment.scaleRegions.beginRegion())
        #expect(environment.scaleRegions.completePolygon(
            [PDFPointValue(x: 100, y: 100), PDFPointValue(x: 400, y: 100), PDFPointValue(x: 400, y: 400)],
            pageID: pages[1].id, pageLabel: pages[1].label
        ))
        environment.document.goToPage(id: here.id)
        for _ in 0..<200 where environment.scaleRegions.draft != nil { await Task.yield() }
        #expect(environment.scaleRegions.draft == nil)
    }

    // MARK: - S-047: a recalled workspace shows or hides the band

    /// Old output: `isTopBandShown == true` while `layoutState.isTopBandHidden == true` — the
    /// flag was stored and not applied, so the next tab switch or launch flipped the band.
    @Test("S-047: applying a workspace applies its hidden-toolbar flag")
    func workspaceAppliesTheBandFlag() throws {
        let environment = ProjectShellEnvironment.mock()
        let (layout, window) = iter2Window(environment: environment, key: "it2.band")
        defer { window.close() }
        try #require(layout.topBand != nil)
        layout.setTopBandShown(false)
        let hidden = layout.layoutState
        layout.setTopBandShown(true)
        let shown = layout.layoutState
        #expect(layout.isTopBandShown)

        layout.applyWorkspaceLayout(hidden)
        #expect(!layout.isTopBandShown)
        #expect(layout.layoutState.isTopBandHidden == true)
        layout.applyWorkspaceLayout(shown)
        #expect(layout.isTopBandShown)
        #expect(layout.layoutState.isTopBandHidden != true)
    }

    // MARK: - S-048: the page field reaches a sheet by its number as the core compares it

    /// Old output: `nil` for "a102" (the field compared `sheetNumber ?? label` case-insensitively
    /// only, so the entry reverted) and index 1 for a number two sheets share (the first match).
    @Test("S-048: a typed sheet number is normalised, an ambiguous one refused, then label and position")
    func typedSheetNumbers() {
        let pages = [
            iter2Page(index: 0, label: "1", sheetNumber: "A-101"),
            iter2Page(index: 1, label: "2", sheetNumber: "A-102"),
            iter2Page(index: 2, label: "7"),
            iter2Page(index: 3, label: "S-201")
        ]
        #expect(StatusBarDisplay.pageDestination(forTyped: "a102", pages: pages) == 1)
        #expect(StatusBarDisplay.pageDestination(forTyped: "A 101", pages: pages) == 0)
        #expect(StatusBarDisplay.pageDestination(forTyped: "s-201", pages: pages) == 3, "an unnamed sheet by its label")
        #expect(StatusBarDisplay.pageDestination(forTyped: "7", pages: pages) == 2, "a label that is a number")
        #expect(StatusBarDisplay.pageDestination(forTyped: "4", pages: pages) == 3, "then the position")
        #expect(StatusBarDisplay.pageDestination(forTyped: "nowhere", pages: pages) == nil)
        let shared = [iter2Page(index: 0, label: "1", sheetNumber: "A-102"), iter2Page(index: 1, label: "2", sheetNumber: "a102")]
        #expect(StatusBarDisplay.pageDestination(forTyped: "A-102", pages: shared) == nil, "two sheets claim it: go nowhere")
        #expect(PageDescriptor.normalisedSheetNumber("a-1.01 ") == "A1.01")
    }

    // MARK: - S-050: the ledger options menu hides the tab on show

    /// Old output: on History the item ran Toggle Quantity Ledger, which revealed the ledger —
    /// `isSurfaceVisible(.quantityLedger) == true`, the pane still open on its other tab.
    @Test("S-050: 'Hide' on the History tab hides History")
    func hideItemFollowsTheTab() throws {
        #expect(QuantityLedgerPane.hideMenuCommand(for: .history) == .toggleHistory)
        #expect(QuantityLedgerPane.hideMenuCommand(for: .quantities) == .toggleQuantityLedger)
        #expect(QuantityLedgerPane.hideMenuTitle(for: .history) == "Hide History")
        #expect(QuantityLedgerPane.hideMenuTitle(for: .quantities) == "Hide Quantity Ledger")

        let environment = ProjectShellEnvironment.mock()
        let (_, window) = iter2Window(environment: environment, key: "it2.hide")
        defer { window.close() }
        if !environment.isSurfaceVisible(.history) { environment.perform(.toggleHistory) }
        try #require(environment.isSurfaceVisible(.history))
        environment.perform(QuantityLedgerPane.hideMenuCommand(for: .history))
        #expect(!environment.isSurfaceVisible(.history))
        #expect(!environment.isSurfaceVisible(.quantityLedger), "the pane is hidden, not switched to Quantities")
    }

    // MARK: - S-051: No Fill only where there is a fill to remove

    /// Old behaviour: the style strip offered "No Fill" always; over a rectangle with no stored
    /// fill the bulk edit changed nothing.
    @Test("S-051: the strip offers No Fill exactly when the Inspector does")
    func noFillOnlyWithAStoredFill() {
        let tint = ColorRGBA(red: 0, green: 0.5, blue: 0, alpha: 0.2)
        let bare = InspectorSelectionSummary(markups: [iter2Markup(), iter2Markup(kind: .polygon)])
        let filled = InspectorSelectionSummary(markups: [iter2Markup(fill: tint), iter2Markup(kind: .ellipse, fill: tint)])
        let mixed = InspectorSelectionSummary(markups: [iter2Markup(fill: tint), iter2Markup()])
        #expect(!MarkupStyleStrip.offersNoFill(bare))
        #expect(MarkupStyleStrip.offersNoFill(filled))
        #expect(!MarkupStyleStrip.offersNoFill(mixed))
        for summary in [bare, filled, mixed] {
            #expect(MarkupStyleStrip.offersNoFill(summary) == InspectorStyleEditing.canRemoveFill(summary.markups))
        }
    }

    // MARK: - S-052: a switched-off rule lights no chip

    /// Old output: `activeKindChip == .lengths` with the rule switched off, and the next click
    /// removed the rule instead of filtering.
    @Test("S-052: a disabled kind rule does not light its chip; a click then filters")
    func disabledRuleLightsNoChip() throws {
        let (defaults, name) = try ShellScratchDefaults.make(prefix: "zenit.test.it2kind")
        defer { ShellScratchDefaults.discard(defaults, suiteName: name) }
        let presenter = MockLedgerPresenter()
        let model = LedgerPaneModel(presenter: presenter, preferences: LedgerPanePreferences(defaults: defaults))
        let off = LedgerFilterRule(id: UUID(), column: .planLength, comparison: .isNotEmpty, operand: .none, isEnabled: false)
        model.setFilter(LedgerFilterGroup(id: UUID(), conjunction: .all, rules: [off]))
        let all = model.matchCount
        #expect(LedgerPaneModel.kindChip(of: off) == nil)
        #expect(model.activeKindChip == nil)
        model.toggleKindChip(.lengths)
        #expect(model.activeKindChip == .lengths)
        #expect(model.matchCount < all, "the click turned a filter on")
        #expect(model.filter.rules.contains(off), "the person's switched-off rule is left as it was")
    }

    // MARK: - S-053: one person, one set of initials

    /// Old output: the top bar gave "AE" for "a.berg@site.example" and "J" for "john_doe",
    /// the Inspector "AB" and "JD"; the deleted design-system badge gave "JE" for "jd@example.com".
    @Test("S-053: the top bar badge and the Inspector avatar draw the same initials")
    func initialsAgree() {
        let cases: [(String, String)] = [
            ("a.berg@site.example", "AB"), ("john_doe", "JD"), ("John Doe", "JD"), ("Mononym", "M"),
            ("  ana maría de la prueba ", "AP"), ("Doe, John", "DJ"), ("jd@example.com", "J"),
            ("Test-Exempel Person", "TP"), ("(Team) Studio", "S")
        ]
        for (name, expected) in cases {
            #expect(AuthorInitials.initials(for: name, locale: Locale(identifier: "en_US")) == expected, "\(name)")
            #expect(ZenitToolbarModel.initials(for: name) == expected, "top bar: \(name)")
            #expect(InspectorMarkupFormatting.initials(for: name, locale: Locale(identifier: "en_US")) == expected, "Inspector: \(name)")
        }
        #expect(ZenitToolbarModel.initials(for: "123 !!") == "", "the badge draws its person glyph")
        #expect(InspectorMarkupFormatting.initials(for: "123 !!") == "?", "the avatar draws a question mark")
    }

    // MARK: - S-056: one set of style limits

    @Test("S-056: the strip, the Inspector and the tool card share the width and size limits")
    func styleLimitsAreShared() throws {
        #expect(InspectorStyleEditing.lineWidthRange == 0.25...48)
        #expect(InspectorStyleEditing.fontSizeRange == 4...288)
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ZPDFUIShell")
        for file in ["Toolbar/MarkupStyleStrip.swift", "Inspector/InspectorMarkupTab.swift", "Inspector/InspectorToolStyleCard.swift"] {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            #expect(!text.contains("0.25...48"), "\(file) spells the width limit out")
            #expect(!text.contains("4...288"), "\(file) spells the size limit out")
            #expect(text.contains("InspectorStyleEditing.lineWidthRange"), "\(file)")
        }
    }

    // MARK: - S-057: the card menu's label and hint name one sheet one way

    /// Old output: "Page 3 options" with the hint "Actions for page P7".
    @Test("S-057: the page menu's hint names the set position, then the sheet's own number")
    func pageMenuHintUsesThePosition() {
        let plain = iter2Page(index: 6, label: "7")
        #expect(NavigatorPageAction.menuLabel(for: plain, position: 2) == "Page 3 options")
        #expect(NavigatorPageAction.menuHint(for: plain, position: 2) == "Actions for page 3")
        let named = iter2Page(index: 6, label: "7", sheetNumber: "A-101")
        #expect(NavigatorPageAction.menuHint(for: named, position: 2) == "Actions for page 3, A-101")
        let labelled = iter2Page(index: 0, label: "S-201")
        #expect(NavigatorPageAction.menuHint(for: labelled, position: 4) == "Actions for page 5, S-201")
    }

    // MARK: - S-058: palette rows answer to sheet numbers and names

    /// Old output: the row read "Go to 3" with keywords ["3", "3"], so "A-101", "a101" and
    /// "site" found nothing.
    @Test("S-058: a page row is titled and found by its sheet number and name")
    func paletteFindsSheets() {
        let page = iter2Page(index: 2, label: "3", sheetNumber: "A-101", sheetTitle: "SITE PLAN")
        #expect(ProjectShellEnvironment.paletteSheetName(page) == "A-101 · SITE PLAN")
        let keywords = ProjectShellEnvironment.paletteKeywords(forPage: page, position: 2)
        #expect(keywords.contains("A-101") && keywords.contains("A101") && keywords.contains("SITE PLAN"))
        let item = CommandPaletteItem(
            id: "page", title: "Go to " + ProjectShellEnvironment.paletteSheetName(page),
            detail: "Page", category: .page, keywords: keywords, perform: {}
        )
        for query in ["A-101", "a101", "site", "3"] {
            #expect(CommandPaletteModel.score(query: query, item: item) != nil, "\(query)")
        }
        // A sheet whose name already carries its number is not named twice; an unnamed page
        // keeps its label.
        let carried = iter2Page(index: 0, label: "1", sheetNumber: "A-102", sheetTitle: "A-102 Floor Plan")
        #expect(ProjectShellEnvironment.paletteSheetName(carried) == "A-102 Floor Plan")
        #expect(ProjectShellEnvironment.paletteSheetName(iter2Page(index: 0, label: "4")) == "4")
    }

    // MARK: - S-059: a resize writes the layout once, at the end

    /// Old output: one store write per resize step (five here), each posting
    /// `UserDefaults.didChangeNotification`.
    @Test("S-059: a divider drag defers the layout write to its end, and writes it once")
    func dragWritesOnce() async throws {
        let environment = ProjectShellEnvironment.mock()
        let defaults = Iter2CountingDefaults()
        let store = ProjectWindowLayoutStore(defaults: defaults, key: "it2.drag")
        let (layout, window) = iter2Window(environment: environment, key: "it2.drag", store: store)
        defer { window.close() }
        layout.configure(window: window)
        // `configure` settles the launch layout on the next main-queue turn; persistence opens then.
        try await Task.sleep(for: .milliseconds(100))
        window.layoutIfNeeded()
        layout.view.layoutSubtreeIfNeeded()
        layout.setNavigatorVisible(true)
        let split = layout.contentSplitController.splitView

        var dragging = true
        layout.isUserResizing = { dragging }
        let before = defaults.writes
        for position in [260.0, 270, 280, 290, 300] {
            split.setPosition(position, ofDividerAt: 0)
            split.layoutSubtreeIfNeeded()
        }
        #expect(defaults.writes == before, "nothing is written while the divider moves")
        let width = layout.layoutState.navigatorWidth
        #expect(abs(width - 300) < 20, "the in-memory layout follows every step (\(width))")

        dragging = false
        iter2SpinDefaultRunLoop(seconds: 0.1)
        #expect(defaults.writes == before + 1, "one write when the drag is over")
        #expect(store.load().navigatorWidth == width)

        // An unchanged save is not written again.
        layout.persistLayoutState()
        #expect(defaults.writes == before + 1)
    }
}
