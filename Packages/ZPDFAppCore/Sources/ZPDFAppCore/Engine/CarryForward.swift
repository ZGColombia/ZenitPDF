import Foundation
import ZPDFContracts

// NL-DOCS-12 foundation: carrying markups from one revision's sheet to the next, re-measured
// through the engine, each classified, with a per-measurement quantity delta report.
//
// The planner is pure: it turns markups and sheet pairings into `.addMarkup` commands whose
// geometry has been moved through each pairing's alignment. The session re-measures them when the
// batch is applied — values are never copied — and one batch is one undo. The old revision's
// markups stay where they are, on the old sheets.

/// A similarity transform from an old sheet's page space to its new revision's: uniform scale,
/// rotation, then translation. What a two- or three-point alignment produces; a shear or a
/// mirror is not a revision of a drawing and is not representable.
public struct PageAlignment: Sendable, Hashable {
    public var scale: Double
    /// Radians, counter-clockwise.
    public var rotation: Double
    public var dx: Double
    public var dy: Double

    public init(scale: Double = 1, rotation: Double = 0, dx: Double = 0, dy: Double = 0) {
        self.scale = scale
        self.rotation = rotation
        self.dx = dx
        self.dy = dy
    }

    public static let identity = PageAlignment()

    /// Whether points land where they were, to a billionth of a point per unit.
    public var isIdentity: Bool {
        abs(scale - 1) < 1e-9 && abs(rotation) < 1e-12 && abs(dx) < 1e-9 && abs(dy) < 1e-9
    }

    public func apply(_ point: PDFPoint) -> PDFPoint {
        let c = cos(rotation), s = sin(rotation)
        return PDFPoint(
            x: scale * (c * point.x - s * point.y) + dx,
            y: scale * (s * point.x + c * point.y) + dy
        )
    }

    /// Moves every piece of a geometry onto `page`.
    public func apply(_ geometry: MeasurementGeometry, onto page: PageID) -> MeasurementGeometry {
        // A bulge is relative to its chord, so it survives a similarity carry (ADR-0030 §5).
        func ring(_ r: PolygonRing) -> PolygonRing { PolygonRing(points: r.points.map(apply), isClosed: r.isClosed, bulges: r.bulges) }
        return MeasurementGeometry(
            pageID: page,
            points: geometry.points.map(apply),
            segments: geometry.segments.map { SegmentGeometry(start: apply($0.start), end: apply($0.end)) },
            polygons: geometry.polygons.map { PolygonGeometry(outer: ring($0.outer), holes: $0.holes.map(ring)) },
            arcs: geometry.arcs.map {
                ArcGeometry(center: apply($0.center), radius: $0.radius * scale,
                            startAngle: $0.startAngle + rotation, sweepAngle: $0.sweepAngle)
            },
            circles: geometry.circles.map { CircleGeometry(center: apply($0.center), radius: $0.radius * scale) },
            countPoints: geometry.countPoints.map {
                CountPoint(id: $0.id, position: apply($0.position), sequenceNumber: $0.sequenceNumber,
                           groupID: $0.groupID, symbolID: $0.symbolID)
            },
            pointBulges: geometry.pointBulges
        )
    }
}

/// One sheet's pairing to its new revision.
public struct CarryPair: Sendable, Hashable {
    /// The new revision's page.
    public var target: PageID
    public var alignment: PageAlignment
    /// Where the drawing changed between the two revisions, in the **new** page's space
    /// (from Revision Compare's raster or vector diff).
    public var changedRegions: [PDFRect]
    /// Every markup carried through this pair asks for review, wherever it lies (NL-DOCS-12):
    /// the sheets had to be aligned, or could not be compared at all, so no region of the old
    /// sheet is known to be unchanged. A region cannot say this: a measurement beyond the new
    /// sheet's extent — a re-plot onto a smaller paper size — meets no region on it.
    public var reviewsEverything: Bool

