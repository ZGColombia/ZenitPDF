import AppKit
import Foundation
import SwiftUI
import Testing
import ZPDFDesignSystem
import ZPDFUIPresentation
@testable import ZPDFUIShell

// Regression tests for the quality loop's iteration-5 "uishell" list:
// the live-test items L-xx and the
// reviewed items V-xxx. Every test names its item and states what the old code produced. No
// window is put on screen: views are hosted in `NSHostingView`s that never join a window, and
// the toolbar items are built by the builder's delegate method without a toolbar on screen.

@MainActor
@Suite("Iteration 5 uishell fixes", .shellTierSerialised)
struct Iter5UIShellFixTests {

    // MARK: - Hosting helpers

    /// Lays a hosted view out off screen and gives SwiftUI a few main-actor turns to settle.
    private func settle(_ view: NSView, size: NSSize) async {
        view.frame = NSRect(origin: .zero, size: size)
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        for _ in 0..<4 {
            try? await Task.sleep(nanoseconds: 30_000_000)
            view.layoutSubtreeIfNeeded()
        }
    }

    /// Every pop-up button SwiftUI created for a borderless `Menu` under `view`.
    private func allPopUpButtons(in view: NSView) -> [NSPopUpButton] {
        var found: [NSPopUpButton] = []
        if let button = view as? NSPopUpButton { found.append(button) }
        for sub in view.subviews { found += allPopUpButtons(in: sub) }
        return found
    }

    // MARK: - L-07: the status strip's Scale and Unit menus keep their values

    /// Old output: the Scale and Unit segments, once their menu hooks were wired, drew pop-up
    /// buttons titled "Scale" and "Unit" — a borderless menu keeps only the first `Text` of the
    /// HStack read-out it was given as its label, so "1:100" and "m" were dropped.
    @Test("L-07: the Scale and Unit menu segments show their values, not only their labels")
    func statusMenuSegmentsKeepTheirValues() async throws {
        let environment = ProjectShellEnvironment.mock()
        environment.onScaleSegmentPressed = {}
        environment.onApplyScaleRatio = { _ in }
        environment.onSetOutputUnits = { _ in }
        var snapshot = environment.status.snapshot
        snapshot.activeScaleDisplay = "1:100"
        snapshot.scaleRegionName = nil
        snapshot.outputUnitSymbol = "m"
        let rows = StatusStripRows(environment: environment, snapshot: StatusBarView.shownSnapshot(snapshot))
        let host = NSHostingView(rootView: rows)
        await settle(host, size: NSSize(width: 1_800, height: 28))

        let titles = allPopUpButtons(in: host).map(\.title)
        try #require(!titles.isEmpty, "the menu segments are pop-up buttons")
        #expect(titles.contains("Scale 1:100"), "old output: \"Scale\" — got \(titles)")
        #expect(titles.contains("Unit m"), "old output: \"Unit\" — got \(titles)")
        #expect(!titles.contains("Scale") && !titles.contains("Unit"), "a label without its value: \(titles)")
    }

    // MARK: - L-08: the Shapes dropdown keeps its accessible name

