import Foundation
import Testing
@testable import ZPDFUIPresentation

/// ADR-0014 / CR-102, mirrored into the presentation seam.
///
/// `QuantityDimension.ratio` and `.count` were the **same value** here, exactly as they were in
/// the contracts: both `QuantityDimension(lengthPower: 0)`, spelled differently where the intent
/// was a factor. `isCompatible(with:)` is equality, so a slope ratio or a waste factor summed
/// straight into a count total with no refusal — the one place the product's headline guarantee,
/// *incompatible dimensions are never added*, was true only in spelling.
///
/// Old output, with `.ratio` back to `QuantityDimension(lengthPower: 0)` — the two named
/// values one value again:
///
/// ```
/// ✘ Test "A ratio and a count are not the same dimension" recorded an issue at
///   RatioDimensionTests.swift:38:9: Expectation failed:
///   (QuantityDimension.ratio → QuantityDimension(lengthPower: 0, angle: false,
///   currencyCode: nil, ratio: false)) != (QuantityDimension.count → QuantityDimension(
///   lengthPower: 0, angle: false, currencyCode: nil, ratio: false))
/// ✘ Test "Adding a ratio to a count is refused, and names both" recorded an issue at
///   RatioDimensionTests.swift:65:21: Expectation failed: an error was expected but none was
///   thrown and "DecimalQuantity(value: 5.15, dimension: QuantityDimension(lengthPower: 0,
///   angle: false, currencyCode: nil, ratio: false))" was returned
/// ✘ Test "A ratio cell and a count cell do not merge into one total" recorded an issue at
///   RatioDimensionTests.swift:129:9: Expectation failed: (refused.total(.count)
///   → DecimalQuantity(value: 5.15, dimension: …ratio: false))) == nil
/// ✘ Test "A ratio cell and a count cell do not merge into one total" recorded an issue at
///   RatioDimensionTests.swift:131:9: Expectation failed:
///   (refused.displayValue(.count) → "5").isEmpty → false
/// ✘ Test "A count's encoded form is unchanged, and a ratio carries the key" recorded an issue
///   at RatioDimensionTests.swift:187:9: Expectation failed:
///   (ratioJSON → "{"angle":false,"lengthPower":0}").contains(""ratio":true")
/// ```
///
/// And the second half — the tag in place, `LedgerRow` still minting `.ratio` for a free-typed
/// number, which is the state the follow-up fix started from:
///
/// ```
/// ✘ Test "An untyped number in a count column is a count, and in a ratio column a ratio"
///   recorded an issue at RatioDimensionTests.swift:137:9: Expectation failed:
///   (cell.asQuantity(inColumn: .count)?.dimension → QuantityDimension(lengthPower: 0,
///   angle: false, currencyCode: nil, ratio: true)) == (.count → …ratio: false))
/// ✘ Test "An untyped number totals with the measured counts beside it" recorded an issue at
///   RatioDimensionTests.swift:160:9: Expectation failed: (totals.total(.count)?.value → nil) == 7
/// ✘ Test "An untyped number totals with the measured counts beside it" recorded an issue at
///   RatioDimensionTests.swift:165:9: Expectation failed:
///   !((totals.incompatibleColumns → [count]).contains(.count → count) → true)
/// ```
@MainActor
@Suite("Ratio dimension (ADR-0014)")
struct RatioDimensionTests {

    // MARK: - The tag

    @Test("A ratio and a count are not the same dimension")
    func ratioAndCountDiffer() {
        #expect(QuantityDimension.ratio != QuantityDimension.count)
        #expect(!QuantityDimension.ratio.isCompatible(with: .count))
        #expect(!QuantityDimension.count.isCompatible(with: .ratio))
        // Both are still dimensionless: every "any dimensionless value may go here" site keeps
        // working. The distinction is a tag, not a unit.
        #expect(QuantityDimension.ratio.isDimensionless)
        #expect(QuantityDimension.count.isDimensionless)
        // …and it is spoken apart, so a refusal names two different things.
        #expect(QuantityDimension.ratio.displayName != QuantityDimension.count.displayName)
    }

