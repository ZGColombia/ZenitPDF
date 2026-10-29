import Foundation
import Testing

@testable import ZPDFContracts

/// Adversarial cases found by attacking the numeric policy rather than by exercising it.
///
/// Every test here failed before the fix it guards. They are grouped by the invariant they
/// defend, not by the type they touch.
@Suite("Adversarial numerics")
struct AdversarialNumericTests {

    // MARK: - Decimal overflow must not become a silent NaN

    /// `Decimal` saturates to `NaN` rather than trapping, and a `NaN` `Decimal` compares as
    /// neither less nor greater than anything. A ledger total that overflowed would therefore
    /// sort as an ordinary value and print as "NaN" at the export boundary, with no error
    /// anywhere in between. Every arithmetic entry point must refuse to hand one back.
    @Test("Decimal overflow is a typed error, never a NaN quantity")
    func decimalOverflowIsTyped() throws {
        let huge = DecimalQuantity.length(try #require(Decimal(string: "1e100", locale: nil)))

        #expect(throws: NumericError.decimalOverflow(operation: "multiply")) {
            try huge.multiplied(by: huge)
        }
        #expect(throws: NumericError.decimalOverflow(operation: "scale")) {
            try huge.scaled(by: try #require(Decimal(string: "1e100", locale: nil)))
        }

        let nearTop = DecimalQuantity.length(Decimal.greatestFiniteMagnitude)
        #expect(throws: NumericError.decimalOverflow(operation: "add")) {
            try nearTop.adding(nearTop)
        }
        #expect(throws: NumericError.decimalOverflow(operation: "subtract")) {
            try nearTop.subtracting(nearTop.negated)
        }
    }

    /// The same guard has to hold on the batch path, which is what the ledger actually calls.
    @Test("Summing to overflow throws instead of returning NaN")
    func summationOverflowIsTyped() throws {
        let nearTop = DecimalQuantity.length(Decimal.greatestFiniteMagnitude)
        #expect(throws: (any Error).self) {
            try DecimalQuantity.sum(Array(repeating: nearTop, count: 8))
        }
    }

    /// A quantity that somehow holds a NaN must at least admit it, so callers can assert on it.
    @Test("isFinite reports a NaN magnitude")
    func isFiniteReportsNaN() throws {
        #expect(DecimalQuantity.length(1).isFinite)
        #expect(!DecimalQuantity.length(Decimal.nan).isFinite)
    }

    // MARK: - NumericPolicy.exact

    /// The published range must match what `Decimal` actually accepts.
    @Test("Every exponent in the published range produces a finite Decimal")
    func publishedExponentRangeIsHonest() {
        for exponent in NumericPolicy.decimalExponentRange {
            let value = NumericPolicy.exact(1, exponent)
            #expect(!value.isNaN, "exponent \(exponent) produced NaN")
            if exponent >= -100 { #expect(value != 0, "exponent \(exponent) collapsed to zero") }
        }
    }

    // MARK: - Double -> Decimal at the extremes

    /// Out-of-range doubles must throw, never return `Decimal.nan` or silently underflow to zero.
    @Test("Double values outside Decimal's range are typed errors")
    func doubleToDecimalExtremes() throws {
        for value in [1e300, 1e-300, 5e-324, Double.greatestFiniteMagnitude] {
            #expect(throws: NumericError.notRepresentableAsDecimal(value)) {
                try NumericPolicy.decimal(from: value)
            }
        }
        for value in [Double.nan, Double.infinity, -Double.infinity] {
            #expect(throws: (any Error).self) { try NumericPolicy.decimal(from: value) }
        }
        // The band that matters for a takeoff round-trips.
        for value in [1e9, 1e-9, 0.3048, -1234.5678] {
            let decimal = try NumericPolicy.decimal(from: value)
            #expect(!decimal.isNaN)
            #expect(abs(NumericPolicy.double(from: decimal) - value) <= abs(value) * 1e-14)
        }
    }

    // MARK: - Dimension safety cannot be bypassed by decoding

    /// `validate()` exists but nothing on the decode path called it, so a hand-edited or
    /// corrupted project file could introduce a dimension the algebra never allows — and two
    /// such dimensions, being equal, would happily add.
    @Test("A malformed dimension payload is rejected at decode")
    func malformedDimensionIsRejectedOnDecode() throws {
        let decoder = JSONDecoder()

        for payload in [
            #"{"lengthPower":99,"angle":false}"#,
            #"{"lengthPower":-4,"angle":false}"#,
            #"{"lengthPower":0,"angle":false,"currencyCode":"zz"}"#,
            #"{"lengthPower":0,"angle":false,"currencyCode":"kronor"}"#,
            #"{"lengthPower":0,"angle":false,"currencyCode":""}"#,
            #"{"lengthPower":1,"angle":false,"ratio":true}"#,
            #"{"lengthPower":0,"angle":true,"ratio":true}"#,
            #"{"lengthPower":0,"angle":false,"currencyCode":"SEK","ratio":true}"#
        ] {
            #expect(throws: (any Error).self, "accepted \(payload)") {
                try decoder.decode(QuantityDimension.self, from: Data(payload.utf8))
            }
        }

        // Well-formed payloads still decode, including the negative powers a unit rate needs.
        for payload in [
            #"{"lengthPower":2,"angle":false}"#,
            #"{"lengthPower":-2,"angle":false,"currencyCode":"SEK"}"#,
            #"{"lengthPower":0,"angle":true}"#,
            #"{"lengthPower":0,"angle":false,"ratio":true}"#,
            #"{"lengthPower":0,"angle":false,"ratio":false}"#
        ] {
            _ = try decoder.decode(QuantityDimension.self, from: Data(payload.utf8))
        }
    }

    /// `DecimalQuantity` carries a dimension, so it inherits the same guard.
    @Test("A quantity carrying a malformed dimension is rejected at decode")
    func malformedQuantityIsRejectedOnDecode() {
        let payload = #"{"value":1,"dimension":{"lengthPower":500,"angle":false}}"#
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(DecimalQuantity.self, from: Data(payload.utf8))
        }
    }

    /// A round trip through `Codable` must survive the new guard unchanged.
    @Test("Valid dimensions still round-trip")
    func validDimensionsRoundTrip() throws {
        let cases: [QuantityDimension] = [
            .count, .length, .area, .volume, .angle,
            .currency("SEK"), .currencyRate("EUR", perLengthPower: 2)
        ]
        for dimension in cases {
            let data = try JSONEncoder().encode(dimension)
            #expect(try JSONDecoder().decode(QuantityDimension.self, from: data) == dimension)
        }
    }

    // MARK: - Slope

    /// `sqrt(1 + r*r)` overflows to infinity once `r` passes about 1.3e154, and a `NaN` ratio
    /// propagated straight through. Neither may leave the type as a number.
    @Test("trueLengthFactor is finite or a typed error, never inf or NaN")
    func trueLengthFactorStaysFinite() throws {
        // Well inside the range: unchanged behaviour.
        #expect(try SlopeExpression.ratioNToOne(1).trueLengthFactor() == 2.0.squareRoot())
        let thousand = try SlopeExpression.ratioNToOne(1000).trueLengthFactor()
        #expect(abs(thousand - 1000.000499999875) < 1e-9)

        // Beyond the naive formula's overflow point the answer is still representable.
        var enormous = Decimal(1)
        for _ in 0..<16 { enormous *= NumericPolicy.exact(1, 10) }   // 1e160
        if !enormous.isNaN {
            let factor = try SlopeExpression.ratioNToOne(enormous).trueLengthFactor()
            #expect(factor.isFinite, "1e160 slope produced \(factor)")
        }

        // A NaN ratio must be refused rather than returned.
        #expect(throws: SlopeError.nonFiniteSlopeRatio) {
            try SlopeExpression.ratioNToOne(Decimal.nan).trueLengthFactor()
        }
        #expect(throws: SlopeError.nonFiniteSlopeRatio) {
            try SlopeExpression.decimalRatio(Decimal.nan).trueLengthFactor()
        }
    }

    // MARK: - Unit conversions that are exact by definition

    /// The imperial definitions are exact decimals and must convert without a remainder.
    @Test("Imperial length, area and volume conversions are exact")
    func imperialConversionsAreExact() throws {
        let exactFoot = try #require(Decimal(string: "0.3048", locale: nil))
        let exactInch = try #require(Decimal(string: "0.0254", locale: nil))
        #expect(LengthUnit.foot.toBase(1) == exactFoot)
        #expect(LengthUnit.inch.toBase(1) == exactInch)
        #expect(LengthUnit.mile.convert(1, to: .foot) == 5280)
        #expect(LengthUnit.yard.convert(1, to: .foot) == 3)
        #expect(LengthUnit.foot.convert(1, to: .inch) == 12)
        #expect(AreaUnit.acre.convert(1, to: .squareFoot) == 43560)
        #expect(AreaUnit.squareYard.convert(1, to: .squareFoot) == 9)
        #expect(VolumeUnit.cubicYard.convert(1, to: .cubicFoot) == 27)
        #expect(VolumeUnit.cubicMetre.convert(1, to: .litre) == 1000)

        // ft -> m -> ft must be the identity, not 0.9999...
        for unit in LengthUnit.allCases {
            #expect(LengthUnit.metre.convert(unit.toBase(1), to: unit) == 1, "\(unit) round trip")
        }
    }

    /// Degree, gradian and turn are defined against a full turn by exact integers. Routing them
    /// through radians made `360 deg -> turn` come back as 0.99999999999999999999999999999999999998.
    /// Only a conversion that actually involves the radian may be inexact.
    @Test("Angle conversions that are exact by definition do not drift")
    func angleConversionsThatAreExactDoNotDrift() {
        #expect(AngleUnit.degree.convert(360, to: .turn) == 1)
        #expect(AngleUnit.turn.convert(1, to: .degree) == 360)
        #expect(AngleUnit.turn.convert(1, to: .gradian) == 400)
        #expect(AngleUnit.gradian.convert(400, to: .turn) == 1)
        #expect(AngleUnit.gradian.convert(1, to: .degree) == Decimal(string: "0.9", locale: nil))
        #expect(AngleUnit.degree.convert(90, to: .gradian) == 100)
        #expect(AngleUnit.degree.convert(180, to: .turn) * 2 == 1)

        // Self-conversion is the identity for every unit, radian included.
        for unit in AngleUnit.allCases {
            #expect(unit.convert(7, to: unit) == 7, "\(unit) self conversion")
        }
    }

    /// The exactness the contract advertises must match what the conversion actually delivers.
    @Test("A unit that claims exactness delivers it against every exact peer")
    func exactnessClaimIsHonest() {
        for from in AngleUnit.allCases where from != .radian {
            for to in AngleUnit.allCases where to != .radian {
                let there = from.convert(360_000, to: to)
                let back = to.convert(there, to: from)
                #expect(back == 360_000, "\(from) -> \(to) -> \(from) drifted to \(back)")
            }
        }
    }
}
