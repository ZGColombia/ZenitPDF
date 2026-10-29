import Foundation
import Testing
@testable import ZPDFContracts

/// Quantities core, the contract side (ADR-0035).
///
/// Expected values are derived by hand in the comment beside each check, never read from the
/// code under test.
@Suite("ADR-0035 quantities core (contracts)")
struct Iter1QuantitiesCoreContractTests {

    // MARK: - R-172 exact-or-refuse addition

    /// 38 nines plus 0.5 needs 39 significant digits. Old output: `adding` returned the sum
    /// rounded to 38 digits (1e38 after the carry), silently, while the ledger's `NSDecimalAdd`
    /// path refused the same two numbers. Now both refuse.
    @Test("R-172: an addition that would round is refused, not rounded")
    func inexactAdditionRefused() throws {
        let wide = DecimalQuantity.area(Decimal(string: "99999999999999999999999999999999999999")!)
        let half = DecimalQuantity.area(Decimal(string: "0.5")!)
        #expect(throws: NumericError.decimalOverflow(operation: "add")) { try wide.adding(half) }
        #expect(throws: NumericError.decimalOverflow(operation: "subtract")) { try wide.subtracting(half) }
        #expect(throws: NumericError.decimalOverflow(operation: "add")) { try DecimalQuantity.sum([wide, half]) }

        // The primitive reports what NSDecimalAdd reports.
        #expect(NumericPolicy.add(wide.value, half.value).status == .lossOfPrecision)
        // 38 nines − 7.7 = …91.3 exactly, 39 digits. NSDecimalSubtract returns …92 with
        // `.noError` on this toolchain, which is why subtraction is the addition of the negated
        // operand: that reports the loss.
        let sevenPointSeven = Decimal(string: "7.7")!
        #expect(NumericPolicy.subtract(wide.value, sevenPointSeven).status == .lossOfPrecision)
        #expect(throws: NumericError.decimalOverflow(operation: "subtract")) {
            try wide.subtracting(.area(sevenPointSeven))
        }

        // Exact sums are unchanged: 0.1 + 0.2 = 0.3 exactly in Decimal; 12.5 − 0.25 = 12.25.
        #expect(try DecimalQuantity.area(Decimal(string: "0.1")!).adding(.area(Decimal(string: "0.2")!)).value
            == Decimal(string: "0.3")!)
        #expect(try DecimalQuantity.length(Decimal(string: "12.5")!).subtracting(.length(Decimal(string: "0.25")!)).value
            == Decimal(string: "12.25")!)
        #expect(try NumericPolicy.exactSum(1, 2) == 3)
    }

    // MARK: - R-169 coordinate bound

    /// The bound is 1e7 page points, inclusive; one step beyond is outside. A NaN is outside too.
    @Test("R-169: the coordinate bound is 1e7 pt, inclusive, for every kind of coordinate")
    func coordinateBound() {
        let page = PageID(UUID(uuidString: "11111111-1111-4111-8111-111111111111")!)
        #expect(MeasurementGeometry.coordinateMagnitudeBound == 1e7)
        #expect(MeasurementGeometry(pageID: page, points: [PDFPoint(x: -1e7, y: 1e7)]).isWithinCoordinateBound)
        #expect(!MeasurementGeometry(pageID: page, points: [PDFPoint(x: 1e7.nextUp, y: 0)]).isWithinCoordinateBound)
        #expect(!MeasurementGeometry(pageID: page, points: [PDFPoint(x: .nan, y: 0)]).isWithinCoordinateBound)
        #expect(!MeasurementGeometry(pageID: page, circles: [CircleGeometry(center: PDFPoint(x: 0, y: 0), radius: 2e7)])
            .isWithinCoordinateBound)
        #expect(!MeasurementGeometry(
            pageID: page,
            arcs: [ArcGeometry(center: PDFPoint(x: 0, y: -3e7), radius: 1, startAngle: 0, sweepAngle: 1)]
        ).isWithinCoordinateBound)
        let hole = PolygonRing(points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 1, y: 0), PDFPoint(x: 5e7, y: 1)])
        let outer = PolygonRing(points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 10, y: 0), PDFPoint(x: 10, y: 10)])
        #expect(!MeasurementGeometry(pageID: page, polygons: [PolygonGeometry(outer: outer, holes: [hole])])
            .isWithinCoordinateBound)
    }

    // MARK: - R-182 opening areas

    /// Old output: `validate()` accepted any opening; −5 m² reached the wall calculator.
    @Test("R-182: validate() refuses a negative or NaN opening area and accepts zero")
    func openingAreasValidated() throws {
        #expect(throws: MeasurementError.negativeParameter(.openingAreas)) {
            try MeasurementParameters(openingAreas: [2, -5]).validate()
        }
        #expect(throws: MeasurementError.negativeParameter(.openingAreas)) {
            try MeasurementParameters(openingAreas: [.nan]).validate()
        }
        try MeasurementParameters(openingAreas: [0, Decimal(string: "1.5")!]).validate()
    }

    // MARK: - NL-MEASURE-10 per-markup display override

    /// A record written before ADR-0035 has no `displayOverride` key: it decodes with no override
    /// (the project's units), and a record without an override encodes without the key, so every
    /// existing record stays byte-identical.
    @Test("NL-MEASURE-10: an old parameters record decodes with no override and re-encodes unchanged")
    func displayOverrideIsAdditive() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let old = try encoder.encode(MeasurementParameters.default)
        #expect(!String(decoding: old, as: UTF8.self).contains("displayOverride"))
        let decoded = try JSONDecoder().decode(MeasurementParameters.self, from: old)
        #expect(decoded.displayOverride == nil)
        #expect(try encoder.encode(decoded) == old)

        // A metric override on a record is distinguishable from no override — the thing the
        // `display` field alone could not say — and survives a round trip.
        var overridden = MeasurementParameters.default
        overridden.displayOverride = DisplayUnitPolicy(length: .metre, precision: .decimalPlaces(2))
        let data = try encoder.encode(overridden)
        let back = try JSONDecoder().decode(MeasurementParameters.self, from: data)
        #expect(back.displayOverride == DisplayUnitPolicy(length: .metre, precision: .decimalPlaces(2)))
        #expect(back != MeasurementParameters.default)
    }
}