    public init(target: PageID, alignment: PageAlignment, changedRegions: [PDFRect] = [], reviewsEverything: Bool = false) {
        self.target = target
        self.alignment = alignment
        self.changedRegions = changedRegions
        self.reviewsEverything = reviewsEverything
    }
}

/// What carrying one markup found.
public enum CarryForwardClass: String, Sendable, Hashable, CaseIterable {
    /// Same place, nothing under it changed.
    case unchanged
    /// The drawing moved (the alignment is not the identity); nothing under the markup changed.
    case moved
    /// Linework under the markup changed: carried, and flagged for a person to check. Never
    /// silently moved and trusted.
    case needsReview
}

/// One carried markup.
public struct CarryForwardItem: Sendable, Hashable {
    public var sourceID: MarkupID
    public var carriedID: MarkupID
    public var target: PageID
    public var classification: CarryForwardClass
}

/// The planned carry: the commands to apply as one batch, and what each one is.
public struct CarryForwardPlan: Sendable {
    public var items: [CarryForwardItem]
    public var commands: [DocumentCommand]
    /// Markups not carried: their sheet has no pairing, or they belong to a parent that is not
    /// carried (a cutout goes with its parent).
    public var skipped: [MarkupID]
    /// Of ``skipped``: measurements in a Scale Region that could not be carried, held as a paste
    /// holds one — never re-measured at the sheet's scale (U-030).
    public var heldForScale: [MarkupID] = []
}

/// The page scales and Scale Regions of paired sheets, copied onto their new sheets (U-030).
///
/// Carry Forward and Combine Open Drawings used to copy the page scale only and clear every
/// carried markup's region, so a measurement drawn in a 1:20 detail on a 1:100 sheet was
/// re-measured at 1:100 — five times its length, twenty-five times its area. Each region now goes
/// with its sheet: its boundary through the pair's alignment, its scale copied onto the new page.
public struct CarriedScales: Sendable {

    /// One carried region: the copy, and the copy of its scale.
    public struct Region: Sendable, Hashable {
        public var id: ScaleRegionID
        public var scaleID: ScaleID
    }

    /// `.changeScale` for every copied scale — each page's own scale before its regions', so it
    /// stays the page's own — then one `.setScaleRegions` with the target's regions and the
    /// carried ones. Apply them before the carried markups, in the same batch.
    public var commands: [DocumentCommand] = []
    /// Source scale → its copy on the new sheet.
    public var scaleIDs: [ScaleID: ScaleID] = [:]
    /// Source region → its copy.
    public var regions: [ScaleRegionID: Region] = [:]
    /// Source regions that could not be carried: their scale is not on their sheet.
    public var regionsLeftBehind: Set<ScaleRegionID> = []

    public init() {}
}

public enum CarryForwardPlanner {

