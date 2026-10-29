import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFQuantityLedger

/// The core half: X-032 (a negated filter rule
/// reads a "No input" cell as the empty cell W-063 made it everywhere else).
@Suite("Iteration 7 — ledger core fixes")
struct Iter7LedgerCoreFixTests {

    // MARK: - X-032

    /// One Quotient column (`100 / [Divisor]`) holding every kind of cell at once:
    ///
    /// ```text
    /// row 0  Divisor 4      Quotient 100 / 4 = 25      a value
    /// row 1  Divisor 5      Quotient 100 / 5 = 20      a value
    /// row 2  Divisor blank  Quotient No input          missingInput (ADR-0040)
    /// row 3  cutout row     Quotient empty             a cutout carries no formula cell (ADR-0018)
    /// row 4  Divisor 0      Quotient ÷0                a refusal
    /// ```
    static func mixedQuotientStore() throws -> LedgerStore {
        let columns = try Iter5LedgerCoreFixTests.refusalColumns(withAdded: false)
        let divisor = Iter5LedgerCoreFixTests.divisor
        let cells: [(MeasurementTool, [ColumnID: LedgerCellValue])] = [
            (.area, [divisor: .number(.count(4))]),
            (.area, [divisor: .number(.count(5))]),
            (.area, [:]),
            (.polygonCutout, [:]),
            (.area, [divisor: .number(.count(0))])
        ]
        let markups = cells.enumerated().map { index, row in
            MarkupRecord(
                id: MarkupID(SyntheticLedger.deterministicUUID(7_300 + index)),
                documentID: DocumentID(SyntheticLedger.deterministicUUID(-1)),
                pageID: PageID(SyntheticLedger.deterministicUUID(-2)),
                kind: .measurement,
                tool: row.0,
                subject: "S",
                customValues: row.1,
                createdAt: SyntheticLedger.epoch,
                modifiedAt: SyntheticLedger.epoch
            )
        }
        return try LedgerStore(markups: markups, columns: columns)
    }

    @Test("X-032: the fixture holds a value, a No input cell, an empty cell and a refusal in one column")
    func fixtureHoldsEveryKindOfCell() throws {
        let store = try Self.mixedQuotientStore()
        let quotient = Iter5LedgerCoreFixTests.quotient
        #expect(store.value(at: 0, column: quotient).quantity == .count(25))
        #expect(store.value(at: 1, column: quotient).quantity == .count(20))
        #expect(store.value(at: 2, column: quotient).cellError?.kind == .missingInput)
        #expect(store.value(at: 3, column: quotient) == .empty)
        #expect(store.value(at: 4, column: quotient).cellError?.kind == .divisionByZero)
    }

    /// Every positive operator and its negation split the four non-error rows (0, 1, 2, 3)
    /// between them, each row exactly once; the refusal (row 4) matches neither.
    ///
    /// Old output: every negation dropped row 2 (No input) and kept row 3 (empty), so row 2
    /// was in neither half — "is not 25" [1, 3], "does not contain 2" [0, 1, 3] and
    /// "is none of {25}" [0, 1, 3].
    @Test("X-032: 'is X' and 'is not X' cover every non-error row exactly once, No input included")
    func negationsAreExactComplements() throws {
        let store = try Self.mixedQuotientStore()
        let quotient = Iter5LedgerCoreFixTests.quotient
        let evaluator = LedgerFilterEvaluator(store: store)
        let all = Array(0..<store.rowCount)
        let nonError = [0, 1, 2, 3]

        let pairs: [(LedgerFilterRule, LedgerFilterRule, [Int])] = [
            (
                LedgerFilterRule(column: quotient, op: .equals, value: .number(25)),
                LedgerFilterRule(column: quotient, op: .notEquals, value: .number(25)),
                [1, 2, 3]
            ),
            (
                LedgerFilterRule(column: quotient, op: .contains, value: .text("2")),
                LedgerFilterRule(column: quotient, op: .notContains, value: .text("2")),
                [0, 1, 2, 3]
            ),
            (
                LedgerFilterRule(column: quotient, op: .inSet, value: .textSet(["25"])),
                LedgerFilterRule(column: quotient, op: .notInSet, value: .textSet(["25"])),
                [0, 1, 2, 3]
            )
        ]
        for (positive, negative, expectedNegative) in pairs {
            let yes = evaluator.filter(all, with: .rule(positive))
            let no = evaluator.filter(all, with: .rule(negative))
            #expect(no == expectedNegative, "\(negative.op)")
            #expect(Set(yes).isDisjoint(with: no), "\(positive.op) and \(negative.op) overlap")
            #expect((yes + no).sorted() == nonError, "\(positive.op) ∪ \(negative.op) must be every non-error row")
            // The single-row path is the same compiled rule.
            #expect(all.filter { evaluator.matches(rowIndex: $0, node: .rule(negative)) } == no)
        }
    }

    /// The No input cell reads as the empty cell for every operator, not only the negations:
    /// whatever a rule says about row 3 (empty), it says about row 2 (No input).
    @Test("X-032: a No input cell answers every operator the way an empty cell does")
    func noInputAnswersLikeEmpty() throws {
        let store = try Self.mixedQuotientStore()
        let quotient = Iter5LedgerCoreFixTests.quotient
        let evaluator = LedgerFilterEvaluator(store: store)
        let operands: [LedgerFilterOperator: LedgerFilterValue] = [
            .equals: .number(25), .notEquals: .number(25),
            .lessThan: .number(30), .lessThanOrEqual: .number(30),
            .greaterThan: .number(0), .greaterThanOrEqual: .number(0),
            .between: .numberRange(lower: 0, upper: 100),
            .contains: .text("2"), .notContains: .text("2"),
            .beginsWith: .text("2"), .endsWith: .text("5"),
            .isEmpty: .none, .isNotEmpty: .none, .isTrue: .none, .isFalse: .none,
            .inSet: .textSet(["25"]), .notInSet: .textSet(["25"])
        ]
        for op in LedgerFilterOperator.allCases {
            let rule = LedgerFilterNode.rule(LedgerFilterRule(column: quotient, op: op, value: operands[op] ?? .none))
            #expect(
                evaluator.matches(rowIndex: 2, node: rule) == evaluator.matches(rowIndex: 3, node: rule),
                "\(op): No input and empty disagree"
            )
            #expect(!evaluator.matches(rowIndex: 4, node: rule), "\(op): a refusal matches nothing")
        }
    }
}
