import Foundation
import Testing
import ZPDFQuantityLedger
import ZPDFUIPresentation
@testable import ZPDFUILedger

/// Asserts the filter really filters, in every operator family the builder offers — on the
/// evaluator the application filters with.
///
/// Until loop iteration 1 (R-126) these tests ran this package's own `LedgerFilterEvaluator`,
/// which nothing shipping ever constructed; the ledger is filtered by the aggregation core's
/// ``ZPDFQuantityLedger/LedgerFilterEvaluator``, behind the application's seam
/// (`LedgerSpecBuilder.filter` in ZPDFAppCore), which turns the builder's tree into the core's
/// nodes — "contains" into `.contains`, "is any of" into `.inSet`, an "all" group into `.and`,
/// an inverted group into `.not`. Each test now builds that node over the same six rows
/// (``LiveLedgerFixture``) and expects the same count.
///
/// Three of the old tests only exercised the duplicate's regex guard — its pattern length and
/// nesting limits and its per-pass budget. The live engine has no regex operator by design
/// (QUALITY_BAR A23): the seam drops a pattern rule and the panel says so,
/// which ``LedgerFilterDiagnostic/unappliedRules(in:columns:)`` asserts in
/// `LedgerCodeReviewRegressionTests` and `Fix2U2FilterTests`. Those three went with it.
@Suite("Ledger filter evaluation (live engine)", .ledgerTierSerialised)
struct LedgerFilterEvaluatorTests {

    private typealias Fixture = LiveLedgerFixture

    @Test("An empty filter keeps every row")
    func emptyFilterKeepsEverything() throws {
        let store = try Fixture.store()
        // The seam turns a group with no enabled rule into `.all`.
        #expect(LedgerFixtures.group(.all).isEmpty)
        #expect(Fixture.count(.all, in: store) == LedgerFixtures.rows.count)
        #expect(Fixture.count(.and([]), in: store) == LedgerFixtures.rows.count)
    }

    @Test("Text contains matches whatever the case")
    func textContains() throws {
        let store = try Fixture.store()
        #expect(Fixture.count(Fixture.rule(Fixture.subject, .contains, .text("cONCRETE")), in: store) == 2)
    }

    @Test("Begins with and ends with anchor to their edge")
    func anchoredText() throws {
        let store = try Fixture.store()
        #expect(Fixture.count(Fixture.rule(Fixture.label, .beginsWith, .text("C-")), in: store) == 2)
        #expect(Fixture.count(Fixture.rule(Fixture.label, .endsWith, .text("-01")), in: store) == 3)
    }

    @Test("Numeric comparisons read the SI base value, not the formatted string")
    func numericComparison() throws {
        let store = try Fixture.store()
        #expect(Fixture.count(Fixture.rule(Fixture.planArea, .greaterThanOrEqual, .number(40)), in: store) == 3)
    }

    @Test("Between is inclusive at both ends")
    func betweenIsInclusive() throws {
        let store = try Fixture.store()
        // 5 m and 12 m sit exactly on the bounds and are kept.
        let forward = Fixture.rule(Fixture.planLength, .between, .numberRange(lower: 5, upper: 12))
        #expect(Fixture.count(forward, in: store) == 3)
    }

    @Test("Is any of matches stored choice values, not display titles")
    func choiceMembership() throws {
        let store = try Fixture.store()
        // The builder sends option values; the seam forwards them as a text set.
        #expect(Fixture.count(Fixture.rule(Fixture.approval, .inSet, .textSet(["approved"])), in: store) == 4)
        #expect(Fixture.count(Fixture.rule(Fixture.approval, .inSet, .textSet(["Approved"])), in: store) == 0)
    }

    @Test("AND and OR combine as written, and a nested group is evaluated first")
    func conjunctions() throws {
        let store = try Fixture.store()
        let and = LedgerFilterNode.and([
            Fixture.rule(Fixture.zone, .equals, .text("Zone A")),
            Fixture.rule(Fixture.trade, .equals, .text("Concrete"))
        ])
        #expect(Fixture.count(and, in: store) == 2)

        let or = LedgerFilterNode.or([
            Fixture.rule(Fixture.trade, .equals, .text("Glazing")),
            Fixture.rule(Fixture.trade, .equals, .text("Drywall"))
        ])
        #expect(Fixture.count(or, in: store) == 4)

        let nested = LedgerFilterNode.and([
            Fixture.rule(Fixture.approval, .inSet, .textSet(["approved"])),
            or
        ])
        #expect(Fixture.count(nested, in: store) == 3)
    }

    @Test("An inverted group flips its own result only")
    func negation() throws {
        let store = try Fixture.store()
        let inverted = LedgerFilterNode.not(.and([Fixture.rule(Fixture.trade, .equals, .text("Concrete"))]))
        #expect(Fixture.count(inverted, in: store) == 4)
    }
}

/// Saved filters and the tree editor, which live in this package and ship.
@Suite("Ledger saved filters", .ledgerTierSerialised)
struct LedgerSavedFilterTests {

    @Test("Filter trees can be edited, saved and restored by name")
    func savedFiltersRoundTrip() throws {
        var store = LedgerSavedFilterStore()
        let filter = LedgerFixtures.group(.all, rules: [
            LedgerFixtures.rule(.trade, .equals, .text("Glazing"))
        ])
        store.save(name: "Glazing only", filter: filter)
        store.save(name: "  ", filter: filter)
        #expect(store.filters.count == 1)

        let data = try store.encoded()
        let restored = try LedgerSavedFilterStore.decoded(from: data)
        #expect(restored.filter(named: "glazing only")?.filter == filter)

        let cleared = LedgerFilterTreeEditor.cleared(filter)
        #expect(cleared.isEmpty)
        #expect(cleared.id == filter.id)
    }
}
