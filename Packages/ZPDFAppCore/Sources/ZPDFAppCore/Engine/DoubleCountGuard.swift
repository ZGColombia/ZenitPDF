import Foundation
import ZPDFContracts
import ZPDFMeasurementEngine

/// The double-count guard (NL-MEASURE-13): two areas of the same subject that cover the same
/// ground are both summed, and nothing used to notice.
///
/// Which markups are compared is the product decision, and it lives here: plan areas (Area,
/// Rectangle Area, Volume, True Sloped Area) on the same page, with the same non-empty subject
/// and the same Project Zone, that have a quantity. A cutout is part of its parent and is never
/// compared; a Wall Area's outline is the room its walls run around, not a floor, so it is out
/// too. The overlap itself is `OverlapGuard`'s, on the net regions (holes out).
public enum DoubleCountGuard {

    /// One overlap worth saying.
    public struct Finding: Hashable, Sendable {
        public let first: MarkupID
        public let second: MarkupID
        public let firstLabel: String
        public let secondLabel: String
        public let subject: String
        public let pageID: PageID
        /// The shared area in square metres, through the first markup's scale.
        public let squareMetres: Decimal
        /// The shared region, page space, for the canvas hatch. Display only.
        public var region: [PolygonGeometry] = []
    }

    /// Below this real area an overlap is a drawing tolerance, not a double count.
    public static let floorSquareMetres: Decimal = NumericPolicy.exact(1, -4)

    static let comparedTools: Set<MeasurementTool> = [.area, .rectangleArea, .volume, .trueSlopedArea]

    /// The markups compared with one another: one page, one subject, one Project Zone.
    struct GroupKey: Hashable, Sendable {
        let page: PageID
        let subject: String
        let zone: ZoneID?
    }

    /// Each compared group's overlaps, kept with the outlines they were computed from (U-038).
    ///
    /// The guard runs after every command, and a group's overlaps are one Clipper2 intersection
    /// per pair whose boxes touch — adjacent rooms of one subject always do. A label, colour,
    /// status or custom-value edit leaves every outline as it was, so the booleans are asked
    /// again only for a group whose outlines changed; labels and scales are read fresh each time.
    public struct OverlapCache: Sendable {
        struct Entry: Sendable {
            let outlines: [PolygonGeometry]
            /// `nil` when the engine refused the group; it is not asked again until it changes.
            let overlaps: [AreaOverlap]?
        }
        var entries: [GroupKey: Entry] = [:]
        /// How many groups went through the polygon booleans, over the cache's life.
        public private(set) var evaluations = 0

        public init() {}

        mutating func overlaps(of key: GroupKey, outlines: [PolygonGeometry]) -> [AreaOverlap]? {
            if let kept = entries[key], kept.outlines == outlines { return kept.overlaps }
            evaluations += 1
            let computed = try? OverlapGuard.overlaps(of: outlines)
            entries[key] = Entry(outlines: outlines, overlaps: computed)
            return computed
        }
    }

    /// Whether a record takes part at all.
    static func isCompared(_ record: MarkupRecord) -> Bool {
        guard let tool = record.tool, comparedTools.contains(tool),
              record.parentMarkupID == nil,
              record.measurement != nil,
              !record.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              record.geometry?.polygons.isEmpty == false else { return false }
        return true
    }

    /// Every overlap among `records`. Always every pair: the tray is kept exactly in step with
    /// the result, so a partial answer would dismiss the warnings of pairs it did not look at.
    ///
    /// - Parameter scale: the scale a record was measured under, for the m² conversion.
    public static func findings(
        in records: [MarkupRecord],
        scale: (MarkupRecord) -> ScaleTransform?
    ) -> [Finding] {
        var cache = OverlapCache()
        return findings(in: records, scale: scale, cache: &cache)
    }

    /// Every overlap among `records`, the booleans asked only for groups whose outlines changed
    /// since `cache` last saw them (U-038). Groups no longer present leave the cache.
    public static func findings(
        in records: [MarkupRecord],
        scale: (MarkupRecord) -> ScaleTransform?,
        cache: inout OverlapCache
    ) -> [Finding] {
        let compared = records.filter(isCompared)
        let groups = Dictionary(grouping: compared) {
            GroupKey(page: $0.pageID, subject: $0.subject.trimmingCharacters(in: .whitespacesAndNewlines), zone: $0.zoneID)
        }
        cache.entries = cache.entries.filter { key, _ in (groups[key]?.count ?? 0) >= 2 }
        var found: [Finding] = []
        for (key, members) in groups.sorted(by: { $0.key.subject < $1.key.subject }) where members.count >= 2 {
            guard let overlaps = cache.overlaps(of: key, outlines: members.compactMap { $0.geometry?.polygons.first }) else {
                continue
            }
            for overlap in overlaps {
                let a = members[overlap.first], b = members[overlap.second]
                guard let scale = scale(a) else { continue }
                let determinant = Swift.abs(scale.matrix.determinant)
                guard let pageArea = try? NumericPolicy.decimal(from: overlap.pageArea) else { continue }
                let squareMetres = pageArea * determinant
                guard squareMetres >= floorSquareMetres else { continue }
                found.append(Finding(
                    first: a.id, second: b.id, firstLabel: a.label, secondLabel: b.label,
                    subject: key.subject, pageID: key.page, squareMetres: squareMetres,
                    region: overlap.region
                ))
            }
        }
        return found
    }
}

extension TakeoffSession {

    /// Every double-count finding in the document (NL-MEASURE-13).
    public func doubleCountFindings() -> [DoubleCountGuard.Finding] {
        var cache = doubleCountCache
        defer { doubleCountCache = cache }
        return DoubleCountGuard.findings(in: orderedMarkups, scale: { record in
            self.scale(onPage: record.pageID, scaleID: record.scaleID)
        }, cache: &cache)
    }
}
