import Foundation
import Testing
import ZPDFContracts

@testable import ZPDFFormulaEngine

/// Attempts to smuggle a value past the dimension checker (spec 11.4: incompatible dimensions are
/// never added).
///
/// The engine's headline guarantee is that two dimensioned values are only added when their
/// dimensions are equal. `CONVERT` used to break it from the inside: it returned a magnitude
/// expressed in the *target display unit* while tagging the result with the *SI dimension*, so
/// two values that both claimed `length` could be a metre and a millimetre.
@Suite("Dimension safety cannot be bypassed")
struct DimensionBypassTests {

    /// The bug in one line: one metre plus one metre reported as 1001 metres.
    @Test("CONVERT cannot launder a magnitude back into a dimensioned sum")
    func convertCannotLaunderAMagnitude() throws {
        // Two magnitudes in different units still sum to a meaningless 1001, but the result is
        // no longer *labelled* as 1001 metres: it is a bare number, so nothing downstream can
        // treat it as a length. That is the difference between a bad formula and a wrong total.
        let mixed = try evaluate("CONVERT(1, m, mm) + CONVERT(1, m, m)")
        #expect(try mixed.dimension().isDimensionless)
        #expect(try mixed.dimension() != .length)

        // Laundering against a real measurement is now refused outright.
        #expect(throws: (any Error).self) {
            try evaluate("CONVERT(Length, m, mm) + Length", row: try sampleRow(length: "1"))
        }
        #expect(throws: (any Error).self) {
            try evaluate("Area + CONVERT(Area, m2, ft2)", row: try sampleRow(area: "1"))
        }
    }

    /// `CONVERT` answers "how many of unit X is this", which is a bare magnitude, not a quantity
    /// in the SI base unit. Tagging it as a quantity is what made the laundering possible, so the
    /// result is dimensionless and says so.
    @Test("CONVERT yields a dimensionless magnitude")
    func convertYieldsDimensionlessMagnitude() throws {
        let value = try evaluate("CONVERT(Area, m2, ft2)", row: try sampleRow(area: "1"))
        #expect(try value.dimension().isDimensionless)
        #expect(try value.decimal() > 10)

        let length = try evaluate("CONVERT(1, m, mm)")
        #expect(try length.dimension().isDimensionless)
        #expect(try length.decimal() == 1000)
    }

    /// A dimensionless magnitude is still the right operand for a rate, which is the reason
    /// anybody writes `CONVERT` in a takeoff at all.
    @Test("A converted magnitude still multiplies against a unit cost")
    func convertedMagnitudeMultipliesAgainstARate() throws {
        let value = try evaluate(
            "CONVERT(Area, m2, ft2) * UnitCost",
            row: FormulaRow(
                fields: [.netArea: .area(1)],
                unitCost: .money(2, currencyCode: "USD")
            )
        )
        #expect(try value.dimension() == .currency("USD"))
        #expect(try value.decimal() > 20)
    }

    /// Nesting has to keep working: the inner result is dimensionless, and the outer `CONVERT`
    /// accepts a dimensionless operand as "a magnitude already in the source unit".
    @Test("Nested CONVERT still round-trips")
    func nestedConvertRoundTrips() throws {
        #expect(try number("CONVERT(CONVERT(2.5, m, mm), mm, m)") == (try dec("2.5")))
        #expect(try number("CONVERT(CONVERT(1, ft, m), m, ft)") == 1)
    }

    /// The operand check that was already there must survive: a value whose dimension is not the
    /// source unit's is still refused, with the same error shape.
    @Test("CONVERT still refuses an operand of the wrong dimension")
    func convertStillRefusesWrongOperandDimension() throws {
        let error = try captureFormulaError { try FormulaEngine.compile("CONVERT(Area, m, ft)") }
        guard case .dimensionMismatch(let operation, let left, let right) = error.code else {
            Issue.record("got \(error.code)")
            return
        }
        #expect(operation == "convert")
        #expect(left == .area)
        #expect(right == .length)
    }

    /// Two magnitudes in the same unit are a legitimate dimensionless sum.
    @Test("Magnitudes in the same unit still add")
    func magnitudesInTheSameUnitAdd() throws {
        #expect(try number("CONVERT(1, m, mm) + CONVERT(2, m, mm)") == 3000)
    }

    /// The exact-angle fix has to be visible through the formula surface too.
    @Test("CONVERT is exact for angle pairs that are exact by definition")
    func convertIsExactForExactAnglePairs() throws {
        #expect(try number("CONVERT(360, deg, turn)") == 1)
        #expect(try number("CONVERT(1, turn, deg)") == 360)
        #expect(try number("CONVERT(1, gon, deg)") == (try dec("0.9")))
    }

    /// `QuantityDimension`'s memberwise initialiser is unchecked on purpose, so the guarantee
    /// that no out-of-range dimension escapes rests on the algebra rejecting the *result* before
    /// it constructs one. A user can type any of these into a column, so each has to come back as
    /// a typed error — never a trap, and never an `m^6` quantity.
    @Test("A formula that would form an out-of-range dimension is a typed error")
    func outOfRangeDimensionsAreTypedErrors() throws {
        let row = FormulaRow(fields: [.netArea: .area(2), .volume: .volume(2)])
        for source in ["Area * Area", "Area ^ 5", "POW(Area, 30)", "Volume * Volume"] {
            do {
                _ = try FormulaEngine.compile(source).evaluate(row: row)
                Issue.record("\(source) was accepted")
            } catch let error as FormulaEngineError {
                guard case .dimensionRejected(let dimensionError) = error.code,
                      case .unsupportedLengthPower = dimensionError else {
                    Issue.record("\(source) gave \(error.code)")
                    continue
                }
            }
        }
        // The halving direction stays in range and must still work.
        #expect(try evaluate("SQRT(Area)", row: row).dimension() == .length)
    }

    /// Overflow inside a formula must be a typed error rather than a NaN cell.
    @Test("Decimal overflow in a formula is a typed error")
    func overflowIsTyped() throws {
        #expect(throws: (any Error).self) {
            try evaluate("POW(10, 60) * POW(10, 60) * POW(10, 60)")
        }
    }
}
