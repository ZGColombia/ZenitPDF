import Foundation
import Testing
import ZPDFUILedger
import ZPDFUIPresentation
@testable import ZPDFUIShell

/// Type grouping at the pane level: the docked Quantity Ledger opens grouped by
/// measurement type, the grouping choice and the collapsed groups persist, "no grouping"
/// remains a stored choice of its own, and selection still round-trips the presenter.
@MainActor
@Suite("Quantity Ledger pane grouping", .shellTierSerialised)
struct LedgerPaneGroupingTests {

    /// A defaults suite that never touches the user's real preferences — and never leaves a
    /// new plist in them either. This fixture used to mint eighteen
    /// `zenit.test.ledgerpane.<UUID>` files in six runs of `build-ui-packages.sh`, and 254 of
    /// the 2 634 `zenit` plists on a development machine were its UUIDs. One fixed name now,
    /// emptied on both sides; safe because this target is serialised
    /// (``ShellTierSerialisation``), so one test holds the prefix at a time.
    private func makeDefaults() throws -> (UserDefaults, () -> Void) {
        let (defaults, name) = try ShellScratchDefaults.make(prefix: "zenit.test.ledgerpane")
        return (defaults, { ShellScratchDefaults.discard(defaults, suiteName: name) })
    }

    @Test("The pane opens grouped by measurement type by default")
    func defaultGroupingIsByType() throws {
        let (defaults, tearDown) = try makeDefaults()
        defer { tearDown() }
        let environment = ProjectShellEnvironment.mock()
        let model = LedgerPaneModel(
            presenter: environment.ledger,
            preferences: LedgerPanePreferences(defaults: defaults)
        )
        #expect(model.groupingColumns == [.icon])
        #expect(model.host.controller.mode == .grouped)

        // Loading the table builds the plan: the sample project's rows partition by tool.
        model.host.controller.loadViewIfNeeded()
        model.refresh()
        let plan = model.host.controller.plan
        #expect(!plan.groups.isEmpty)
        #expect(plan.order.count == environment.ledger.rowCount)
        let titles = Set(plan.groups.map(\.title))
        #expect(titles.contains(MeasurementKind.area.displayName))
        // Every group header carries its count and, where units agree, one merged total
        // in the display Value column — the summary shape type grouping needs.
        for group in plan.groups {
            #expect(group.rowCount > 0)
        }
        let area = plan.groups.first { $0.title == MeasurementKind.area.displayName }
        #expect(area?.subtotals.result(LedgerDefaultColumns.valueColumnID)?.quantity?.dimension == .area)
    }

    @Test("Grouping never changes any total: the grand totals match the flat list's")
    func groupingKeepsGrandTotals() throws {
        let (defaults, tearDown) = try makeDefaults()
        defer { tearDown() }
        let environment = ProjectShellEnvironment.mock()
        let model = LedgerPaneModel(
            presenter: environment.ledger,
            preferences: LedgerPanePreferences(defaults: defaults)
        )
        model.host.controller.loadViewIfNeeded()
        model.refresh()
        let grouped = model.host.controller.plan.grandSubtotals

        model.setGrouping([])
        let flat = model.host.controller.plan.grandSubtotals
        #expect(grouped.rowCount == flat.rowCount)
        for column in [LedgerColumnID.planLength, .planArea, .perimeter, .count] {
            #expect(grouped.result(column) == flat.result(column), "\(column) changed under grouping")
        }
    }

    @Test("The grouping choice persists, and 'no grouping' is a stored choice, not a fallback")
    func groupingChoicePersists() throws {
        let (defaults, tearDown) = try makeDefaults()
        defer { tearDown() }
        let environment = ProjectShellEnvironment.mock()
        let preferences = LedgerPanePreferences(defaults: defaults)
        let model = LedgerPaneModel(presenter: environment.ledger, preferences: preferences)

        model.setGrouping([.subject])
        #expect(LedgerPanePreferences(defaults: defaults).groupingColumns == [.subject])

        model.setGrouping([])
        #expect(LedgerPanePreferences(defaults: defaults).groupingColumns == [])

        // A fresh pane over the same defaults opens flat — the user's explicit choice —
        // never silently back on the default.
        let reopened = LedgerPaneModel(
            presenter: environment.ledger,
            preferences: LedgerPanePreferences(defaults: defaults)
        )
        #expect(reopened.groupingColumns.isEmpty)
        #expect(reopened.host.controller.mode == .flat)
    }

    @Test("Collapsed groups persist across panes")
    func collapsedStatePersistsAcrossPanes() throws {
        let (defaults, tearDown) = try makeDefaults()
        defer { tearDown() }
        let environment = ProjectShellEnvironment.mock()
        let model = LedgerPaneModel(
            presenter: environment.ledger,
            preferences: LedgerPanePreferences(defaults: defaults)
        )
        model.host.controller.loadViewIfNeeded()
        model.refresh()
        let path = try #require(model.host.controller.plan.groups.first?.path)

        model.host.controller.collapseAllGroups()
        #expect(LedgerPanePreferences(defaults: defaults).collapsedGroupPaths.contains(path))

        let reopened = LedgerPaneModel(
            presenter: environment.ledger,
            preferences: LedgerPanePreferences(defaults: defaults)
        )
        reopened.host.controller.loadViewIfNeeded()
        reopened.refresh()
        #expect(reopened.host.controller.collapsedGroupPaths.contains(path))
    }

    @Test("Selecting in the table routes through the presenter; canvas selection never echoes")
    func selectionRoundTrip() throws {
        let (defaults, tearDown) = try makeDefaults()
        defer { tearDown() }
        let environment = ProjectShellEnvironment.mock()
        let model = LedgerPaneModel(
            presenter: environment.ledger,
            preferences: LedgerPanePreferences(defaults: defaults)
        )
        model.host.controller.loadViewIfNeeded()
        model.refresh()

        let rowID = try #require(environment.ledger.row(at: 0)?.markupID)
        model.host.onSelectionChange?([rowID])
        #expect(environment.ledger.selectedRowIDs == [rowID])

        // A canvas-driven selection lands in the table without bouncing back.
        let other = try #require(environment.ledger.row(at: 1)?.markupID)
        model.applyExternalSelection([other])
        #expect(model.host.selectedRowIDs == [other])
    }

    @Test("The pane's grouping menu leads with Type and keeps every existing level")
    func groupingMenuVocabulary() {
        let options = LedgerPaneModel.groupingOptions
        #expect(options.first?.column == .icon)
        let columns = options.map(\.column)
        for expected in [LedgerColumnID.subject, .label, .pageLabel, .projectZone, .status] {
            #expect(columns.contains(expected), "\(expected) missing from the grouping menu")
        }
    }
}
