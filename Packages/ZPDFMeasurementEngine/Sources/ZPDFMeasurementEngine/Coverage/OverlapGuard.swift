import Foundation
import ZPDFClipper2
import ZPDFContracts

/// Two measured areas that cover the same ground (NL-MEASURE-13, the double-count guard).
public struct AreaOverlap: Hashable, Sendable {
    /// Index of the first area in the input, always smaller than ``second``.
    public let first: Int
    /// Index of the second area in the input.
    public let second: Int
    /// The shared region's area in PDF points squared: the intersection of the two **net**
    /// regions (outer ring minus holes), through the same Clipper2 routine as the coverage map.
    public let pageArea: Double
    /// The shared region itself, page space, for the canvas hatch (NL-MEASURE-13). Display only:
    /// the quantity is ``pageArea``.
    public let region: [PolygonGeometry]

    public init(first: Int, second: Int, pageArea: Double, region: [PolygonGeometry] = []) {
        self.first = first
        self.second = second
        self.pageArea = pageArea
        self.region = region
    }
}

/// Finds where measured areas overlap, so two areas of the same subject that are both summed
/// can be named instead of silently counted twice.
///
/// Pure and page-space. The caller decides which markups to compare — the same subject on the
/// same page, never a cutout against its parent — and converts the page area to square metres
/// with the page's scale.
///
/// This is the engine's one pairwise overlap rule (R-175). The coverage map used to carry a
/// second scan — an R-tree prefilter, a pair budget and a floor of 1e-9 pt² — that only tests
/// called, while the app ran this one, a box double loop with a floor of 1e-6 pt². The prefilter
/// moved here, the floor is this type's, and the coverage map's copy is gone.
public enum OverlapGuard {

    /// The smallest shared area, in PDF points², that counts as an overlap. Below it the
    /// "overlap" is lattice noise along a shared edge, not a double count.
    public static let defaultFloor = 1e-6

    /// The pairwise overlaps of `polygons` above `floor` (PDF points²), in index order.
    ///
    /// Candidate pairs come from the packed R-tree over the flattened rings' boxes
    /// (`CoverageMap.intersectingPartners`), so on a real sheet the booleans run only for the few
    /// pairs whose boxes meet — the same pairs, in the same `first`-then-`second` order, the box
    /// double loop visited. Two areas that merely share an edge overlap by zero and are not
    /// reported.
    public static func overlaps(
        of polygons: [PolygonGeometry],
        floor: Double = OverlapGuard.defaultFloor,
        options: MeasurementEngineOptions = .default
    ) throws(MeasurementEngineError) -> [AreaOverlap] {
        guard polygons.count >= 2 else { return [] }
        // The boxes of the rings as the booleans see them: an arc's bulge is part of its area, and
        // a box over the vertices alone skipped a pair that overlaps only inside it (ADR-0030 §5.7).
        let boxes = polygons.map { CoverageRegions.flattened($0).bounds }
        let partners = CoverageMap.intersectingPartners(of: boxes)
        var regions: [ClipperPaths?] = Array(repeating: nil, count: polygons.count)
        func region(_ index: Int) throws(MeasurementEngineError) -> ClipperPaths {
            if let cached = regions[index] { return cached }
            let computed = try CoverageRegions.netRegion(of: polygons[index], options: options)
            regions[index] = computed
            return computed
        }
        var found: [AreaOverlap] = []
        for first in 0..<(polygons.count - 1) {
            for second in partners[first] {
                let a = try region(first)
                let b = try region(second)
                let shared = try EngineClipper.run { () throws(ClipperError) -> ClipperPaths in
                    try Clipper2.intersection(a, b, fillRule: .nonZero, scale: options.clipperScale)
                }
                let area = CoverageRegions.pdfArea(of: shared)
                if area > floor {
                    let region = (try? CoverageRegions.polygons(from: shared, options: options)) ?? []
                    found.append(AreaOverlap(first: first, second: second, pageArea: area, region: region))
                }
            }
        }
        return found
    }
}
