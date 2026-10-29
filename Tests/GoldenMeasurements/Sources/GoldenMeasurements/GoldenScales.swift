import Foundation
import ZPDFContracts

/// The scales the corpus measures under.
///
/// Every one is a literal ``AffineScaleMatrix`` rather than a calibration, so a case's expected
/// value can be derived from the matrix on paper. Metric, imperial, separate-XY, a 90-degree
/// rotated page and a 30-degree rotated page are all represented, because those are the four
/// ways a real drawing breaks the "one number of metres per point" assumption.
public enum GoldenScale: Sendable {
    static func make(
        _ byte: UInt8,
        _ matrix: AffineScaleMatrix,
        units: ScaleUnitPolicy,
        source: ScaleSource,
        label: String
    ) -> ScaleTransform {
        ScaleTransform(
            id: ScaleID(UUID(uuid: (0x5C, byte, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 1))),
            version: 1,
            matrix: matrix,
            units: units,
            source: source,
            label: label
        )
    }

    /// 1 metre per PDF point. Page numbers *are* metres, so a reader can check the arithmetic
    /// without doing any conversion at all.
    public static let unit = make(
        1,
        AffineScaleMatrix(a: 1, b: 0, c: 0, d: 1),
        units: .metric,
        source: .preset,
        label: "1 m/pt"
    )

    /// 50 mm per PDF point: a plausible metric architectural sheet.
    public static let metric50 = make(
        2,
        AffineScaleMatrix(
            a: NumericPolicy.exact(5, -2),
            b: 0,
            c: 0,
            d: NumericPolicy.exact(5, -2)
        ),
        units: .metric,
        source: .preset,
        label: "50 mm/pt"
    )

    /// One foot per PDF point: 0.3048 m exactly, by definition of the international foot.
    public static let imperialFoot = make(
        3,
        AffineScaleMatrix(
            a: NumericPolicy.exact(3048, -4),
            b: 0,
            c: 0,
            d: NumericPolicy.exact(3048, -4)
        ),
        units: .imperial,
        source: .preset,
        label: "1 ft/pt"
    )

    /// One inch per PDF point: 0.0254 m exactly.
    public static let imperialInch = make(
        4,
        AffineScaleMatrix(
            a: NumericPolicy.exact(254, -4),
            b: 0,
            c: 0,
            d: NumericPolicy.exact(254, -4)
        ),
        units: .imperial,
        source: .preset,
        label: "1 in/pt"
    )

    /// Independent X and Y calibration: 20 mm/pt across, 50 mm/pt up (spec 10.3).
    public static let separateXY = make(
        5,
        AffineScaleMatrix(
            a: NumericPolicy.exact(2, -2),
            b: 0,
            c: 0,
            d: NumericPolicy.exact(5, -2)
        ),
        units: .metric,
        source: .calibrationXY,
        label: "20 mm/pt x, 50 mm/pt y"
    )

    /// A page rotated 90 degrees, folded into the matrix: `[[0, -k], [k, 0]]` with k = 40 mm/pt.
    /// Lengths are unchanged by the rotation; `|det| = k^2` is still the area factor.
    public static let rotated90 = make(
        6,
        AffineScaleMatrix(
            a: 0,
            b: NumericPolicy.exact(4, -2) * -1,
            c: NumericPolicy.exact(4, -2),
            d: 0
        ),
        units: .metric,
        source: .inherited,
        label: "40 mm/pt, page rotated 90 deg"
    )

    /// A page rotated 30 degrees at 100 mm/pt.
    ///
    /// `a = d = 0.1 cos 30 = 0.0866025403784439`, `b = -0.05`, `c = 0.05`, and
    /// `det = 0.1^2 (cos^2 + sin^2) = 0.01` exactly in the limit — the stored decimal is truncated
    /// at 16 digits, which is nine orders of magnitude below the 0.10 % area tolerance.
    public static let rotated30 = make(
        7,
        AffineScaleMatrix(
            a: Decimal(string: "0.0866025403784439")!,
            b: NumericPolicy.exact(5, -2) * -1,
            c: NumericPolicy.exact(5, -2),
            d: Decimal(string: "0.0866025403784439")!
        ),
        units: .metric,
        source: .inherited,
        label: "100 mm/pt, page rotated 30 deg"
    )

    /// Deliberately outside the sane range (spec 10.2), to exercise the extreme-scale warning.
    public static let extreme = make(
        8,
        AffineScaleMatrix(a: 100_000, b: 0, c: 0, d: 100_000),
        units: .metric,
        source: .preset,
        label: "100 km/pt"
    )
}

/// Page and markup identifiers for the corpus. Literals, never `UUID()`.
public enum GoldenIdentity: Sendable {
    public static let pageID = PageID(UUID(uuidString: "60106010-0001-4000-8000-000000000001")!)

    public static func countPointID(_ index: Int) -> CountPointID {
        CountPointID(
            UUID(
                uuid: (
                    0x60, 0x10, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0,
                    UInt8(index >> 8), UInt8(index & 0xFF)
                )
            )
        )
    }
}

/// Shorthand for building corpus geometry.
public enum GoldenGeometry: Sendable {
    public static func points(_ pairs: [(Double, Double)]) -> [PDFPoint] {
        pairs.map { PDFPoint(x: $0.0, y: $0.1) }
    }

    public static func ring(_ pairs: [(Double, Double)]) -> PolygonRing {
        PolygonRing(points: points(pairs), isClosed: true)
    }

    public static func polyline(_ pairs: [(Double, Double)]) -> MeasurementGeometry {
        MeasurementGeometry(pageID: GoldenIdentity.pageID, points: points(pairs))
    }

    public static func polygon(
        _ outer: [(Double, Double)],
        holes: [[(Double, Double)]] = []
    ) -> MeasurementGeometry {
        MeasurementGeometry(
            pageID: GoldenIdentity.pageID,
            polygons: [PolygonGeometry(outer: ring(outer), holes: holes.map(ring))]
        )
    }

    /// An axis-aligned rectangle ring, counter-clockwise from its lower-left corner.
    public static func rectangle(
        x: Double,
        y: Double,
        width: Double,
        height: Double
    ) -> [(Double, Double)] {
        [(x, y), (x + width, y), (x + width, y + height), (x, y + height)]
    }

    /// A regular `n`-gon inscribed in a circle of radius `radius`, centred on the origin.
    ///
    /// Its exact area is `n/2 · r² · sin(2π/n)` and its exact perimeter is `2 n r sin(π/n)`, both
    /// closed forms, which is what makes it a usable golden case rather than a circle drawn badly.
    public static func regularPolygon(sides: Int, radius: Double) -> [(Double, Double)] {
        (0..<sides).map { index in
            let angle = 2 * Double.pi * Double(index) / Double(sides)
            return (radius * Foundation.cos(angle), radius * Foundation.sin(angle))
        }
    }

    public static func circle(center: (Double, Double), radius: Double) -> MeasurementGeometry {
        MeasurementGeometry(
            pageID: GoldenIdentity.pageID,
            circles: [
                CircleGeometry(
                    center: PDFPoint(x: center.0, y: center.1),
                    radius: radius
                )
            ]
        )
    }

    public static func counts(_ n: Int) -> MeasurementGeometry {
        MeasurementGeometry(
            pageID: GoldenIdentity.pageID,
            countPoints: (0..<n).map { index in
                CountPoint(
                    id: GoldenIdentity.countPointID(index),
                    position: PDFPoint(x: Double(index) * 3, y: Double(index % 5) * 3)
                )
            }
        )
    }
}
