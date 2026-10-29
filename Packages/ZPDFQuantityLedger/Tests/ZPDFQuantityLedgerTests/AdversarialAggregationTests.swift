import Foundation
import Testing
import ZPDFContracts
import ZPDFFormulaEngine
@testable import ZPDFQuantityLedger

/// Data built specifically to break the aggregation core, rather than to demonstrate it.
///
/// Each case here is a construction where a plausible implementation gives a *visibly* wrong
/// answer — not one off in the fifteenth digit, but one a quantity surveyor would notice on an
/// invoice. Every one must either come out exactly right or fail with a typed error; "close" is
/// a failure.
///
/// The six attacks, and what each would break:
///
/// | Attack | What it breaks |
/// |---|---|
/// | Values needing more decimals than the column shows | a subtotal summed from displayed values |
/// | A group total against its rounded children | double rounding at the group boundary |
/// | A filter cutting through the middle of a group | a subtotal computed over the group's *stored* rows |
/// | A formula reading another formula | an evaluation order that is not a topological sort |
/// | `0.1 + 0.2` and friends | any `Double` in the aggregation path |
/// | 100 000 terms spanning 1e-6 to 1e6 | the same, at a magnitude where `Double` drift is visible |
@Suite("Adversarial aggregation")
struct AdversarialAggregationTests {

    static let value = HandBuiltLedger.valueColumn
    static let subject = HandBuiltLedger.subjectColumn

    static func count(_ decimal: Decimal) -> LedgerCellValue { .number(.count(decimal)) }

    /// A `Decimal` written as an exact significand and exponent, never through a `Double` literal.
    /// `Decimal(0.1)` is the binary double 0.1000000000000000055511151231257827, and a test that
    /// used it would be testing the literal rather than the summation.
    static func exact(_ significand: UInt64, _ exponent: Int) -> Decimal {
        Decimal(sign: .plus, exponent: exponent, significand: Decimal(significand))
    }

    static func grandSum(_ store: LedgerStore, _ column: ColumnID) throws -> Decimal {
        let view = store.makeView(LedgerViewSpec(aggregation: HandBuiltLedger.plan([column])))
        let total = try #require(view.grandTotal[column])
        return try #require(total.decimal)
    }

    // MARK: - 1. Double rounding

    /// `0.1 + 0.2 == 0.3`, exactly, and the three other traps that catch a `Double` in the path.
    ///
    /// In binary `Double`, `0.1 + 0.2` is `0.30000000000000004`, `0.1 * 3` is
    /// `0.30000000000000004`, and `2.675` rounds to `2.67` at two places rather than `2.68`
    /// because it is stored as `2.67499999999999982236431605997495353221893310546875`. All four
    /// must come out exact here, and the comparison is against a `Decimal` built from an exact
    /// significand rather than from a `Double` literal.
    @Test("0.1 + 0.2 is exactly 0.3, and 2.675 rounds up, not down")
    func decimalTraps() throws {
        let tenth = Self.exact(1, -1)
        let fifth = Self.exact(2, -1)
        let threeTenths = Self.exact(3, -1)

        #expect(try DecimalSummation.add(tenth, fifth) == threeTenths)
        #expect(try DecimalSummation.sum([tenth, tenth, tenth]) == threeTenths)
        #expect(try DecimalSummation.sum(Array(repeating: tenth, count: 10)) == 1)

        // Through the real ledger, not just the primitive.
        let store = try HandBuiltLedger.makeStore(rows: [
            [Self.value: Self.count(tenth)],
            [Self.value: Self.count(fifth)]
        ])
        #expect(try Self.grandSum(store, Self.value) == threeTenths)

        // 2.675 at two decimal places. `.plain` is half-away-from-zero and the value is exact as
        // a Decimal, so 2.68 — the answer arithmetic gives, not the one binary storage gives.
        var rounded = Decimal()
        var subject = Self.exact(2675, -3)
        NSDecimalRound(&rounded, &subject, 2, .plain)
        #expect(rounded == Self.exact(268, -2))
    }

