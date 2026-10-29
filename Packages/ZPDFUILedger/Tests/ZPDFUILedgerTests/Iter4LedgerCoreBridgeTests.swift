import Foundation
import Testing
import ZPDFContracts
import ZPDFQuantityLedger
import ZPDFUIPresentation
@testable import ZPDFUILedger

/// Loop iteration 4, area ui-workflows-ledger: the parts of the fixes that meet the ledger core.
///
/// U-059: the Type option a person picks is the token the core compares, so "Type is Length"
/// matches the length rows. U-069: the table's number style and the core's number locale
/// print every value alike — two copies of one rule that no test used to compare.
@Suite("Ledger, loop iteration 4 — core meeting points", .ledgerTierSerialised)
struct Iter4LedgerCoreBridgeTests {

    // MARK: - U-059

    private static func record(_ index: Int, tool: ZPDFContracts.MeasurementTool) -> MarkupRecord {
        MarkupRecord(
            id: MarkupID(UUID(uuid: (0, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, UInt8(index)))),
            documentID: DocumentID(UUID(uuid: (1, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 0))),
            pageID: PageID(UUID(uuid: (2, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 0))),
            kind: .measurement,
            tool: tool,
            subject: "S\(index)",
            createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            modifiedAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
    }

    @Test("U-059: \"Type is Length\" picked from the list matches the length rows in the core")
    func pickedTypeMatchesInTheCore() throws {
        let columns = try LedgerColumnSet.standard()
        let store = try LedgerStore(
            markups: [Self.record(0, tool: .length), Self.record(1, tool: .rectangleArea), Self.record(2, tool: .length)],
            columns: columns,
            names: LedgerNameCatalog()
        )
        let icon = try #require(columns.columnID(standard: .icon))
        let presented = LedgerFilterTypeColumn.presented(
            LedgerColumn(id: .icon, title: "Type", kind: .text, width: 32)
        )
        let length = try #require(presented.choices.first { $0.title == MeasurementKind.length.displayName })
        let rectangle = try #require(presented.choices.first { $0.title == MeasurementKind.rectangleArea.displayName })
        let evaluator = LedgerFilterEvaluator(store: store)
        func matches(_ op: LedgerFilterOperator, _ value: LedgerFilterValue) -> [Int] {
            evaluator.filter(Array(0..<3), with: .rule(ZPDFQuantityLedger.LedgerFilterRule(column: icon, op: op, value: value)))
        }
        // What the free-text field sent before: the name the column shows. Old output: [] for both.
        #expect(matches(.equals, .text(MeasurementKind.length.displayName)) == [])
        #expect(matches(.contains, .text(MeasurementKind.rectangleArea.displayName)) == [])
        // What the pick list sends: the option's stored token (the seam passes a text column's
        // text through, and a set as a text set).
        #expect(matches(.equals, .text(length.value)) == [0, 2])
        #expect(matches(.inSet, .textSet([length.value, rectangle.value])) == [0, 1, 2])
        #expect(matches(.notEquals, .text(length.value)) == [1])
    }

    // MARK: - U-069

    @Test("U-069: the table's number style prints every value as the core's number locale does")
    func numberStyleMatchesTheCoreLocale() {
        let locales = ["en_US", "sv_SE", "de_CH", "fr_FR", "ar_EG", "nb_NO", "fi_FI", "de_DE", "hi_IN"]
            .map(Locale.init(identifier:))
        let values = ["0", "-0", "7", "-7", "0.5", "-0.004", "12.125", "-1234.5", "1234567.891", "-9876543210.0123", "1000", "999.999"]
            .map { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX"))! }
        let digits: [Int?] = [nil, 0, 1, 2, 3, 6]
        var compared = 0
        for locale in locales {
            let style = LedgerNumberStyle.forLocale(locale)
            let core = LedgerNumberLocale.forLocale(locale)
            #expect(style.decimalSeparator == core.decimalSeparator, "\(locale.identifier)")
            #expect(style.groupingSeparator == core.groupingSeparator, "\(locale.identifier)")
            for value in values {
                for places in digits {
                    let table = style.string(value, fractionDigits: places)
                    let ledger = core.string(value, decimalPlaces: places)
                    #expect(table == ledger, "\(locale.identifier) \(value) \(String(describing: places)): \(table) vs \(ledger)")
                    compared += 1
                }
            }
        }
        #expect(compared == locales.count * values.count * digits.count)
    }
}
