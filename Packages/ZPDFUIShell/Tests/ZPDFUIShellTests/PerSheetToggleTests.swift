import Foundation
import Testing
import ZPDFUILedger
import ZPDFUIPresentation
@testable import ZPDFUIShell

/// The header's one-click switch between the per-sheet summary and the combined
/// whole-document view: the summary separated per sheet, and one button that merges it all.
///
/// The grouping machinery already existed behind *Group by ▸ Page*; what is pinned here is the
/// part a menu item never had to get right — that switching back lands on the grouping the
/// person was reading before, rather than dropping them into the flat list.
@MainActor
@Suite("Quantity Ledger per-sheet toggle", .shellTierSerialised)
struct PerSheetToggleTests {

    /// A defaults suite that never touches the user's real preferences and never leaves a new
    /// plist in them either. The ledger pane's existing prefix rather
    /// than one of its own: a new prefix costs the machine one more permanent plist, and the
    /// domain is emptied on entry and exit under a target that admits one test at a time
    /// (``ShellTierSerialisation``), so sharing it cannot bleed.
    private func makeModel() throws -> (LedgerPaneModel, () -> Void) {
        let (defaults, name) = try ShellScratchDefaults.make(prefix: "zenit.test.ledgerpane")
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
        let model = LedgerPaneModel(
            presenter: environment.ledger,
            preferences: LedgerPanePreferences(defaults: defaults)
        )
        return (model, { ShellScratchDefaults.discard(defaults, suiteName: name) })
    }

    @Test("Switching the toggle on groups the ledger by sheet")
    func togglingOnGroupsByPage() throws {
        let (model, tearDown) = try makeModel()
        defer { tearDown() }
        #expect(!model.isGroupedBySheet, "the pane must not open already in the detour")

        model.toggleSheetGrouping()
        #expect(model.groupingColumns == [.pageLabel])
        #expect(model.host.controller.mode == .grouped)
    }

    @Test("Switching it off restores the grouping that was in force before, not the flat list")
    func togglingOffRestoresThePreviousGrouping() throws {
        let (model, tearDown) = try makeModel()
        defer { tearDown() }
        model.setGrouping([.subject])

        model.toggleSheetGrouping()
        #expect(model.groupingColumns == [.pageLabel])

        model.toggleSheetGrouping()
        #expect(model.groupingColumns == [.subject], """
            the switch back dropped the reader's grouping. Combining the sheets is a detour \
            from whatever they were reading, and a return that forgets it costs a menu walk.
            """)
        #expect(model.host.controller.mode == .grouped)
    }

    @Test("Two presses are identity, from the flat list and from a grouping alike")
    func togglingTwiceIsIdentity() throws {
        let (model, tearDown) = try makeModel()
        defer { tearDown() }

        let starts: [[LedgerColumnID]] = [[], [.icon], [.subject], [.projectZone]]
        for start in starts {
            model.setGrouping(start)
            model.toggleSheetGrouping()
            model.toggleSheetGrouping()
            #expect(model.groupingColumns == start, "two presses moved \(start) to \(model.groupingColumns)")
        }
    }

    @Test("A pane reopened already grouped by sheet combines to the flat list and stays togglable")
    func combiningWithNothingRememberedFallsToTheFlatList() throws {
        let (model, tearDown) = try makeModel()
        defer { tearDown() }
        // The persisted state a person left the pane in: per sheet, with no in-memory memory
        // of what came before it.
        model.setGrouping([.pageLabel])
        #expect(model.isGroupedBySheet)

        model.toggleSheetGrouping()
        #expect(model.groupingColumns.isEmpty, "the combined view is the whole document in one list")
        #expect(model.host.controller.mode == .flat)

        model.toggleSheetGrouping()
        #expect(model.groupingColumns == [.pageLabel])
    }

    @Test("isGroupedBySheet reflects the state, and claims only the grouping it can put back")
    func isGroupedBySheetReflectsState() throws {
        let (model, tearDown) = try makeModel()
        defer { tearDown() }

        model.setGrouping([])
        #expect(!model.isGroupedBySheet)
        model.setGrouping([.pageLabel])
        #expect(model.isGroupedBySheet)
        model.setGrouping([.subject])
        #expect(!model.isGroupedBySheet)
        // Page-outermost but multi-level is a different view; the toggle must not claim it,
        // because pressing it would silently discard the inner level.
        model.setGrouping([.pageLabel, .subject])
        #expect(!model.isGroupedBySheet)

        model.toggleSheetGrouping()
        #expect(model.isGroupedBySheet)
        model.toggleSheetGrouping()
        #expect(model.groupingColumns == [.pageLabel, .subject])
    }

    @Test("The toggle writes through the same persisted choice the grouping menu does")
    func theToggleChoicePersists() throws {
        let (defaults, name) = try ShellScratchDefaults.make(prefix: "zenit.test.ledgerpane")
        defer { ShellScratchDefaults.discard(defaults, suiteName: name) }
        let mocks = MockPresenters.makeEnvironment()
        let preferences = LedgerPanePreferences(defaults: defaults)
        let model = LedgerPaneModel(presenter: mocks.ledger, preferences: preferences)

        // The pane opens on the default, grouped by measurement type.
        let opened = model.groupingColumns
        #expect(opened == [.icon])

        model.toggleSheetGrouping()
        #expect(LedgerPanePreferences(defaults: defaults).groupingColumns == [.pageLabel])

        // The restore is persisted too, so a pane reopened after the detour is where the
        // person left it rather than back on the sheet grouping.
        model.toggleSheetGrouping()
        #expect(LedgerPanePreferences(defaults: defaults).groupingColumns == opened)
        let reopened = LedgerPaneModel(
            presenter: mocks.ledger,
            preferences: LedgerPanePreferences(defaults: defaults)
        )
        #expect(!reopened.isGroupedBySheet)
    }
}
