import AppKit
import Foundation
import Testing
import ZPDFDesignSystem
import ZPDFUIPresentation
@testable import ZPDFUILedger

/// Bug hunt 2, low-severity table, column-menu, host and cell defects: BH-704, BH-705,
/// BH-731, BH-732, BH-737. No window is ever opened. (BH-734 and BH-735 were fixes to
/// LedgerMarkupJump and LedgerSelectionCoordinator, and BH-733 to LedgerScreen's filter counts,
/// all removed as dead code in R-124; the shipping pane's counts are ZPDFUIShell's
/// `LedgerPaneModel.matchCount` / `totalCount`, asserted in its LedgerPanePanelsTests.)
@MainActor
@Suite("Fix2 U1 low-severity bugs", .ledgerTierSerialised)
struct Fix2U1LowBugTests {

    private func menuItem(_ menu: NSMenu, path: [String]) -> NSMenuItem? {
        var current: NSMenu? = menu
        var found: NSMenuItem?
        for title in path {
            found = current?.items.first { $0.title == title }
            current = found?.submenu
        }
        return found
    }

    // MARK: BH-704

    @Test("BH-704: the alignment menu works for a column whose key contains a pipe")
    func alignmentMenuWithPipe() throws {
        // Old output: alignment stayed .leading — "custom.Wall|Slab|trailing" split on the
        // first pipe into "custom.Wall" and "Slab|trailing", and the guard returned.
        let odd = LedgerColumn(id: .custom("Wall|Slab"), title: "Wall or Slab", kind: .text, width: 90)
        let source = LedgerArrayRowSource(rows: LedgerFixtures.rows, columns: LedgerFixtures.columns + [odd])
        let controller = LedgerTableController(rowSource: source)
        controller.loadViewIfNeeded()
        let menu = LedgerColumnMenuBuilder.menu(for: controller)
        let item = try #require(menuItem(menu, path: ["Alignment", "Wall or Slab", "Trailing"]))
        controller.setColumnAlignmentFromMenu(item)
        #expect(controller.columns.first { $0.id == odd.id }?.alignment == .trailing)

        // The older string encoding still works, split at the last pipe.
        let legacy = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        legacy.representedObject = "custom.Wall|Slab|center"
        controller.setColumnAlignmentFromMenu(legacy)
        #expect(controller.columns.first { $0.id == odd.id }?.alignment == .center)
    }

    // MARK: BH-705

    @Test("BH-705: applying a layout from the menu makes it the active layout and reports the store")
    func applyingLayoutMarksItActive() throws {
        // Old output: activeLayoutID stayed on "Takeoff" (saved last) after picking "Review".
        let source = LedgerArrayRowSource(rows: LedgerFixtures.rows, columns: LedgerFixtures.columns)
        let controller = LedgerTableController(rowSource: source)
        controller.loadViewIfNeeded()
        var store = LedgerColumnLayoutStore()
        let savedReview = store.save(controller.columns, name: "Review")
        let savedTakeoff = store.save(controller.columns, name: "Takeoff")
        let review = try #require(savedReview)
        let takeoff = try #require(savedTakeoff)
        controller.layoutStore = store
        #expect(controller.layoutStore.activeLayoutID == takeoff.id)
        var reported: [LedgerColumnLayoutStore] = []
        controller.onLayoutStoreChange = { reported.append($0) }

        let item = try #require(menuItem(LedgerColumnMenuBuilder.menu(for: controller), path: ["Saved Layouts", "Review"]))
        controller.applyLayoutFromMenu(item)

        #expect(controller.layoutStore.activeLayoutID == review.id)
        #expect(reported.last?.activeLayoutID == review.id)
        let rebuilt = LedgerColumnMenuBuilder.menu(for: controller)
        #expect(menuItem(rebuilt, path: ["Saved Layouts", "Review"])?.state == .on)
        #expect(menuItem(rebuilt, path: ["Saved Layouts", "Takeoff"])?.state == .off)
    }

    // MARK: BH-731

    @Test("BH-731: turning Subtotals off clears group totals and leaves the headings")
    func subtotalsSwitch() throws {
        // Old output: no switch existed; group headers always drew their totals.
        let source = LedgerArrayRowSource(rows: LedgerFixtures.rows, columns: LedgerFixtures.columns)
        let host = LedgerTableHost(rowSource: source, mode: .grouped, groupingColumns: [.projectZone])
        host.controller.loadViewIfNeeded()
        let zoneA = try #require(host.controller.slice(forPath: "Zone A"))
        let area = try #require(host.controller.column(.planArea))
        #expect(host.controller.groupCellText(zoneA, column: area).isEmpty == false)

        host.setShowsSubtotals(false)
        #expect(host.showsSubtotals == false)
        #expect(host.controller.groupCellText(zoneA, column: area).isEmpty)
        let copied = try #require({ () -> String? in
            host.controller.outlineViewForTesting.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            return host.controller.copyText()
        }())
        #expect(copied.contains("Zone A (3)"), "the heading stays")
    }

    // MARK: BH-732

    @Test("BH-732: the host sets one unit policy and rounding for headers and totals bar")
    func hostUnitPolicy() throws {
        // Old output: no host API; controller.unitPolicy stayed .metric, so headers printed
        // metres while rows showed millimetres.
        let source = LedgerArrayRowSource(rows: LedgerFixtures.rows, columns: LedgerFixtures.columns)
        let host = LedgerTableHost(rowSource: source, mode: .grouped, groupingColumns: [.projectZone])
        host.controller.loadViewIfNeeded()
        host.controller.locale = Locale(identifier: "en_US_POSIX")
        let policy = LedgerUnitPolicy(length: .millimetre)
        host.setUnitPolicy(policy)
        host.setRounding(.integer)
        #expect(host.unitPolicy == policy)
        #expect(host.controller.unitPolicy == policy)
        #expect(host.rounding == .integer)
        let zoneA = try #require(host.controller.slice(forPath: "Zone A"))
        let length = try #require(host.controller.column(.planLength))
        // 12 + 8 + 20 m = 40 m = 40000 mm; the column declares "m", so the header keeps
        // the converted unit beside the number.
        let number = LedgerNumberFormatting.string(40_000, fractionDigits: 0, locale: Locale(identifier: "en_US_POSIX"))
        #expect(host.controller.groupCellText(zoneA, column: length) == "\(number) mm")
    }

    // MARK: BH-737

    @Test("BH-737: the swatch border follows an appearance change")
    func swatchBorderFollowsAppearance() throws {
        // Old output: the border kept the variant resolved at configure time.
        let column = try #require(LedgerFixtures.columns.first)
        let cell = LedgerCellView(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        let dark = try #require(NSAppearance(named: .darkAqua))
        let light = try #require(NSAppearance(named: .aqua))
        func resolved(_ appearance: NSAppearance) -> CGColor {
            var color = NSColor.clear.cgColor
            appearance.performAsCurrentDrawingAppearance { color = ZPDFColor.nsColor(.border).cgColor }
            return color
        }
        cell.appearance = dark
        cell.configure(text: "x", column: column, swatchColor: .systemRed, isDimmed: false, accessibilityLabel: "x")
        #expect(cell.swatchBorderColorForTesting == resolved(dark))

        cell.appearance = light
        cell.viewDidChangeEffectiveAppearance()
        #expect(cell.swatchBorderColorForTesting == resolved(light))
        #expect(resolved(light) != resolved(dark), "the token really differs between appearances")
    }
}