    /// Old output: the pop-up button behind the Shapes › had the SF Symbol's own description,
    /// "Forward", as the only name AppKit could give it; once the chip redrew (the calibration
    /// sheet closing), automation read "Forward" instead of "Open the list of shapes".
    ///
    /// L-100 (live test 8) replaced the Shapes pop-up — a 17 × 14 pt target whatever its label
    /// asked for — with a plain SwiftUI button labelled `paletteHelp`; the L-08 path (a pop-up
    /// naming itself after its image, and losing the name on a redraw) needs a pop-up, and none
    /// is left behind the ›. Measure's and Count's corner marks are still pop-ups (their image is
    /// the whole 16 pt corner, L-105), and they keep their names as before.
    @Test("L-08: the palette indicators describe themselves by their help, before and after a redraw")
    func paletteIndicatorsKeepTheirNames() async throws {
        let environment = ProjectShellEnvironment.mock()
        let builder = ZenitToolbarBuilder(environment: environment)
        let toolbar = NSToolbar(identifier: "it5-l08")
        let expected: [(NSToolbarItem.Identifier, ZenitToolChip.Palette, String)] = [
            (.zenitShapes, .shapes, "Open the list of shapes"),
            (.zenitMeasure, .measure, "Open the list of measurement tools"),
            (.zenitCount, .count, "Open the list of count tools")
        ]
        for (identifier, palette, name) in expected {
            let item = try #require(builder.toolbar(toolbar, itemForItemIdentifier: identifier, willBeInsertedIntoToolbar: true))
            let view = try #require(item.view)
            // The names AppKit can give the pop-ups behind the indicator: none for Shapes' ›.
            let wanted: [String] = palette == .shapes ? [] : [name]
            await settle(view, size: NSSize(width: 120, height: 52))
            let before = allPopUpButtons(in: view).compactMap { $0.image?.accessibilityDescription }
            #expect(before == wanted, "old output: [\"Forward\"] or a direction — got \(before)")
            // A redraw of the chip: another tool armed, then this one's state changes back.
            environment.toolbar.selectTool(.text)
            await settle(view, size: NSSize(width: 120, height: 52))
            environment.toolbar.selectTool(.select)
            await settle(view, size: NSSize(width: 120, height: 52))
            let after = allPopUpButtons(in: view).compactMap { $0.image?.accessibilityDescription }
            #expect(after == wanted, "after a redraw: \(after)")
            #expect(ZenitToolChip.paletteHelp(palette) == name)
            let indicator = ZenitToolChip.indicator(for: palette)
            #expect(ZenitToolChip.paletteIndicatorImage(palette, indicator: indicator).accessibilityDescription == name)
        }
    }

    // MARK: - V-042: History re-reads the trail when the trail changes

    /// A trail whose revision moves on its own, as the app's history store does.
    @MainActor
    private final class TrailStub: LedgerAuditPresenting {
        var events: [LedgerAuditEvent] = []
        private(set) var auditRevision = 0
        func append(_ event: LedgerAuditEvent) {
            events.append(event)
            auditRevision += 1
        }
        func derivation(for markupID: UUID) -> LedgerDerivationModel? { nil }
        func auditEvents(matching filter: LedgerAuditFilter) -> [LedgerAuditEvent] { events.filter(filter.matches) }
        var auditPageLabels: [String] { [] }
        var auditActions: [String] { [] }
    }

    /// Old output: the memo was keyed on the ledger's `contentRevision` alone, so a Verify Scale
    /// entry written while the ledger did not rebuild came back as the one-entry list from
    /// before, and the pane's "1 entry" count stayed.
    @Test("V-042: a trail write the ledger never saw reaches the History query")
    func historyFollowsTheTrail() {
        let trail = TrailStub()
        trail.append(LedgerAuditEvent(sequence: 1, occurredAt: .distantPast, action: "markup_created", actor: "A. Berg"))
        let cache = HistoryEventCache()
        let ledgerRevision = 7
        let first = HistoryPaneContent.events(matching: LedgerAuditFilter(), audit: trail, ledgerRevision: ledgerRevision, cache: cache)
        #expect(first.count == 1)

        trail.append(LedgerAuditEvent(sequence: 2, occurredAt: .distantPast, action: "scale_verified", actor: "A. Berg"))
        let second = HistoryPaneContent.events(matching: LedgerAuditFilter(), audit: trail, ledgerRevision: ledgerRevision, cache: cache)
        #expect(second.map(\.sequence) == [1, 2], "old output: [1]")
        #expect(HistoryPaneContent.entryCountText(second.count) == "2 entries")

        // Still a memo: nothing changed, nothing re-queried.
        let queries = cache.queryCount
        _ = HistoryPaneContent.events(matching: LedgerAuditFilter(), audit: trail, ledgerRevision: ledgerRevision, cache: cache)
        #expect(cache.queryCount == queries)
        // The mock's trail moves with its rows, and so does its revision.
        let mock = MockPresenters.makeEnvironment().ledger
        let audit = mock as? LedgerAuditPresenting
        #expect(audit != nil)
        #expect(audit?.auditRevision == mock.contentRevision)
    }

