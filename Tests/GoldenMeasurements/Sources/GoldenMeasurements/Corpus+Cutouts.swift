import Foundation
import ZPDFContracts

/// Cutout cases for ADR-0018: the parent's Plan Area (the engine's `netArea`) is its outline minus
/// the **union** of its cutouts, under every policy that subtracts; Volume and True Area are built
/// from that net number; `ignore` leaves the outline whole. Every expected value is written as the
/// arithmetic that produces it, on paper, before the engine ran.
///
/// The ledger half of the rule — a cutout's own row carries no quantity and never reaches a
/// subtotal — is proved in the ledger and export packages, which own rows and totals.
extension GoldenCorpus {
    public static let cutouts: [GoldenCase] = [
        GoldenCase(
            id: "K01",
            title: "Cutout in the corner, touching two outline edges: 10 x 10 - 4 x 4 = 84 m2",
            derivation: .handDerived,
            tool: .area,
            geometry: GoldenGeometry.polygon(
                GoldenGeometry.rectangle(x: 0, y: 0, width: 10, height: 10),
                holes: [GoldenGeometry.rectangle(x: 0, y: 0, width: 4, height: 4)]
            ),
            scale: GoldenScale.unit,
            // plan    10 * 10          = 100
            // cutout  4 * 4            =  16   (inside the outline; shares two of its edges)
            // net     100 - 16         =  84
            // perimeter, outerOnly: the drawn outline, 4 * 10 = 40, whatever the cutouts do
            expected: [.planArea: 100, .cutoutArea: 16, .netArea: 84, .perimeter: 40],
            forbiddenWarnings: [.cutoutOutsideParent]
        ),
        GoldenCase(
            id: "K02",
            title: "Notch touching one outline edge, perimeter of what is left: 92 m2, 44 m",
            derivation: .handDerived,
            tool: .area,
            geometry: GoldenGeometry.polygon(
                GoldenGeometry.rectangle(x: 0, y: 0, width: 10, height: 10),
                holes: [GoldenGeometry.rectangle(x: 3, y: 0, width: 4, height: 2)]
            ),
            scale: GoldenScale.unit,
            parameters: MeasurementParameters(perimeterPolicy: .outerPlusCutoutEdges),
            // net    100 - 4 * 2 = 92
            // boundary of the net region, walked counter-clockwise from (0,0):
            //   (0,0)->(3,0) 3, up 2, across 4, down 2, (7,0)->(10,0) 3, right 10, top 10, left 10
            //   3 + 2 + 4 + 2 + 3 + 10 + 10 + 10 = 44  (the 4 m of shared bottom edge is gone)
            expected: [.planArea: 100, .cutoutArea: 8, .netArea: 92, .perimeter: 44],
            forbiddenWarnings: [.cutoutOutsideParent]
        ),
        GoldenCase(
            id: "K03",
            title: "Two disjoint cutouts under subtractAndReportSeparately: same net as subtract, 9000 m2",
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
            parameters: MeasurementParameters(cutoutPolicy: .subtractAndReportSeparately),
            // cutouts 20 * 30 + 20 * 20 = 600 + 400 = 1000; net 10000 - 1000 = 9000.
            // Reporting separately changes what the ledger shows beside the parent, never the
            // parent's own net number.
            expected: [.planArea: 10_000, .cutoutArea: 1_000, .netArea: 9_000]
        ),
        GoldenCase(
            id: "K04",
            title: "Two overlapping cutouts under subtractAndReportSeparately: union 16 + 16 - 4 = 28, net 72",
            derivation: .handDerived,
            tool: .area,
            geometry: GoldenGeometry.polygon(
                GoldenGeometry.rectangle(x: 0, y: 0, width: 10, height: 10),
                holes: [
                    GoldenGeometry.rectangle(x: 1, y: 1, width: 4, height: 4),
                    GoldenGeometry.rectangle(x: 3, y: 3, width: 4, height: 4)
                ]
            ),
            scale: GoldenScale.unit,
            parameters: MeasurementParameters(cutoutPolicy: .subtractAndReportSeparately),
            // each cutout 4 * 4 = 16; overlap [3,5] x [3,5] = 2 * 2 = 4
            // union 16 + 16 - 4 = 28; net 100 - 28 = 72
            // WRONG 100 - 16 - 16 = 68 (overlap subtracted twice)
            expected: [.planArea: 100, .cutoutArea: 28, .netArea: 72]
        ),
        GoldenCase(
            id: "K05",
            title: "The same overlapping cutouts under ignore: the outline stays whole, 100 m2",
            derivation: .handDerived,
            tool: .area,
            geometry: GoldenGeometry.polygon(
                GoldenGeometry.rectangle(x: 0, y: 0, width: 10, height: 10),
                holes: [
                    GoldenGeometry.rectangle(x: 1, y: 1, width: 4, height: 4),
                    GoldenGeometry.rectangle(x: 3, y: 3, width: 4, height: 4)
                ]
            ),
            scale: GoldenScale.unit,
            parameters: MeasurementParameters(cutoutPolicy: .ignore),
            // ignore: net = plan = 10 * 10 = 100
            expected: [.planArea: 100, .netArea: 100]
        ),
        GoldenCase(
            id: "K06",
            title: "Volume with two overlapping cutouts: 72 m2 net x 0.25 m = 18 m3",
            derivation: .handDerived,
            tool: .volume,
            geometry: GoldenGeometry.polygon(
                GoldenGeometry.rectangle(x: 0, y: 0, width: 10, height: 10),
                holes: [
                    GoldenGeometry.rectangle(x: 1, y: 1, width: 4, height: 4),
                    GoldenGeometry.rectangle(x: 3, y: 3, width: 4, height: 4)
                ]
            ),
            scale: GoldenScale.unit,
            parameters: MeasurementParameters(depth: .length(Decimal(string: "0.25")!)),
            // net 100 - (16 + 16 - 4) = 72; volume 72 * 0.25 = 18
            // WRONG 100 * 0.25 = 25 (gross), 68 * 0.25 = 17 (overlap twice)
            expected: [.netArea: 72, .volume: 72 * 0.25]
        ),
        GoldenCase(
            id: "K07",
            title: "Cutout on a 1:2 sloped plane: true area = (200 - 20) x sqrt(1.25)",
            derivation: .handDerived,
            tool: .trueSlopedArea,
            geometry: GoldenGeometry.polygon(
                GoldenGeometry.rectangle(x: 0, y: 0, width: 20, height: 10),
                holes: [GoldenGeometry.rectangle(x: 5, y: 3, width: 4, height: 5)]
            ),
            scale: GoldenScale.unit,
            parameters: MeasurementParameters(
                // Area needs no azimuth: the projection factor is direction-independent.
                slope: .uniformPlane(.decimalRatio(Decimal(string: "0.5")!))
            ),
            // plan 20 * 10 = 200; cutout 4 * 5 = 20; net 180
            // slope factor sqrt(1 + 0.5^2) = sqrt(1.25)
            // true 180 * sqrt(1.25)                    = 201.246117974981
            // WRONG 200 * sqrt(1.25) - 20              = 203.606797749979 (factor before cutout)
            expected: [
                .planArea: 200,
                .cutoutArea: 20,
                .netArea: 180,
                .trueArea: 180 * (1.25 as Double).squareRoot()
            ]
        ),
        GoldenCase(
            id: "K08",
            title: "Volume of a slab with a corner cutout, reported separately: 84 m2 x 0.2 m = 16.8 m3",
            derivation: .handDerived,
            tool: .volume,
            geometry: GoldenGeometry.polygon(
                GoldenGeometry.rectangle(x: 0, y: 0, width: 10, height: 10),
                holes: [GoldenGeometry.rectangle(x: 6, y: 6, width: 4, height: 4)]
            ),
            scale: GoldenScale.unit,
            parameters: MeasurementParameters(
                depth: .length(Decimal(string: "0.2")!),
                cutoutPolicy: .subtractAndReportSeparately
            ),
            // net 100 - 16 = 84; volume 84 * 0.2 = 16.8 — the policy does not change the volume
            expected: [.planArea: 100, .cutoutArea: 16, .netArea: 84, .volume: 84 * 0.2],
            forbiddenWarnings: [.cutoutOutsideParent]
        )
    ]
}
