import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUILedger

/// Asserts the filter description the application's CSV export prints in its banner.
///
/// The package's own CSV, audit-trail CSV and Zenit JSON writer, its rounding warning, its
/// export dialog and options went in loop iteration 1 (R-124): none of them ever shipped, and
/// the application's exports (the on-screen CSV, `ZPDFExport`'s workbook, report and JSON, the
/// audit-trail section) are tested where they live. What this package still exports is
/// ``LedgerExportWriter/describe(filter:columns:locale:)``.
@Suite("Ledger export filter description", .ledgerTierSerialised)
struct LedgerExportTests {

    @Test("The filter description reads as a sentence for an export's banner")
    func filterDescription() {
        let filter = LedgerFixtures.group(.all, rules: [
            LedgerFixtures.rule(.subject, .contains, .text("Slab"), index: 0),
            LedgerFixtures.rule(.planArea, .greaterThan, .number(10), index: 1)
        ])
        let text = LedgerExportWriter.describe(filter: filter, columns: LedgerFixtures.columns)
        #expect(text.contains("Subject"))
        #expect(text.contains("Slab"))
        #expect(text.contains("Plan Area"))

        let empty = LedgerExportWriter.describe(
            filter: LedgerFixtures.group(.all),
            columns: LedgerFixtures.columns
        )
        #expect(empty.isEmpty == false)
    }
}

/// Asserts the ledger's spoken summary line. (The selection-coordinator tests that shared this
/// suite went with LedgerSelectionCoordinator, removed as dead code in R-124.)
@MainActor
@Suite("Ledger accessibility summary", .ledgerTierSerialised)
struct LedgerAccessibilitySummaryTests {

    @Test("The accessibility summary names rows, groups, the total and the selection")
    func accessibilitySummary() {
        let summary = LedgerAccessibilitySummary.text(
            rowCount: 412,
            groupCount: 3,
            totalText: "1 240.5 m²",
            selectionCount: 2
        )
        #expect(summary.contains("412"))
        #expect(summary.contains("3"))
        #expect(summary.contains("1 240.5 m²"))
        #expect(summary.contains("2"))

        let flat = LedgerAccessibilitySummary.text(rowCount: 5, groupCount: 0, totalText: nil)
        #expect(flat.contains("5"))
        #expect(!flat.contains("groups"))
    }
}