    @Test("The tag is only valid on a dimensionless quantity")
    func theTagIsOnlyValidWhereItMeansSomething() {
        #expect(QuantityDimension.ratio.isValid)
        #expect(QuantityDimension.count.isValid)
        #expect(QuantityDimension.length.isValid)
        #expect(!QuantityDimension(lengthPower: 1, ratio: true).isValid)
        #expect(!QuantityDimension(lengthPower: 0, angle: true, ratio: true).isValid)
        #expect(!QuantityDimension(lengthPower: 0, currencyCode: "SEK", ratio: true).isValid)
    }

    @Test("Adding a ratio to a count is refused, and names both")
    func addingARatioToACountIsRefused() {
        let doors = DecimalQuantity.count(4)
        let waste = DecimalQuantity(value: Decimal(string: "1.15") ?? 0, dimension: .ratio)

        let error = #expect(throws: QuantityError.self) { try doors.adding(waste) }
        #expect(error == .incompatibleDimensions(.count, .ratio))

        // The old behaviour, stated so this test says what it defends against: the two were one
        // value, so `4 + 1.15` produced `5.15 count` and travelled on into a total.
        let sameDimension = QuantityDimension(lengthPower: 0) == QuantityDimension(lengthPower: 0, ratio: true)
        #expect(!sameDimension, "the tag is what keeps 4 doors + 1.15 from being 5.15 doors")
    }

    // MARK: - The ledger

    private func column(
        _ id: LedgerColumnID,
        _ title: String,
        _ dimension: QuantityDimension
    ) -> LedgerColumn {
        LedgerColumn(
            id: id,
            title: title,
            kind: .number,
            dimension: dimension,
            width: 100,
            alignment: .trailing,
            aggregate: .sum
        )
    }

    private func row(_ values: [LedgerColumnID: LedgerCellValue]) -> LedgerRow {
        LedgerRow(
            markupID: UUID(),
            values: values,
            displayValues: [:],
            colorRGBA: ColorRGBA(red: 0, green: 0, blue: 0, alpha: 1),
            kind: .count
        )
    }

    // The two totals tests below run on the mock totals rule (`mockSumming`, R-138), which the
    // sample project and the mock ledger build their totals with. The shipped totals are the
    // core aggregator's, through ZPDFAppCore's `LedgerBridge.totals`.

    @Test("A ratio cell and a count cell do not merge into one total")
    func aRatioCellAndACountCellDoNotMerge() {
        let wasteID = LedgerColumnID.custom("waste")
        let columns = [column(.count, "Count", .count), column(wasteID, "Waste", .ratio)]
        let rows = [
            row([.count: .quantity(.count(4)), wasteID: .number(Decimal(string: "1.15") ?? 0)]),
            row([.count: .quantity(.count(2)), wasteID: .number(Decimal(string: "1.05") ?? 0)])
        ]

        let totals = LedgerTotals.mockSumming(rows: rows, columns: columns) { _, quantity in
            SampleFormatting.string(quantity)
        }

        // Two columns, two totals, in two different dimensions. Neither is the other's.
        #expect(totals.total(.count)?.value == 6)
        #expect(totals.total(.count)?.dimension == .count)
        #expect(totals.total(wasteID)?.dimension == .ratio)
        #expect(totals.total(wasteID)?.value == Decimal(string: "2.20"))

        // …and putting a factor into the count column is refused rather than summed.
        let mixed = [
            row([.count: .quantity(.count(4))]),
            row([.count: .quantity(DecimalQuantity(value: Decimal(string: "1.15") ?? 0, dimension: .ratio))])
        ]
        let refused = LedgerTotals.mockSumming(rows: mixed, columns: [column(.count, "Count", .count)]) { _, q in
            SampleFormatting.string(q)
        }
        #expect(refused.total(.count) == nil, "4 doors + 1.15 must not be 5.15 doors")
        #expect(refused.incompatibleColumns.contains(.count))
        #expect(refused.displayValue(.count).isEmpty)
    }

