import Foundation
import Testing
@testable import ZPDFContracts

/// Spec 11.4: incompatible dimensions are never added. These tests pin down what the algebra
/// accepts as well as what it rejects, because a rule that only ever says no is easy to satisfy
/// and useless.
@Suite("Dimension algebra")
struct DimensionAlgebraTests {

    @Test("Products of length build area and volume")
    func lengthProducts() throws {
        #expect(try QuantityDimension.length.multiplied(by: .length) == .area)
        #expect(try QuantityDimension.area.multiplied(by: .length) == .volume)
        #expect(try QuantityDimension.length.multiplied(by: .count) == .length)
    }

    @Test("Quotients reduce length powers")
    func lengthQuotients() throws {
        #expect(try QuantityDimension.volume.divided(by: .area) == .length)
        #expect(try QuantityDimension.area.divided(by: .length) == .length)
        // A like-for-like quotient is a ratio, not a count (ADR-0014): 10 m / 4 m is a factor.
        #expect(try QuantityDimension.length.divided(by: .length) == .ratio)
    }

    @Test("A fourth power of length is rejected")
    func lengthPowerOverflow() {
        #expect(throws: DimensionError.unsupportedLengthPower(4)) {
            _ = try QuantityDimension.volume.multiplied(by: .length)
        }
    }

    @Test("angle times angle has no meaning here")
    func angleProduct() {
        #expect(throws: DimensionError.angleProductUndefined) {
            _ = try QuantityDimension.angle.multiplied(by: .angle)
        }
    }

    @Test("Dividing a non-angle by an angle is rejected; angle over angle is dimensionless")
    func angleQuotient() throws {
        #expect(throws: DimensionError.angleQuotientUndefined) {
            _ = try QuantityDimension.length.divided(by: .angle)
        }
        #expect(try QuantityDimension.angle.divided(by: .angle) == .ratio)
    }

    @Test("Money times money is rejected; money over the same money cancels")
    func currencyRules() throws {
        #expect(throws: DimensionError.self) {
            _ = try QuantityDimension.currency("SEK").multiplied(by: .currency("SEK"))
        }
        #expect(try QuantityDimension.currency("SEK").divided(by: .currency("SEK")) == .ratio)
        #expect(throws: DimensionError.self) {
            _ = try QuantityDimension.currency("SEK").divided(by: .currency("EUR"))
        }
        #expect(throws: DimensionError.self) {
            _ = try QuantityDimension.area.divided(by: .currency("SEK"))
        }
        // Unit cost times area is a total cost, and stays in the same currency.
        let unitCost = QuantityDimension(lengthPower: -2, currencyCode: "SEK")
        #expect(try unitCost.multiplied(by: .area) == .currency("SEK"))
    }

    @Test("An ISO 4217 code must be three uppercase letters")
    func currencyCodeValidation() {
        #expect(QuantityDimension.isValidCurrencyCode("SEK"))
        #expect(!QuantityDimension.isValidCurrencyCode("sek"))
        #expect(!QuantityDimension.isValidCurrencyCode("SEKK"))
        #expect(!QuantityDimension.isValidCurrencyCode("S3K"))
        #expect(throws: DimensionError.self) {
            try QuantityDimension(currencyCode: "sek").validate()
        }
    }

    @Test("Adding an area to a length is a typed error, not a number")
    func additionRejectsMismatch() {
        #expect(throws: DimensionError.self) {
            _ = try DecimalQuantity.area(10) + DecimalQuantity.length(2)
        }
        #expect(throws: DimensionError.self) {
            _ = try DecimalQuantity.count(1) - DecimalQuantity.angle(1)
        }
    }

    @Test("Adding two areas works and stays an area")
    func additionAcceptsMatch() throws {
        let total = try DecimalQuantity.area(10) + DecimalQuantity.area(2.5)
        #expect(total.value == Decimal(string: "12.5"))
        #expect(total.dimension == .area)
    }

    @Test("Area times depth is a volume; volume over area is a depth")
    func quantityProducts() throws {
        let volume = try DecimalQuantity.area(12) * DecimalQuantity.length(Decimal(string: "0.2") ?? 0)
        #expect(volume.dimension == .volume)
        #expect(volume.value == Decimal(string: "2.4"))

        let depth = try volume / DecimalQuantity.area(12)
        #expect(depth.dimension == .length)
        #expect(depth.value == Decimal(string: "0.2"))
    }

    @Test("Dividing by zero is a typed error, never an infinity")
    func divisionByZero() {
        #expect(throws: DimensionError.divisionByZero) {
            _ = try DecimalQuantity.area(1) / DecimalQuantity.length(0)
        }
    }

    @Test("Summing a homogeneous list works; a heterogeneous one throws")
    func summation() throws {
        let total = try DecimalQuantity.sum([.length(1), .length(2), .length(3)])
        #expect(total == DecimalQuantity.length(6))
        #expect(throws: DimensionError.self) {
            _ = try DecimalQuantity.sum([.length(1), .area(2)])
        }
        #expect(try DecimalQuantity.sum([], dimension: .volume) == DecimalQuantity.zero(.volume))
    }

    @Test("Base unit symbols name the SI unit the value is stored in")
    func baseUnitSymbols() {
        #expect(QuantityDimension.count.baseUnitSymbol == "1")
        #expect(QuantityDimension.length.baseUnitSymbol == "m")
        #expect(QuantityDimension.area.baseUnitSymbol == "m^2")
        #expect(QuantityDimension.volume.baseUnitSymbol == "m^3")
        #expect(QuantityDimension.angle.baseUnitSymbol == "rad")
        #expect(QuantityDimension.currency("SEK").baseUnitSymbol == "SEK")
        #expect(QuantityDimension(lengthPower: -2, currencyCode: "SEK").baseUnitSymbol == "SEK/m^2")
    }

    @Test("Every measurement field's dimension is supported and self-consistent")
    func measurementFieldDimensions() throws {
        for field in MeasurementField.allCases {
            try field.dimension.validate()
        }
        #expect(MeasurementField.volume.dimension == .volume)
        #expect(MeasurementField.slopePercent.dimension == .ratio)
        #expect(MeasurementField.slopeRatio.dimension == .ratio)
        #expect(MeasurementField.count.dimension == .count)
        #expect(MeasurementField.slopeAngle.dimension == .angle)
        #expect(MeasurementField.netWallArea.dimension == .area)
    }

    // MARK: - Ratio versus count (ADR-0014, code review CR-102)

    /// Before ADR-0014 `.ratio` and `.count` were the same value, so `4 count + 1.15 ratio`
    /// summed to `5.15` with no refusal. Old output: `DecimalQuantity(5.15, .count)`.
    @Test("A ratio never sums into a count total (CR-102)")
    func ratioAndCountAreNotAdditive() throws {
        #expect(QuantityDimension.ratio != QuantityDimension.count)
        #expect(throws: DimensionError.incompatibleDimensions(left: .count, right: .ratio)) {
            _ = try DecimalQuantity.count(4) + DecimalQuantity.ratio(Decimal(string: "1.15")!)
        }
        #expect(throws: DimensionError.self) {
            _ = try DecimalQuantity.sum([.count(1), .ratio(1)])
        }
        // Homogeneous ratios still add, and stay ratios.
        let factors = try DecimalQuantity.ratio(1) + DecimalQuantity.ratio(Decimal(string: "0.15")!)
        #expect(factors == DecimalQuantity.ratio(Decimal(string: "1.15")!))
    }

    @Test("A ratio scales whatever it multiplies and only survives against another ratio")
    func ratioProducts() throws {
        #expect(try QuantityDimension.area.multiplied(by: .ratio) == .area)
        #expect(try QuantityDimension.ratio.multiplied(by: .length) == .length)
        #expect(try QuantityDimension.count.multiplied(by: .ratio) == .count)
        #expect(try QuantityDimension.ratio.multiplied(by: .count) == .count)
        #expect(try QuantityDimension.ratio.multiplied(by: .ratio) == .ratio)
        #expect(try QuantityDimension.currency("SEK").multiplied(by: .ratio) == .currency("SEK"))
        // 4 doors x 1.1 waste = 4.4 doors, still a count; a factor squared is a factor.
        let doors = try DecimalQuantity.count(4) * DecimalQuantity.ratio(Decimal(string: "1.1")!)
        #expect(doors.dimension == .count)
        #expect(doors.value == Decimal(string: "4.4"))
    }

    @Test("Quotients: like-for-like is a ratio, a count over a factor is a count")
    func ratioQuotients() throws {
        #expect(try QuantityDimension.count.divided(by: .count) == .ratio)
        #expect(try QuantityDimension.ratio.divided(by: .ratio) == .ratio)
        #expect(try QuantityDimension.count.divided(by: .ratio) == .count)
        #expect(try QuantityDimension.ratio.divided(by: .count) == .count)
        #expect(try QuantityDimension.length.divided(by: .ratio) == .length)
        #expect(try QuantityDimension.area.divided(by: .length) == .length)
        let rate = QuantityDimension(lengthPower: -2, currencyCode: "SEK")
        #expect(try rate.divided(by: rate) == .ratio)
        // The ratio tag never lands on a dimensioned result.
        for dimension in [try QuantityDimension.ratio.divided(by: .length),
                          try QuantityDimension.length.divided(by: .ratio),
                          try QuantityDimension.ratio.multiplied(by: .area)] {
            #expect(!dimension.ratio)
            try dimension.validate()
        }
    }

    @Test("The ratio tag is only valid on a dimensionless dimension")
    func ratioValidation() throws {
        try QuantityDimension.ratio.validate()
        for bad in [
            QuantityDimension(lengthPower: 1, ratio: true),
            QuantityDimension(lengthPower: 0, angle: true, ratio: true),
            QuantityDimension(lengthPower: 0, currencyCode: "SEK", ratio: true)
        ] {
            #expect(throws: DimensionError.ratioOnDimensionedQuantity(bad)) { try bad.validate() }
        }
        #expect(QuantityDimension.ratio.isDimensionless)
        #expect(QuantityDimension.ratio.baseUnitSymbol == "1")
    }

    /// The encoded form of every pre-ADR-0014 dimension is unchanged; only a ratio gains a key.
    @Test("A ratio encodes with its tag; a count encodes exactly as before")
    func ratioCodable() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let count = String(decoding: try encoder.encode(QuantityDimension.count), as: UTF8.self)
        let ratio = String(decoding: try encoder.encode(QuantityDimension.ratio), as: UTF8.self)
        #expect(count == #"{"angle":false,"lengthPower":0}"#)
        #expect(ratio == #"{"angle":false,"lengthPower":0,"ratio":true}"#)
        let decoder = JSONDecoder()
        #expect(try decoder.decode(QuantityDimension.self, from: Data(ratio.utf8)) == .ratio)
        // Old bytes — no key — are a count, because that is all the bytes ever said.
        #expect(try decoder.decode(QuantityDimension.self, from: Data(count.utf8)) == .count)
        #expect(throws: DimensionError.ratioOnDimensionedQuantity(QuantityDimension(lengthPower: 2, ratio: true))) {
            try decoder.decode(QuantityDimension.self, from: Data(#"{"lengthPower":2,"angle":false,"ratio":true}"#.utf8))
        }
    }

    /// A slope ratio stored by a pre-ADR-0014 build carries `{"lengthPower":0,"angle":false}`,
    /// which now decodes as a count; the field says it is a ratio. Old output: the decoded
    /// value kept `.count` and `validateDimensions()` threw `incompatibleDimensions`.
    @Test("A stored dimensionless value takes its field's dimension on decode")
    func storedResultReTagsDimensionlessValues() throws {
        let payload = """
        {"values":{"slopeRatio":{"value":0.5,"dimension":{"lengthPower":0,"angle":false}},
                   "slopePercent":{"value":50,"dimension":{"lengthPower":0,"angle":false}},
                   "count":{"value":3,"dimension":{"lengthPower":0,"angle":false}},
                   "planLength":{"value":12,"dimension":{"lengthPower":1,"angle":false}}},
         "warnings":[],"formulaVersion":2}
        """
        let decoded = try JSONDecoder().decode(MeasurementResult.self, from: Data(payload.utf8))
        #expect(decoded[.slopeRatio]?.dimension == .ratio)
        #expect(decoded[.slopeRatio]?.value == Decimal(string: "0.5"))
        #expect(decoded[.slopePercent]?.dimension == .ratio)
        #expect(decoded[.count]?.dimension == .count)
        #expect(decoded[.planLength]?.dimension == .length)
        #expect(decoded.formulaVersion == 2)
        try decoded.validateDimensions()

        // A genuinely wrong dimension is left alone, so the mismatch stays visible.
        let wrong = """
        {"values":{"planArea":{"value":1,"dimension":{"lengthPower":1,"angle":false}}},
         "warnings":[],"formulaVersion":2}
        """
        let mismatch = try JSONDecoder().decode(MeasurementResult.self, from: Data(wrong.utf8))
        #expect(mismatch[.planArea]?.dimension == .length)
        #expect(throws: DimensionError.self) { try mismatch.validateDimensions() }

        // And a fresh result round-trips with its tags intact.
        let fresh = MeasurementResult(values: [.slopeRatio: .ratio(1), .count: .count(2)])
        let data = try JSONEncoder().encode(fresh)
        #expect(try JSONDecoder().decode(MeasurementResult.self, from: data) == fresh)
    }
}