    // MARK: - V-043: the Repeat stepper steps from what it last asked for

    /// Old output: a value binding over the snapshot's count, so two clicks before the refresh
    /// landed asked for 2 and 2 again — two undo steps and two audit rows for one value.
    @Test("V-043: two quick increments before the refresh ask for 2 and then 3")
    func repeatStepperUsesThePendingCount() {
        var inFlight = InspectorStepsInFlight<Int>()
        var asked: [Int] = []
        for _ in 0..<2 {
            // The snapshot still says 1: the edit has not landed.
            guard let next = InspectorRepeatStepper.click(delta: 1, count: 1, inFlight: &inFlight) else { break }
            asked.append(next)
        }
        #expect(asked == [2, 3], "old output: [2, 2]")
        #expect(InspectorRepeatStepper.stepped(count: 1, pending: 3, delta: -1) == 2)
        #expect(InspectorRepeatStepper.stepped(count: 1, pending: nil, delta: -1) == nil, "Once is the floor")
        // X-021: the ceiling is the store's 10 000, not 999 (Iter7UIShellFixTests).
        #expect(InspectorRepeatStepper.stepped(count: 10_000, pending: nil, delta: 1) == nil, "10 000 is the ceiling")
        #expect(InspectorRepeatStepper.stepped(count: 4, pending: nil, delta: 1) == 5, "no edit in flight: the snapshot")
    }

    /// The held-stepper case the first fix missed. The row cleared its one pending count on every
    /// count change, so when the refresh for 2 landed while 3 was still in flight, the next click
    /// stepped from the snapshot's 2 and asked for 3 again. Old output (clear on any change):
    /// asks [2, 3, 3] — a duplicate undo step and audit row, and the click meant for 4 lost.
    @Test("V-043: a refresh landing mid-sequence keeps the later asks; an undo resets to the snapshot")
    func repeatStepperKeepsTheAsksStillInFlight() {
        var inFlight = InspectorStepsInFlight<Int>()
        var count = 1
        var asked: [Int] = []
        func click(_ delta: Int) {
            if let next = InspectorRepeatStepper.click(delta: delta, count: count, inFlight: &inFlight) { asked.append(next) }
        }
        /// A refresh: the snapshot's count changes, as `.onChange(of: count)` reports it.
        func land(_ value: Int) {
            count = value
            inFlight.snapshotMoved(to: value)
        }

        click(1); click(1)
        land(2)                                   // the first edit's refresh; 3 is still in flight
        #expect(inFlight.last == 3, "the ask still in flight must stay the base")
        click(1)
        #expect(asked == [2, 3, 4], "old output: [2, 3, 3]")
        #expect(Set(asked).count == asked.count, "no value asked twice")
        land(3)
        #expect(inFlight.asks == [4])
        land(4)
        #expect(inFlight.asks.isEmpty, "the snapshot caught up")

        // An undo during a sequence: asks 5 and 6 are out, then the count moves to 3, a value
        // nobody asked for. The stepper follows the truth: the next click asks for 4.
        click(1); click(1)
        #expect(asked.suffix(2) == [5, 6])
        land(3)
        #expect(inFlight.asks.isEmpty, "a count nobody asked for drops every ask")
        click(1)
        #expect(asked.last == 4)

        // Refreshes that coalesce: 5 and 6 are asked and a single refresh shows 6.
        land(4)
        click(1); click(1)
        land(6)
        #expect(inFlight.asks.isEmpty)
        // A click back to a value: 7 then 6 are asked; the refresh for 7 leaves 6 in flight.
        click(1); click(-1)
        land(7)
        #expect(inFlight.asks == [6])
        click(-1)
        #expect(asked.last == 5, "steps from the 6 still in flight, not from the snapshot's 7")
    }