    /// The page scales and Scale Regions of every paired sheet of `source`, as commands that copy
    /// them onto the new sheets (U-030). `existing` is the target document's current region set,
    /// which `.setScaleRegions` replaces whole, so it is kept in front of the carried regions.
    public static func carriedScales(
        from source: TakeoffSession.TakeoffState,
        pairs: [PageID: CarryPair],
        keeping existing: [ScaleRegionDefinition],
        newID: () -> UUID = { UUID() }
    ) -> CarriedScales {
        var carried = CarriedScales()
        var regions: [ScaleRegionDefinition] = []
        let scales = Dictionary(source.scales.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func copy(_ id: ScaleID, onto page: PageID, from sheet: PageID) -> ScaleID? {
            if let copied = carried.scaleIDs[id] { return copied }
            guard let scale = scales[id], scale.pageID == sheet else { return nil }
            let moved = ScaleTransform(
                id: ScaleID(newID()), pageID: page, version: 1,
                matrix: scale.matrix, units: scale.units, source: scale.source, label: scale.label
            )
            carried.commands.append(.changeScale(moved))
            carried.scaleIDs[id] = moved.id
            return moved.id
        }
        for page in source.pages {
            guard let pair = pairs[page.id] else { continue }
            if let own = source.pageScaleIDs[page.id] { _ = copy(own, onto: pair.target, from: page.id) }
            for region in source.scaleRegions where region.pageID == page.id {
                guard let scale = copy(region.scaleID, onto: pair.target, from: page.id) else {
                    carried.regionsLeftBehind.insert(region.id)
                    continue
                }
                let moved = ScaleRegionDefinition(
                    id: ScaleRegionID(newID()), pageID: pair.target, name: region.name,
                    boundary: region.boundary.map(pair.alignment.apply), scaleID: scale,
                    priority: region.priority, locked: region.locked, isVisible: region.isVisible,
                    colorRGBA: region.colorRGBA
                )
                regions.append(moved)
                carried.regions[region.id] = CarriedScales.Region(id: moved.id, scaleID: scale)
            }
        }
        if !regions.isEmpty { carried.commands.append(.setScaleRegions(existing + regions)) }
        return carried
    }

    /// Plans carrying `markups` through `pairs` (old page → pairing). Cutouts are carried after
    /// their parent and re-parented to the carried parent.
    ///
    /// With `scales` — what ``carriedScales(from:pairs:keeping:newID:)`` copies in the same batch
    /// — a measurement in a Scale Region names the carried region and its scale, and one whose
    /// region could not be carried is held (U-030). Without it every carried markup is measured
    /// at its new sheet's own scale.
    public static func plan(
        markups: [MarkupRecord],
        pairs: [PageID: CarryPair],
        now: Date,
        scales: CarriedScales? = nil,
        newID: () -> MarkupID = { MarkupID(UUID()) }
    ) -> CarryForwardPlan {
        var items: [CarryForwardItem] = []
        var commands: [DocumentCommand] = []
        var skipped: [MarkupID] = []
        var held: [MarkupID] = []
        var carried: [MarkupID: MarkupID] = [:]
        // Each carry gets groups of its own, as a paste does (MarkupClipboard): a copy sharing its
        // source's group was selected, moved and deleted with the previous revision's markups
        // whenever both were live (R-056).
        var markupGroups: [MarkupGroupID: MarkupGroupID] = [:]
        var countGroups: [CountGroupID: CountGroupID] = [:]
        func carriedCountGroup(_ group: CountGroupID) -> CountGroupID {
            if let mapped = countGroups[group] { return mapped }
            let mapped = CountGroupID(newID().rawValue)
            countGroups[group] = mapped
            return mapped
        }
        let parentsFirst = markups.filter { $0.parentMarkupID == nil } + markups.filter { $0.parentMarkupID != nil }
        for record in parentsFirst {
            guard let pair = pairs[record.pageID], let geometry = record.geometry else {
                skipped.append(record.id)
                continue
            }
            var copy = record
            copy.id = newID()
            copy.pageID = pair.target
            copy.geometry = pair.alignment.apply(geometry, onto: pair.target)
            copy.measurement = nil
            copy.scaleID = nil
            copy.scaleVersion = nil
            copy.scaleRegionID = nil
            // A cutout takes its carried parent's region and scale (`addCutout`).
            if let region = record.scaleRegionID, record.parentMarkupID == nil, let scales {
                guard let moved = scales.regions[region] else {
                    held.append(record.id)
                    skipped.append(record.id)
                    continue
                }
                copy.scaleRegionID = moved.id
                copy.scaleID = moved.scaleID
            }
            copy.cutoutMarkupIDs = []
            copy.createdAt = now
            copy.modifiedAt = now
            if let group = record.groupID {
                let mapped = markupGroups[group] ?? MarkupGroupID(newID().rawValue)
                markupGroups[group] = mapped
                copy.groupID = mapped
            }
            copy.countGroupID = record.countGroupID.map(carriedCountGroup)
            if var carriedGeometry = copy.geometry, !carriedGeometry.countPoints.isEmpty {
                carriedGeometry.countPoints = carriedGeometry.countPoints.map { point in
                    var point = point
                    point.id = CountPointID(newID().rawValue)
                    point.groupID = point.groupID.map(carriedCountGroup)
                    return point
                }
                copy.geometry = carriedGeometry
            }
            let classification = pair.reviewsEverything
                ? CarryForwardClass.needsReview
                : classify(copy.geometry, alignment: pair.alignment, changed: pair.changedRegions)
            if let parent = record.parentMarkupID {
                guard let carriedParent = carried[parent] else { skipped.append(record.id); continue }
                copy.parentMarkupID = nil
                commands.append(.addCutout(parent: carriedParent, cutout: copy))
            } else {
                commands.append(.addMarkup(copy))
            }
            carried[record.id] = copy.id
            items.append(CarryForwardItem(sourceID: record.id, carriedID: copy.id, target: pair.target, classification: classification))
        }
        var plan = CarryForwardPlan(items: items, commands: commands, skipped: skipped)
        plan.heldForScale = held
        return plan
    }

    /// Classifies a carried geometry: under a change → review; else moved or unchanged.
    static func classify(_ geometry: MeasurementGeometry?, alignment: PageAlignment, changed: [PDFRect]) -> CarryForwardClass {
        if let bounds = geometry.flatMap(bounds(of:)),
           changed.contains(where: { intersects($0.standardized, bounds) }) {
            return .needsReview
        }
        return alignment.isIdentity ? .unchanged : .moved
    }

    /// The measurement's box as drawn — `MeasurementGeometry.bounds`, the one rule (W-089): arc
    /// edges included, a loose arc boxed as the arc rather than its circle. This was a copy that
    /// ignored bulges, so a bent edge reaching into a changed region was carried as unchanged.
    static func bounds(of geometry: MeasurementGeometry) -> PDFRect? {
        geometry.bounds
    }

    static func intersects(_ a: PDFRect, _ b: PDFRect) -> Bool {
        a.origin.x <= b.origin.x + b.size.width && b.origin.x <= a.origin.x + a.size.width
            && a.origin.y <= b.origin.y + b.size.height && b.origin.y <= a.origin.y + a.size.height
    }
}

/// The quantity delta report of a carry: every measurement's old and new headline value, and
/// the total change per unit. `Decimal` throughout; nothing is rounded here.
public struct CarryForwardReport: Sendable, Hashable {

