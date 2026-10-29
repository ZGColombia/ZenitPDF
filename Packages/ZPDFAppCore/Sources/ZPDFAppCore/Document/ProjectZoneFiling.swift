import Foundation
import ZPDFContracts
import ZPDFGeometry

/// The markups a Project Zone's boundary encloses when the zone is drawn (L-92).
///
/// A zone drawn round markups that were already on the sheet used to file none of them: four
/// count marks and a polylength inside the boundary stayed unfiled, the zone showed 0, and
/// Group by Zone said nothing was filed yet. A zone was only any use for markups filed into it
/// one selection at a time afterwards. Creating a zone with a boundary now files what lies
/// inside it, through the same `.setMarkupZone` command "Assign Selection" runs and in the same
/// undo step as the zone itself; this decides which markups that is.
public enum ProjectZoneFiling {

    /// The markups `zone`'s boundary encloses, in the order `markups` gives them.
    ///
    /// A markup is taken when all of these hold:
    /// - it is on the zone's page;
    /// - every point of its geometry lies inside the boundary or on it — every point the Scale
    ///   Region sampler takes (vertices, arc and curve samples, count positions), so a markup is
    ///   judged by the zone exactly as by a Scale Region drawn on the same line, and one that
    ///   straddles the edge stays where it is;
    /// - it is not locked: a locked markup is never re-filed through the back door (BH-435);
    /// - it is unfiled, or filed in one of the zone's ancestors — a room drawn inside
    ///   "Floor 2" refines what lies in it, while a markup a person filed elsewhere stays there.
    ///
    /// A zone with no boundary, or none on a page, encloses nothing.
    public static func markupsEnclosed(
        by zone: ProjectZoneDefinition,
        among markups: [MarkupRecord],
        zones: [ProjectZoneDefinition]
    ) -> [MarkupID] {
        guard let pageID = zone.pageID, zone.boundary.count >= 3 else { return [] }
        let ancestors = ancestorIDs(of: zone, in: zones)
        return markups.compactMap { record in
            guard record.pageID == pageID, !record.locked else { return nil }
            if let filed = record.zoneID, !ancestors.contains(filed) { return nil }
            guard let geometry = record.geometry else { return nil }
            let samples = ScaleRegionResolver.samplePoints(of: geometry, tool: record.tool)
            guard !samples.isEmpty, samples.allSatisfy({ $0.isFinite }) else { return nil }
            let enclosed = samples.allSatisfy { PolygonMath.classify($0, in: zone.boundary) != .outside }
            return enclosed ? record.id : nil
        }
    }

    /// Every zone `zone` is nested inside, nearest first; a cycle in a damaged project ends the
    /// walk rather than the application.
    static func ancestorIDs(of zone: ProjectZoneDefinition, in zones: [ProjectZoneDefinition]) -> Set<ZoneID> {
        var result = Set<ZoneID>()
        var next = zone.parentID
        while let id = next, id != zone.id, result.insert(id).inserted {
            next = zones.first { $0.id == id }?.parentID
        }
        return result
    }
}