    /// The Inspector's number stepper (BH-802) had the same clearing flaw: `pendingValue = nil` on
    /// every value change. Old output for a width of 2 held at +0.25: asks [2.25, 2.5, 2.5].
    @Test("V-043: the number stepper keeps its asks in flight too, and matches a rounded return")
    func numberStepperKeepsTheAsksStillInFlight() {
        var inFlight = InspectorStepsInFlight<Double>()
        var value: Double? = 2
        var asked: [Double] = []
        let range = 0.25...48.0
        let sameAsk = InspectorNumberControl.sameAsk(step: 0.25)
        func click(_ delta: Double) {
            if let next = InspectorNumberControl.click(delta: delta, value: value, range: range, inFlight: &inFlight) {
                asked.append(next)
            }
        }
        func land(_ new: Double?) {
            value = new
            inFlight.snapshotMoved(to: new, matches: sameAsk)
        }
        click(0.25); click(0.25)
        land(2.25)
        click(0.25)
        #expect(asked == [2.25, 2.5, 2.75], "old output: [2.25, 2.5, 2.5]")
        // A mixed selection is a value nobody asked for.
        land(nil)
        #expect(inFlight.asks.isEmpty)

        // A fill opacity comes back through an 8-bit alpha: 35 % returns as 34.9… and is still the
        // ask for 35, so the 40 behind it stays in flight.
        var opacity = InspectorStepsInFlight<Double>()
        opacity.asked(35)
        opacity.asked(40)
        opacity.snapshotMoved(to: Double(UInt8((0.35 * 255).rounded())) / 255 * 100,
                              matches: InspectorNumberControl.sameAsk(step: 5))
        #expect(opacity.asks == [40])
    }

    // MARK: - V-044: a drawing dropped on a Quick PDF's card opens as its own

