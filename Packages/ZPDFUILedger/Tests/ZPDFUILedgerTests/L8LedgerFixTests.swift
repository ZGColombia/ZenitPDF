import AppKit
import Foundation
import SwiftUI
import Testing
import ZPDFUIPresentation
@testable import ZPDFUILedger

/// Live test 8, area l8-ledger: the Per Sheet toggle no longer leaves a second Page column in
/// the grouped outline (L-86), Reset Columns puts the default layout back — one Page
/// column, the user's own columns hidden (L-88) — and the filter panel's naming row stays inside
/// the panel and clear of its scroller (L-84).
@MainActor
@Suite("Ledger, live test 8", .ledgerTierSerialised)
struct L8LedgerFixTests {

    /// The columns a takeoff publishes: the mockup's lead, the built-ins after it, and one column
    /// a person made (the live test's "Area x 2" formula column).
    static let areaTimesTwo = LedgerColumnID.custom("areaTimesTwo")

    static var publishedColumns: [LedgerColumn] {
        [
            LedgerColumn(id: .pageLabel, title: "Page", kind: .text, width: 88),
            LedgerColumn(id: .icon, title: "Type", kind: .text, width: 32),
            LedgerColumn(id: .label, title: "Label", kind: .text, width: 120, isEditable: true),
            LedgerColumn(id: .subject, title: "Subject", kind: .text, width: 180, isEditable: true),
            LedgerColumn(id: .comment, title: "Comment", kind: .text, width: 180, isEditable: true),
            LedgerColumn(id: .perimeter, title: "Perimeter", kind: .number, dimension: .length, width: 96,
                         alignment: .trailing, aggregate: .sum, displayUnitSymbol: "m"),
            LedgerColumn(id: .status, title: "Status", kind: .choice, width: 96, choices: LedgerFixtures.statusChoices),
            LedgerColumn(id: .planArea, title: "Plan Area", kind: .number, dimension: .area, width: 96,
                         alignment: .trailing, aggregate: .sum, displayUnitSymbol: "m²"),
            LedgerColumn(id: areaTimesTwo, title: "Area x 2", kind: .formula, width: 96,
                         alignment: .trailing, formulaSource: "[planArea] * 2", isUserDefined: true)
        ]
    }

    static let defaultVisible: [LedgerColumnID] = [
        .pageLabel, .icon, .label, .subject, .comment,
        LedgerDefaultColumns.valueColumnID, LedgerDefaultColumns.unitColumnID, .perimeter
    ]

    static func ids(_ table: NSTableView) -> [LedgerColumnID] {
        table.tableColumns.map { LedgerColumnID($0.identifier.rawValue) }
    }

    /// The table a person is looking at: the outline while grouped, the flat table otherwise.
    static func shownTable(_ controller: LedgerTableController) -> NSTableView {
        controller.mode == .grouped ? controller.outlineViewForTesting : controller.mainTableViewForTesting
    }

    static func makeHost(grouping: [LedgerColumnID]) -> LedgerTableHost {
        let source = LedgerArrayRowSource(rows: LedgerFixtures.rows, columns: publishedColumns)
        let host = LedgerTableHost(rowSource: source, mode: grouping.isEmpty ? .flat : .grouped, groupingColumns: grouping)
        host.controller.loadViewIfNeeded()
        return host
    }

    // MARK: - L-86

