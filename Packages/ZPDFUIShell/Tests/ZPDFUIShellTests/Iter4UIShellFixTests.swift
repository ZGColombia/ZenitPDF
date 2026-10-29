import AppKit
import Foundation
import SwiftUI
import Testing
import ZPDFDesignSystem
import ZPDFUIPresentation
@testable import ZPDFUIShell

// Regression tests for the quality loop's iteration-4 "uishell" list.
// Every test names its item and
// states what the old code produced. No window is put on screen: the layout tests build their
// controller's view without one, and the detached ledger's window is handed to a counter.

@MainActor
@Suite("Iteration 4 uishell fixes", .shellTierSerialised)
struct Iter4UIShellFixTests {

    // MARK: - U-041: the Assign form keeps the stored due date

    /// Old output: the form opened with the assignee filled in and the due date always off
    /// (`hasDue = false`), so pressing Assign unchanged stored Bo with `due == nil` and the
    /// 1 Oct due date was gone.
    @Test("U-041: reopening Assign on an assignment with a due date and confirming it unchanged keeps the date")
    func assignFormKeepsTheDueDate() throws {
        let presenter = MockReviewThreadPresenter(author: "A. Berg")
        let markup = UUID()
        let due = Date(timeIntervalSince1970: 1_790_812_800) // 2026-10-01 00:00 UTC
        presenter.assign([markup], to: "Bo", due: due)

        let draft = ReviewListPane.openingDraft(for: markup, review: presenter)
        #expect(draft.assignee == "Bo")
        #expect(draft.hasDue, "old output: the due-date toggle always opened off")
        #expect(draft.due == due)
        #expect(draft.canAssign && draft.canClear)

        // Assign pressed with nothing changed: what the pane's commit sends.
        presenter.assign([markup], to: draft.assignee, due: draft.committedDue)
        let stored = try #require(presenter.assignment(for: markup))
        #expect(stored.assignee == "Bo")
        #expect(stored.due == due, "old output: nil")
    }

    @Test("U-041: an assignment without a due date opens with the toggle off and stores none")
    func assignFormWithoutDueDate() {
        let presenter = MockReviewThreadPresenter(author: "A. Berg")
        let markup = UUID()
        presenter.assign([markup], to: "Cy", due: nil)
        let draft = ReviewListPane.openingDraft(for: markup, review: presenter)
        #expect(draft.assignee == "Cy")
        #expect(!draft.hasDue)
        #expect(draft.committedDue == nil)
    }

    /// Old output: Clear was always enabled and wrote an empty-assignee entry, which the Comments
    /// tab read as "… cleared the assignment" on a markup nobody had ever assigned.
    @Test("U-041: a markup that was never assigned has nothing to clear and a blank name cannot be assigned")
    func clearNeedsAnAssignment() {
        let presenter = MockReviewThreadPresenter(author: "A. Berg")
        let draft = ReviewListPane.openingDraft(for: UUID(), review: presenter)
        #expect(!draft.canClear)
        #expect(!draft.canAssign)
        #expect(draft.assignee.isEmpty && !draft.hasDue)
        #expect(!ReviewListPane.openingDraft(for: nil, review: presenter).canClear)
        var typed = draft
        typed.assignee = "   "
        #expect(!typed.canAssign)
        typed.assignee = " Bo "
        #expect(typed.canAssign)
    }

    // MARK: - U-042: company colours can be removed; Add never does nothing

    private static let companyRed = ColorRGBA(red: 0.8, green: 0.1, blue: 0.1, alpha: 1)

