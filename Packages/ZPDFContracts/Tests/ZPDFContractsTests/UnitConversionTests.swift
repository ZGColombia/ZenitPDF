import Foundation
import Testing
@testable import ZPDFContracts

/// The conversion factors are the whole reason the takeoff can be trusted. A wrong factor is not
/// a rounding problem, it is a wrong bid, so these tests assert exact `Decimal` equality rather
/// than a tolerance.
@Suite("Unit conversions")
struct UnitConversionTests {

    /// Values chosen to include a whole number, a half, a long decimal and a large magnitude.
    static let probes: [Decimal] = [1, 2, Decimal(string: "0.5") ?? 0,
                                    Decimal(string: "1234.5678") ?? 0,
                                    Decimal(string: "987654321.123456") ?? 0]

    @Test("Length units round-trip exactly through the SI base")
    func lengthRoundTrip() {
        for unit in LengthUnit.allCases {
            #expect(unit.isExactByDefinition)
            for probe in Self.probes {
                #expect(unit.fromBase(unit.toBase(probe)) == probe,
                        "\(unit.rawValue) failed to round-trip \(probe)")
            }
        }
    }

    @Test("Area units round-trip exactly through the SI base")
    func areaRoundTrip() {
        for unit in AreaUnit.allCases {
            #expect(unit.isExactByDefinition)
            for probe in Self.probes {
                #expect(unit.fromBase(unit.toBase(probe)) == probe,
                        "\(unit.rawValue) failed to round-trip \(probe)")
            }
        }
    }

    @Test("Volume units round-trip exactly through the SI base")
    func volumeRoundTrip() {
        for unit in VolumeUnit.allCases {
            #expect(unit.isExactByDefinition)
            for probe in Self.probes {
                #expect(unit.fromBase(unit.toBase(probe)) == probe,
                        "\(unit.rawValue) failed to round-trip \(probe)")
            }
        }
    }

    @Test("Radian round-trips exactly; the other angle units are declared approximate")
    func angleExactness() {
        #expect(AngleUnit.radian.isExactByDefinition)
        for unit in AngleUnit.allCases where unit != .radian {
            #expect(!unit.isExactByDefinition, "\(unit.rawValue) must not claim exactness: it depends on pi")
        }
        for probe in Self.probes {
            #expect(AngleUnit.radian.fromBase(AngleUnit.radian.toBase(probe)) == probe)
        }
    }

    @Test("The international definitions hold exactly")
    func internationalDefinitions() {
        #expect(LengthUnit.inch.factorToBase == Decimal(string: "0.0254"))
        #expect(LengthUnit.foot.factorToBase == Decimal(string: "0.3048"))
        #expect(LengthUnit.yard.factorToBase == Decimal(string: "0.9144"))
        #expect(LengthUnit.mile.factorToBase == Decimal(string: "1609.344"))
        #expect(AreaUnit.acre.factorToBase == Decimal(string: "4046.8564224"))
        #expect(AreaUnit.squareMile.factorToBase == Decimal(string: "2589988.110336"))
    }

    @Test("Derived imperial relations are exact")
    func imperialRelations() {
        #expect(LengthUnit.inch.convert(12, to: .foot) == 1)
        #expect(LengthUnit.foot.convert(3, to: .yard) == 1)
        #expect(LengthUnit.foot.convert(5280, to: .mile) == 1)
        #expect(AreaUnit.squareInch.convert(144, to: .squareFoot) == 1)
        #expect(AreaUnit.squareFoot.convert(9, to: .squareYard) == 1)
        #expect(AreaUnit.squareYard.convert(4840, to: .acre) == 1)
        #expect(AreaUnit.acre.convert(640, to: .squareMile) == 1)
        #expect(VolumeUnit.cubicInch.convert(1728, to: .cubicFoot) == 1)
        #expect(VolumeUnit.cubicFoot.convert(27, to: .cubicYard) == 1)
    }

    @Test("Squared and cubed length factors agree with the area and volume tables")
    func dimensionalConsistency() {
        for unit in LengthUnit.allCases {
            if let squared = unit.squared {
                #expect(squared.factorToBase == unit.factorToBase * unit.factorToBase,
                        "\(squared.rawValue) disagrees with \(unit.rawValue) squared")
            }
            if let cubed = unit.cubed {
                let expected = unit.factorToBase * unit.factorToBase * unit.factorToBase
                #expect(cubed.factorToBase == expected,
                        "\(cubed.rawValue) disagrees with \(unit.rawValue) cubed")
            }
        }
    }

    @Test("Metric relations are exact")
    func metricRelations() {
        #expect(LengthUnit.millimetre.convert(1000, to: .metre) == 1)
        #expect(AreaUnit.squareMetre.convert(10000, to: .hectare) == 1)
        #expect(AreaUnit.hectare.convert(100, to: .squareKilometre) == 1)
        #expect(VolumeUnit.litre.convert(1000, to: .cubicMetre) == 1)
        #expect(VolumeUnit.cubicCentimetre.convert(1000, to: .litre) == 1)
    }

    @Test("A quantity converted out of the wrong family is a typed error")
    func dimensionMismatchOnConversion() {
        let area = DecimalQuantity.area(10)
        #expect(throws: UnitConversionError.self) {
            _ = try area.converted(to: LengthUnit.metre)
        }
    }

    @Test("pi is the 37-decimal truncation, assembled without a Double")
    func piConstant() {
        #expect(AngleUnit.pi == Decimal(string: "3.1415926535897932384626433832795028842"))
    }
}
