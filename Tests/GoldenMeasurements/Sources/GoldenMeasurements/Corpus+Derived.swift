import Foundation
import ZPDFContracts

/// Volume, wall area, slope, rise/drop, angle and count cases.
extension GoldenCorpus {
    public static let derived: [GoldenCase] = [
        // MARK: - Volume (spec 12.6)

        GoldenCase(
            id: "V01",
            title: "10 x 20 m slab, 200 mm deep: 40 m3",
            derivation: .handDerived,
            tool: .volume,
            geometry: GoldenGeometry.polygon(GoldenGeometry.rectangle(x: 0, y: 0, width: 10, height: 20)),
            scale: GoldenScale.unit,
            parameters: MeasurementParameters(depth: .length(Decimal(string: "0.2")!)),
            expected: [.netArea: 200, .depth: 0.2, .volume: 200 * 0.2]
        ),
        GoldenCase(
            id: "V02",
            title: "9400 m2 net slab, 150 mm deep: 1410 m3",
            derivation: .handDerived,
            tool: .volume,
            geometry: GoldenGeometry.polygon(
                GoldenGeometry.rectangle(x: 0, y: 0, width: 100, height: 100),
                holes: [GoldenGeometry.rectangle(x: 20, y: 20, width: 20, height: 30)]
            ),
            scale: GoldenScale.unit,
            parameters: MeasurementParameters(depth: .length(Decimal(string: "0.15")!)),
            expected: [.netArea: 9_400, .volume: 9_400 * 0.15]
        ),
        GoldenCase(
            id: "V03",
            title: "150 m2 at 50 mm/pt, 250 mm deep: 37.5 m3",
            derivation: .handDerived,
            tool: .volume,
            geometry: GoldenGeometry.polygon(GoldenGeometry.rectangle(x: 0, y: 0, width: 300, height: 200)),
            scale: GoldenScale.metric50,
            parameters: MeasurementParameters(depth: .length(Decimal(string: "0.25")!)),
            expected: [.netArea: 150, .volume: 37.5]
        ),
        GoldenCase(
            id: "V04",
            title: "Imperial footing 120 x 24 ft, 2 ft deep",
            derivation: .handDerived,
            tool: .volume,
            geometry: GoldenGeometry.polygon(GoldenGeometry.rectangle(x: 0, y: 0, width: 120, height: 24)),
            scale: GoldenScale.imperialFoot,
            parameters: MeasurementParameters(
                depth: .length(Decimal(string: "0.6096")!),
                display: .imperial
            ),
            expected: [
                .netArea: (120 * 0.3048) * (24 * 0.3048),
                .volume: (120 * 0.3048) * (24 * 0.3048) * 0.6096
            ]
        ),
        GoldenCase(
            id: "V05",
            title: "600 m2 triangular slab, 50 mm deep: 30 m3",
            derivation: .handDerived,
            tool: .volume,
            geometry: GoldenGeometry.polygon([(0, 0), (30, 0), (0, 40)]),
            scale: GoldenScale.unit,
            parameters: MeasurementParameters(depth: .length(Decimal(string: "0.05")!)),
            expected: [.netArea: 600, .volume: 30]
        ),
        GoldenCase(
            id: "V06",
            title: "100 m2 on a page rotated 30 deg, 1.2 m deep: 120 m3",
            derivation: .handDerived,
            tool: .volume,
            geometry: GoldenGeometry.polygon(GoldenGeometry.rectangle(x: 0, y: 0, width: 100, height: 100)),
            scale: GoldenScale.rotated30,
            parameters: MeasurementParameters(depth: .length(Decimal(string: "1.2")!)),
            expected: [.netArea: 100, .volume: 120]
        ),
        GoldenCase(
            id: "V07",
            title: "L-shaped slab 1800 m2, 300 mm deep: 540 m3",
            derivation: .handDerived,
            tool: .volume,
            geometry: GoldenGeometry.polygon(GoldenCorpus.lShape),
            scale: GoldenScale.unit,
            parameters: MeasurementParameters(depth: .length(Decimal(string: "0.3")!)),
            expected: [.netArea: 1_800, .volume: 540]
        ),
        GoldenCase(
            id: "V08",
            title: "Separate-XY slab 2 m x 5 m, 2 m deep: 20 m3",
            derivation: .handDerived,
            tool: .volume,
            geometry: GoldenGeometry.polygon(GoldenGeometry.rectangle(x: 0, y: 0, width: 100, height: 100)),
            scale: GoldenScale.separateXY,
            parameters: MeasurementParameters(depth: .length(2)),
            expected: [.netArea: 10, .volume: 20]
        ),

        // MARK: - Wall area (spec 12.7)

        GoldenCase(
            id: "W01",
            title: "25 m wall, 2.7 m high, one 2.1x0.9 door and one 1.2x1.5 window",
            derivation: .handDerived,
            tool: .wallArea,
            geometry: GoldenGeometry.polyline([(0, 0), (25, 0)]),
            scale: GoldenScale.unit,
            parameters: MeasurementParameters(
                height: .length(Decimal(string: "2.7")!),
                openingAreas: [Decimal(string: "1.89")!, Decimal(string: "1.8")!]
            ),
            expected: [
                .planLength: 25,
                .wallArea: 25 * 2.7,
                .netWallArea: 25 * 2.7 - (1.89 + 1.8)
            ]
        ),
        GoldenCase(
            id: "W02",
            title: "10 x 6 m room, 3 m high: 32 m perimeter x 3 m minus 3.6 m2 of openings",
            derivation: .handDerived,
            tool: .wallArea,
            geometry: GoldenGeometry.polygon(GoldenGeometry.rectangle(x: 0, y: 0, width: 10, height: 6)),
            scale: GoldenScale.unit,
            parameters: MeasurementParameters(
                height: .length(3),
                openingAreas: [2, Decimal(string: "1.6")!]
            ),
            expected: [.perimeter: 32, .wallArea: 96, .netWallArea: 92.4]
        ),
        GoldenCase(
            id: "W03",
            title: "100 ft wall, 8 ft high, no openings",
            derivation: .handDerived,
            tool: .wallArea,
            geometry: GoldenGeometry.polyline([(0, 0), (100, 0)]),
            scale: GoldenScale.imperialFoot,
            parameters: MeasurementParameters(
                height: .length(Decimal(string: "2.4384")!),
                display: .imperial
            ),
            expected: [
                .planLength: 100 * 0.3048,
                .wallArea: (100 * 0.3048) * 2.4384,
                .netWallArea: (100 * 0.3048) * 2.4384
            ]
        ),
        GoldenCase(
            id: "W04",
            title: "200 x 160 pt room at 50 mm/pt: 36 m perimeter, 2.5 m high, 4.5 m2 of openings",
            derivation: .handDerived,
            tool: .wallArea,
            geometry: GoldenGeometry.polygon(GoldenGeometry.rectangle(x: 0, y: 0, width: 200, height: 160)),
            scale: GoldenScale.metric50,
            parameters: MeasurementParameters(
                height: .length(Decimal(string: "2.5")!),
                openingAreas: [Decimal(string: "4.5")!]
            ),
            expected: [.perimeter: 36, .wallArea: 90, .netWallArea: 85.5]
        ),

        // MARK: - Slope (spec 12.8)

        GoldenCase(
            id: "S01",
            title: "1:3 slope: ratio 1/3, 33.33 %, atan(1/3)",
            derivation: .handDerived,
            tool: .slope,
            geometry: MeasurementGeometry(pageID: GoldenIdentity.pageID),
            scale: GoldenScale.unit,
            parameters: MeasurementParameters(slope: .uniformPlane(.ratioOneToN(3))),
            expected: [
                .slopeRatio: 1.0 / 3.0,
                .slopePercent: 100.0 / 3.0,
                .slopeAngle: Foundation.atan(1.0 / 3.0)
            ]
        ),
        GoldenCase(
            id: "S02",
            title: "25 % slope: ratio 0.25, atan(0.25)",
            derivation: .handDerived,
            tool: .slope,
            geometry: MeasurementGeometry(pageID: GoldenIdentity.pageID),
            scale: GoldenScale.unit,
            parameters: MeasurementParameters(slope: .uniformPlane(.percent(25))),
            expected: [.slopeRatio: 0.25, .slopePercent: 25, .slopeAngle: Foundation.atan(0.25)]
        ),
        GoldenCase(
            id: "S03",
            title: "30 degree slope: ratio tan(30 deg), angle pi/6",
            derivation: .handDerived,
            tool: .slope,
            geometry: MeasurementGeometry(pageID: GoldenIdentity.pageID),
            scale: GoldenScale.unit,
            parameters: MeasurementParameters(slope: .uniformPlane(.degrees(30))),
            expected: [
                .slopeRatio: Foundation.tan(Double.pi / 6),
                .slopePercent: 100 * Foundation.tan(Double.pi / 6),
                .slopeAngle: Double.pi / 6
            ]
        ),
        GoldenCase(
            id: "S04",
            title: "100 m plan run at a 1:2 slope: 100 sqrt(1.25) m of true length",
            derivation: .handDerived,
            tool: .trueSlopedLength,
            geometry: GoldenGeometry.polyline([(0, 0), (100, 0)]),
            scale: GoldenScale.unit,
            parameters: MeasurementParameters(
                // The line runs straight up the fall line, which is the one case where the
                // scalar slope factor happens to be right.
                slope: .uniformPlane(.ratioNToOne(Decimal(string: "0.5")!), azimuth: GoldenFallLine.east)
            ),
            expected: [.planLength: 100, .trueLength: 100 * (1.25 as Double).squareRoot()]
        ),
        GoldenCase(
            id: "S05",
            title: "400 pt at 50 mm/pt on a 1:4 slope: 20 sqrt(1.0625) m",
            derivation: .handDerived,
            tool: .trueSlopedLength,
            geometry: GoldenGeometry.polyline([(0, 0), (400, 0)]),
            scale: GoldenScale.metric50,
            parameters: MeasurementParameters(
                slope: .uniformPlane(.ratioOneToN(4), azimuth: GoldenFallLine.east)
            ),
            expected: [.planLength: 20, .trueLength: 20 * (1.0625 as Double).squareRoot()]
        ),
        GoldenCase(
            id: "S06",
            title: "100 m2 roof plane at a 1:2 slope: 100 sqrt(1.25) m2 of true area",
            derivation: .handDerived,
            tool: .trueSlopedArea,
            geometry: GoldenGeometry.polygon(GoldenGeometry.rectangle(x: 0, y: 0, width: 10, height: 10)),
            scale: GoldenScale.unit,
            parameters: MeasurementParameters(
                // Area needs no azimuth: the projection factor is direction-independent.
                slope: .uniformPlane(.decimalRatio(Decimal(string: "0.5")!))
            ),
            expected: [
                .planArea: 100,
                .netArea: 100,
                .trueArea: 100 * (1.25 as Double).squareRoot()
            ]
        ),
        GoldenCase(
            id: "S07",
            title: "Imperial roof plane 40 x 30 ft at a 4:12 pitch: plan x sqrt(1 + 1/9)",
            derivation: .handDerived,
            tool: .trueSlopedArea,
            geometry: GoldenGeometry.polygon(GoldenGeometry.rectangle(x: 0, y: 0, width: 40, height: 30)),
            scale: GoldenScale.imperialFoot,
            parameters: MeasurementParameters(
                slope: .uniformPlane(.ratioOneToN(3)),
                display: .imperial
            ),
            expected: [
                .planArea: (40 * 0.3048) * (30 * 0.3048),
                .trueArea: (40 * 0.3048) * (30 * 0.3048) * (1 + 1.0 / 9.0).squareRoot()
            ]
        ),
        GoldenCase(
            id: "S08",
            title: "Rise/drop per segment, all 4 m of fall in the first 30 m: sqrt(916) + 30",
            derivation: .handDerived,
            tool: .riseDrop,
            geometry: GoldenGeometry.polyline([(0, 0), (30, 0), (60, 0)]),
            scale: GoldenScale.unit,
            parameters: MeasurementParameters(
                slope: .perSegment([4, 0])
            ),
            expected: [
                .planLength: 60,
                .trueLength: (916.0 as Double).squareRoot() + 30,
                .rise: 4
            ]
        ),
        GoldenCase(
            id: "S09",
            title: "The same 4 m of fall applied to the whole 60 m polyline: sqrt(3616)",
            derivation: .handDerived,
            tool: .riseDrop,
            geometry: GoldenGeometry.polyline([(0, 0), (30, 0), (60, 0)]),
            scale: GoldenScale.unit,
            parameters: MeasurementParameters(slope: .total(4)),
            expected: [
                .planLength: 60,
                .trueLength: (3_616.0 as Double).squareRoot(),
                .rise: 4
            ]
        ),
        GoldenCase(
            id: "S10",
            title: "Per-segment fall in proportion to segment length equals the total-applied answer",
            derivation: .handDerived,
            tool: .riseDrop,
            geometry: GoldenGeometry.polyline([(0, 0), (30, 0), (60, 0)]),
            scale: GoldenScale.unit,
            parameters: MeasurementParameters(
                slope: .perSegment([2, 2])
            ),
            expected: [.trueLength: (3_616.0 as Double).squareRoot(), .rise: 4]
        ),
        GoldenCase(
            id: "S11",
            title: "Length tool carrying a 100 % slope: true length is plan x sqrt(2)",
            derivation: .handDerived,
            tool: .length,
            geometry: GoldenGeometry.polyline([(0, 0), (3, 4)]),
            scale: GoldenScale.unit,
            parameters: MeasurementParameters(
                // The 3-4-5 runs straight up the fall line: azimuth atan2(4, 3) = 53.13010235...
                slope: .uniformPlane(.percent(100), azimuth: GoldenFallLine.towards(dx: 3, dy: 4))
            ),
            expected: [.planLength: 5, .trueLength: 5 * (2.0 as Double).squareRoot()]
        ),
        GoldenCase(
            id: "S12",
            title: "45 degree slope on a 3-4-5: factor sqrt(2), angle pi/4",
            derivation: .handDerived,
            tool: .trueSlopedLength,
            geometry: GoldenGeometry.polyline([(0, 0), (3, 4)]),
            scale: GoldenScale.unit,
            parameters: MeasurementParameters(
                slope: .uniformPlane(.degrees(45), azimuth: GoldenFallLine.towards(dx: 3, dy: 4))
            ),
            expected: [
                .planLength: 5,
                .trueLength: 5 * (2.0 as Double).squareRoot(),
                .slopeAngle: Double.pi / 4,
                .slopeRatio: 1
            ]
        ),
        GoldenCase(
            id: "S13",
            title: "Rise/drop over a 300 pt polyline at 50 mm/pt with a 1.5 m total fall",
            derivation: .handDerived,
            tool: .riseDrop,
            geometry: GoldenGeometry.polyline([(0, 0), (200, 0), (200, 100)]),
            scale: GoldenScale.metric50,
            parameters: MeasurementParameters(
                slope: .total(Decimal(string: "1.5")!)
            ),
            expected: [
                .planLength: 15,
                .trueLength: (15.0 * 15.0 + 1.5 * 1.5).squareRoot(),
                .rise: 1.5
            ]
        ),

        // MARK: - Angle (spec 12.10)

        GoldenCase(
            id: "G01",
            title: "Right angle at the origin: pi/2",
            derivation: .handDerived,
            tool: .angle,
            geometry: GoldenGeometry.polyline([(10, 0), (0, 0), (0, 10)]),
            scale: GoldenScale.unit,
            expected: [.angle: Double.pi / 2]
        ),
        GoldenCase(
            id: "G02",
            title: "45 degrees: pi/4",
            derivation: .handDerived,
            tool: .angle,
            geometry: GoldenGeometry.polyline([(10, 0), (0, 0), (10, 10)]),
            scale: GoldenScale.unit,
            expected: [.angle: Double.pi / 4]
        ),
        GoldenCase(
            id: "G03",
            title: "135 degrees: 3 pi/4",
            derivation: .handDerived,
            tool: .angle,
            geometry: GoldenGeometry.polyline([(10, 0), (0, 0), (-10, 10)]),
            scale: GoldenScale.unit,
            expected: [.angle: 3 * Double.pi / 4]
        ),
        GoldenCase(
            id: "G04",
            title: "60 degrees from a unit vector at 60 deg: pi/3",
            derivation: .handDerived,
            tool: .angle,
            geometry: GoldenGeometry.polyline([
                (1, 0),
                (0, 0),
                (Foundation.cos(Double.pi / 3), Foundation.sin(Double.pi / 3))
            ]),
            scale: GoldenScale.unit,
            expected: [.angle: Double.pi / 3]
        ),
        GoldenCase(
            id: "G05",
            title: "Separate XY turns a page-space 45 deg into atan(2.5) in the real world",
            derivation: .handDerived,
            tool: .angle,
            geometry: GoldenGeometry.polyline([(10, 0), (0, 0), (10, 10)]),
            scale: GoldenScale.separateXY,
            expected: [.angle: Foundation.atan(2.5)]
        ),

        // MARK: - Count (spec 12.13)

        GoldenCase(
            id: "C01",
            title: "12 placed symbols: exactly 12",
            derivation: .handDerived,
            tool: .count,
            geometry: GoldenGeometry.counts(12),
            scale: GoldenScale.unit,
            expected: [.count: 12]
        ),
        GoldenCase(
            id: "C02",
            title: "A single placed symbol: exactly 1",
            derivation: .handDerived,
            tool: .count,
            geometry: GoldenGeometry.counts(1),
            scale: GoldenScale.unit,
            expected: [.count: 1]
        ),
        GoldenCase(
            id: "C03",
            title: "47 placed symbols: exactly 47, with no scale involved at all",
            derivation: .handDerived,
            tool: .count,
            geometry: GoldenGeometry.counts(47),
            scale: GoldenScale.extreme,
            expected: [.count: 47],
            forbiddenWarnings: [.extremeScale]
        ),

        // MARK: - Temporary measure (spec 12.14)

        GoldenCase(
            id: "T01",
            title: "Temporary measure over a 30 m polyline and a 100 m2 square",
            derivation: .handDerived,
            tool: .temporaryMeasure,
            geometry: MeasurementGeometry(
                pageID: GoldenIdentity.pageID,
                points: GoldenGeometry.points([(0, 0), (10, 0), (10, 10), (0, 10)]),
                polygons: [
                    PolygonGeometry(
                        outer: GoldenGeometry.ring(
                            GoldenGeometry.rectangle(x: 0, y: 0, width: 10, height: 10)
                        )
                    )
                ]
            ),
            scale: GoldenScale.unit,
            expected: [.planLength: 30, .planArea: 100, .perimeter: 40]
        )
    ]
}
