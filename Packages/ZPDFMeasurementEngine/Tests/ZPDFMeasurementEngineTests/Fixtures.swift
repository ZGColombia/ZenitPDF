import Foundation
import ZPDFContracts
@testable import ZPDFMeasurementEngine

/// Deterministic fixtures. Every identifier is a literal, so no test ever depends on `UUID()`.
enum Fixture {
    static let pageID = PageID(UUID(uuidString: "11111111-1111-4111-8111-111111111111")!)
    static let scaleID = ScaleID(UUID(uuidString: "22222222-2222-4222-8222-222222222222")!)

    /// 1 metre per PDF point, so page-space numbers and metres are the same number.
    static let unitScale: ScaleTransform = {
        ScaleTransform(
            id: scaleID,
            version: 1,
            matrix: AffineScaleMatrix(a: 1, b: 0, c: 0, d: 1),
            units: .metric,
            source: .preset
        )
    }()

    static func uniform(_ metresPerPoint: Decimal) -> ScaleTransform {
        ScaleTransform(
            id: scaleID,
            version: 1,
            matrix: AffineScaleMatrix(a: metresPerPoint, b: 0, c: 0, d: metresPerPoint),
            units: .metric,
            source: .preset
        )
    }

    static func separateXY(x: Decimal, y: Decimal) -> ScaleTransform {
        ScaleTransform(
            id: scaleID,
            version: 1,
            matrix: AffineScaleMatrix(a: x, b: 0, c: 0, d: y),
            units: .metric,
            source: .calibrationXY
        )
    }

    static func points(_ pairs: [(Double, Double)]) -> [PDFPoint] {
        pairs.map { PDFPoint(x: $0.0, y: $0.1) }
    }

    static func ring(_ pairs: [(Double, Double)]) -> PolygonRing {
        PolygonRing(points: points(pairs), isClosed: true)
    }

    static func polygon(
        _ outer: [(Double, Double)],
        holes: [[(Double, Double)]] = []
    ) -> MeasurementGeometry {
        MeasurementGeometry(
            pageID: pageID,
            polygons: [PolygonGeometry(outer: ring(outer), holes: holes.map(ring))]
        )
    }

    static func polyline(_ pairs: [(Double, Double)]) -> MeasurementGeometry {
        MeasurementGeometry(pageID: pageID, points: points(pairs))
    }

    static func double(_ value: Decimal) -> Double {
        NumericPolicy.double(from: value)
    }
}
