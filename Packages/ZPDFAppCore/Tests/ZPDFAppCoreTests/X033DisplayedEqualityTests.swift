import Foundation
import Testing
import ZPDFContracts
import ZPDFQuantityLedger
import ZPDFUIPresentation
@testable import ZPDFAppCore

/// X-033: "is" and "is not" on a measured ledger column
/// compare the number the cell shows, not the 15-significant-digit value it stores.
@Suite("Iteration 7 — a measured equality compares what the cell shows")
struct X033DisplayedEqualityTests {

    private static func decimal(_ text: String) -> Decimal { Decimal(string: text)! }

    /// Plan Area, hand-derived at the metric default of two decimals (half away from zero):
    ///
    /// ```text
    /// row 0  12.3456789012345 m²  shows 12.35
    /// row 1  12.345 m²            shows 12.35   (the half rounds away from zero)
    /// row 2  12.3549999999999 m²  shows 12.35
    /// row 3  12.355 m²            shows 12.36   (the next half)
    /// row 4  12.3449999999999 m²  shows 12.34
    /// row 5  0.004 m²             shows 0.00
    /// row 6  no area              empty
    /// ```
    static let areas: [String?] = [
        "12.3456789012345", "12.345", "12.3549999999999", "12.355", "12.3449999999999", "0.004", nil
    ]

