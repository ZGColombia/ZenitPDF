import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFMeasurementEngine

/// Low-severity bug-hunt-2 regressions on the measurement engine.
///
/// Hand-derived expectations only (QUALITY_BAR §2.6); each test states the old output.
@Suite("Low-severity engine regressions (bug hunt 2)")
struct LowSeverityRegressionTests {
    let engine = MeasurementEngine()

    // MARK: - BH-557

    /// Old output: a one-click Temporary Measure (one bare point) returned a result with no
    /// values and no warnings — a measurement of nothing — where every other tool refuses.
    @Test("BH-557: a single-point Temporary Measure is refused, not measured as nothing")
    func singlePointTemporaryMeasureIsRefused() throws {
        let geometry = MeasurementGeometry(pageID: Fixture.pageID, points: Fixture.points([(5, 5)]))
        #expect(throws: MeasurementEngineError.unsupportedGeometry(tool: .temporaryMeasure, expected: .anyGeometry)) {
            try engine.calculate(tool: .temporaryMeasure, geometry: geometry, scale: Fixture.unitScale)
        }
        // Two points still measure: 3-4-5 triangle leg, 5 m at 1 m/pt.
        let two = MeasurementGeometry(pageID: Fixture.pageID, points: Fixture.points([(0, 0), (3, 4)]))
        let result = try engine.calculate(tool: .temporaryMeasure, geometry: two, scale: Fixture.unitScale)
        #expect(try #require(result[.planLength]).value == 5)
    }

    // BH-565 (an enormous finite sweep must not trap) moved to `Iter7QuantitiesCoreTests`
    // when X-043 replaced the arc flattening it exercised with quadrature on the curve.
}
