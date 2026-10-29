import Foundation
import ZPDFContracts

/// Length, polylength, dimension, perimeter, arc and circle cases.
///
/// Every expectation is written as the arithmetic a person would do: a Pythagorean triple, a
/// count of edges times an edge length, `2 pi r`. Nothing here is read back from the engine.
extension GoldenCorpus {
    public static let linear: [GoldenCase] = [
        GoldenCase(
            id: "L01",
            title: "3-4-5 triangle leg at 1 m/pt: hand-derived Pythagorean triple",
            derivation: .handDerived,
            tool: .length,
            geometry: GoldenGeometry.polyline([(0, 0), (3, 4)]),
            scale: GoldenScale.unit,
            expected: [.planLength: 5]
        ),
        GoldenCase(
            id: "L02",
            title: "100 pt horizontal at 50 mm/pt = 5 m",
            derivation: .handDerived,
            tool: .length,
            geometry: GoldenGeometry.polyline([(0, 0), (100, 0)]),
            scale: GoldenScale.metric50,
            expected: [.planLength: 100 * 0.05]
        ),
        GoldenCase(
            id: "L03",
            title: "Two-leg polyline 30 + 40 pt at 50 mm/pt = 3.5 m",
            derivation: .handDerived,
            tool: .polylength,
            geometry: GoldenGeometry.polyline([(0, 0), (30, 0), (30, 40)]),
            scale: GoldenScale.metric50,
            expected: [.planLength: (30 + 40) * 0.05]
        ),
        GoldenCase(
            id: "L04",
            title: "120 pt vertical at 1 ft/pt = 120 ft = 36.576 m exactly",
            derivation: .handDerived,
            tool: .length,
            geometry: GoldenGeometry.polyline([(0, 0), (0, 120)]),
            scale: GoldenScale.imperialFoot,
            parameters: MeasurementParameters(display: .imperial),
            expected: [.planLength: 120 * 0.3048]
        ),
        GoldenCase(
            id: "L05",
            title: "96 pt at 1 in/pt = 8 ft = 2.4384 m exactly",
            derivation: .handDerived,
            tool: .length,
            geometry: GoldenGeometry.polyline([(0, 0), (96, 0)]),
            scale: GoldenScale.imperialInch,
            parameters: MeasurementParameters(display: .imperial),
            expected: [.planLength: 96 * 0.0254]
        ),
        GoldenCase(
            id: "L06",
            title: "Separate XY: 100 pt along x at 20 mm/pt = 2 m",
            derivation: .handDerived,
            tool: .length,
            geometry: GoldenGeometry.polyline([(0, 0), (100, 0)]),
            scale: GoldenScale.separateXY,
            expected: [.planLength: 2]
        ),
        GoldenCase(
            id: "L07",
            title: "Separate XY: 100 pt along y at 50 mm/pt = 5 m",
            derivation: .handDerived,
            tool: .length,
            geometry: GoldenGeometry.polyline([(0, 0), (0, 100)]),
            scale: GoldenScale.separateXY,
            expected: [.planLength: 5]
        ),
        GoldenCase(
            id: "L08",
            title: "Separate XY diagonal: sqrt(2^2 + 5^2) = sqrt(29) m, not 100 pt times one factor",
            derivation: .handDerived,
            tool: .length,
            geometry: GoldenGeometry.polyline([(0, 0), (100, 100)]),
            scale: GoldenScale.separateXY,
            expected: [.planLength: (29.0 as Double).squareRoot()]
        ),
        GoldenCase(
            id: "L09",
            title: "Page rotated 90 deg at 40 mm/pt: rotation is an isometry, so 100 pt is 4 m",
            derivation: .handDerived,
            tool: .length,
            geometry: GoldenGeometry.polyline([(0, 0), (100, 0)]),
            scale: GoldenScale.rotated90,
            expected: [.planLength: 4]
        ),
        GoldenCase(
            id: "L10",
            title: "Page rotated 30 deg at 100 mm/pt: 100 pt is 10 m in any direction",
            derivation: .handDerived,
            tool: .length,
            geometry: GoldenGeometry.polyline([(0, 0), (100, 0)]),
            scale: GoldenScale.rotated30,
            expected: [.planLength: 10]
        ),
        GoldenCase(
            id: "L11",
            title: "200-segment staircase of unit steps: exactly 200 m, a compensated-summation case",
            derivation: .handDerived,
            tool: .polylength,
            geometry: GoldenGeometry.polyline(GoldenCorpus.staircase(steps: 100)),
            scale: GoldenScale.unit,
            expected: [.planLength: 200]
        ),
        GoldenCase(
            id: "L12",
            title: "Dimension across a 300 x 400 pt diagonal at 50 mm/pt = 25 m",
            derivation: .handDerived,
            tool: .dimension,
            geometry: GoldenGeometry.polyline([(0, 0), (300, 400)]),
            scale: GoldenScale.metric50,
            expected: [.planLength: 500 * 0.05]
        ),
        GoldenCase(
            id: "L13",
            title: "Dimension across a 30 x 40 pt diagonal at 1 ft/pt = 50 ft",
            derivation: .handDerived,
            tool: .dimension,
            geometry: GoldenGeometry.polyline([(0, 0), (30, 40)]),
            scale: GoldenScale.imperialFoot,
            parameters: MeasurementParameters(display: .imperial),
            expected: [.planLength: 50 * 0.3048]
        ),
        GoldenCase(
            id: "L14",
            title: "Open polylength around three sides of a 10 m square = 30 m",
            derivation: .handDerived,
            tool: .polylength,
            geometry: GoldenGeometry.polyline([(0, 0), (10, 0), (10, 10), (0, 10)]),
            scale: GoldenScale.unit,
            expected: [.planLength: 30]
        ),
        GoldenCase(
            id: "L15",
            title: "Perimeter of a 10 x 10 m square = 40 m, area 100 m2",
            derivation: .handDerived,
            tool: .perimeter,
            geometry: GoldenGeometry.polygon(GoldenGeometry.rectangle(x: 0, y: 0, width: 10, height: 10)),
            scale: GoldenScale.unit,
            expected: [.perimeter: 40, .planArea: 100]
        ),
        GoldenCase(
            id: "L16",
            title: "Perimeter of an L-shape: 60 + 20 + 40 + 30 + 20 + 50 = 220 m",
            derivation: .handDerived,
            tool: .perimeter,
            geometry: GoldenGeometry.polygon(GoldenCorpus.lShape),
            scale: GoldenScale.unit,
            expected: [.perimeter: 220, .planArea: 1800]
        ),
        GoldenCase(
            id: "L17",
            title: "Perimeter of a 300 x 200 pt rectangle at 50 mm/pt: 2 (15 + 10) = 50 m",
            derivation: .handDerived,
            tool: .perimeter,
            geometry: GoldenGeometry.polygon(GoldenGeometry.rectangle(x: 0, y: 0, width: 300, height: 200)),
            scale: GoldenScale.metric50,
            expected: [.perimeter: 50, .planArea: 150]
        ),
        GoldenCase(
            id: "L18",
            title: "Perimeter policy outer + cutout edges: 400 m outer + 100 m around a 20 x 30 hole",
            derivation: .handDerived,
            tool: .perimeter,
            geometry: GoldenGeometry.polygon(
                GoldenGeometry.rectangle(x: 0, y: 0, width: 100, height: 100),
                holes: [GoldenGeometry.rectangle(x: 20, y: 20, width: 20, height: 30)]
            ),
            scale: GoldenScale.unit,
            parameters: MeasurementParameters(perimeterPolicy: .outerPlusCutoutEdges),
            expected: [.perimeter: 400 + 100]
        ),
        GoldenCase(
            id: "L19",
            title: "Arc of 50 pt radius sweeping 90 deg at 50 mm/pt: 2.5 m radius, 2.5 pi/2 m long",
            derivation: .handDerived,
            tool: .arcLength,
            geometry: MeasurementGeometry(
                pageID: GoldenIdentity.pageID,
                arcs: [
                    ArcGeometry(center: PDFPoint(x: 0, y: 0), radius: 50, startAngle: 0, sweepAngle: Double.pi / 2)
                ]
            ),
            scale: GoldenScale.metric50,
            expected: [
                .arcLength: 2.5 * Double.pi / 2,
                .radius: 2.5,
                .angle: Double.pi / 2
            ]
        ),
        GoldenCase(
            id: "L20",
            title: "Arc through three points on a 10 m circle: quarter arc is 10 pi/2 m",
            derivation: .handDerived,
            tool: .arcLength,
            geometry: GoldenGeometry.polyline([
                (10, 0),
                (10 * 0.7071067811865476, 10 * 0.7071067811865476),
                (0, 10)
            ]),
            scale: GoldenScale.unit,
            expected: [.arcLength: 10 * Double.pi / 2, .radius: 10]
        ),
        GoldenCase(
            id: "L21",
            title: "Arc of 100 pt radius sweeping 120 deg at 1 ft/pt",
            derivation: .handDerived,
            tool: .arcLength,
            geometry: MeasurementGeometry(
                pageID: GoldenIdentity.pageID,
                arcs: [
                    ArcGeometry(
                        center: PDFPoint(x: 0, y: 0),
                        radius: 100,
                        startAngle: 0,
                        sweepAngle: 2 * Double.pi / 3
                    )
                ]
            ),
            scale: GoldenScale.imperialFoot,
            parameters: MeasurementParameters(display: .imperial),
            expected: [
                .arcLength: 100 * 0.3048 * 2 * Double.pi / 3,
                .radius: 100 * 0.3048
            ]
        ),
        GoldenCase(
            id: "L22",
            title: "Radius tool: 25 pt rim at 50 mm/pt gives r = 1.25 m, C = 2 pi r, and no summed area (ADR-0019)",
            derivation: .handDerived,
            tool: .radius,
            geometry: GoldenGeometry.polyline([(0, 0), (25, 0)]),
            scale: GoldenScale.metric50,
            expected: [
                .radius: 1.25,
                .diameter: 2.5,
                .circumference: 2 * Double.pi * 1.25
            ]
        ),
        GoldenCase(
            id: "L23",
            title: "Diameter tool: two points 60 m apart give r = 30 m",
            derivation: .handDerived,
            tool: .diameter,
            geometry: GoldenGeometry.polyline([(0, 0), (60, 0)]),
            scale: GoldenScale.unit,
            expected: [
                .radius: 30,
                .diameter: 60,
                .circumference: 2 * Double.pi * 30
            ]
        ),
        GoldenCase(
            id: "L24",
            title: "Three-point circle through (0,0), (10,10), (20,0): centre (10,0), radius 10 m",
            derivation: .handDerived,
            tool: .threePointCircle,
            geometry: GoldenGeometry.polyline([(0, 0), (10, 10), (20, 0)]),
            scale: GoldenScale.unit,
            expected: [
                .radius: 10,
                .diameter: 20,
                .circumference: 2 * Double.pi * 10
            ]
        ),
        GoldenCase(
            id: "L25",
            title: "Three-point circle through (0,0), (0,20), (20,0) at 1 ft/pt: r = sqrt(200) pt",
            derivation: .handDerived,
            tool: .threePointCircle,
            geometry: GoldenGeometry.polyline([(0, 0), (0, 20), (20, 0)]),
            scale: GoldenScale.imperialFoot,
            parameters: MeasurementParameters(display: .imperial),
            expected: [
                .radius: (200.0 as Double).squareRoot() * 0.3048,
                .diameter: 2 * (200.0 as Double).squareRoot() * 0.3048,
                .circumference: 2 * Double.pi * (200.0 as Double).squareRoot() * 0.3048
            ]
        )
    ]
}