    private static func store(
        field: ZPDFContracts.MeasurementField,
        values: [String?],
        dimension: (Decimal) -> ZPDFContracts.DecimalQuantity
    ) throws -> LedgerStore {
        let markups = values.enumerated().map { index, value in
            var fields: [ZPDFContracts.MeasurementField: ZPDFContracts.DecimalQuantity] = [:]
            if let value {
                fields[field] = dimension(decimal(value))
                if field == .netArea { fields[.planArea] = dimension(decimal(value)) }
            }
            return MarkupRecord(
                id: MarkupID(UUID()),
                documentID: DocumentID(UUID()),
                pageID: PageID(UUID()),
                kind: .measurement,
                tool: field == .netArea ? .area : .length,
                subject: "Row \(index)",
                measurement: MeasurementResult(values: fields),
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        }
        return try LedgerStore(markups: markups, columns: try LedgerColumnSet.standard())
    }

    private static func rows(
        _ store: LedgerStore,
        column: StandardLedgerColumn,
        _ comparison: LedgerFilterComparison,
        _ si: Decimal,
        formatter: QuantityFormatter?
    ) throws -> [Int] {
        let key = try #require(store.columns.column(standard: column)).key
        let request = LedgerRequest(filter: LedgerFilterGroup(id: UUID(), rules: [
            ZPDFUIPresentation.LedgerFilterRule(id: UUID(), column: LedgerColumnID(key), comparison: comparison, operand: .number(si))
        ]))
        let spec = LedgerSpecBuilder.translate(request, columns: store.columns, formatter: formatter).spec
        return store.makeView(spec).matchingRowIndices
    }

    @Test("X-033: Plan Area is 12.35 finds the three rows that show 12.35, and is not 12.35 the rest")
    func metricAreaMatchesWhatIsShown() throws {
        let store = try Self.store(field: .netArea, values: Self.areas, dimension: { .area($0) })
        let formatter = QuantityFormatter()
        let target = Self.decimal("12.35")

        // Old output: [] for "is" and every row for "is not" — exact Decimal equality.
        #expect(try Self.rows(store, column: .planArea, .equals, target, formatter: nil) == [])
        #expect(try Self.rows(store, column: .planArea, .equals, target, formatter: formatter) == [0, 1, 2])
        #expect(try Self.rows(store, column: .planArea, .notEquals, target, formatter: formatter) == [3, 4, 5, 6])
        // Zero: the 0.004 m² row shows 0.00.
        #expect(try Self.rows(store, column: .planArea, .equals, 0, formatter: formatter) == [5])
        // Typed with more decimals than shown: still the rows that show 12.35.
        #expect(try Self.rows(store, column: .planArea, .equals, Self.decimal("12.3456"), formatter: formatter) == [0, 1, 2])

        // Every match is a row whose cell text is "12.35", and every other non-empty row is not.
        let planArea = try #require(store.columns.column(standard: .planArea))
        for index in 0..<store.rowCount {
            guard let quantity = store.value(at: index, column: planArea.id).quantity else { continue }
            let text = formatter.text(Shown.Quantity(domain: quantity))
            #expect((text == "12.35") == [0, 1, 2].contains(index), "row \(index) shows \(text)")
        }
    }

    /// 12.5 ft = 3.81 m shows 12'-6" at sixteenths. One sixteenth of an inch is 0.0015875 m, so
    /// the band is 3.81 ± 0.00079375 m: 3.8107 (+0.44 of a sixteenth) and 3.8093 (−0.44) show
    /// 12'-6"; 3.8108 (+0.504) shows 12'-6 1/16" and 3.8092 (−0.504) 12'-5 15/16".
    @Test("X-033: in feet and inches, Plan Length is 12.5 ft finds the rows that show 12'-6\"")
    func feetAndInchesMatchWhatIsShown() throws {
        let store = try Self.store(
            field: .planLength,
            values: ["3.81", "3.8107", "3.8108", "3.8093", "3.8092"],
            dimension: { .length($0) }
        )
        let formatter = QuantityFormatter(units: DisplayUnitSelection(length: .foot))
        let target = Self.decimal("3.81")
        #expect(formatter.text(Shown.Quantity(value: target, dimension: .length)) == "12'-6\"")
        #expect(try Self.rows(store, column: .planLength, .equals, target, formatter: nil) == [0])
        #expect(try Self.rows(store, column: .planLength, .equals, target, formatter: formatter) == [0, 1, 3])
        #expect(try Self.rows(store, column: .planLength, .notEquals, target, formatter: formatter) == [2, 4])
    }

    @Test("X-033: a typed number column and a count stay exact")
    func typedAndCountColumnsStayExact() throws {
        let columns = try LedgerColumnSet.standard()
        let count = try #require(columns.column(standard: .count))
        let formatter = QuantityFormatter()
        #expect(LedgerSpecBuilder.displayedEquality(column: count, op: .equals, value: .number(3), formatter: formatter) == nil)
        let typed = LedgerColumnDefinition(
            id: ColumnID(UUID()), key: "custom.height", title: "Height", kind: .number, dimension: .length, order: 99
        )
        #expect(LedgerSpecBuilder.displayedEquality(column: typed, op: .equals, value: .number(Self.decimal("2.4")), formatter: formatter) == nil)
        let planArea = try #require(columns.column(standard: .planArea))
        #expect(LedgerSpecBuilder.displayedEquality(column: planArea, op: .greaterThan, value: .number(1), formatter: formatter) == nil)
        #expect(LedgerSpecBuilder.displayedEquality(column: planArea, op: .equals, value: .number(1), formatter: formatter) != nil)
    }

    /// The band and `QuantityFormatter.text` are two readings of one rule; this holds them to
    /// each other around every half-step, on both sides of zero, in every rendering the ledger
    /// uses for a length, an area, a volume and an angle.
    @Test("X-033: a value is in the band exactly when the formatter writes it as the same text")
    func bandAgreesWithTheFormatter() {
        let cases: [(QuantityFormatter, Shown.Dimension, [String])] = [
            (QuantityFormatter(), .area, ["12.35", "12.3456789012345", "-1.25", "0", "0.004", "-0.004", "1000"]),
            (QuantityFormatter(units: DisplayUnitSelection(metricDecimalPlaces: 3)), .length, ["2.4005", "-7.0625", "0.0004"]),
            (QuantityFormatter(units: DisplayUnitSelection(length: .millimetre, metricDecimalPlaces: 0)), .length, ["1.2345", "0.0004"]),
            (QuantityFormatter(units: DisplayUnitSelection(length: .foot)), .length, ["3.81", "-3.81", "0.0005", "0.0047625"]),
            (QuantityFormatter(units: DisplayUnitSelection(length: .inch, imperialPrecision: .eighth)), .length, ["0.254", "1"]),
            (QuantityFormatter(units: DisplayUnitSelection(length: .foot).withImperialLengthStyle(.decimalFeet)), .length, ["3.81", "3.8123"]),
            (QuantityFormatter(units: DisplayUnitSelection(area: .squareFoot)), .area, ["1.1612880", "9.290304"]),
            (QuantityFormatter(units: DisplayUnitSelection(volume: .cubicYard)), .volume, ["0.764554857984", "2.5"]),
            (QuantityFormatter(), .angle, ["0.5235987755982988", "-0.1"])
        ]
        var probed = 0
        for (formatter, dimension, seeds) in cases {
            for seed in seeds {
                let si = Self.decimal(seed)
                let shown = formatter.text(Shown.Quantity(value: si, dimension: dimension))
                guard let band = formatter.displayBand(ofSI: si, dimension: dimension) else {
                    // Only a feet-and-inches zero has no band (it shows 0'-0" and only zero does).
                    #expect(si == 0 && formatter.units.usesFeetInchesMarks, "no band for \(seed) shown as \(shown)")
                    continue
                }
                #expect(band.contains(si), "\(seed) is outside its own band")
                // Probe both edges and points around them.
                let width = band.upper - band.lower
                var probes: [Decimal] = [band.lower, band.upper]
                for fraction in ["0.000001", "0.01", "0.25", "0.5", "0.75", "0.99", "0.999999"] {
                    probes.append(band.lower + width * Self.decimal(fraction))
                }
                for fraction in ["0.000001", "0.01", "0.4"] {
                    probes.append(band.lower - width * Self.decimal(fraction))
                    probes.append(band.upper + width * Self.decimal(fraction))
                }
                for probe in probes {
                    let probeText = formatter.text(Shown.Quantity(value: probe, dimension: dimension))
                    let atEdge = probe == band.lower || probe == band.upper
                    // An edge of an angle band is converted through pi, and feet and inches are
                    // counted through `Double` by the formatter itself, so an exact edge may land
                    // a last digit either side; the points around it are what count there.
                    if atEdge, dimension.angle || (dimension.lengthPower == 1 && formatter.units.usesFeetInchesMarks) {
                        continue
                    }
                    probed += 1
                    #expect(
                        band.contains(probe) == (probeText == shown),
                        "\(seed): \(probe) shows \(probeText), the band says \(band.contains(probe)) for \(shown)"
                    )
                }
            }
        }
        // 9 renderings, 24 seeds with a band, up to 15 probes each.
        #expect(probed > 300, "\(probed) probes")
    }
}
