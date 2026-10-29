import Foundation
import ZPDFCollaboration
import ZPDFContracts

/// What this copy of the project holds that a markup from another copy may name, for the two
/// roads by which another copy's markups arrive: a Shared Review sync and a `.zpdfreview` import.
///
/// **Set-aside markups are present (T-020).** A sheet removed from the set keeps its markups,
/// set aside — out of the canvas and the ledger, still the project's (NL-DOCS-07). The review
/// used to look only at the live markups, so removing a sheet here published every markup on it
/// as deleted, for everyone, and an import brought them back live a second time under the same
/// identity. Here they count as present; a change another copy makes to one waits, left as it is,
/// until the sheet is back in the set.
///
/// **Zones, Scale Regions and scales are checked (T-021).** None of them travels: a Project Zone
/// or a Scale Region another reviewer made after the copies parted is not here, and a page scale
/// has its own identity on each machine. A record naming one of those used to be applied as is —
/// the command threw, the batch rolled back and every later sync was refused the same way, or
/// the add went through and the save failed its foreign keys.
struct ReviewApplyContext: Sendable {

    /// Every markup of the document: those in the set, and those set aside with a removed sheet.
    var local: [MarkupID: MarkupRecord]
    /// The markups set aside with a sheet removed from the set.
    var setAside: Set<MarkupID> = []
    /// The sheets in the set.
    var livePages: Set<PageID>
    /// The Project Zones this copy holds.
    var zones: Set<ZoneID> = []
    /// The Scale Regions this copy holds, with the scale each measures by.
    var regions: [ScaleRegionID: ScaleID] = [:]
    /// Every scale this copy holds.
    var scales: Set<ScaleID> = []
    /// For a record naming a Scale Region this copy does not hold: where its geometry lies among
    /// this copy's regions (``AppCoreEnvironment/scaleRegionPlacement(of:)``).
    var regionPlacements: [MarkupID: AppCoreEnvironment.ScaleRegionPlacement] = [:]

    init(
        local: [MarkupID: MarkupRecord],
        setAside: Set<MarkupID> = [],
        livePages: Set<PageID>,
        zones: Set<ZoneID> = [],
        regions: [ScaleRegionID: ScaleID] = [:],
        scales: Set<ScaleID> = []
    ) {
        self.local = local
        self.setAside = setAside
        self.livePages = livePages
        self.zones = zones
        self.regions = regions
        self.scales = scales
    }

    /// Whether a record names a Scale Region this copy does not hold.
    func namesForeignRegion(_ record: MarkupRecord) -> Bool {
        record.scaleRegionID.map { regions[$0] == nil } ?? false
    }

    /// Where a record naming a foreign region lies here. A measurement nobody placed is held,
    /// never measured at a scale nobody chose.
    func placement(of record: MarkupRecord) -> AppCoreEnvironment.ScaleRegionPlacement {
        regionPlacements[record.id] ?? (record.tool == nil ? .pageDefault : .held)
    }
}

/// The document commands that bring this copy to another copy's markups, and what they leave.
struct ReviewApplyPlan: Sendable {
    var commands: [DocumentCommand] = []
    /// Markups changed in a way this build has no in-place command for (identity, layer, symbol,
    /// claim): left as they are.
    var unsupported: Set<MarkupID> = []
    /// Markups on a sheet that is not in this copy's set — removed here, or never held: left as
    /// they are here until the sheet is back (T-020).
    var onRemovedSheets: Set<MarkupID> = []
    /// Markups naming a Project Zone or Scale Region this copy does not hold: filed without the
    /// zone, measured by this copy's own regions, or held when they lie across two (T-021).
    var missingStructure: Set<MarkupID> = []
    /// Arriving markups that were not added.
    var skippedAdds: Set<MarkupID> = []
    /// Removals that were not applied.
    var skippedRemovals: Set<MarkupID> = []

    /// Markups left wholly or partly as they are. The three reasons never overlap.
    var notApplied: Int { unsupported.count + onRemovedSheets.count + missingStructure.count }
}

extension TakeoffSession {

    /// Every markup of the document for a review exchange: those in the set in their order, then
    /// those set aside with a removed sheet, in the order they stood (T-020).
    var reviewMarkups: [MarkupRecord] {
        orderedMarkups + setAsideMarkups.values.sorted { $0.position < $1.position }.map(\.record)
    }

    /// What this copy holds, read in one actor call.
    func reviewApplyContext() -> ReviewApplyContext {
        ReviewApplyContext(
            local: Dictionary(reviewMarkups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            setAside: Set(setAsideMarkups.keys),
            livePages: Set(pageOrderIDs),
            zones: Set(projectZoneDefinitions.map(\.id)),
            regions: Dictionary(scaleRegionDefinitions.map { ($0.id, $0.scaleID) }, uniquingKeysWith: { first, _ in first }),
            scales: Set(allScales.map(\.id))
        )
    }
}

extension AppCoreEnvironment {

    /// The context for applying `changes`: what this copy holds, and where each arriving record
    /// that names a Scale Region this copy lacks lies among this copy's own regions.
    func reviewApplyContext(for changes: SharedReviewSyncPlanner.LocalChanges) async -> ReviewApplyContext {
        var context = await session.reviewApplyContext()
        // A cutout takes its parent's scale and region in `addCutout`, so only outlines are placed.
        var probes = changes.added.filter { $0.parentMarkupID == nil && context.namesForeignRegion($0) }
        probes += changes.changed.filter { $0.keys.contains(.shape) && $0.record.parentMarkupID == nil && context.namesForeignRegion($0.record) }
            .map(\.record)
        for record in probes where context.livePages.contains(record.pageID) {
            context.regionPlacements[record.id] = await scaleRegionPlacement(of: record)
        }
        return context
    }
}
