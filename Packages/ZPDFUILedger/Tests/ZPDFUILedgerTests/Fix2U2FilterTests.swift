import Foundation
import Testing
import ZPDFQuantityLedger
import ZPDFUIPresentation
@testable import ZPDFUILedger

/// Bug hunt 2 regressions on the filter builder and the filter evaluator. Every test names
/// what the old code answered.
///
/// BH-227, BH-229 and BH-713 were fixes to this package's own regex guard — its nesting
/// check, its cached rejections and its per-pass budget. That evaluator never shipped and was
/// removed as a dead duplicate in loop iteration 1 (R-126); the live engine has no regex
/// operator at all, by design, and a pattern rule is reported as not applied (BH-712 below).
/// BH-228 now runs on the live path: the builder's day boundaries and the core's evaluator.
@Suite("Fix2 U2: filter builder and evaluator", .ledgerTierSerialised)
struct Fix2U2FilterTests {

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    private static func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute)) ?? Date()
    }

    private static let millimetreColumn = LedgerColumn(
        id: .planLength, title: "Plan Length", kind: .number, dimension: .length,
        width: 90, aggregate: .sum, displayUnitSymbol: "mm"
    )

    private static let dateColumnID = LedgerColumnID.custom("created")
    private static let dateColumn = LedgerColumn(id: dateColumnID, title: "Created", kind: .date, width: 90)

    // MARK: BH-039

    @Test("BH-039: a numeric operand is typed in the display unit and stored in SI")
    func numericOperandIsConvertedToSI() {
        // Old: the field stored the typed 500 verbatim as the SI operand, so "Plan Length is at
        // least 500" (read as 500 mm) compared 0.5 m against 500 and dropped every row.
        let conversion = LedgerFilterUnitConversion.forColumn(Self.millimetreColumn)
        #expect(conversion.symbol == "mm")
        #expect(conversion.siValue(fromDisplay: 500) == Decimal(string: "0.5"))
        #expect(conversion.displayValue(fromSI: Decimal(string: "0.5")!) == 500)

        let feet = LedgerColumn(
            id: .planLength, title: "Plan Length", kind: .number, dimension: .length,
            width: 90, displayUnitSymbol: "ft"
        )
        let footConversion = LedgerFilterUnitConversion.forColumn(feet)
        #expect(footConversion.siValue(fromDisplay: 10) == Decimal(string: "3.048"))
        #expect(footConversion.displayValue(fromSI: Decimal(string: "3.048")!) == 10)

        let squareFeet = LedgerColumn(
            id: .planArea, title: "Plan Area", kind: .number, dimension: .area,
            width: 90, displayUnitSymbol: "ft²"
        )
        #expect(LedgerFilterUnitConversion.forColumn(squareFeet).siValue(fromDisplay: 1) == Decimal(string: "0.09290304"))

        // A count column and an unknown symbol are the identity.
        let count = LedgerFixtures.columns.first { $0.id == .count }
        #expect(LedgerFilterUnitConversion.forColumn(count).siValue(fromDisplay: 7) == 7)
    }

    // MARK: BH-040

    @Test("BH-040: a comma-decimal locale renders and parses the same number")
    func localeTolerantNumberField() {
        let swedish = Locale(identifier: "sv_SE")
        // Old: the field rendered Decimal.description ("12.5") and parsed with
        // Decimal(string:locale: sv_SE), which read the prefix "12" — the operand became 12.
        #expect(Decimal(string: "12.50", locale: swedish) == 12)
        #expect(LedgerNumberParsing.decimal(from: "12.50") == Decimal(string: "12.5"))
        #expect(LedgerNumberParsing.decimal(from: "12,5") == Decimal(string: "12.5"))
        #expect(LedgerNumberParsing.editingString(Decimal(string: "12.5")!, locale: swedish) == "12,5")
        #expect(LedgerNumberParsing.decimal(from: "−3,25") == Decimal(string: "-3.25"))
        #expect(LedgerNumberParsing.decimal(from: "1 234,5") == Decimal(string: "1234.5"))

        let english = Locale(identifier: "en_US")
        // S-076: a text with both decimal marks is refused rather than read by the locale's
        // grouping rule — the ledger reads typed text with ZPDFDecimalParser, Zenit's one
        // grammar. Old expectation: 1234.5 under en-US (and the same rule made "0,6" read 6).
        #expect(LedgerNumberParsing.decimal(from: "1,234.5") == nil)
        #expect(LedgerNumberParsing.editingString(Decimal(string: "12.5")!, locale: english) == "12.5")
        // A partial or trailing-garbage entry is not a number (the old parse took a prefix).
        #expect(LedgerNumberParsing.decimal(from: "3²") == nil)
        #expect(LedgerNumberParsing.decimal(from: "12.5.1") == nil)
        #expect(LedgerNumberParsing.decimal(from: "") == nil)
        #expect(LedgerNumberParsing.decimal(from: "-") == nil)
    }

    // MARK: BH-041

    @Test("BH-041: date operands are pinned to day boundaries, never to the time of creation")
    func dateOperandsAreDayGranular() {
        let now = Self.date(5, 14, 32)
        // Old: .date(Date()) — 14:32 on the day, so "Created is at least 5 Sep" dropped rows
        // created that morning and "is 5 Sep" matched nothing.
        let fresh = LedgerFilterOperandRules.defaultOperand(for: Self.dateColumn, now: now, calendar: Self.utc)
        #expect(fresh == .date(Self.date(5, 0)))

        let between = LedgerFilterOperandRules.operand(
            for: .between, column: Self.dateColumn, previous: .date(now), now: now, calendar: Self.utc
        )
        let endOfDay = Self.date(6, 0).addingTimeInterval(-0.001)
        // Old: .dateRange(start: Date(), end: Date()) — both ends at the current instant.
        #expect(between == .dateRange(start: Self.date(5, 0), end: endOfDay))

        let after = LedgerFilterOperandRules.operand(
            for: .greaterThan, column: Self.dateColumn, previous: .date(now), now: now, calendar: Self.utc
        )
        #expect(after == .date(endOfDay))
        let before = LedgerFilterOperandRules.operand(
            for: .lessThan, column: Self.dateColumn, previous: .date(now), now: now, calendar: Self.utc
        )
        #expect(before == .date(Self.date(5, 0)))
    }

    // MARK: BH-042

    @Test("BH-042: 'is' on a choice column carries a single option value the engine can equate")
    func choiceEqualityUsesTextOperand() {
        let status = LedgerFixtures.columns.first { $0.id == .status }
        // Old: the .choices(["approved"]) operand was kept; the core has no equality for a
        // choice set, so "Status is Approved" matched 0 rows and "is not" matched every row.
        #expect(LedgerFilterOperandRules.operand(for: .equals, column: status, previous: .choices(["approved"]))
                == .text("approved"))
        #expect(LedgerFilterOperandRules.operand(for: .notEquals, column: status, previous: .choices([]))
                == .text(""))
        // And back: "is any of" turns the single value into a one-element set.
        #expect(LedgerFilterOperandRules.operand(for: .isAnyOf, column: status, previous: .text("draft"))
                == .choices(["draft"]))
    }

    // MARK: BH-225

    @Test("BH-225: switching 'is between' to 'is' drops the range")
    func rangeCollapsesUnderEquality() {
        let length = LedgerFixtures.columns.first { $0.id == .planLength }
        // Old: .numberRange(lower: 1, upper: 5) was kept under "is" — matched nothing.
        #expect(LedgerFilterOperandRules.operand(for: .equals, column: length, previous: .numberRange(lower: 1, upper: 5))
                == .number(1))
        #expect(LedgerFilterOperandRules.operand(for: .notEquals, column: Self.dateColumn,
                                                 previous: .dateRange(start: Self.date(3, 0), end: Self.date(4, 0)),
                                                 calendar: Self.utc)
                == .date(Self.date(3, 0)))
        #expect(LedgerFilterOperandRules.operand(for: .greaterThan, column: length, previous: .numberRange(lower: 2, upper: 9))
                == .number(2))
    }

    // MARK: BH-226

    @Test("BH-226: a rule on a column this ledger does not have is reported as not applied")
    func unknownColumnIsDiagnosed() {
        let filter = LedgerFixtures.group(.all, rules: [
            LedgerFixtures.rule(.custom("material"), .equals, .text("Steel"))
        ])
        let diagnostics = LedgerFilterDiagnostic.unappliedRules(in: filter, columns: LedgerFixtures.columns)
        // Old: [] — the panel showed the rule with a blank column and "N of N rows match".
        #expect(diagnostics == [.unknownColumnNotApplied(columnName: "custom.material")])
        #expect(!diagnostics[0].message.isEmpty)
    }

    // MARK: BH-228

    @Test("BH-228: ordered date comparisons are day-granular like equality")
    func orderedDateComparisonIsDayGranular() throws {
        // The live path: the builder pins a date operand to a day boundary chosen by the
        // comparison (`LedgerFilterDates`, BH-041), and the core compares instants. A markup
        // created at 09:00 against an operand typed as 14:32 the same day is on that day.
        // (Equality is the seam's whole-day range, asserted in ZPDFAppCore's own tests.)
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_788_600_000))
        let rowTime = dayStart.addingTimeInterval(9 * 3600)
        let operand = dayStart.addingTimeInterval(14 * 3600 + 32 * 60)
        let store = try LiveLedgerFixture.store(created: rowTime)
        func kept(_ comparison: LedgerFilterComparison, _ op: LedgerFilterOperator) -> Int {
            let pinned = LedgerFilterDates.normalized(operand, for: comparison, calendar: calendar)
            return LiveLedgerFixture.count(LiveLedgerFixture.rule(LiveLedgerFixture.created, op, .date(pinned)), in: store)
        }
        let all = LedgerFixtures.rows.count
        // Old: "is at least" false and "is less than" true for a row the "is" rule includes.
        #expect(kept(.greaterThanOrEqual, .greaterThanOrEqual) == all)
        #expect(kept(.lessThan, .lessThan) == 0)
        #expect(kept(.lessThanOrEqual, .lessThanOrEqual) == all)
        #expect(kept(.greaterThan, .greaterThan) == 0)
    }

    // MARK: Low: BH-710, BH-711, BH-712, BH-714

    @Test("BH-710: a tree of disabled rules or empty groups can still be cleared and saved")
    func disabledRulesStillCount() {
        var rule = LedgerFixtures.rule(.label, .contains, .text("C"))
        rule.isEnabled = false
        let filter = LedgerFixtures.group(.all, rules: [rule])
        #expect(filter.isEmpty) // constrains nothing …
        // Old: Clear All and Save keyed off isEmpty, so both were disabled here.
        #expect(LedgerFilterOperandRules.hasContent(filter)) // … but there is something to clear
        let nested = LedgerFixtures.group(.all, groups: [LedgerFixtures.group(.any, index: 1)])
        #expect(LedgerFilterOperandRules.hasContent(nested))
        #expect(!LedgerFilterOperandRules.hasContent(LedgerFixtures.group(.all)))
    }

    @Test("BH-711: removing a nested group takes it out of the tree")
    func nestedGroupRemoval() {
        let child = LedgerFixtures.group(.any, index: 1)
        let root = LedgerFixtures.group(.all, groups: [child])
        // Old: the only control emptied the child and kept it in `groups`.
        let removed = LedgerFilterTreeEditor.removingGroup(id: child.id, in: root)
        #expect(removed.groups.isEmpty)
    }

    @Test("BH-712: a pattern operand kept under 'is' is diagnosed and not evaluated")
    func regexOperandUnderEquality() {
        let filter = LedgerFixtures.group(.all, rules: [
            LedgerFixtures.rule(.label, .equals, .regex("^C-"))
        ])
        // Old: [] — the seam dropped it silently while the panel called the filter applied.
        #expect(LedgerFilterDiagnostic.unappliedRules(in: filter, columns: LedgerFixtures.columns)
                == [.regexNotApplied])
        let label = LedgerFixtures.columns.first { $0.id == .label }
        #expect(LedgerFilterOperandRules.operand(for: .equals, column: label, previous: .regex("^C-")) == .text(""))
    }

    @Test("BH-714: saving under an existing id replaces that entry")
    func saveNeverDuplicatesAnID() {
        var store = LedgerSavedFilterStore()
        let identity = LedgerFixtures.id(42)
        store.save(name: "A", filter: LedgerFixtures.group(.all), id: identity)
        store.save(name: "B", filter: LedgerFixtures.group(.any), id: identity)
        // Old: two entries sharing one id.
        #expect(store.filters.count == 1)
        #expect(store.filters.first?.name == "B")
    }
}
