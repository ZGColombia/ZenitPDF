import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUILedger

/// Bug hunt 2, the ledger package's export writer: BH-709, the filter description the
/// application's CSV banner prints. BH-038, BH-706, BH-707 and BH-708 were fixes to the
/// package's own CSV writer, rounding warning, audit-trail CSV and export dialog, which never
/// shipped and were removed as dead duplicates in loop iteration 1 (R-124).
@Suite("Fix2 U1 export", .ledgerTierSerialised)
struct Fix2U1ExportTests {

    // MARK: BH-709

    @Test("BH-709: the filter description localises numbers and prints choice titles")
    func filterDescriptionLocalised() {
        // Old output: "Plan Area is greater than 10.5" in Swedish and "Status is any of approved".
        let filter = LedgerFixtures.group(.all, rules: [
            LedgerFixtures.rule(.planArea, .greaterThan, .number(Decimal(string: "10.5")!), index: 0),
            LedgerFixtures.rule(.status, .isAnyOf, .choices(["approved"]), index: 1)
        ])
        let text = LedgerExportWriter.describe(
            filter: filter, columns: LedgerFixtures.columns, locale: Locale(identifier: "sv_SE")
        )
        #expect(text.contains("10,5"))
        #expect(text.contains("10.5") == false)
        #expect(text.contains("Approved"))
        #expect(text.contains("approved") == false)
    }
}
