import Foundation
import ZPDFContracts
import ZPDFSnapEngine
import ZPDFUIPresentation

// MARK: - Boundary marks and snap boundaries (spec 13.2 source 4, U-086)

/// One thing the canvas draws over a page that is not a markup: a Project Zone's or a Scale
/// Region's saved outline, or the points a calibration in force on the page was picked at.
///
/// The one list both halves read. The snap index's boundary layer (`zoneBoundary`, priority 12;
/// `calibrationPoint`, priority 1) is fed from these marks and from nothing else
/// (``TakeoffSession/snapBoundaries(onPages:)``), and the canvas draws exactly these marks
/// (`DocumentSnapshot.boundaryMarks`, `AppCanvasPresenter.boundaryMarks`). A boundary target
/// with no drawn mark would be a candidate from invisible geometry — the confidently wrong snap
/// `QUALITY_BAR` S16 forbids — which is what U-086's first fix shipped: the targets were fed
/// while no view drew a saved outline or calibration point.
public struct PageBoundaryMark: Sendable, Hashable, Identifiable {

    /// What the mark is.
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        /// A Project Zone's saved boundary.
        case projectZone
        /// A Scale Region's saved boundary.
        case scaleRegion
        /// The picked points of a calibration in force on the page.
        case calibration
    }

    /// Stable identity, shared with the snap boundary the mark feeds:
    /// `zone:<uuid>`, `scaleRegion:<uuid>`, `calibration:<scale uuid>`.
    public let id: String
    public let kind: Kind
    /// The page the mark is drawn on.
    public let pageID: PageID
    /// The zone's or region's name; empty for a calibration.
    public let name: String
    /// A closed outline for a zone or region (the first point is not repeated), the picked
    /// points for a calibration. Page space.
    public let points: [PDFPoint]
    /// The outline colour the panel set; `nil` for a calibration, which draws in the canvas's
    /// calibration ink.
    public let colorRGBA: ColorRGBA?

    public init(id: String, kind: Kind, pageID: PageID, name: String, points: [PDFPoint], colorRGBA: ColorRGBA?) {
        self.id = id
        self.kind = kind
        self.pageID = pageID
        self.name = name
        self.points = points
        self.colorRGBA = colorRGBA
    }

    /// The snap boundary this mark contributes: the outline as one closed polyline, or each
    /// picked point.
    var snapBoundary: SnapBoundary {
        switch kind {
        case .projectZone:
            SnapBoundary(id: id, category: .zone, geometry: [.polyline(points: points, isClosed: true)])
        case .scaleRegion:
            SnapBoundary(id: id, category: .scaleRegion, geometry: [.polyline(points: points, isClosed: true)])
        case .calibration:
            SnapBoundary(id: id, category: .calibrationPoint, geometry: points.map { .point($0) })
        }
    }
}

extension DocumentSnapshot {

    /// The boundary marks drawn on one page, in the order the canvas draws them.
    public func boundaryMarks(onPage pageID: UUID?) -> [PageBoundaryMark] {
        guard let pageID else { return [] }
        return boundaryMarks.filter { $0.pageID.rawValue == pageID }
    }
}

extension TakeoffSession {

    /// Every page's boundary marks, pages in document order.
    ///
    /// On a page, in drawing order: each visible Project Zone with a drawn boundary, each visible
    /// Scale Region, then the calibrations in force there — the page's own scale and the scale of
    /// each visible region on it — whose picks were made on this page (a scale applied to another
    /// sheet in bulk has no pick here). A superseded scale is kept for the values measured with
    /// it (NL-MEASURE-03) and draws nothing: its picks are history, not a target. A hidden
    /// outline draws nothing and is no target; hiding a region also hides its scale's picks.
    public func allBoundaryMarks() -> [PageBoundaryMark] {
        let marks = boundaryMarks(onPages: nil)
        return pageDescriptors.flatMap { marks[$0.id] ?? [] }
    }

    /// The boundary marks on one page. See ``allBoundaryMarks()`` for the rule.
    public func boundaryMarks(onPage page: PageID) -> [PageBoundaryMark] {
        boundaryMarks(onPages: [page])[page] ?? []
    }

    /// ``allBoundaryMarks()`` for the pages in `pages` (every page when `nil`), in one pass over
    /// the document's zones, regions and scales.
    func boundaryMarks(onPages pages: Set<PageID>?) -> [PageID: [PageBoundaryMark]] {
        func wanted(_ page: PageID) -> Bool { pages?.contains(page) ?? true }
        var result: [PageID: [PageBoundaryMark]] = [:]
        for zone in projectZoneDefinitions where zone.isVisible && zone.boundary.count >= 3 {
            guard let page = zone.pageID, wanted(page) else { continue }
            result[page, default: []].append(PageBoundaryMark(
                id: "zone:" + zone.id.rawValue.uuidString, kind: .projectZone, pageID: page,
                name: zone.name, points: zone.boundary, colorRGBA: zone.colorRGBA
            ))
        }
        // The scales in force per page: the page's own, then each visible region's.
        var inForce: [PageID: Set<ScaleID>] = [:]
        for region in scaleRegionDefinitions where region.isVisible && region.boundary.count >= 3 && wanted(region.pageID) {
            result[region.pageID, default: []].append(PageBoundaryMark(
                id: "scaleRegion:" + region.id.rawValue.uuidString, kind: .scaleRegion, pageID: region.pageID,
                name: region.name, points: region.boundary, colorRGBA: region.colorRGBA
            ))
            inForce[region.pageID, default: []].insert(region.scaleID)
        }
        for (page, scale) in pageScales where wanted(page) {
            inForce[page, default: []].insert(scale.id)
        }
        // Sorted, so two builds of one document draw and index in one order (QUALITY_BAR S15).
        for page in inForce.keys.sorted(by: { $0.rawValue.uuidString < $1.rawValue.uuidString }) {
            for scaleID in (inForce[page] ?? []).sorted(by: { $0.rawValue.uuidString < $1.rawValue.uuidString }) {
                guard let scale = scaleTransform(scaleID), scale.pageID == page,
                      let points = evidence(for: scaleID)?.points.filter(\.isFinite), !points.isEmpty else { continue }
                result[page, default: []].append(PageBoundaryMark(
                    id: "calibration:" + scaleID.rawValue.uuidString, kind: .calibration, pageID: page,
                    name: "", points: points, colorRGBA: nil
                ))
            }
        }
        return result
    }

    /// The page's snap boundaries: its boundary marks, as the snap index takes them.
    ///
    /// The snap index has carried a boundary layer since spec 13.2 — `zoneBoundary` (priority 12)
    /// and `calibrationPoint` (priority 1), in the POINT and MARK snap sets. It is fed from
    /// ``boundaryMarks(onPage:)`` and from nothing else, so every target is a mark the canvas
    /// draws (U-086, `QUALITY_BAR` S16).
    func snapBoundaries(onPage page: PageID) -> [SnapBoundary] {
        snapBoundaries(onPages: [page])[page] ?? []
    }

    /// ``snapBoundaries(onPage:)`` for several pages in one pass — what the per-mutation refresh
    /// of every installed index reads.
    func snapBoundaries(onPages pages: Set<PageID>) -> [PageID: [SnapBoundary]] {
        boundaryMarks(onPages: pages).mapValues { $0.map(\.snapBoundary) }
    }
}
