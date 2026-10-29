import Foundation
import Testing
@testable import ZPDFExport

/// NL-PLAT-08 round 2: a unit per column, grouping by a column with subtotals, and a grand total.
/// Every expected value is derived by hand from the golden ledger: plan areas (i+1)/8 m², footprints
/// (i+1)·10 m² (shown in ft² by the ledger), cost = golden × 100; Concrete on rows 0, 2, 4 and Steel
/// on 1, 3, 5. One ft² is exactly 0.09290304 m².
@Suite("Export profiles — units per column, grouping, subtotals", .sharedHeap)
struct ProfileUnitsAndGroupingTests {

    static let profile: LedgerExportProfile = {
        var profile = LedgerExportProfile(
            name: "Cost-code import",
            columns: [
                .init(key: "subject", header: "Moment"),
                .init(key: "planArea", header: "Yta ft2", decimals: 3, unit: "ft2"),
                .init(key: "footprint", header: "Fotavtryck m2", decimals: 1, unit: "m2"),
                .init(key: "cost", header: "Kostnad", decimals: 2),
            ],
            delimiter: ";", decimalSeparator: ",", encoding: .utf8, lineEnding: .lf
        )
        profile.grouping = .init(key: "subject", subtotals: true, subtotalLabel: "{group} summa",
                                 grandTotal: true, grandTotalLabel: "Totalt")
        return profile
    }()

    @Test("Grouped by subject with subtotals and a total, in ft² and m², is the reference file byte for byte")
    func groupedReference() throws {
        let projection = try ExportFixture.projection(try ExportFixture.goldenReport())
        let rendered = try Self.profile.renderDetailed(projection)
        #expect(rendered.missingKeys.isEmpty)
        #expect(rendered.unitMismatchKeys.isEmpty)
        // 0.125 m² / 0.09290304 = 1.34548… → 1,345. The subtotal is the sum of the stored values
        // converted once: 1.125 m² → 12,109 — not 1,345 + 4,036 + 6,727 = 12,108.
        // The footprint converts back from the ledger's ft² display to its stored m² exactly.
        let reference = """
        Moment;Yta ft2;Fotavtryck m2;Kostnad
        Concrete;1,345;10,0;44,49
        Concrete;4,036;30,0;267,50
        Concrete;6,727;50,0;123456789,10
        Concrete summa;12,109;90,0;123457101,09
        Steel;2,691;20,0;100,50
        Steel;5,382;40,0;-0,40
        Steel;8,073;60,0;812,50
        Steel summa;16,146;120,0;912,60
        Totalt;28,255;210,0;123458013,69

        """
        #expect(String(decoding: rendered.data, as: UTF8.self) == reference)
    }

    @Test("A unit that does not fit the column's dimension leaves those cells empty and names the column")
    func mismatchNamed() throws {
        var profile = LedgerExportProfile(name: "Wrong", columns: [
            .init(key: "label"), .init(key: "planArea", decimals: 0, unit: "mm"),
        ], encoding: .utf8, lineEnding: .lf)
        profile.includeHeader = false
        let projection = try ExportFixture.projection(try ExportFixture.goldenReport())
        let rendered = try profile.renderDetailed(projection)
        #expect(rendered.unitMismatchKeys == ["planArea"])
        #expect(String(decoding: rendered.data, as: UTF8.self).hasPrefix("L0;\nL1;\n"))
    }

    @Test("Units convert exactly: 0.125 m² is 1250 cm², 1.25 m is 1250 mm and 4.10105 ft")
    func conversions() throws {
        #expect(ProfileUnit(symbol: "cm2")!.convert(fromSI: Decimal(string: "0.125")!) == 1250)
        #expect(ProfileUnit(symbol: "mm")!.convert(fromSI: Decimal(string: "1.25")!) == 1250)
        #expect(LedgerExportProfile.rounded(ProfileUnit(symbol: "ft")!.convert(fromSI: Decimal(string: "1.25")!), places: 5) == "4.10105")
        #expect(ProfileUnit(symbol: "m³")?.symbol == "m3")
        #expect(ProfileUnit(symbol: "furlong") == nil)
        var bad = Self.profile
        bad.columns[1].unit = "furlong"
        #expect(throws: LedgerExportProfile.ProfileError.self) { try LedgerExportProfile.read(try bad.encoded()) }
    }

    @Test("The unit and the grouping survive the file; a profile written before them still reads")
    func fileRoundTrip() throws {
        #expect(try LedgerExportProfile.read(try Self.profile.encoded()) == Self.profile)
        let old = #"{"formatVersion":1,"name":"Old","columns":[{"key":"subject"}],"delimiter":";","decimalSeparator":",","quoteAllFields":false,"includeHeader":true,"encoding":"utf8","lineEnding":"lf","fileNamePattern":"{project}"}"#
        let read = try LedgerExportProfile.read(Data(old.utf8))
        #expect(read.grouping == nil)
        #expect(read.columns.first?.unit == nil)
    }
}
