import Foundation
import ZPDFContracts

/// Cases whose expectation is a *warning* or an invariant rather than a number.
///
/// A measurement engine that returns the right number and says nothing about a cutout hanging
/// off the edge of its parent is not correct; it is merely arithmetically lucky. These cases are
/// part of the same gate as the numeric ones.
extension GoldenCorpus {
    public static let diagnostics: [GoldenCase] = [
        GoldenCase(
            id: "N01",
            title: "A 100 km/pt scale is outside the sane range and must say so",
            derivation: .invariant,
            tool: .length,
            geometry: GoldenGeometry.polyline([(0, 0), (1, 0)]),
            scale: GoldenScale.extreme,
            expected: [.planLength: 100_000],
            expectedWarnings: [.extremeScale]
        ),
        GoldenCase(
            id: "N02",
            title: "A bowtie is normalised to its two lobes: 2 m2, not the shoelace's 0",
            derivation: .handDerived,
            tool: .area,
            geometry: GoldenGeometry.polygon([(0, 0), (2, 2), (2, 0), (0, 2)]),
            scale: GoldenScale.unit,
            expected: [.planArea: 2],
            expectedWarnings: [.selfIntersectingPolygon, .polygonNormalized]
        ),
        GoldenCase(
            id: "N03",
            title: "A cutout hanging over the parent edge removes only its overlap: 100 - 4 m2",
            derivation: .handDerived,
            tool: .area,
            geometry: GoldenGeometry.polygon(
                GoldenGeometry.rectangle(x: 0, y: 0, width: 10, height: 10),
                holes: [GoldenGeometry.rectangle(x: 8, y: 8, width: 6, height: 6)]
            ),
            scale: GoldenScale.unit,
            expected: [.netArea: 100 - 4, .cutoutArea: 4],
            expectedWarnings: [.cutoutOutsideParent]
        ),
        GoldenCase(
            id: "N04",
            title: "A cutout entirely outside its parent is refused, not silently ignored",
            derivation: .handDerived,
            tool: .area,
            geometry: GoldenGeometry.polygon(
                GoldenGeometry.rectangle(x: 0, y: 0, width: 10, height: 10),
                holes: [GoldenGeometry.rectangle(x: 20, y: 20, width: 4, height: 4)]
            ),
            scale: GoldenScale.unit,
            // ADR-0015 (CR-33): before it, this case returned 100 with a warning nobody
            // could act on. A hole that touches nothing is a drawing mistake, and the
            // engine says so.
            expectedRefusal: "cutoutOutsideParent"
        ),
        GoldenCase(
            id: "N05",
            title: "A collinear ring encloses nothing and says so instead of returning a bare zero",
            derivation: .invariant,
            tool: .area,
            geometry: GoldenGeometry.polygon([(0, 0), (10, 0), (5, 0)]),
            scale: GoldenScale.unit,
            expected: [.planArea: 0, .netArea: 0],
            expectedWarnings: [.degenerateArea]
        ),
        GoldenCase(
            id: "N06",
            title: "An open ring is closed implicitly, with the warning that says so",
            derivation: .handDerived,
            tool: .area,
            geometry: MeasurementGeometry(
                pageID: GoldenIdentity.pageID,
                polygons: [
                    PolygonGeometry(
                        outer: PolygonRing(
                            points: GoldenGeometry.points(
                                GoldenGeometry.rectangle(x: 0, y: 0, width: 10, height: 10)
                            ),
                            isClosed: false
                        )
                    )
                ]
            ),
            scale: GoldenScale.unit,
            expected: [.planArea: 100],
            expectedWarnings: [.openPolygonClosedImplicitly]
        ),
        GoldenCase(
            id: "N07",
            title: "Repeated vertices are collapsed, and the area is unchanged",
            derivation: .handDerived,
            tool: .area,
            geometry: GoldenGeometry.polygon([
                (0, 0), (0, 0), (10, 0), (10, 0), (10, 10), (0, 10)
            ]),
            scale: GoldenScale.unit,
            expected: [.planArea: 100, .perimeter: 40],
            expectedWarnings: [.duplicatePointsCollapsed]
        ),
        GoldenCase(
            id: "N08",
            title: "A vertical slope has an angle but no ratio, and never an infinity",
            derivation: .invariant,
            tool: .slope,
            geometry: MeasurementGeometry(pageID: GoldenIdentity.pageID),
            scale: GoldenScale.unit,
            parameters: MeasurementParameters(
                slope: .uniformPlane(.riseOverRun(rise: 3, run: 0))
            ),
            // CR-22: a `rise:run` pitch is a ratio, so no rise/run length is written as
            // metres any more; the angle is the whole answer for a vertical pitch.
            expected: [.slopeAngle: Double.pi / 2],
            expectedWarnings: [.verticalSlopeUndefinedRun]
        ),
        GoldenCase(
            id: "N09",
            title: "A three-point circle that only just clears the collinearity floor warns",
            derivation: .invariant,
            tool: .threePointCircle,
            geometry: GoldenGeometry.polyline([(0, 0), (500, 0.0001), (1000, 0)]),
            scale: GoldenScale.unit,
            expectedWarnings: [.nearlyCollinearPoints]
        ),
        GoldenCase(
            id: "N10",
            title: "A short per-segment rise/drop list is padded with zero and warns",
            derivation: .handDerived,
            tool: .riseDrop,
            geometry: GoldenGeometry.polyline([(0, 0), (30, 0), (60, 0)]),
            scale: GoldenScale.unit,
            parameters: MeasurementParameters(
                slope: .perSegment([4])
            ),
            expected: [.trueLength: (916.0 as Double).squareRoot() + 30],
            expectedWarnings: [.riseDropCountMismatch]
        ),
        GoldenCase(
            id: "N11",
            title: "A measurement made under an older scale version is flagged as stale",
            derivation: .invariant,
            tool: .length,
            geometry: GoldenGeometry.polyline([(0, 0), (10, 0)]),
            scale: GoldenScale.unit,
            expected: [.planLength: 10],
            expectedWarnings: [.staleScaleVersion],
            expectedScaleVersion: GoldenCorpus.staleScaleExpectedVersion
        ),
        GoldenCase(
            id: "N12",
            title: "A clean rectangle raises no warnings at all",
            derivation: .invariant,
            tool: .area,
            geometry: GoldenGeometry.polygon(GoldenGeometry.rectangle(x: 0, y: 0, width: 12, height: 8)),
            scale: GoldenScale.unit,
            expected: [.planArea: 96],
            forbiddenWarnings: [
                .degenerateArea,
                .selfIntersectingPolygon,
                .polygonNormalized,
                .duplicatePointsCollapsed,
                .cutoutOutsideParent,
                .extremeScale,
                .openPolygonClosedImplicitly,
                .staleScaleVersion
            ]
        )
    ]
}