    /// Old output, after Per Sheet off and on: the outline's columns read
    /// `pageLabel, pageLabel, icon, label, subject, display.value, display.unit, …` — the outline
    /// view kept the column it drew its disclosure in through every rebuild and the new Page
    /// column was added beside it, so every row showed its page twice.
    @Test("L-86: Per Sheet off and on again leaves exactly one Page column")
    func perSheetToggleKeepsOnePageColumn() {
        // The pane reopened on a persisted Per Sheet, as in the live test.
        let host = Self.makeHost(grouping: [.pageLabel])
        let controller = host.controller
        let expected = controller.columns.filter(\.visible).map(\.id)
        #expect(Self.ids(Self.shownTable(controller)) == expected)

        for _ in 0..<2 {
            host.setGrouping([])                 // Per Sheet off: the combined, flat view
            #expect(controller.mode == .flat)
            #expect(Self.ids(Self.shownTable(controller)) == expected)
            host.setGrouping([.pageLabel])       // Per Sheet on again
            #expect(controller.mode == .grouped)
            #expect(Self.ids(Self.shownTable(controller)) == expected, "\(Self.ids(Self.shownTable(controller)))")
        }
        let pageColumns = controller.outlineViewForTesting.tableColumns.filter { $0.identifier.rawValue == "pageLabel" }
        #expect(pageColumns.count == 1)
        #expect(controller.outlineViewForTesting.outlineTableColumn === controller.outlineViewForTesting.tableColumns.first,
                "the disclosure is drawn in the leading column the outline actually shows")
    }

    /// The same rebuild runs for every column change while grouped: showing a column used to
    /// leave the old leading column behind as well.
    @Test("L-86: a column change while grouped does not duplicate the leading column")
    func groupedColumnChangeKeepsColumnsUnique() {
        let host = Self.makeHost(grouping: [.icon])
        let controller = host.controller
        controller.setColumn(.status, visible: true)
        controller.moveColumn(.subject, to: 0)
        let shown = Self.ids(Self.shownTable(controller))
        #expect(shown == controller.columns.filter(\.visible).map(\.id), "\(shown)")
        #expect(Set(shown).count == shown.count)
        #expect(controller.outlineViewForTesting.outlineTableColumn?.identifier.rawValue == LedgerColumnID.subject.rawValue)
    }

    // MARK: - L-88

    /// Old output: Reset Columns kept the user's "Area x 2" column on screen (and, through
    /// L-86, the second Page column): `pageLabel, pageLabel, icon, …, perimeter, custom.areaTimesTwo`.
    @Test("L-88: Reset Columns restores the default layout and hides the user's own columns")
    func resetRestoresTheDefaultLayout() throws {
        let host = Self.makeHost(grouping: [.pageLabel])
        let controller = host.controller
        // The user's column arrives visible, as its definition says (NL-QTY-01).
        #expect(controller.columns.first { $0.id == Self.areaTimesTwo }?.visible == true)
        host.setGrouping([])
        host.setGrouping([.pageLabel])
        controller.setColumn(.status, visible: true)
        controller.setColumn(.label, pinned: true)

        controller.resetColumns()

        #expect(controller.columns.filter(\.visible).map(\.id) == Self.defaultVisible)
        #expect(Self.ids(Self.shownTable(controller)) == Self.defaultVisible)
        let userColumn = try #require(controller.columns.first { $0.id == Self.areaTimesTwo })
        #expect(!userColumn.visible, "hidden, not deleted: Show Columns brings it back")
        #expect(!controller.columns.contains { $0.pinned })

        // Shown again from the header menu, it comes back like any hidden column.
        controller.setColumn(Self.areaTimesTwo, visible: true)
        #expect(Self.ids(Self.shownTable(controller)).last == Self.areaTimesTwo)
    }

    // MARK: - L-84 (re-check)

    /// The filter panel's state, as the pane's model holds it.
    @MainActor
    final class FilterState {
        var filter = LedgerFilterGroup(id: UUID(), rules: [
            LedgerFilterRule(id: UUID(), column: .pageLabel, comparison: .contains, operand: .text("1"))
        ])
        var saved = LedgerSavedFilterStore()
        var canvas = LedgerCanvasFilterBehavior.dimNonMatching
    }

    static func spin(_ seconds: TimeInterval = 0.1) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    static func allViews(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(allViews) }

    /// The ledger's side panel width (`QuantityLedgerPane.sidePanelWidth`).
    static let sidePanelWidth: CGFloat = 340

    /// Re-check of L-84, "Save needed a second click". The panel sits at the window's right edge,
    /// and the scroll view's overlay scroller takes the last 17 pt of it when it shows: it grows
    /// under a pointer that nears the edge and takes the click. The old content ran wider than the
    /// panel (the rule row alone needed about 440 pt), so what showed of the naming row's Save lay
    /// in that strip and the first click went to the scroller. SwiftUI draws Save itself, so the
    /// test lays the naming row out in a panel short enough to scroll and checks what lies where.
    /// Old output with the rows wrapped but no strip kept: Cancel at x 262–328, 5 pt into the
    /// scroller at x 323.
    @Test("L-84: the filter naming row lies inside the side panel, clear of its scroller, and Return saves")
    func filterNamingRowIsInReach() throws {
        _ = NSApplication.shared
        let state = FilterState()
        let width = Self.sidePanelWidth
        let builder = LedgerFilterBuilder(
            columns: Self.publishedColumns,
            filter: Binding(get: { state.filter }, set: { state.filter = $0 }),
            savedFilters: Binding(get: { state.saved }, set: { state.saved = $0 }),
            canvasBehavior: Binding(get: { state.canvas }, set: { state.canvas = $0 }),
            matchCount: 1, totalCount: 1, namingFilter: true
        )
        // Short enough that the content scrolls, so the scroller is there.
        let height: CGFloat = 300
        let hosting = NSHostingView(rootView: builder.frame(width: width, height: height))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.contentView = nil }
        hosting.layoutSubtreeIfNeeded()
        Self.spin()

        let fields = Self.allViews(hosting).compactMap { $0 as? NSTextField }.filter(\.isEditable)
        let nameField = try #require(fields.first { $0.placeholderString == "Filter name" }, "the naming row's name field")
        let nameFrame = nameField.convert(nameField.bounds, to: hosting)
        let scrollView = try #require(nameField.enclosingScrollView)
        let document = try #require(scrollView.documentView)
        let scroller = try #require(scrollView.verticalScroller)
        try #require(!scroller.isHidden, "the panel scrolls, so its scroller is there")
        let strip = scroller.convert(scroller.bounds, to: hosting).minX
        #expect(strip < width && strip > width - 40, "the scroller's strip starts at \(strip)")

        // SwiftUI's own buttons have no AppKit control, only a focus-ring view the size of the button.
        let buttons = Self.allViews(document)
            .filter { String(describing: type(of: $0)).contains("FocusRing") && !($0 is NSControl) }
            .map { $0.convert($0.bounds, to: hosting) }
        let rowButtons = buttons
            .filter { abs($0.midY - nameFrame.midY) < 6 && $0.minX >= nameFrame.maxX - 1 }
            .sorted { $0.minX < $1.minX }
        try #require(rowButtons.count == 2, "Save and Cancel beside the name field: \(rowButtons)")
        let save = rowButtons[0]

        // The name field, Save and Cancel — and every other control in the panel — lie inside the
        // panel and left of the scroller's strip.
        let controls = Self.allViews(document).compactMap { $0 as? NSControl }.map { $0.convert($0.bounds, to: hosting) }
        for frame in [nameFrame] + buttons + controls {
            #expect(frame.minX >= 0 && frame.maxX <= strip + 0.5, "\(frame) reaches past x \(strip), into the scroller's strip or off the \(width) pt panel")
        }

        // A click at Save's middle lands in the panel's content, where SwiftUI draws Save: not on
        // the scroller, not on the bare clip view a click on empty space reaches.
        let middle = hosting.convert(NSPoint(x: save.midX, y: save.midY), to: nil)
        let hit = try #require(window.contentView?.superview?.hitTest(middle), "something is under Save's middle")
        #expect(!(hit is NSScroller) && !(hit is NSClipView), "a click at Save's middle lands on \(type(of: hit))")
        #expect(hit.isDescendant(of: document), "a click at Save's middle lands in the panel's content, not on \(type(of: hit))")
        let empty = hosting.convert(NSPoint(x: strip - 2, y: save.midY), to: nil)
        #expect(window.contentView?.superview?.hitTest(empty) is NSClipView, "the strip beside Cancel is empty")

        // Return in the name field saves, as in any naming field.
        window.makeFirstResponder(nameField)
        Self.spin()
        let editor = try #require(window.firstResponder as? NSTextView, "the name field is being edited")
        editor.insertText("Ground floor", replacementRange: NSRange(location: NSNotFound, length: 0))
        Self.spin()
        editor.insertNewline(nil)
        Self.spin()
        #expect(state.saved.filters.map(\.name) == ["Ground floor"])
    }
}