    /// Old output: every card declared a URL drop destination and returned `false` in a Quick
    /// PDF; SwiftUI does not pass a refusal up, so a PDF dropped on a card never reached the
    /// column's "opens as a separate drawing". The first fix removed the card's destination in a
    /// Quick PDF, which still left the card's page-reorder (plain-text) destination able to claim
    /// a file drag that carries text and refuse it. Now the card takes every drawing drop itself,
    /// by the column's own rule, and the column's hint shows over it.
    @Test("V-044: a card takes a drawing in both modes — before itself in a project, as its own in a Quick PDF")
    func cardsTakeDrawingDropsByTheColumnsRule() {
        let environment = ProjectShellEnvironment.mock()
        var drops: [([URL], Int)] = []
        environment.onNavigatorDropFiles = { urls, index in drops.append((urls, index)); return true }
        let pdf = URL(fileURLWithPath: "/tmp/it5-v044.pdf")
        let notes = URL(fileURLWithPath: "/tmp/notes.txt")

        // A Quick PDF: the card forwards to the column's append position, as a drop between the
        // cards does. Old output: false and no call.
        environment.navigatorDropAddsToProject = false
        #expect(NavigatorDropPolicy.dropOnCard([pdf, notes], insertionIndex: 1, pageCount: 4, in: environment),
                "old output: refused")
        #expect(drops.last?.0 == [pdf])
        #expect(drops.last?.1 == 4, "a Quick PDF drop is the column's drop")
        #expect(!NavigatorDropPolicy.cardDrawsInsertionLine(addsToProject: false), "no line: nothing lands before the card")
        #expect(NavigatorDropPolicy.showsColumnHint(columnTargeted: false, cardsTargeted: [UUID()]),
                "the column's hint shows over a card standing in for it")
        #expect(!NavigatorDropPolicy.showsColumnHint(columnTargeted: false, cardsTargeted: []))

        // A project: the drawing lands before the card, under its line.
        environment.navigatorDropAddsToProject = true
        #expect(NavigatorDropPolicy.dropOnCard([pdf, notes], insertionIndex: 2, pageCount: 4, in: environment))
        #expect(drops.count == 2)
        #expect(drops.last?.1 == 2, "a project inserts before the card")
        #expect(NavigatorDropPolicy.cardDrawsInsertionLine(addsToProject: true))

        // Nothing the Navigator opens: refused in both modes, as the column refuses it.
        #expect(!NavigatorDropPolicy.dropOnCard([notes], insertionIndex: 0, pageCount: 4, in: environment))
        environment.navigatorDropAddsToProject = false
        #expect(!NavigatorDropPolicy.dropOnCard([notes], insertionIndex: 0, pageCount: 4, in: environment))
        #expect(drops.count == 2)

        // The card's reorder destination takes only a card's private payload; a file's name
        // arriving as text is refused, never mistaken for a move.
        var moves = 0
        environment.onMovePages = { _, _ in moves += 1 }
        #expect(!NavigatorPageDrag.drop(["it5-v044.pdf", pdf.path], at: 0, in: environment))
        #expect(moves == 0)
    }

    // MARK: - V-045: one no-op rule for the card menu and the drag

    /// Old output: [A B C D] with A and C selected had its first page at 0, so Move to Top and
    /// Move Up computed target 0 == first and were disabled.
    @Test("V-045: a scattered selection at the top can be gathered by Move to Top and Move Up")
    func scatteredSelectionMovesFromTheMenu() {
        let (a, b, c, d) = (UUID(), UUID(), UUID(), UUID())
        let order = [a, b, c, d]
        let block = [a, c]
        let top = NavigatorArrangeAction.moveToTop.target(moving: block, in: order)
        #expect(top == 0, "old output: nil (disabled)")
        #expect(NavigatorArrangeAction.reordered(order, moving: block, to: top ?? -1) == [a, c, b, d])
        #expect(NavigatorArrangeAction.moveUp.target(moving: block, in: order) == 0, "old output: nil")
        // W-044: Move Down lands the gathered block one place after its LAST member, past D —
        // [B D A C]. It used to count from A, the first member (target 1, [B A C D]).
        #expect(NavigatorArrangeAction.moveDown.target(moving: block, in: order) == 2)
        #expect(NavigatorArrangeAction.moveToBottom.target(moving: block, in: order) == 2)
        // A contiguous block already at the top is still a no-op, by the same rule.
        #expect(NavigatorArrangeAction.moveToTop.target(moving: [a, b], in: order) == nil)
        #expect(NavigatorArrangeAction.moveToBottom.target(moving: [c, d], in: order) == nil)
        // A scattered block at the bottom gathers downward too: [A B C D] with B and D.
        #expect(NavigatorArrangeAction.moveToBottom.target(moving: [b, d], in: order) == 2)
        #expect(NavigatorArrangeAction.reordered(order, moving: [b, d], to: 2) == [a, c, b, d])
    }

    // MARK: - V-046: one lock rule for moving markups onto a layer

    private static let walls = UUID(uuidString: "00000000-0000-4000-8000-0000000046A1")!
    private static let base = UUID(uuidString: "00000000-0000-4000-8000-0000000046A2")!

    private func layerModel() -> MarkupLayerPanelModel {
        let model = MarkupLayerPanelModel()
        model.apply(
            rows: [
                MarkupLayerRow(id: Self.walls, name: "Walls", isLocked: true, markupCount: 1),
                MarkupLayerRow(id: Self.base, name: "Default", markupCount: 3, isDefault: true)
            ],
            activeLayerID: Self.base
        )
        return model
    }

    @Test("V-046: a locked target and a locked markup are refused by the same rule on both surfaces")
    func oneLayerLockRule() throws {
        let plain = try #require(ZenitSampleProject.shared.markups.first { !$0.locked })
        var ownLock = plain
        ownLock.locked = true
        var layerLock = plain
        layerLock.locked = true
        layerLock.layerLocked = true

        let model = layerModel()
        // Old Inspector: filed a selection onto the locked Walls layer.
        #expect(model.assignRefusal([plain], to: Self.walls) == .targetLocked)
        // Old Navigator: moved a markup with its own lock.
        #expect(model.assignRefusal([ownLock], to: Self.base) == .markupLocked)
        #expect(model.assignRefusal([layerLock], to: Self.base) == .markupOnLockedLayer)
        #expect(model.assignRefusal([], to: Self.base) == .nothingSelected)
        #expect(model.assignRefusal([plain], to: UUID()) == .unknownLayer)
        #expect(model.assignRefusal([plain], to: Self.base) == nil)
        #expect(model.assignRefusal([plain], to: nil) == nil, "a new layer is never locked")
        #expect(model.assignRefusal([ownLock], to: nil) == .markupLocked)
        #expect(!MarkupLayerPanelModel.reason(.targetLocked).isEmpty)

        // The Navigator's route.
        var routed: [(Set<UUID>, UUID)] = []
        model.onAssign = { routed.append(($0, $1)) }
        model.assign([ownLock], to: Self.base)
        model.assign([plain], to: Self.walls)
        #expect(routed.isEmpty, "old output: the Navigator moved the locked markup")
        model.assign([plain], to: Self.base)
        #expect(routed.count == 1)

        // The Inspector's route asks the same model.
        let environment = ProjectShellEnvironment.mock()
        environment.markupLayers.apply(rows: model.rows, activeLayerID: Self.base)
        var inspectorRouted: [UUID] = []
        environment.markupLayers.onAssign = { _, layer in inspectorRouted.append(layer) }
        let panel = InspectorPanel(environment: environment, panelState: ShellPanelState())
        let summary = InspectorSelectionSummary(markups: [plain])
        panel.assignLayer(Self.walls, for: summary)
        #expect(inspectorRouted.isEmpty, "old output: [Walls], a selection filed onto a locked layer")
        panel.assignLayer(Self.base, for: summary)
        #expect(inspectorRouted == [Self.base])
    }

    // MARK: - V-047: every layer order is reachable by drag, and only a layer drag is taken

    private static let layerIDs = (0..<4).map { UUID(uuidString: "00000000-0000-4000-8000-0000000047A\($0)")! }

    /// Old output: no drop target under the last row, so [B C D A] could not be reached by drag;
    /// and a row's drop took any text and returned `true` before reading it.
    @Test("V-047: the end strip lands a layer at the bottom; foreign text is refused")
    func layerDropsReachTheBottomAndRefuseStrangers() {
        let model = MarkupLayerPanelModel()
        model.apply(
            rows: zip(Self.layerIDs, ["A", "B", "C", "D"]).map { MarkupLayerRow(id: $0, name: $1, markupCount: 1) },
            activeLayerID: Self.layerIDs[0]
        )
        var moves: [(UUID, Int)] = []
        model.onMove = { moves.append(($0, $1)) }
        let (a, _, c, d) = (Self.layerIDs[0], Self.layerIDs[1], Self.layerIDs[2], Self.layerIDs[3])

        #expect(model.drop([MarkupLayerDrag.payload(for: a)], at: model.rows.count), "the end strip")
        #expect(moves.last?.0 == a)
        #expect(moves.last?.1 == 3, "[B C D A]")
        moves.removeAll()

        #expect(!model.drop(["hello"], at: 2), "old output: true, with a drop line and no move")
        #expect(!model.drop([a.uuidString], at: 2), "the old bare payload is not a layer drag any more")
        #expect(!model.drop([NavigatorPageDrag.payload(for: UUID())], at: 2), "a page card is not a layer")
        #expect(!model.drop([MarkupLayerDrag.payload(for: d)], at: model.rows.count), "D is already last")
        #expect(moves.isEmpty)
        // A row drop still lands above the row (U-045).
        #expect(model.drop([MarkupLayerDrag.payload(for: a)], at: 2))
        #expect(moves.last?.1 == 1)
        _ = c
        #expect(MarkupLayerDrag.layerID(in: MarkupLayerDrag.payload(for: c)) == c)
    }

    // MARK: - V-048: the compact summary chips keep the kind filter

    private func summary() -> LedgerSummary {
        let totals = LedgerTotals(
            rowCount: 8,
            quantities: [
                .planArea: DecimalQuantity(value: 2480, dimension: .area),
                .planLength: DecimalQuantity(value: 312.5, dimension: .length),
                .count: DecimalQuantity(value: 12, dimension: .count)
            ],
            displayValues: [.planArea: "2,480 SF", .planLength: "312' - 6\"", .count: "12"],
            incompatibleColumns: []
        )
        return LedgerSummary(totals: totals, rowCount: 8, kindCounts: [.area: 2, .length: 7, .count: 3])
    }

    /// Old output: the compact strip ignored the active kind (and had no click), so after Areas
    /// was chosen a narrow window drew exactly the same chips as an unfiltered one.
    @Test("V-048: the compact strip draws the filtered kind as selected and is clickable")
    func compactChipsShowTheFilter() async {
        let size = NSSize(width: 560, height: ZPDFSpacing.Chrome.summaryChipHeight)
        var tapped: [LedgerSummary.Kind] = []
        let filtered = LedgerSummaryStrip(summary: summary(), onChip: { tapped.append($0) }, activeKind: .areas, isCompact: true)
        let unfiltered = LedgerSummaryStrip(summary: summary(), onChip: { tapped.append($0) }, activeKind: nil, isCompact: true)
        let a = await DesignQARenderHarnessTests.render(DesignQARenderHarnessTests.host(filtered, appearance: .dark), size: size, appearance: .dark)
        let b = await DesignQARenderHarnessTests.render(DesignQARenderHarnessTests.host(unfiltered, appearance: .dark), size: size, appearance: .dark)
        var differing = 0
        for y in stride(from: 0, to: a.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: a.pixelsWide, by: 2) {
                let p = DesignQARenderHarnessTests.pixel(a, x, y)
                let q = DesignQARenderHarnessTests.pixel(b, x, y)
                if abs(p.r - q.r) + abs(p.g - q.g) + abs(p.b - q.b) > 6 { differing += 1 }
            }
        }
        #expect(differing > 20, "old output: identical renders (0 differing samples); got \(differing)")
        #expect(LedgerSummaryStrip.isSelected(.areas, activeKind: .areas))
        #expect(!LedgerSummaryStrip.isSelected(.markups, activeKind: .markups), "Markups clears, it is never selected")
        #expect(LedgerCompactSummaryChip.paint(isSelected: true, isHovering: false, isInteractive: true)
            == ZPDFSummaryChip.paint(isSelected: true, isHovering: false, isInteractive: true))
        #expect(!LedgerSummaryStrip.chipHelp(.areas, isInteractive: true).isEmpty)
    }

    // MARK: - L-14: nothing in the Inspector is cut off at its minimum width

    private func width(_ text: String, _ style: ZPDFTextStyle) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: ZPDFTypography.nsFont(style)]).width)
    }

    /// A legacy (always visible) vertical scroller, which a mouse-connected Mac shows beside the
    /// Inspector's form — the live test's case.
    private var scroller: CGFloat { NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) }

    /// Old output: at the old 240 pt minimum a tab was 56 pt wide ("Comments" needs 64 in the
    /// selected weight), the card title had 97 pt ("Length Measurement" needs 143) and the date
    /// row 108 pt ("27 Sept 2026" and "08:15" need 124): "Comm…", "Length Meas…", "27 Sep 20…".
    @Test("L-14: tab titles, the card title and a timestamp fit at the Inspector's minimum width")
    func inspectorFitsAtItsMinimumWidth() {
        let minimum = CGFloat(ProjectWindowLayoutState.minimumInspectorWidth)
        let gutter = InspectorMetrics.gutter

        // The tab strip: four equal tabs across the panel less its gutters (outside the scroller).
        let tab = (minimum - 2 * gutter) / CGFloat(InspectorTab.allCases.count)
        for inspectorTab in InspectorTab.allCases {
            #expect(width(inspectorTab.title, .tabSelected) <= tab, "\(inspectorTab.title) in \(tab) pt")
        }

        // The header card: gutters, card padding, the tile, two gaps and the menu's hit target.
        let title = minimum - 2 * gutter - scroller - 2 * InspectorMetrics.cardPadding - InspectorMetrics.tile
            - 2 * ZPDFSpacing.l - ZPDFSpacing.Control.minimumHitTarget
        #expect(width("Length Measurement", .cardTitle) <= title, "one line in \(title) pt")

        // A timestamp row: gutters, card padding, the label column and its gap.
        let row = minimum - 2 * gutter - scroller - 2 * InspectorMetrics.cardPadding - InspectorMetrics.labelColumn - ZPDFSpacing.m
        let sample = Date(timeIntervalSince1970: 1_790_490_900) // 27 Sep 2026
        for identifier in ["en_GB", "en_US"] {
            let parts = InspectorMarkupFormatting.dateAndTime(
                sample, locale: Locale(identifier: identifier), timeZone: TimeZone(identifier: "UTC")!
            )
            let needed = width(parts.date, .monoNumeric) + ZPDFSpacing.l + width(parts.time, .monoNumeric)
            #expect(needed <= row, "\(identifier): \(parts.date) \(parts.time) needs \(needed) of \(row) pt")
        }

        // A stored narrower width comes back at the minimum.
        var stored = ProjectWindowLayoutState.default
        stored.inspectorWidth = 240
        #expect(stored.normalized().inspectorWidth == ProjectWindowLayoutState.minimumInspectorWidth)
    }

    // MARK: - L-11: one chip at a time holds a transient fill

    /// Old output: every chip kept its own `isHovering`/`isPressed`, cleared only by its own
    /// exit, its own release or its own armed state changing. A Text chip whose exit or release
    /// never arrived stayed raised beside the Select chip that had just been armed — two chips lit.
    @Test("L-11: at most one chip holds a hover or press fill, and a tool change clears both")
    func onePointerOwnerForTheBar() {
        let toolbar = ZenitToolbarModel()
        let pointer = toolbar.chipPointer
        let (select, text, shapes) = (UUID(), UUID(), UUID())
        toolbar.selectTool(.text)

        // The pointer entered Text, its exit never arrived, and it entered Select.
        pointer.hover(text, true)
        pointer.hover(select, true)
        #expect(pointer.hovered == select, "old output: Text still hovered as well")
        // A late exit from Text changes nothing; an exit from Select clears it.
        pointer.hover(text, false)
        #expect(pointer.hovered == select)
        pointer.hover(select, false)
        #expect(pointer.hovered == nil)

        // A press on Shapes whose release never came (a menu took the pointer), then Select armed.
        pointer.press(shapes, true)
        #expect(pointer.pressed == shapes && pointer.hovered == shapes)
        pointer.press(text, true)
        #expect(pointer.pressed == text, "one chip held down at a time")
        toolbar.selectTool(.select)
        #expect(pointer.pressed == nil && pointer.hovered == nil, "a tool change settles the whole bar")

        // Re-arming the same tool is no change and leaves a real hover alone.
        pointer.hover(select, true)
        toolbar.selectTool(.select)
        #expect(pointer.hovered == select)
        pointer.settle()
        #expect(pointer.hovered == nil && pointer.pressed == nil)
    }
}
