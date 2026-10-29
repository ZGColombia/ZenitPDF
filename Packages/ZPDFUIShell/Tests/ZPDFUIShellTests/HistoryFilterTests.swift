import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIShell

/// CR-115 — the History pane's "Selected Markup" filter pinned itself to whatever was selected
/// when the box was ticked and never looked again.
///
/// The id was *written* into the filter from inside the checkbox's `Binding.set`, so clicking
/// the next markup left the trail showing the previous one's changes under a checkbox that
/// still said "Selected Markup" — the worst kind of wrong, because it looks right.
@MainActor
@Suite("History selection filter", .shellTierSerialised)
struct HistoryFilterTests {

    private func makeEnvironment() -> ProjectShellEnvironment { .mock() }

    /// The rule the old code implemented, kept as a control so this test states what it is
    /// defending against and not only what it wants. `pinned` is the id captured at tick time.
    private func oldRule(base: LedgerAuditFilter, pinned: UUID?) -> LedgerAuditFilter {
        var filter = base
        filter.markupID = pinned
        return filter
    }

    /// The old rule lived inside a `Binding.set` where no test could reach it, so it is stated
    /// as the control above, and the old behaviour was measured by making `effectiveFilter`
    /// ignore the selection and return `base` — which is what a filter written once at tick
    /// time does. Old output:
    ///
    /// ```
    /// ✘ Test "The trail follows the selection instead of the tick" recorded an issue at
    ///   HistoryFilterTests.swift:56:9: Expectation failed:
    ///   (followed.markupID → nil) == (second → F484327F-49C5-4863-BEC5-8828A52BFD09)
    /// ```
    @Test("The trail follows the selection instead of the tick")
    func theTrailFollowsTheSelection() throws {
        let base = LedgerAuditFilter()
        let first = UUID(), second = UUID()

        // Ticked while `first` was selected.
        let pinnedAtTick = oldRule(base: base, pinned: first)
        #expect(pinnedAtTick.markupID == first)

        // The person clicks the next markup. The old rule shows the previous one's changes.
        #expect(
            oldRule(base: base, pinned: first).markupID != second,
            "the control is only meaningful while the old rule really does pin"
        )

        // The rule now.
        let followed = HistoryPaneContent.effectiveFilter(
            base: base,
            followsSelection: true,
            selection: [second]
        )
        #expect(followed.markupID == second)
    }

    @Test("Following an empty selection shows nothing rather than the last markup")
    func anEmptySelectionEmptiesTheTrail() {
        let filter = HistoryPaneContent.effectiveFilter(
            base: LedgerAuditFilter(),
            followsSelection: true,
            selection: []
        )
        // BH-293: nil meant "no markup filter" — the WHOLE trail. The filter now names the
        // identity no markup has.
        #expect(filter.markupID == HistoryPaneContent.noMarkup)
    }

    @Test("Following a multi-selection shows nothing rather than one arbitrary member")
    func aMultiSelectionIsNotOneMarkup() {
        let filter = HistoryPaneContent.effectiveFilter(
            base: LedgerAuditFilter(),
            followsSelection: true,
            selection: [UUID(), UUID(), UUID()]
        )
        #expect(
            filter.markupID == HistoryPaneContent.noMarkup,
            "'the selected markup's changes' has no meaning for three of them"
        )
    }

    @Test("With the box unticked the selection is ignored entirely")
    func anUntickedFilterIgnoresTheSelection() {
        let filter = HistoryPaneContent.effectiveFilter(
            base: LedgerAuditFilter(),
            followsSelection: false,
            selection: [UUID()]
        )
        #expect(filter.markupID == nil)
        #expect(filter.isEmpty)
    }

    @Test("The other two filters are carried through untouched")
    func theOtherFiltersAreCarried() {
        var base = LedgerAuditFilter()
        base.pageLabel = "A-102"
        base.action = "measure"
        let filter = HistoryPaneContent.effectiveFilter(
            base: base,
            followsSelection: true,
            selection: []
        )
        #expect(filter.pageLabel == "A-102")
        #expect(filter.action == "measure")
    }

    @Test("The trail really answers with the followed markup's events, end to end")
    func theTrailAnswersForTheFollowedMarkup() throws {
        let environment = makeEnvironment()
        let audit = try #require(environment.ledger as? LedgerAuditPresenting)
        let all = audit.auditEvents(matching: LedgerAuditFilter())
        let subjects = Set(all.compactMap(\.markupID))
        try #require(subjects.count >= 2)
        let ordered = Array(subjects).sorted { $0.uuidString < $1.uuidString }
        let first = ordered[0], second = ordered[1]

        let firstEvents = audit.auditEvents(matching: HistoryPaneContent.effectiveFilter(
            base: LedgerAuditFilter(), followsSelection: true, selection: [first]
        ))
        #expect(!firstEvents.isEmpty)
        #expect(firstEvents.allSatisfy { $0.markupID == first })

        // The selection moves; so does the trail.
        let secondEvents = audit.auditEvents(matching: HistoryPaneContent.effectiveFilter(
            base: LedgerAuditFilter(), followsSelection: true, selection: [second]
        ))
        #expect(!secondEvents.isEmpty)
        #expect(secondEvents.allSatisfy { $0.markupID == second })
        #expect(firstEvents.map(\.id) != secondEvents.map(\.id))
    }
}
