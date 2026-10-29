import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFQuantityLedger
import ZPDFUIPresentation

/// W-042: the Inspector's Custom Data reads a selected markup's
/// stored values whatever the ledger's filter. The application's presenter answers
/// `unfilteredRows(withIDs:)` from the store; `rows(withIDs:)` resolves through `index(of:)`,
/// which is `nil` for a row the filter hides.
@MainActor
@Suite("Iteration 6 — unfiltered ledger rows")
struct Iter6UIShellUnfilteredRowsTests {

    /// Old output: no such requirement; the Inspector read `rows(withIDs:)` and got `[]` for a
    /// row the filter hid, so every custom value of that markup read "—".
    @Test("W-042: a row the filter hides is still answered from the store, and says it is filtered out")
    func unfilteredRowsIgnoreTheFilter() async throws {
        let session = try await AppLedgerPresenterOutlineTests.session(AppLedgerPresenterOutlineTests.specs)
        let ids = try await AppLedgerPresenterOutlineTests.columns(session)
        let presenter = try await AppLedgerPresenterOutlineTests.presenter(session, grouping: [])
        let all = (0..<presenter.rowCount).compactMap { presenter.row(at: $0) }
        let a = try #require(all.first { $0.displayValue(ids.subject) == "A" })
        let b = try #require(all.first { $0.displayValue(ids.subject) == "B" })

        presenter.setFilter(LedgerFilterGroup(id: UUID(), rules: [
            LedgerFilterRule(id: UUID(), column: ids.subject, comparison: .equals, operand: .text("B"))
        ]))
        await presenter.refresh()
        #expect(presenter.rowCount == 3)
        #expect(presenter.rows(withIDs: [a.markupID]).isEmpty, "the filter hides A")

        let answered = presenter.unfilteredRows(withIDs: [a.markupID, b.markupID])
        #expect(Set(answered.map(\.markupID)) == [a.markupID, b.markupID])
        let hidden = try #require(answered.first { $0.markupID == a.markupID })
        #expect(hidden.displayValue(ids.subject) == "A")
        #expect(hidden.displayValue(ids.planArea) == a.displayValue(ids.planArea), "the same cell, the same path")
        #expect(!hidden.matchesFilter)
        #expect(answered.first { $0.markupID == b.markupID }?.matchesFilter == true)

        // Through the protocol, as the shell holds the presenter.
        let existential: any LedgerPresenting = presenter
        #expect(existential.unfilteredRows(withIDs: [a.markupID]).count == 1)
    }
}