    @Test("An untyped number in a count column is a count, and in a ratio column a ratio")
    func theColumnDecidesAnUntypedNumber() {
        let cell = LedgerCellValue.number(12)
        #expect(cell.asQuantity(inColumn: .count)?.dimension == .count)
        #expect(cell.asQuantity(inColumn: .ratio)?.dimension == .ratio)
        #expect(cell.dimension(inColumn: .count) == .count)
        #expect(cell.dimension(inColumn: .ratio) == .ratio)
        // No column to ask: dimensionless-untagged, which is a count — the same answer the
        // contracts' decoder gives a stored dimensionless value nothing has re-tagged.
        #expect(cell.asQuantity(inColumn: nil)?.dimension == .count)

        let sheet = row([.count: .number(12)])
        #expect(sheet.quantity(.count, declaring: .count)?.dimension == .count)
        #expect(sheet.quantity(.count, declaring: .count)?.value == 12)
    }

    @Test("An untyped number totals with the measured counts beside it")
    func anUntypedNumberSumsIntoItsCountColumn() {
        let columns = [column(.count, "Count", .count)]
        let rows = [
            row([.count: .quantity(.count(4))]),
            row([.count: .number(3)])
        ]
        let totals = LedgerTotals.mockSumming(rows: rows, columns: columns) { _, q in
            SampleFormatting.string(q)
        }
        #expect(
            totals.total(.count)?.value == 7,
            "a typed 3 in a Count column is three things and must add to the four beside it"
        )
        #expect(totals.total(.count)?.dimension == .count)
        #expect(!totals.incompatibleColumns.contains(.count))
    }

    @Test("A stored quantity keeps its own dimension; only an untyped number takes the column's")
    func aStoredQuantityIsNotRetagged() {
        let stored = LedgerCellValue.quantity(.metres(3))
        #expect(stored.asQuantity(inColumn: .count)?.dimension == .length,
                "a measured length is not turned into a count by the column it lands in")
        #expect(stored.dimension(inColumn: .ratio) == .length)
    }

    // MARK: - Codable

    @Test("A count's encoded form is unchanged, and a ratio carries the key")
    func encodingIsBackwardCompatible() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let countJSON = try String(decoding: encoder.encode(QuantityDimension.count), as: UTF8.self)
        #expect(!countJSON.contains("ratio"), "a pre-ADR count must encode byte-identically")

        let ratioJSON = try String(decoding: encoder.encode(QuantityDimension.ratio), as: UTF8.self)
        #expect(ratioJSON.contains("\"ratio\":true"))

        let decoder = JSONDecoder()
        // A payload written before ADR-0014 has no key and decodes as a count.
        let legacy = Data(#"{"lengthPower":0,"angle":false}"#.utf8)
        #expect(try decoder.decode(QuantityDimension.self, from: legacy) == .count)
        // …and both named values round-trip.
        for dimension in [QuantityDimension.count, .ratio, .length, .area, .angle, .currency("SEK")] {
            let data = try encoder.encode(dimension)
            #expect(try decoder.decode(QuantityDimension.self, from: data) == dimension)
        }
    }

    @Test("A ratio quantity round-trips through a ledger cell")
    func aRatioCellRoundTrips() throws {
        let waste = DecimalQuantity(value: Decimal(string: "1.15") ?? 0, dimension: .ratio)
        let cell = LedgerCellValue.quantity(waste)
        let data = try JSONEncoder().encode(cell)
        let decoded = try JSONDecoder().decode(LedgerCellValue.self, from: data)
        #expect(decoded == cell)
        #expect(decoded.asQuantity?.dimension == .ratio)
    }
}