    /// Rounding must happen exactly once, at the boundary, and never to an already-rounded input.
    ///
    /// The trap: `0.4449` is `0.44` at two places, but `0.445` at three places and then `0.45` at
    /// two. A pipeline that rounds for the cell and then rounds the cell for the export produces
    /// the second answer. So does one that rounds each row before adding.
    @Test("Rounding twice never happens: 0.4449 is 0.44, and 3 x 0.4449 sums raw")
    func noDoubleRounding() throws {
        let awkward = Self.exact(4449, -4)
        let store = try HandBuiltLedger.makeStore(rows: [
            [Self.value: Self.count(awkward)],
            [Self.value: Self.count(awkward)],
            [Self.value: Self.count(awkward)]
        ])
        // 3 x 0.4449 = 1.3347 exactly. Rounding each row to two places first gives 1.32, and to
        // three places first gives 1.335 -> 1.34 at two. Neither may appear.
        #expect(try Self.grandSum(store, Self.value) == Self.exact(13347, -4))

        let view = store.makeView(LedgerViewSpec(aggregation: HandBuiltLedger.plan([Self.value])))
        let report = LedgerReportBuilder(timestamps: FixedTimestampProvider(SyntheticLedger.epoch))
            .makeReport(view, title: "rounding")
        let total = try #require(
            report.grandTotals.first { $0.column == Self.value && $0.function == .sum }
        )
        // The export carries the exact value as well as the display one, so nothing downstream
        // has to re-derive it from a string.
        #expect(try #require(total.rawDecimal) == Self.exact(13347, -4))
    }

    // MARK: - 2. A subtotal computed from rounded children

    /// Ten rows of `0.0499` in each of three groups, on a column that displays three decimals.
    ///
    /// ```text
    /// exact per group   10 x 0.0499                       = 0.499
    /// exact grand       3 x 0.499                         = 1.497
    /// if rows round first (3 dp)   10 x 0.050  = 0.500     -> 1.500   wrong by 0.003
    /// if groups round first (2 dp)  3 x 0.50   = 1.50      -> 1.50    wrong by 0.003
    /// ```
    ///
    /// 0.2 % on a concrete order, and invisible in any test whose fixture happens to use values
    /// that survive rounding.
    @Test("A group subtotal is the exact sum of raw rows, never of rounded children")
    func subtotalsComeFromRawValues() throws {
        let awkward = Self.exact(499, -4)
        var rows: [[ColumnID: LedgerCellValue]] = []
        var subjects: [String] = []
        for group in 0..<3 {
            for _ in 0..<10 {
                rows.append([Self.value: Self.count(awkward)])
                subjects.append("G\(group)")
            }
        }
        let store = try HandBuiltLedger.makeStore(rows: rows, subjects: subjects)
        let view = store.makeView(
            LedgerViewSpec(
                grouping: [LedgerGroupingField(column: Self.subject)],
                aggregation: HandBuiltLedger.plan([Self.value])
            )
        )
        #expect(view.tree.roots.count == 3)

        var sumOfSubtotals = Decimal.zero
        for group in view.tree.roots {
            let subtotal = try #require(group.aggregates[Self.value]?.decimal)
            #expect(subtotal == Self.exact(499, -3), "group subtotal was \(subtotal)")
            sumOfSubtotals += subtotal
        }
        let grand = try #require(view.grandTotal[Self.value]?.decimal)
        #expect(grand == Self.exact(1497, -3))
        #expect(grand == sumOfSubtotals, "the grand total is not the sum of the subtotals")
        // The two wrong answers a rounding-first pipeline gives.
        #expect(grand != Self.exact(15, -1))
        #expect(grand != Self.exact(150, -2))
    }

    /// Three levels deep, with a value at each level that only reconciles if every level merges
    /// raw accumulators. `1/3`-like thirds are used so that any division-then-remultiplication in
    /// the middle shows up immediately.
    @Test("Nested subtotals reconcile exactly three levels down")
    func nestedSubtotalsReconcile() throws {
        let text = HandBuiltLedger.textColumn
        var rows: [[ColumnID: LedgerCellValue]] = []
        var subjects: [String] = []
        for outer in 0..<4 {
            for inner in 0..<5 {
                for leaf in 0..<6 {
                    let value = Self.exact(UInt64(1 + outer * 100 + inner * 10 + leaf), -7)
                    rows.append([Self.value: Self.count(value), text: .text("I\(inner)")])
                    subjects.append("O\(outer)")
                }
            }
        }
        let store = try HandBuiltLedger.makeStore(rows: rows, subjects: subjects)
        let view = store.makeView(
            LedgerViewSpec(
                grouping: [
                    LedgerGroupingField(column: Self.subject),
                    LedgerGroupingField(column: text)
                ],
                aggregation: HandBuiltLedger.plan([Self.value])
            )
        )
        // Independent closed form: the exact sum of every value put in.
        var expected = Decimal.zero
        for outer in 0..<4 {
            for inner in 0..<5 {
                for leaf in 0..<6 {
                    expected += Self.exact(UInt64(1 + outer * 100 + inner * 10 + leaf), -7)
                }
            }
        }
        #expect(try #require(view.grandTotal[Self.value]?.decimal) == expected)

        for root in view.tree.roots {
            let parent = try #require(root.aggregates[Self.value]?.decimal)
            var childSum = Decimal.zero
            for child in root.children {
                childSum += try #require(child.aggregates[Self.value]?.decimal)
            }
            #expect(parent == childSum, "level-1 subtotal \(parent) != sum of children \(childSum)")
        }
    }

    // MARK: - 3. A filter that cuts through a group

    /// A filter whose predicate is orthogonal to the grouping key, so it removes *part* of every
    /// group rather than whole groups. The subtotal must then be over the visible rows only, and
    /// the group must neither vanish nor keep its unfiltered total.
    ///
    /// Rows: 60 of them, grouped by subject into 3 groups of 20; the filter keeps values `> 10`,
    /// which in each group is the last 12 of its 20 rows.
    @Test("A filter cutting through every group re-totals each group over the visible rows")
    func filterCrossesGroupBoundaries() throws {
        var rows: [[ColumnID: LedgerCellValue]] = []
        var subjects: [String] = []
        for group in 0..<3 {
            for index in 0..<20 {
                rows.append([Self.value: Self.count(Decimal(index + 1))])
                subjects.append("G\(group)")
            }
        }
        let store = try HandBuiltLedger.makeStore(rows: rows, subjects: subjects)
        let grouping = [LedgerGroupingField(column: Self.subject)]
        let plan = HandBuiltLedger.plan([Self.value], functions: [.sum, .count, .rowCount])

        let unfiltered = store.makeView(LedgerViewSpec(grouping: grouping, aggregation: plan))
        // 1..20 sums to 210 per group, 630 in all.
        #expect(try #require(unfiltered.grandTotal[Self.value]?.decimal) == 630)

        let filtered = store.makeView(
            LedgerViewSpec(
                filter: .rule(
                    LedgerFilterRule(
                        column: Self.value,
                        op: .greaterThan,
                        value: .number(10)
                    )
                ),
                grouping: grouping,
                aggregation: plan
            )
        )
        // 11..20 sums to 155 per group, 465 in all. Every group survives, none keeps 210.
        #expect(filtered.rowCount == 30)
        #expect(filtered.tree.roots.count == 3, "a partly-filtered group must not disappear")
        for group in filtered.tree.roots {
            let subtotal = try #require(group.aggregates[Self.value]?.decimal)
            #expect(subtotal == 155, "group subtotal was \(subtotal), not the visible-row sum")
            #expect(group.aggregates.value(AggregateKey(column: Self.value, function: .rowCount))
                == .integer(10))
        }
        #expect(try #require(filtered.grandTotal[Self.value]?.decimal) == 465)

        // The complement must make up the difference exactly: 630 - 465 = 165.
        let complement = store.makeView(
            LedgerViewSpec(
                filter: .not(
                    .rule(
                        LedgerFilterRule(
                            column: Self.value,
                            op: .greaterThan,
                            value: .number(10)
                        )
                    )
                ),
                grouping: grouping,
                aggregation: plan
            )
        )
        #expect(try #require(complement.grandTotal[Self.value]?.decimal) == 165)
        #expect(complement.rowCount + filtered.rowCount == 60)
    }

    /// A filter that removes a whole group must remove the group, not leave an empty one carrying
    /// the old total — and clearing it must restore the original numbers bit for bit.
    @Test("A filter that empties a group removes it, and clearing restores the exact total")
    func filterEmptyingAGroup() throws {
        var rows: [[ColumnID: LedgerCellValue]] = []
        var subjects: [String] = []
        for group in 0..<3 {
            for _ in 0..<4 {
                rows.append([Self.value: Self.count(Decimal(group + 1))])
                subjects.append("G\(group)")
            }
        }
        let store = try HandBuiltLedger.makeStore(rows: rows, subjects: subjects)
        let grouping = [LedgerGroupingField(column: Self.subject)]
        let plan = HandBuiltLedger.plan([Self.value])
        let before = store.makeView(LedgerViewSpec(grouping: grouping, aggregation: plan))
        let baseline = try #require(before.grandTotal[Self.value]?.decimal)
        #expect(baseline == 24) // 4*(1+2+3)

        let filtered = store.makeView(
            LedgerViewSpec(
                filter: .rule(
                    LedgerFilterRule(column: Self.value, op: .notEquals, value: .number(2))
                ),
                grouping: grouping,
                aggregation: plan
            )
        )
        #expect(filtered.tree.roots.count == 2, "an emptied group must not linger")
        #expect(try #require(filtered.grandTotal[Self.value]?.decimal) == 16)

        let cleared = store.makeView(LedgerViewSpec(grouping: grouping, aggregation: plan))
        #expect(try #require(cleared.grandTotal[Self.value]?.decimal) == baseline)
    }

    // MARK: - 4. A formula reading another formula

    /// A three-deep formula chain declared in the *reverse* of its dependency order, so a
    /// left-to-right evaluator reads a column that has not been computed yet and silently
    /// produces blanks or zeros.
    ///
    /// ```text
    /// base   = 7           (stored)
    /// third  = [Second] + 1
    /// second = [First] * 3
    /// first  = [Base] + 5
    /// so     first = 12, second = 36, third = 37
    /// ```
    @Test("A formula reading another formula evaluates in dependency order, not declaration order")
    func chainedFormulas() throws {
        let base = HandBuiltLedger.columnID("base")
        let first = HandBuiltLedger.columnID("first")
        let second = HandBuiltLedger.columnID("second")
        let third = HandBuiltLedger.columnID("third")
        let columns = try LedgerColumnSet(columns: [
            LedgerColumnDefinition(
                id: base, key: "base", title: "Base", kind: .number, dimension: .count, order: 0
            ),
            // Declared last-first on purpose.
            LedgerColumnDefinition(
                id: third, key: "third", title: "Third", kind: .formula, dimension: .count,
                formula: FormulaExpression(source: "[Second] + 1"), isEditable: false, order: 1
            ),
            LedgerColumnDefinition(
                id: second, key: "second", title: "Second", kind: .formula, dimension: .count,
                formula: FormulaExpression(source: "[First] * 3"), isEditable: false, order: 2
            ),
            LedgerColumnDefinition(
                id: first, key: "first", title: "First", kind: .formula, dimension: .count,
                formula: FormulaExpression(source: "[Base] + 5"), isEditable: false, order: 3
            )
        ])
        let store = try HandBuiltLedger.makeStore(
            rows: [[base: Self.count(7)], [base: Self.count(1)]],
            columns: columns
        )
        #expect(store.value(at: 0, column: first).quantity?.value == 12)
        #expect(store.value(at: 0, column: second).quantity?.value == 36)
        #expect(store.value(at: 0, column: third).quantity?.value == 37)
        #expect(store.value(at: 1, column: third).quantity?.value == 19) // (1+5)*3+1

        // And the aggregate over the derived column is the sum of the derived cells, not a
        // re-derivation from the aggregated base.
        #expect(try Self.grandSum(store, third) == 56)
    }

    /// A chained formula must carry exact decimals all the way, not round at each hop.
    ///
    /// `[Base] / 8` on `0.1` is `0.0125`; times `3` is `0.0375`; over four rows, `0.15`. Any
    /// intermediate rounding to two or three places loses it.
    @Test("A formula chain keeps every decimal it is given")
    func chainedFormulasKeepPrecision() throws {
        let base = HandBuiltLedger.columnID("base")
        let eighth = HandBuiltLedger.columnID("eighth")
        let tripled = HandBuiltLedger.columnID("tripled")
        let columns = try LedgerColumnSet(columns: [
            LedgerColumnDefinition(
                id: base, key: "base", title: "Base", kind: .number, dimension: .count,
                precision: .decimalPlaces(2), order: 0
            ),
            LedgerColumnDefinition(
                id: eighth, key: "eighth", title: "Eighth", kind: .formula, dimension: .count,
                precision: .decimalPlaces(2),
                formula: FormulaExpression(source: "[Base] / 8"), isEditable: false, order: 1
            ),
            LedgerColumnDefinition(
                id: tripled, key: "tripled", title: "Tripled", kind: .formula, dimension: .count,
                precision: .decimalPlaces(2),
                formula: FormulaExpression(source: "[Eighth] * 3"), isEditable: false, order: 2
            )
        ])
        let tenth = Self.exact(1, -1)
        let store = try HandBuiltLedger.makeStore(
            rows: Array(repeating: [base: Self.count(tenth)], count: 4),
            columns: columns
        )
        #expect(store.value(at: 0, column: eighth).quantity?.value == Self.exact(125, -4))
        #expect(store.value(at: 0, column: tripled).quantity?.value == Self.exact(375, -4))
        // The declared precision is a *display* property; it must not have touched the value.
        #expect(try Self.grandSum(store, tripled) == Self.exact(15, -2))
    }

    /// A cycle between two formula columns is a typed compile-time refusal, not a hang and not a
    /// column full of blanks.
    @Test("A formula cycle is refused at compile time")
    func formulaCycleIsRefused() {
        let left = HandBuiltLedger.columnID("left")
        let right = HandBuiltLedger.columnID("right")
        #expect(throws: (any Error).self) {
            _ = try LedgerColumnSet(columns: [
                LedgerColumnDefinition(
                    id: left, key: "left", title: "Left", kind: .formula, dimension: .count,
                    formula: FormulaExpression(source: "[Right] + 1"), isEditable: false, order: 0
                ),
                LedgerColumnDefinition(
                    id: right, key: "right", title: "Right", kind: .formula, dimension: .count,
                    formula: FormulaExpression(source: "[Left] + 1"), isEditable: false, order: 1
                )
            ])
        }
    }

    /// A formula chain where the middle link fails must not turn the last link into a zero. An
    /// error has to propagate as an error, and the aggregate has to refuse.
    @Test("A broken link in a formula chain propagates as an error, never as zero")
    func brokenChainDoesNotBecomeZero() throws {
        let base = HandBuiltLedger.columnID("base")
        let quotient = HandBuiltLedger.columnID("quotient")
        let doubled = HandBuiltLedger.columnID("doubled")
        let columns = try LedgerColumnSet(columns: [
            LedgerColumnDefinition(
                id: base, key: "base", title: "Base", kind: .number, dimension: .count, order: 0
            ),
            LedgerColumnDefinition(
                id: quotient, key: "quotient", title: "Quotient", kind: .formula, dimension: .count,
                formula: FormulaExpression(source: "100 / [Base]"), isEditable: false, order: 1
            ),
            LedgerColumnDefinition(
                id: doubled, key: "doubled", title: "Doubled", kind: .formula, dimension: .count,
                formula: FormulaExpression(source: "[Quotient] * 2"), isEditable: false, order: 2
            )
        ])
        let store = try HandBuiltLedger.makeStore(
            rows: [[base: Self.count(4)], [base: Self.count(0)]],
            columns: columns
        )
        #expect(store.value(at: 0, column: doubled).quantity?.value == 50)
        let broken = store.value(at: 1, column: doubled)
        #expect(broken.quantity == nil, "a failed dependency became the number \(String(describing: broken.quantity))")

        let view = store.makeView(LedgerViewSpec(aggregation: HandBuiltLedger.plan([doubled])))
        let total = try #require(view.grandTotal[doubled])
        #expect(total.isRefusal, "the total absorbed a broken row instead of refusing")
        #expect(total.decimal == nil)
    }

    // MARK: - 5 and 6. 100 000 rows where Double would drift visibly

    /// 100 000 rows of `0.01`. The exact total is `1000`.
    ///
    /// Summed as `Double` left to right the answer is 1000.0000000001588, which is wrong in the
    /// eleventh digit — small, but it is also *not equal to 1000*, and a ledger whose grand total
    /// is `999.9999999998` on a round order is a ledger nobody trusts. As `Decimal` it must be the
    /// integer 1000 and must compare equal to it.
    @Test("100 000 rows of 0.01 total exactly 1000")
    func hundredThousandHundredths() throws {
        let hundredth = Self.exact(1, -2)
        let terms = [Decimal](repeating: hundredth, count: 100_000)

        // Independent Double control, to show the drift is real and not hypothetical.
        var drifting = 0.0
        for _ in 0..<100_000 { drifting += 0.01 }
        #expect(drifting != 1000.0, "the Double control did not drift; the case proves nothing")

        let exact = try DecimalSummation.sum(terms)
        #expect(exact == 1000)
        #expect(exact == Decimal(1000))

        // And through the accumulator, which is what a subtotal actually uses.
        var accumulator = AggregateAccumulator(.sum)
        for term in terms { accumulator.add(.value(.number(.count(term)))) }
        #expect(accumulator.value(.sum) == .quantity(DecimalQuantity.count(1000)))
        #expect(accumulator.valueCount == 100_000)
    }

    /// 100 000 terms spanning twelve orders of magnitude, half of them tiny.
    ///
    /// One term of `1e6` followed by 99 999 of `1e-6`: in `Double` the small terms are absorbed
    /// unevenly and the result depends on the order; the exact answer is `1000000.099999`. This
    /// is the case where a `Double` intermediate is not merely imprecise but *order-dependent*,
    /// which is what QUALITY_BAR A3 forbids.
    @Test("100 000 terms across twelve orders of magnitude sum exactly, in any order")
    func wideMagnitudeSpread() throws {
        let big = Self.exact(1, 6)
        let small = Self.exact(1, -6)
        var terms = [big]
        terms.append(contentsOf: [Decimal](repeating: small, count: 99_999))
        // 1e6 + 99999e-6 = 1000000.099999
        let expected = Self.exact(1_000_000_099_999, -6)

        let forward = try DecimalSummation.sum(terms)
        #expect(forward == expected, "forward sum was \(forward)")
        let backward = try DecimalSummation.sum(terms.reversed())
        #expect(backward == expected, "reversed sum was \(backward)")

        var generator = SeededGenerator(seed: 0xA55E_7712_0BAD_F00D)
        var shuffled = terms
        for index in stride(from: shuffled.count - 1, to: 0, by: -1) {
            shuffled.swapAt(index, Int(generator.next() % UInt64(index + 1)))
        }
        #expect(try DecimalSummation.sum(shuffled) == expected, "the sum depends on the order")

        // The Double control, for contrast: order-dependent by construction.
        let doubles = terms.map { NSDecimalNumber(decimal: $0).doubleValue }
        #expect(doubles.reduce(0, +) != doubles.reversed().reduce(0, +))
    }

    /// The same spread driven through a real 100 000-row store, group tree and report — the whole
    /// path, not just the summation primitive — with an independently computed closed form.
    ///
    /// Row `i` carries `(i + 1) / 1e6`, so the exact total is `(100000 * 100001 / 2) / 1e6`,
    /// which is `5000050000e-6 = 5000.05`. Grouped 1 000 ways, the subtotals must still add back
    /// to precisely that.
    @Test("A 100 000-row store totals to its closed form and the subtotals add back to it")
    func hundredThousandRowStore() throws {
        var rows: [[ColumnID: LedgerCellValue]] = []
        var subjects: [String] = []
        rows.reserveCapacity(100_000)
        subjects.reserveCapacity(100_000)
        for index in 0..<100_000 {
            rows.append([Self.value: Self.count(Self.exact(UInt64(index + 1), -6))])
            subjects.append("G\(index % 1_000)")
        }
        let store = try HandBuiltLedger.makeStore(rows: rows, subjects: subjects)
        // Gauss, not a re-run of the code under test: 100000 * 100001 / 2 = 5_000_050_000.
        let expected = Self.exact(5_000_050_000, -6)
        #expect(expected == Self.exact(500_005, -2))

        let view = store.makeView(
            LedgerViewSpec(
                grouping: [LedgerGroupingField(column: Self.subject)],
                aggregation: HandBuiltLedger.plan([Self.value])
            )
        )
        #expect(view.tree.roots.count == 1_000)
        #expect(try #require(view.grandTotal[Self.value]?.decimal) == expected)

        var sumOfSubtotals = Decimal.zero
        var rowsSeen = 0
        for group in view.tree.roots {
            sumOfSubtotals = try DecimalSummation.add(
                sumOfSubtotals,
                try #require(group.aggregates[Self.value]?.decimal)
            )
            rowsSeen += group.rowIndices.count
        }
        #expect(rowsSeen == 100_000)
        #expect(sumOfSubtotals == expected, "subtotals add to \(sumOfSubtotals), not \(expected)")

        // A Double control over the same values, to show the margin being defended is real.
        var drifting = 0.0
        for index in 0..<100_000 { drifting += Double(index + 1) / 1_000_000.0 }
        #expect(drifting != 5000.05)
    }

    // MARK: - Failing loudly

    /// Beyond `Decimal`'s 38 significant digits an addition cannot be exact. It must throw, not
    /// quietly drop the low digits — `Decimal`'s own `+` returns a truncated result with no signal.
    @Test("An addition that cannot be exact throws rather than truncating")
    func inexactAdditionThrows() throws {
        let huge = Self.exact(1, 30)
        let tiny = Self.exact(1, -30)
        // 1e30 + 1e-30 needs 61 significant digits. `Decimal`'s operator gives a rounded answer.
        #expect(throws: LedgerAggregationError.self) {
            _ = try DecimalSummation.add(huge, tiny)
        }
        // The accumulator turns that into a refusal on the total, never a plausible number.
        var accumulator = AggregateAccumulator(.sum)
        accumulator.add(.value(.number(.count(huge))))
        accumulator.add(.value(.number(.count(tiny))))
        #expect(accumulator.value(.sum).isRefusal)
    }

    /// An overflow past `Decimal`'s range is a typed error too, not a `Decimal.nan` that
    /// propagates into a total and prints as something.
    ///
    /// `Decimal`'s range is far larger than it looks — the significand holds 38 digits *and* the
    /// exponent runs to 127, so `greatestFiniteMagnitude` is about `3.4e165` and a naive
    /// "9e127, four times" does not overflow at all; it is the exact 3.6e128. Overflow needs the
    /// maximum itself, where `NSDecimalAdd` reports `.overflow` and hands back `Decimal.nan`.
    /// `Decimal`'s own `+` returns that NaN with no signal, so the guard has to be explicit.
    @Test("An overflowing total refuses instead of producing NaN")
    func overflowRefuses() {
        // First: the near miss must *not* refuse. 4 x 9e127 = 3.6e128, exactly representable.
        var headroom = AggregateAccumulator(.sum)
        let large = Decimal(sign: .plus, exponent: 127, significand: Decimal(9))
        for _ in 0..<4 { headroom.add(.value(.number(.count(large)))) }
        #expect(!headroom.value(.sum).isRefusal, "a representable total was refused")
        #expect(headroom.value(.sum).decimal == Decimal(sign: .plus, exponent: 127, significand: 36))

        // Then the real thing.
        let enormous = Decimal.greatestFiniteMagnitude
        #expect(throws: LedgerAggregationError.self) {
            _ = try DecimalSummation.add(enormous, enormous)
        }
        var accumulator = AggregateAccumulator(.sum)
        accumulator.add(.value(.number(.count(enormous))))
        accumulator.add(.value(.number(.count(enormous))))
        let total = accumulator.value(.sum)
        #expect(total.isRefusal)
        #expect(total.decimal == nil)
    }
}
