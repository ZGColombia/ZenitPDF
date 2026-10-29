import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFFormulaEngine

/// Spec 11.4 leaves rounding to the boundary; a formula *is* a boundary the user asked for.
///
/// The engine rounds **half away from zero**, documented on ``DecimalMath``. These tests pin that
/// down against the banker's-rounding alternative so the choice cannot drift.
@Suite("The ROUND family")
struct RoundingTests {

    @Test("ROUND is half away from zero, not banker's")
    func halfAwayFromZero() throws {
        #expect(try number("ROUND(2.5, 0)") == 3)
        #expect(try number("ROUND(3.5, 0)") == 4)
        #expect(try number("ROUND(0 - 2.5, 0)") == -3)
    }

    @Test("ROUND(0.125, 2) is 0.13; banker's rounding would say 0.12")
    func bankersRoundingIsNotUsed() throws {
        #expect(try number("ROUND(0.125, 2)") == (try dec("0.13")))
        #expect(try number("ROUND(0.135, 2)") == (try dec("0.14")))
    }

    @Test("Decimal arithmetic makes ROUND(2.675, 2) exact where Double would not")
    func decimalIsExact() throws {
        #expect(try number("ROUND(2.675, 2)") == (try dec("2.68")))
    }

    @Test("A missing digit count means zero decimals")
    func defaultDigits() throws {
        #expect(try number("ROUND(2.5)") == 3)
    }

    @Test("ROUNDUP is away from zero and ROUNDDOWN is toward zero")
    func magnitudeDirectedRounding() throws {
        #expect(try number("ROUNDUP(1.1, 0)") == 2)
        #expect(try number("ROUNDUP(0 - 1.1, 0)") == -2)
        #expect(try number("ROUNDDOWN(1.9, 0)") == 1)
        #expect(try number("ROUNDDOWN(0 - 1.9, 0)") == -1)
    }

    @Test("CEILING and FLOOR are sign-directed, which differs from ROUNDUP/ROUNDDOWN")
    func signDirectedRounding() throws {
        #expect(try number("CEILING(0 - 1.1, 0)") == -1)
        #expect(try number("FLOOR(0 - 1.1, 0)") == -2)
        #expect(try number("CEILING(1.1, 0)") == 2)
        #expect(try number("FLOOR(1.9, 0)") == 1)
    }

    @Test("Negative digit counts round to tens, hundreds and beyond")
    func negativeDigits() throws {
        #expect(try number("ROUND(1234.5, -2)") == 1200)
        #expect(try number("ROUNDUP(1201, -2)") == 1300)
        #expect(try number("ROUNDDOWN(1299, -2)") == 1200)
    }

    @Test("Rounding preserves the dimension")
    func roundingPreservesDimension() throws {
        let value = try evaluate("ROUND(Area, 1)", row: try sampleRow(area: "12.55"))
        #expect(try value.decimal() == (try dec("12.6")))
        #expect(try value.dimension() == .area)
    }

    @Test("A fractional or out-of-range digit count is a typed error")
    func invalidDigits() throws {
        let fractional = try captureFormulaError { try number("ROUND(1.5, 0.5)") }
        guard case .invalidRoundingDigits = fractional.code else {
            Issue.record("got \(fractional.code)")
            return
        }
        let tooLarge = try captureFormulaError { try number("ROUND(1.5, 99)") }
        guard case .invalidRoundingDigits = tooLarge.code else {
            Issue.record("got \(tooLarge.code)")
            return
        }
    }

    @Test("Rounding an exact value is the identity")
    func exactValuesAreUntouched() throws {
        #expect(try number("ROUND(2, 0)") == 2)
        #expect(try number("ROUNDUP(2, 0)") == 2)
        #expect(try number("ROUNDDOWN(2, 0)") == 2)
        #expect(try number("CEILING(0 - 2, 0)") == -2)
        #expect(try number("FLOOR(0 - 2, 0)") == -2)
    }
}

@Suite("Unit conversion")
struct ConversionTests {

    @Test("CONVERT moves a magnitude between units of the same dimension")
    func lengthConversion() throws {
        #expect(try number("CONVERT(1, m, mm)") == 1000)
        #expect(try number("CONVERT(1, ft, m)") == (try dec("0.3048")))
        #expect(try number("CONVERT(12, in, ft)") == 1)
    }

    @Test("Area and volume conversions use the exact international factors")
    func areaAndVolumeConversion() throws {
        #expect(try number("CONVERT(1, ft2, m2)") == (try dec("0.09290304")))
        #expect(try number("CONVERT(1, yd3, m3)") == (try dec("0.764554857984")))
        #expect(try number("CONVERT(1, m3, l)") == 1000)
    }

    /// The result is a **magnitude in the target unit**, not a quantity in the SI base unit, so
    /// it is dimensionless. Tagging it `.area` — which this test used to assert — is what let
    /// `CONVERT(1, m, mm) + CONVERT(1, m, m)` report 1001 metres; see
    /// ``DimensionBypassTests/convertCannotLaunderAMagnitude()``.
    @Test("The result is a dimensionless magnitude in the target unit")
    func conversionDimension() throws {
        let value = try evaluate("CONVERT(Area, m2, ft2)", row: try sampleRow(area: "1"))
        #expect(try value.dimension().isDimensionless)
        #expect(try value.decimal() > 10)
    }

    @Test("CONVERT refuses units of different dimensions")
    func incompatibleUnits() throws {
        let error = try captureFormulaError { try FormulaEngine.compile("CONVERT(1, m, m2)") }
        #expect(error.code == .incompatibleUnits(from: "m", to: "m2"))
    }

    @Test("CONVERT refuses a value whose dimension is not the source unit's")
    func valueDimensionMustMatchSourceUnit() throws {
        let error = try captureFormulaError { try FormulaEngine.compile("CONVERT(Area, m, ft)") }
        guard case .dimensionMismatch(let operation, let left, let right) = error.code else {
            Issue.record("got \(error.code)")
            return
        }
        #expect(operation == "convert")
        #expect(left == .area)
        #expect(right == .length)
    }

    @Test("An unknown unit name is a typed error")
    func unknownUnit() throws {
        let error = try captureFormulaError { try FormulaEngine.compile("CONVERT(1, m, furlong)") }
        #expect(error.code == .unknownUnit("furlong"))
    }

    @Test("Unit names may be quoted and are case-insensitive")
    func quotedUnits() throws {
        #expect(try number("CONVERT(1, \"M\", \"MM\")") == 1000)
    }

    @Test("Converting through a round trip returns the original value")
    func roundTripConversion() throws {
        #expect(try number("CONVERT(CONVERT(2.5, m, mm), mm, m)") == (try dec("2.5")))
    }
}
