import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFMeasurementEngine

/// NL-MEASURE-14 / ADR-0019: the informational tools read a size, an angle or a pitch off the
/// drawing. They must not write any field a summed ledger column reads, or measuring an angle
/// on a wall adds the rays to the wall's length total.
@Suite("Informational tools write no summed column (ADR-0019)")
struct InformationalToolRegressionTests {
    let engine = MeasurementEngine()

    /// Every measurement field a summed quantity column reads. Plan Area reads `netArea` and
    /// Gross Area reads `planArea` (ADR-0016, ADR-0018), so both are listed.
    static let summedFields: Set<MeasurementField> = [
        .planLength, .trueLength, .perimeter, .truePerimeter, .planArea, .netArea,
        .trueArea, .planWallArea, .wallArea, .netWallArea, .volume,
    ]

    /// Angle A=(10,0), B=(0,0), C=(0,10) on a 1 m/pt scale. The angle is pi/2 exactly.
    /// Old output: `planLength = 10 + 10 = 20 m` (the two rays), summed into Plan Length.
    @Test("Angle keeps the angle and drops the ray lengths")
    func angleWritesNoPlanLength() throws {
        let result = try engine.calculate(
            tool: .angle,
            geometry: Fixture.polyline([(10, 0), (0, 0), (0, 10)]),
            scale: Fixture.unitScale
        )
        #expect(result[.planLength] == nil)
        let angle = Fixture.double(try #require(result[.angle]).value)
        #expect(abs(angle - Double.pi / 2) < 1e-12)
        #expect(Set(result.values.keys).isDisjoint(with: Self.summedFields))
    }

    /// Radius: centre (0,0), rim (2,0), 1 m/pt. r = 2, d = 4, C = 4 pi.
    /// Old output: `planArea = netArea = 4 pi ≈ 12.566 m²`, `perimeter = 4 pi` — summed into
    /// Plan Area, Gross Area and Perimeter.
    @Test("Radius, Diameter and Three-Point Circle keep r, d, C and drop the disc")
    func circleToolsWriteNoArea() throws {
        let radius = try engine.calculate(
            tool: .radius, geometry: Fixture.polyline([(0, 0), (2, 0)]), scale: Fixture.unitScale
        )
        #expect(radius[.planArea] == nil)
        #expect(radius[.netArea] == nil)
        #expect(radius[.perimeter] == nil)
        #expect(Fixture.double(try #require(radius[.radius]).value) == 2)
        #expect(Fixture.double(try #require(radius[.diameter]).value) == 4)
        let circumference = Fixture.double(try #require(radius[.circumference]).value)
        #expect(abs(circumference - 4 * Double.pi) < 1e-12)
        #expect(Set(radius.values.keys).isDisjoint(with: Self.summedFields))

        // Diameter endpoints (0,0)-(6,0): r = 3.
        let diameter = try engine.calculate(
            tool: .diameter, geometry: Fixture.polyline([(0, 0), (6, 0)]), scale: Fixture.unitScale
        )
        #expect(Fixture.double(try #require(diameter[.radius]).value) == 3)
        #expect(Set(diameter.values.keys).isDisjoint(with: Self.summedFields))

        // (5,0), (0,5), (-5,0) lie on the circle of radius 5 about the origin.
        let three = try engine.calculate(
            tool: .threePointCircle,
            geometry: Fixture.polyline([(5, 0), (0, 5), (-5, 0)]),
            scale: Fixture.unitScale
        )
        #expect(abs(Fixture.double(try #require(three[.radius]).value) - 5) < 1e-12)
        #expect(Set(three.values.keys).isDisjoint(with: Self.summedFields))
    }

    /// Slope drawn as a 10 m run at 1:2 with its own fall line.
    /// Old output: `planLength 10`, `trueLength 11.18033988749895`.
    @Test("Slope keeps ratio, percent and angle and drops the run")
    func slopeWritesNoLength() throws {
        let start = PDFPoint(x: 0, y: 0)
        let end = PDFPoint(x: 10, y: 0)
        let result = try engine.calculate(
            tool: .slope,
            geometry: MeasurementGeometry(pageID: Fixture.pageID, points: [start, end]),
            scale: Fixture.unitScale,
            parameters: MeasurementParameters(
                slope: try .uniformPlane(.ratioOneToN(2), fallLineFrom: start, to: end)
            )
        )
        #expect(Set(result.values.keys).isDisjoint(with: Self.summedFields))
        #expect(try #require(result[.slopePercent]).value == 50)
    }

    /// A 10 m length measured beside the three informational tools: summing every summed
    /// field over the four results gives Plan Length 10 m and no area at all.
    @Test("Mixed under one subject, Plan Length stays at the length's 10 m")
    func mixedToolsLeaveTotalsAlone() throws {
        let results = [
            try engine.calculate(tool: .length, geometry: Fixture.polyline([(0, 0), (10, 0)]), scale: Fixture.unitScale),
            try engine.calculate(tool: .angle, geometry: Fixture.polyline([(10, 0), (0, 0), (0, 10)]), scale: Fixture.unitScale),
            try engine.calculate(tool: .radius, geometry: Fixture.polyline([(0, 0), (2, 0)]), scale: Fixture.unitScale),
        ]
        let planLength = results.compactMap { $0[.planLength]?.value }.reduce(Decimal(0), +)
        let netArea = results.compactMap { $0[.netArea]?.value }.reduce(Decimal(0), +)
        #expect(planLength == 10)
        #expect(netArea == 0)
    }

    /// ADR-0019 raised the formula version to 4; ADR-0035 raised it to 5 for its own
    /// calculation changes, ADR-0035 §8 to 6 for S-105 to S-108 and S-110, ADR-0037 to 7 for
    /// C-08 and T-073 to T-075, and ADR-0041 to 8 for X-043 and X-044. The exact number is
    /// asserted so the next change to
    /// a stored value has to bump it deliberately.
    @Test("The formula version is 8 (ADR-0019 made it 4, ADR-0035 5, ADR-0035 §8 6, ADR-0037 7, ADR-0041 8)")
    func formulaVersionBumped() {
        #expect(ContractVersion.measurementFormulaVersion == 8)
    }
}
