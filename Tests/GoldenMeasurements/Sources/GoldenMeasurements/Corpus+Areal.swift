import Foundation
import ZPDFContracts

/// Area cases: rectangles, triangles, L-shapes, polygons with one to three holes, an inscribed
/// 50-gon, a sliver, and the same shapes under imperial, separate-XY and rotated scales.
extension GoldenCorpus {
    public static let areal: [GoldenCase] = [
        GoldenCase(
            id: "A01",
            title: "10 x 20 m rectangle: 200 m2, perimeter 60 m",
            derivation: .handDerived,
            tool: .area,
            geometry: GoldenGeometry.polygon(GoldenGeometry.rectangle(x: 0, y: 0, width: 10, height: 20)),
            scale: GoldenScale.unit,
            expected: [.planArea: 200, .netArea: 200, .perimeter: 60]
        ),
        GoldenCase(
            id: "A02",
            title: "300 x 200 pt rectangle at 50 mm/pt: 15 m x 10 m = 150 m2",
            derivation: .handDerived,
            tool: .area,
            geometry: GoldenGeometry.polygon(GoldenGeometry.rectangle(x: 0, y: 0, width: 300, height: 200)),
            scale: GoldenScale.metric50,
            expected: [.planArea: 150, .netArea: 150, .perimeter: 50]
        ),
        GoldenCase(
            id: "A03",
            title: "Rectangle Area from two opposite corners: same 150 m2",
            derivation: .handDerived,
            tool: .rectangleArea,
            geometry: GoldenGeometry.polyline([(0, 0), (300, 200)]),
            scale: GoldenScale.metric50,
            expected: [.planArea: 150, .netArea: 150, .perimeter: 50]
        ),
        GoldenCase(
            id: "A04",
            title: "Right triangle 30 x 40 m: 600 m2, perimeter 30 + 40 + 50",
            derivation: .handDerived,
            tool: .area,
            geometry: GoldenGeometry.polygon([(0, 0), (30, 0), (0, 40)]),
            scale: GoldenScale.unit,
            expected: [.planArea: 30.0 * 40.0 / 2, .netArea: 600, .perimeter: 30 + 40 + 50]
        ),
        GoldenCase(
            id: "A05",
            title: "Oblique triangle (0,0), (3,4), (-4,3): shoelace |3*3 - 4*(-4)| / 2 = 12.5 m2",
            derivation: .handDerived,
            tool: .area,
            geometry: GoldenGeometry.polygon([(0, 0), (3, 4), (-4, 3)]),
            scale: GoldenScale.unit,
            expected: [.planArea: (3.0 * 3.0 + 4.0 * 4.0) / 2]
        ),
        GoldenCase(
            id: "A06",
            title: "Right triangle 120 x 90 pt at 1 ft/pt: (120*0.3048)(90*0.3048)/2",
            derivation: .handDerived,
            tool: .area,
            geometry: GoldenGeometry.polygon([(0, 0), (120, 0), (0, 90)]),
            scale: GoldenScale.imperialFoot,
            parameters: MeasurementParameters(display: .imperial),
            expected: [.planArea: (120 * 0.3048) * (90 * 0.3048) / 2]
        ),
        GoldenCase(
            id: "A07",
            title: "L-shape as two rectangles: 60x20 + 20x30 = 1800 m2",
            derivation: .handDerived,
            tool: .area,
            geometry: GoldenGeometry.polygon(GoldenCorpus.lShape),
            scale: GoldenScale.unit,
            expected: [.planArea: 60.0 * 20.0 + 20.0 * 30.0, .netArea: 1800, .perimeter: 220]
        ),
        GoldenCase(
            id: "A08",
            title: "100 x 100 m slab with one 20 x 30 m opening: 10000 - 600 = 9400 m2",
            derivation: .handDerived,
            tool: .area,
            geometry: GoldenGeometry.polygon(
                GoldenGeometry.rectangle(x: 0, y: 0, width: 100, height: 100),
                holes: [GoldenGeometry.rectangle(x: 20, y: 20, width: 20, height: 30)]
            ),
            scale: GoldenScale.unit,
            expected: [.planArea: 10_000, .netArea: 10_000 - 600, .cutoutArea: 600, .perimeter: 400]
        ),
        GoldenCase(
            id: "A09",
            title: "Two disjoint openings, 600 and 400 m2: net 9000 m2",
            derivation: .handDerived,
            tool: .area,
            geometry: GoldenGeometry.polygon(
                GoldenGeometry.rectangle(x: 0, y: 0, width: 100, height: 100),
                holes: [
                    GoldenGeometry.rectangle(x: 10, y: 10, width: 20, height: 30),
                    GoldenGeometry.rectangle(x: 60, y: 60, width: 20, height: 20)
                ]
            ),
            scale: GoldenScale.unit,
            expected: [.netArea: 10_000 - 600 - 400, .cutoutArea: 1_000]
        ),
        GoldenCase(
            id: "A10",
            title: "Three openings, two overlapping on 100 m2: union 900 + 900 - 100 + 400 = 2100",
            derivation: .handDerived,
            tool: .area,
            geometry: GoldenGeometry.polygon(
                GoldenGeometry.rectangle(x: 0, y: 0, width: 100, height: 100),
                holes: [
                    GoldenGeometry.rectangle(x: 10, y: 10, width: 30, height: 30),
                    GoldenGeometry.rectangle(x: 30, y: 30, width: 30, height: 30),
                    GoldenGeometry.rectangle(x: 70, y: 70, width: 20, height: 20)
                ]
            ),
            scale: GoldenScale.unit,
            expected: [
                .netArea: 10_000 - (900 + 900 - 100 + 400),
                .cutoutArea: 900 + 900 - 100 + 400
            ]
        ),
        GoldenCase(
            id: "A11",
            title: "Three openings in a chain, each overlapping the next: union 3*400 - 2*100 = 1000",
            derivation: .handDerived,
            tool: .area,
            geometry: GoldenGeometry.polygon(
                GoldenGeometry.rectangle(x: 0, y: 0, width: 100, height: 100),
                holes: [
                    GoldenGeometry.rectangle(x: 10, y: 10, width: 20, height: 20),
                    GoldenGeometry.rectangle(x: 25, y: 10, width: 20, height: 20),
                    GoldenGeometry.rectangle(x: 40, y: 10, width: 20, height: 20)
                ]
            ),
            scale: GoldenScale.unit,
            expected: [
                .netArea: 10_000 - (3 * 400 - 2 * (5 * 20)),
                .cutoutArea: 3 * 400 - 2 * (5 * 20)
            ]
        ),
        GoldenCase(
            id: "A12",
            title: "100 x 50 pt rectangle on a page rotated 90 deg at 40 mm/pt: 5000 * 0.0016 = 8 m2",
            derivation: .handDerived,
            tool: .area,
            geometry: GoldenGeometry.polygon(GoldenGeometry.rectangle(x: 0, y: 0, width: 100, height: 50)),
            scale: GoldenScale.rotated90,
            expected: [.planArea: 100 * 50 * 0.04 * 0.04, .perimeter: 2 * (100 + 50) * 0.04]
        ),
        GoldenCase(
            id: "A13",
            title: "100 x 100 pt rectangle under separate XY: 2 m x 5 m = 10 m2",
            derivation: .handDerived,
            tool: .area,
            geometry: GoldenGeometry.polygon(GoldenGeometry.rectangle(x: 0, y: 0, width: 100, height: 100)),
            scale: GoldenScale.separateXY,
            expected: [.planArea: 10, .perimeter: 2 * (2 + 5)]
        ),
        GoldenCase(
            id: "A14",
            title: "100 x 100 pt rectangle on a page rotated 30 deg at 100 mm/pt: 10 m x 10 m",
            derivation: .handDerived,
            tool: .area,
            geometry: GoldenGeometry.polygon(GoldenGeometry.rectangle(x: 0, y: 0, width: 100, height: 100)),
            scale: GoldenScale.rotated30,
            expected: [.planArea: 100, .perimeter: 40]
        ),
        GoldenCase(
            id: "A15",
            title: "Concave arrow: 40x20 shaft plus a 20x40 head triangle, 800 + 400 = 1200 m2",
            derivation: .handDerived,
            tool: .area,
            geometry: GoldenGeometry.polygon([
                (0, 10), (40, 10), (40, 0), (60, 20), (40, 40), (40, 30), (0, 30)
            ]),
            scale: GoldenScale.unit,
            expected: [.planArea: 40.0 * 20.0 + (40.0 * 20.0) / 2]
        ),
        GoldenCase(
            id: "A16",
            title: "Regular 50-gon of radius 100 m: n/2 r^2 sin(2 pi / n)",
            derivation: .handDerived,
            tool: .area,
            geometry: GoldenGeometry.polygon(GoldenGeometry.regularPolygon(sides: 50, radius: 100)),
            scale: GoldenScale.unit,
            expected: [
                .planArea: 0.5 * 50 * 100 * 100 * Foundation.sin(2 * Double.pi / 50),
                .perimeter: 2 * 50 * 100 * Foundation.sin(Double.pi / 50)
            ]
        ),
        GoldenCase(
            id: "A17",
            title: "10 x 10 m square translated to (100000, 100000): still 100 m2",
            derivation: .handDerived,
            tool: .area,
            geometry: GoldenGeometry.polygon(
                GoldenGeometry.rectangle(x: 100_000, y: 100_000, width: 10, height: 10)
            ),
            scale: GoldenScale.unit,
            expected: [.planArea: 100, .perimeter: 40]
        ),
        GoldenCase(
            id: "A18",
            title: "Sliver triangle 1000 x 0.001: exactly 0.5 m2",
            derivation: .handDerived,
            tool: .area,
            geometry: GoldenGeometry.polygon([(0, 0), (1000, 0), (1000, 0.001)]),
            scale: GoldenScale.unit,
            expected: [.planArea: 1000.0 * 0.001 / 2]
        ),
        GoldenCase(
            id: "A19",
            title: "Regular hexagon of radius 60 pt at 50 mm/pt: 3 r^2 sin(60 deg) with r = 3 m",
            derivation: .handDerived,
            tool: .area,
            geometry: GoldenGeometry.polygon(GoldenGeometry.regularPolygon(sides: 6, radius: 60)),
            scale: GoldenScale.metric50,
            expected: [
                .planArea: 0.5 * 6 * 3 * 3 * Foundation.sin(2 * Double.pi / 6),
                .perimeter: 6 * 3
            ]
        ),
        GoldenCase(
            id: "A20",
            title: "L-shape with a 5 x 5 opening in each leg: 1800 - 50 m2",
            derivation: .handDerived,
            tool: .area,
            geometry: GoldenGeometry.polygon(
                GoldenCorpus.lShape,
                holes: [
                    GoldenGeometry.rectangle(x: 30, y: 5, width: 5, height: 5),
                    GoldenGeometry.rectangle(x: 5, y: 35, width: 5, height: 5)
                ]
            ),
            scale: GoldenScale.unit,
            expected: [.planArea: 1800, .netArea: 1800 - 50, .cutoutArea: 50]
        ),
        GoldenCase(
            id: "A21",
            title: "Slab with three openings at 50 mm/pt: page-space 2400 pt2 removed",
            derivation: .handDerived,
            tool: .area,
            geometry: GoldenGeometry.polygon(
                GoldenGeometry.rectangle(x: 0, y: 0, width: 200, height: 160),
                holes: [
                    GoldenGeometry.rectangle(x: 10, y: 10, width: 20, height: 20),
                    GoldenGeometry.rectangle(x: 50, y: 50, width: 40, height: 40),
                    GoldenGeometry.rectangle(x: 120, y: 20, width: 20, height: 20)
                ]
            ),
            scale: GoldenScale.metric50,
            expected: [
                .planArea: 200.0 * 160.0 * 0.0025,
                .netArea: (200.0 * 160.0 - (400 + 1600 + 400)) * 0.0025,
                .cutoutArea: 2400.0 * 0.0025
            ]
        ),
        GoldenCase(
            id: "A22",
            title: "Imperial slab 40 x 30 ft with a 4 x 6 ft opening",
            derivation: .handDerived,
            tool: .area,
            geometry: GoldenGeometry.polygon(
                GoldenGeometry.rectangle(x: 0, y: 0, width: 40, height: 30),
                holes: [GoldenGeometry.rectangle(x: 5, y: 5, width: 4, height: 6)]
            ),
            scale: GoldenScale.imperialFoot,
            parameters: MeasurementParameters(display: .imperial),
            expected: [
                .planArea: 40.0 * 30.0 * 0.3048 * 0.3048,
                .netArea: (40.0 * 30.0 - 24.0) * 0.3048 * 0.3048,
                .cutoutArea: 24.0 * 0.3048 * 0.3048
            ]
        ),
        GoldenCase(
            id: "A23",
            title: "Ellipse 10 x 5 m semi-axes: area 50 pi, perimeter from a numerical arc-length integral",
            derivation: .independentNumericalReference,
            tool: .ellipseArea,
            geometry: GoldenGeometry.polyline([(-10, -5), (10, 5)]),
            scale: GoldenScale.unit,
            expected: [
                .planArea: Double.pi * 10 * 5,
                // Simpson's rule on 4 * integral_0^{pi/2} sqrt(a^2 sin^2 t + b^2 cos^2 t) dt
                // with 2e6 intervals, computed outside this codebase.
                .circumference: 48.442241102737235
            ]
        ),
        GoldenCase(
            id: "A24",
            title: "Circle as a degenerate ellipse, radius 3 m: area 9 pi, circumference 6 pi exactly",
            derivation: .handDerived,
            tool: .ellipseArea,
            geometry: GoldenGeometry.polyline([(-3, -3), (3, 3)]),
            scale: GoldenScale.unit,
            expected: [
                .planArea: Double.pi * 9,
                .circumference: 2 * Double.pi * 3,
                .radius: 3,
                .diameter: 6
            ]
        ),
        GoldenCase(
            id: "A25",
            title: "Ellipse under separate XY: page 1000 x 300 pt becomes 10 m by 7.5 m semi-axes",
            derivation: .independentNumericalReference,
            tool: .ellipseArea,
            geometry: GoldenGeometry.polyline([(-500, -150), (500, 150)]),
            scale: GoldenScale.separateXY,
            expected: [
                .planArea: Double.pi * 10 * 7.5,
                .circumference: 55.25873040177342
            ]
        ),
        GoldenCase(
            id: "A26",
            title: "Ellipse at 1 ft/pt: 40 x 20 pt semi-axes are 12.192 m and 6.096 m",
            derivation: .independentNumericalReference,
            tool: .ellipseArea,
            geometry: GoldenGeometry.polyline([(-40, -20), (40, 20)]),
            scale: GoldenScale.imperialFoot,
            parameters: MeasurementParameters(display: .imperial),
            expected: [
                .planArea: Double.pi * 12.192 * 6.096,
                .circumference: 59.06078035245895
            ]
        ),
        GoldenCase(
            id: "A27",
            title: "Polygon Cutout measured on its own: 20 x 30 m opening is 600 m2",
            derivation: .handDerived,
            tool: .polygonCutout,
            geometry: GoldenGeometry.polygon(GoldenGeometry.rectangle(x: 0, y: 0, width: 20, height: 30)),
            scale: GoldenScale.unit,
            expected: [.planArea: 600, .cutoutArea: 600, .perimeter: 100]
        ),
        GoldenCase(
            id: "A28",
            title: "Polygon Cutout at 50 mm/pt: 60 x 40 pt is 3 m x 2 m",
            derivation: .handDerived,
            tool: .polygonCutout,
            geometry: GoldenGeometry.polygon(GoldenGeometry.rectangle(x: 0, y: 0, width: 60, height: 40)),
            scale: GoldenScale.metric50,
            expected: [.planArea: 6, .cutoutArea: 6, .perimeter: 10]
        ),
        GoldenCase(
            id: "A29",
            title: "Ellipse Cutout, 5 m radius: 25 pi m2 removed",
            derivation: .handDerived,
            tool: .ellipseCutout,
            geometry: GoldenGeometry.polyline([(-5, -5), (5, 5)]),
            scale: GoldenScale.unit,
            expected: [.planArea: Double.pi * 25, .cutoutArea: Double.pi * 25]
        ),
        GoldenCase(
            id: "A30",
            title: "Rectangle Area on a rotated 30 deg page from an explicit four-corner ring",
            derivation: .handDerived,
            tool: .rectangleArea,
            geometry: GoldenGeometry.polyline([(0, 0), (200, 0), (200, 100), (0, 100)]),
            scale: GoldenScale.rotated30,
            expected: [.planArea: 200.0 * 100.0 * 0.01, .perimeter: 2 * (20 + 10)]
        )
    ]
}
