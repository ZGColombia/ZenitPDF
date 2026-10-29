import Foundation
import ZPDFContracts
import ZPDFGeometry
import ZPDFUIPresentation

/// Which scale applies where on one sheet, as far as a circle tool cares (L-102).
///
/// Radius, Diameter and Three-Point Circle read one radius off a circle, and the engine refuses
/// one under a scale whose X and Y differ. The scale a measurement is taken with is not always
/// the sheet's own: the commit moves a measurement drawn wholly inside a Scale Region onto that
/// region's scale (`AppCoreEnvironment.scaleRegionDecision`). A sheet calibrated with separate X
/// and Y scales that holds a detail calibrated on the drawing measures circles correctly inside
/// the detail, so the circle tools' gate asks this value about the point, never only about the
/// sheet's own scale — the first L-102 fix did, and refused every circle on such a sheet with
/// advice to recalibrate it.
///
/// Built from the snapshot's ``ScaleRegionSummary`` list with the geometry package's own
/// ``ScaleRegionResolver``, so the answer here is the resolver's answer at the commit: a point on
/// a region's edge is inside it, two overlapping regions are ambiguous, a region whose boundary
/// cannot hold anything is left out (the session's rule, BH-096).
struct UniformScaleCoverage {

    /// The sheet's own scale, or `nil` for an uncalibrated sheet (the missing-scale rule's case).
    let pageScale: ScaleSummary?
    /// Each region's scale, by region.
    private let regionScales: [ScaleRegionID: ScaleSummary]
    /// The sheet's regions, or `nil` when it has none.
    private let resolver: ScaleRegionResolver?

    /// A sheet with no scale and no regions.
    static let none = UniformScaleCoverage(pageID: PageID(UUID()), pageScale: nil, regions: [])

    init(pageID: PageID, pageScale: ScaleSummary?, regions: [ScaleRegionSummary]) {
        self.pageScale = pageScale
        let onPage = regions.filter { $0.pageID == pageID.rawValue }
        var scales: [ScaleRegionID: ScaleSummary] = [:]
        var geometry: [ScaleRegion] = []
        for summary in onPage {
            let region = ScaleRegion(
                id: ScaleRegionID(summary.id),
                pageID: pageID,
                scaleID: ScaleID(summary.scale.id),
                boundary: PolygonRing(points: summary.boundary.map { PDFPoint(x: $0.x, y: $0.y) }, isClosed: true),
                priority: summary.priority,
                isLocked: summary.locked,
                label: summary.name
            )
            guard region.bounds != nil else { continue }
            geometry.append(region)
            scales[region.id] = summary.scale
        }
        self.regionScales = scales
        self.resolver = geometry.isEmpty ? nil : try? ScaleRegionResolver(pageID: pageID, regions: geometry)
    }

    /// Whether some Scale Region on the sheet has one scale for both directions.
    var hasUniformRegion: Bool { resolver != nil && regionScales.values.contains(where: \.isUniform) }

    /// Whether some Scale Region on the sheet has separate X and Y scales.
    var hasNonUniformRegion: Bool { resolver != nil && regionScales.values.contains { !$0.isUniform } }

    /// Whether no part of the sheet has one scale for both directions: its own scale has separate
    /// X and Y, and no region offers a uniform one. `false` on an uncalibrated sheet, which the
    /// missing-scale rule refuses in its own words.
    var circlesImpossibleOnSheet: Bool {
        guard let pageScale, !pageScale.isUniform else { return false }
        return !hasUniformRegion
    }

    /// Whether a circle could be read at `point`: the scale that applies there is uniform — or,
    /// where the person will be asked which scale applies (two overlapping regions, a shared
    /// edge), one of the candidates is. `true` where no scale applies at all: that is the
    /// missing-scale rule's refusal, not this one's.
    func admitsCircle(at point: PDFPointValue) -> Bool {
        let pagePoint = PDFPoint(x: point.x, y: point.y)
        guard let resolver else { return pageScale?.isUniform ?? true }
        switch resolver.resolve(point: pagePoint) {
        case .pageDefault:
            return pageScale?.isUniform ?? true
        case let .region(id):
            return regionScales[id]?.isUniform ?? (pageScale?.isUniform ?? true)
        case let .ambiguous(ambiguity):
            if ambiguity.includesPageDefault, pageScale?.isUniform ?? false { return true }
            return ambiguity.candidates.contains { regionScales[$0]?.isUniform == true }
        }
    }

    /// The region scale a measurement over `geometry` is taken with at the commit, or `nil` when
    /// it is the sheet's own (outside every region, across a boundary, or no regions).
    ///
    /// The commit's sampler and resolution (`AppCoreEnvironment.scaleRegionDecision`), so the
    /// live value is read at the scale the ledger will use. Before, the preview always used the
    /// sheet's scale: inside a 1:20 detail on a 1:100 sheet the live number was five times the
    /// committed one, and a circle inside a uniform detail on a sheet with separate X and Y scales
    /// had no live value at all.
    func regionScaleID(for geometry: MeasurementGeometry, tool: MeasurementTool) -> ScaleID? {
        guard let resolver else { return nil }
        let points = ScaleRegionResolver.samplePoints(of: geometry, tool: tool)
        guard !points.isEmpty, case let .region(id)? = try? resolver.resolve(geometry: points) else { return nil }
        return regionScales[id].map { ScaleID($0.id) }
    }
}