    public struct Row: Sendable, Hashable {
        public var sourceID: MarkupID
        public var carriedID: MarkupID
        public var subject: String
        public var classification: CarryForwardClass
        public var field: MeasurementField?
        public var oldValue: Decimal?
        public var newValue: Decimal?
        /// `new - old`, when both exist.
        public var delta: Decimal? {
            guard let oldValue, let newValue else { return nil }
            return newValue - oldValue
        }
    }

    public var rows: [Row]
    /// Per measurement field: the sum of the deltas of rows that have both values.
    public var totalDelta: [MeasurementField: Decimal]
    /// Measurements not carried because their Scale Region could not go with them (U-030).
    public var heldForScale = 0

    /// Builds the report from the markups before the carry and the session's markups after it.
    public static func make(
        plan: CarryForwardPlan,
        source: [MarkupID: MarkupRecord],
        carried: [MarkupID: MarkupRecord]
    ) -> CarryForwardReport {
        var rows: [Row] = []
        var totals: [MeasurementField: Decimal] = [:]
        for item in plan.items {
            let old = source[item.sourceID]
            let new = carried[item.carriedID]
            let field = (old?.tool ?? new?.tool).map { Domain.Field(shown: Shown.Kind(domain: $0).primaryField) }
            let oldValue = field.flatMap { old?.measurement?[$0]?.value }
            let newValue = field.flatMap { new?.measurement?[$0]?.value }
            let row = Row(
                sourceID: item.sourceID, carriedID: item.carriedID,
                subject: old?.subject ?? new?.subject ?? "",
                classification: item.classification, field: field,
                oldValue: oldValue, newValue: newValue
            )
            if let field, let delta = row.delta { totals[field, default: 0] += delta }
            rows.append(row)
        }
        var report = CarryForwardReport(rows: rows, totalDelta: totals)
        report.heldForScale = plan.heldForScale.count
        return report
    }
}