    /// Old output: the palette showed "Add to Company Colours" for any current colour, and
    /// `ZPDFCompanyColours.add` then refused a hue already in the row, so the button did nothing.
    @Test("U-042: a colour already in the company row is offered for removal, never for adding")
    func companyOfferForAColourAlreadyThere() {
        let navy = ZPDFMarkupInk.navy.color
        #expect(ZPDFColourPalette.companyOffer(current: navy, company: [Self.companyRed, navy]) == .remove(navy))
        var translucent = navy
        translucent.alpha = 0.2
        #expect(
            ZPDFColourPalette.companyOffer(current: translucent, company: [navy]) == .remove(navy),
            "matched by hue, the way add() refuses it"
        )
        #expect(ZPDFColourPalette.companyOffer(current: ZPDFMarkupInk.teal.color, company: [navy]) == .add)
        #expect(ZPDFColourPalette.companyOffer(current: nil, company: [navy]) == .nothing)
    }

    /// Old output: with twelve company colours the Add row still showed and still did nothing.
    @Test("U-042: a full company row shows Add off with its reason")
    func companyOfferWhenFull() {
        let twelve = (0..<ZPDFCompanyColours.capacity).map {
            ColorRGBA(red: Double($0) / 20, green: 0.5, blue: 0.2, alpha: 1)
        }
        let store = ZPDFCompanyColours()
        for colour in twelve { store.add(colour) }
        #expect(store.colours.count == 12)
        #expect(!store.add(ZPDFMarkupInk.olive.color), "the store refuses a thirteenth")
        #expect(ZPDFColourPalette.companyOffer(current: ZPDFMarkupInk.olive.color, company: store.colours) == .full)
        #expect(ZPDFColourPalette.companyFullHelp == "Company Colours holds 12 colours. Remove one to add another.")
        // Still removable when full.
        #expect(ZPDFColourPalette.companyOffer(current: twelve[3], company: store.colours) == .remove(twelve[3]))
    }

    /// The palette as drawn: its row buttons carry marker views, found off screen. Old output:
    /// the Add marker was present for a colour already in the row and no Remove existed.
    @Test("U-042: the rendered palette offers Remove, not Add, for a company colour — and removing takes it out")
    func renderedPaletteOffersRemove() throws {
        let navy = ZPDFMarkupInk.navy.color
        let store = ZPDFCompanyColours()
        store.add(navy)
        store.add(Self.companyRed)
        var removed: [ColorRGBA] = []
        func markers(current: ColorRGBA?) -> Set<String> {
            let palette = ZPDFColourPalette(
                content: .init(title: "Border colour", current: current, recents: [], company: store.colours),
                onPick: { _ in },
                onMore: {},
                onAddToCompany: {},
                onRemoveFromCompany: { removed.append($0) }
            )
            let host = NSHostingView(rootView: palette)
            host.frame = NSRect(x: 0, y: 0, width: ZPDFColourPalette.width, height: 640)
            host.layoutSubtreeIfNeeded()
            return Self.identifiers(in: host)
        }
        let already = markers(current: navy)
        #expect(already.contains(ZPDFColourPalette.companyMarkerIdentifier(index: 0)), "the company row is drawn")
        #expect(!already.contains(ZPDFColourPalette.addCompanyMarkerIdentifier), "old output: Add was offered")
        #expect(already.contains(ZPDFColourPalette.removeCompanyMarkerIdentifier))
        let fresh = markers(current: ZPDFMarkupInk.teal.color)
        #expect(fresh.contains(ZPDFColourPalette.addCompanyMarkerIdentifier))
        #expect(!fresh.contains(ZPDFColourPalette.removeCompanyMarkerIdentifier))

        // What the Inspector's handler does with the stored colour the palette hands it.
        guard case let .remove(stored) = ZPDFColourPalette.companyOffer(current: navy, company: store.colours) else {
            Issue.record("expected a removal offer")
            return
        }
        store.remove(stored)
        #expect(store.colours.count == 1)
        #expect(ZPDFColourMath.sameHue(store.colours[0], Self.companyRed))
        #expect(removed.isEmpty, "rendering alone removes nothing")
    }

    private static func identifiers(in view: NSView) -> Set<String> {
        var found: Set<String> = []
        if let id = view.identifier?.rawValue { found.insert(id) }
        for sub in view.subviews { found.formUnion(identifiers(in: sub)) }
        return found
    }

    // MARK: - U-043: the Inspector's Active scale is the selection's scale

    /// The sample project: the page on screen (page 0) has the default scale 1:50 and the region
    /// "Stair Detail 1:20" at 1:20; page 2 has "Footing Detail 1:10" at 1:10.
    private func scaleFixture() throws -> (ProjectShellEnvironment, PageDescriptor.ID, PageDescriptor.ID) {
        let environment = ProjectShellEnvironment.mock()
        let shown = environment.canvas.viewport.pageID
        let stair = try #require(environment.document.scaleRegions.first { $0.name == "Stair Detail 1:20" })
        let footing = try #require(environment.document.scaleRegions.first { $0.name == "Footing Detail 1:10" })
        #expect(stair.pageID == shown, "fixture: the stair region is on the page on screen")
        #expect(footing.pageID != shown)
        #expect(environment.canvas.activeScale?.displayString == "1:50")
        return (environment, shown, footing.pageID)
    }

    private func markup(page: PageDescriptor.ID, region: String?) -> MarkupSummary {
        MarkupSummary(
            id: UUID(), kind: .measurement, measurementKind: .length, subject: "Wall", label: "",
            pageLabel: "A-101", pageID: page, pageIndex: 0, scaleRegionName: region, author: "A. Berg",
            colorRGBA: ColorRGBA(red: 0, green: 0, blue: 1, alpha: 1),
            created: Date(timeIntervalSince1970: 100), modified: Date(timeIntervalSince1970: 100),
            boundsInPageSpace: PDFRectValue(x: 0, y: 0, width: 1, height: 1)
        )
    }

    /// Old output: the row read `canvas.activeScale`, the page's default, so markup measured in
    /// the 1:20 region showed "Active scale 1:50".
    @Test("U-043: markup in a Scale Region shows the region's scale, not the page default")
    func activeScaleFollowsTheRegion() throws {
        let (environment, shown, footingPage) = try scaleFixture()
        func scale(_ markups: [MarkupSummary]) -> InspectorMeasurementModel.ScaleInForce {
            InspectorMeasurementModel(environment: environment, selection: InspectorSelectionSummary(markups: markups)).scaleInForce
        }
        let inStair = markup(page: shown, region: "Stair Detail 1:20")
        let plain = markup(page: shown, region: nil)
        #expect(scale([inStair]) == .init(text: "1:20", isMixed: false), "old output: 1:50")
        #expect(scale([plain]) == .init(text: "1:50", isMixed: false))
        #expect(scale([inStair, markup(page: shown, region: "Stair Detail 1:20")]) == .init(text: "1:20", isMixed: false))
        #expect(scale([inStair, plain]).isMixed, "1:20 and 1:50 disagree")
        // A region on another sheet resolves on that sheet.
        #expect(scale([markup(page: footingPage, region: "Footing Detail 1:10")]) == .init(text: "1:10", isMixed: false))
        // A region name that is not on the markup's own page is not borrowed from another sheet.
        #expect(scale([markup(page: footingPage, region: "Stair Detail 1:20")]).text == "Page default")
        // Nothing selected: the page on screen.
        #expect(scale([]) == .init(text: "1:50", isMixed: false))
    }

    // MARK: - U-044: page-card drag reaches the end and refuses a drop that changes nothing

    private func pages(_ count: Int) -> [PageDescriptor] {
        let box = PDFRectValue(x: 0, y: 0, width: 100, height: 100)
        return (0..<count).map {
            PageDescriptor(id: UUID(), index: $0, label: "\($0 + 1)", mediaBox: box, cropBox: box, rotation: .degrees0)
        }
    }

    /// Old output: card 0 dropped on card 1 computed target 0 — its own place — and the drop
    /// handler returned true; the order did not change and nothing was said.
    @Test("U-044: a drop that changes nothing is refused; the strip under the last card moves a sheet last")
    func pageDropDestinations() {
        let set = pages(4)
        let ids = set.map(\.id)
        #expect(NavigatorPageDrag.destination(dropOn: 1, block: [ids[0]], pages: set) == nil, "old output: 0, accepted")
        #expect(NavigatorPageDrag.destination(dropOn: 0, block: [ids[0]], pages: set) == nil, "on itself")
        // One place down is the card after next: before card 2 is position 1.
        #expect(NavigatorPageDrag.destination(dropOn: 2, block: [ids[0]], pages: set) == 1)
        // The strip under the last card (position == count) lands the block last.
        let last = NavigatorPageDrag.destination(dropOn: set.count, block: [ids[0]], pages: set)
        #expect(last == 3)
        #expect(NavigatorArrangeAction.reordered(ids, moving: [ids[0]], to: last ?? -1) == [ids[1], ids[2], ids[3], ids[0]])
        // The last card dropped on the strip is already last.
        #expect(NavigatorPageDrag.destination(dropOn: set.count, block: [ids[3]], pages: set) == nil)
        // A two-card block dropped on the card just after it changes nothing either.
        #expect(NavigatorPageDrag.destination(dropOn: 2, block: [ids[0], ids[1]], pages: set) == nil)
    }

    @Test("U-044: the drop handler moves through onMovePages only when the order changes")
    func pageDropHandler() throws {
        let environment = ProjectShellEnvironment.mock()
        let set = environment.document.pages
        try #require(set.count >= 3)
        var moves: [([UUID], Int)] = []
        environment.onMovePages = { ids, position in moves.append((ids, position)) }
        let first = NavigatorPageDrag.payload(for: set[0].id)
        #expect(!NavigatorPageDrag.drop([first], at: 1, in: environment), "old output: true, with no move")
        #expect(moves.isEmpty)
        #expect(NavigatorPageDrag.drop([first], at: set.count, in: environment))
        #expect(moves.count == 1)
        #expect(moves.first?.0 == [set[0].id])
        #expect(moves.first?.1 == set.count - 1, "last")
        #expect(!NavigatorPageDrag.drop(["hello"], at: set.count, in: environment), "a stray text drop")
    }

    // MARK: - U-045: a layer lands where the drop line is drawn

    private static let layerIDs = (0..<4).map { UUID(uuidString: "00000000-0000-4000-8000-0000000045A\($0)")! }

    /// Rows [A, B, C, D]. Old output: dropping A on C (line between B and C) handed over
    /// index 2, which the application's remove-then-insert turns into [B, C, A, D].
    @Test("U-045: a downward layer drop lands above the row it was dropped on")
    func layerDropLandsAtTheLine() {
        let model = MarkupLayerPanelModel()
        let names = ["A", "B", "C", "D"]
        model.apply(
            rows: zip(Self.layerIDs, names).map { MarkupLayerRow(id: $0, name: $1, markupCount: 1) },
            activeLayerID: Self.layerIDs[0]
        )
        var moves: [(UUID, Int)] = []
        model.onMove = { id, index in moves.append((id, index)) }
        let (a, b, c, d) = (Self.layerIDs[0], Self.layerIDs[1], Self.layerIDs[2], Self.layerIDs[3])

        // W-049: through the row drop the Navigator performs, a layer row's own payload.
        func drop(_ id: UUID, on index: Int) -> Bool { model.drop([MarkupLayerDrag.payload(for: id)], at: index) }
        #expect(drop(a, on: 2))
        #expect(moves.last?.0 == a)
        #expect(moves.last?.1 == 1, "between B and C; old output 2")
        moves.removeAll()
        #expect(!drop(a, on: 1))
        #expect(moves.isEmpty, "the line above B is A's own place")
        #expect(drop(d, on: 1))
        #expect(moves.last?.0 == d)
        #expect(moves.last?.1 == 1, "upward drags already matched the line")
        #expect(drop(b, on: 0))
        #expect(moves.last?.1 == 0)
        _ = c
    }

    // MARK: - U-046 / U-047: layout controller

    private func makeLayout(key: String) -> (ProjectWindowLayoutController, ProjectShellEnvironment, ProjectWindowLayoutStore) {
        let mocks = MockPresenters.makeEnvironment()
        let environment = ProjectShellEnvironment(
            document: mocks.document,
            canvas: mocks.canvas,
            ledger: mocks.ledger,
            toolLibrary: mocks.toolLibrary,
            search: mocks.search,
            compare: mocks.compare,
            measurement: mocks.measurement,
            status: mocks.status
        )
        let store = ProjectWindowLayoutStore(defaults: ZPDFInMemoryDefaults(), key: key)
        let layout = ProjectWindowLayoutController(environment: environment, store: store)
        environment.layoutController = layout
        layout.presentDetachedLedgerWindow = { _ in }
        layout.detachedLedgerAutosaveName = ""
        _ = layout.view
        return (layout, environment, store)
    }

    /// Old output: the ledger host's `cancelOperation` ran `toggleBottomPane()`, which only
    /// re-docked a detached ledger — the pane landed open in the window.
    @Test("U-046: Escape in the detached ledger's AppKit content hides the pane, like its ✕")
    func escapeFromTheDetachedLedgerHidesIt() throws {
        let (layout, _, _) = makeLayout(key: "iter4.u046")
        layout.detachQuantityLedger()
        #expect(layout.isQuantityLedgerDetached)
        // The ledger's panel host: its `cancelOperation` is the AppKit Escape route.
        let host = try #require(layout.detachedLedgerControllerForTesting?.window?.contentViewController)
        host.cancelOperation(nil as Any?)
        #expect(!layout.isQuantityLedgerDetached, "re-docked")
        #expect(!layout.isBottomPaneVisible, "old output: docked and open")
        #expect(!layout.isVisible(.quantityLedger))
        #expect(layout.panelState.showsEar(for: .quantityLedger), "an ear brings it back")

        // Docked and open, the same Escape still hides it; with the pane hidden it shows it.
        layout.reveal(.quantityLedger)
        #expect(layout.isBottomPaneVisible)
        host.cancelOperation(nil as Any?)
        #expect(!layout.isBottomPaneVisible)
    }

    /// Old output: `normalized()` turned the empty set back into `[.measurement]`, so
    /// `captureLayoutState()` stored Measurement as open and the next tab switch reopened it.
    @Test("U-047: collapsing the one open Inspector section is remembered through capture, save and load")
    func collapsedInspectorSectionsSurvive() {
        let (layout, _, store) = makeLayout(key: "iter4.u047")
        #expect(layout.panelState.expandedInspectorSections == [.measurement])
        layout.panelState.setExpanded(false, section: .measurement)
        layout.captureLayoutState()
        #expect(layout.layoutState.expandedInspectorSections.isEmpty, "old output: [.measurement]")
        store.save(layout.layoutState)
        #expect(store.load().expandedInspectorSections.isEmpty)
        // A second window reading the same store opens with everything collapsed.
        let reopened = ProjectWindowLayoutController(environment: .mock(), store: store)
        #expect(reopened.panelState.expandedInspectorSections.isEmpty)
    }
}
