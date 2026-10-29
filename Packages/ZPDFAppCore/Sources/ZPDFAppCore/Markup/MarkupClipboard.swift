import Foundation
import ZPDFContracts
import ZPDFUIPresentation

/// What Copy puts on the pasteboard for markups (NL-MARKUP-05, NL-UX-03): whole
/// records plus where they came from, so Paste can mint new identities, place them, and say
/// out loud when a measurement lands on a sheet with another scale.
///
/// A private pasteboard type, so another program never sees half a takeoff; the picture flavour
/// for mail sits beside it (the app writes it).
public struct MarkupClipboardPayload: Codable, Sendable, Equatable {

    /// The pasteboard type the payload is written under.
    public static let pasteboardType = "com.zenitgroup.zenitpdf.markups"

    /// Bumped when the shape changes; a newer payload than this build reads is ignored.
    public static let currentFormat = 1

    public var format: Int
    /// The document the records were copied from.
    public var sourceDocumentID: UUID
    /// The page they were copied from — a paste onto the same page is offset, not stacked.
    public var sourcePageID: UUID
    /// The records, cutout children before their parents.
    public var records: [MarkupRecord]

    public init(sourceDocumentID: UUID, sourcePageID: UUID, records: [MarkupRecord]) {
        self.format = Self.currentFormat
        self.sourceDocumentID = sourceDocumentID
        self.sourcePageID = sourcePageID
        self.records = records
    }

    /// The payload as pasteboard data.
    public func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(self)
    }

    /// A payload read back from pasteboard data, or `nil` for data this build cannot read.
    public static func decoded(from data: Data) -> MarkupClipboardPayload? {
        guard let payload = try? JSONDecoder().decode(MarkupClipboardPayload.self, from: data),
              payload.format <= currentFormat, !payload.records.isEmpty else { return nil }
        return payload
    }

    /// The page-space bounds of every record, for Paste Here.
    public var bounds: PDFRect? {
        let boxes = records.compactMap { $0.geometry?.bounds }
        guard !boxes.isEmpty else { return nil }
        return PDFRect(
            corner: PDFPoint(x: boxes.map(\.minX).min() ?? 0, y: boxes.map(\.minY).min() ?? 0),
            opposite: PDFPoint(x: boxes.map(\.maxX).max() ?? 0, y: boxes.map(\.maxY).max() ?? 0)
        )
    }
}

/// Where a paste lands.
public enum MarkupPastePlacement: Sendable, Equatable {
    /// Moved by this page-space delta from where it was copied.
    case offset(dx: Double, dy: Double)
    /// Exactly where it was copied: Paste in Place.
    case inPlace
    /// With the copied group's top-left corner on this page point: Paste Here.
    case at(PDFPointValue)
}

/// What a paste did.
public struct MarkupPasteReceipt: Sendable, Equatable {
    /// The new markups, in paste order.
    public var pastedIDs: [UUID] = []
    /// Measurements whose value was recomputed from the target sheet's scale.
    public var recalculatedCount = 0
    /// Measurements left out because where they landed spans two or more Scale Regions, so only
    /// a person can say which scale measures them (S-028). Their cutouts stay out with them.
    public var heldForScaleDecisionCount = 0
    /// The Edit-menu name of the step.
    public var actionName = ""
    /// The engine's refusal, when nothing was pasted.
    public var failureDescription: String?
}

/// The pure half of the markup clipboard: fresh identities, placement, and the scale-sensitive
/// fields cleared so the target sheet's scale is the one a measurement is computed with.
public enum MarkupClipboard {

    /// The distance between successive pastes onto the page they were copied from.
    public static let repeatOffset: Double = 10

    /// The records a paste adds.
    ///
    /// - Every record gets a new `MarkupID`, new timestamps from `now`, the paster as author,
    ///   and is unlocked and visible.
    /// - Links inside the copied set are kept (a parent and its cutouts, a count group's
    ///   points) under their new identities; links to records outside the set are dropped.
    /// - A record moved to another page drops its Scale Region and scale identity, so the
    ///   session's `addMarkup` recomputes it with the target page's scale instead of carrying a
    ///   number from a sheet it is no longer on.
    /// - A record copied by an older build is opened as a saved one (``SavedMarkupRepair``).
    public static func prepared(
        _ payload: MarkupClipboardPayload,
        targetPageID: UUID,
        targetDocumentID: UUID,
        dx: Double,
        dy: Double,
        now: Date,
        author: String,
        newID: () -> UUID
    ) -> [MarkupRecord] {
        var idMap: [MarkupID: MarkupID] = [:]
        for record in payload.records { idMap[record.id] = MarkupID(newID()) }
        var groupMap: [CountGroupID: CountGroupID] = [:]
        // ADR-0029: a pasted group is a new group of its own, not a member of the original.
        var markupGroupMap: [MarkupGroupID: MarkupGroupID] = [:]
        let page = PageID(targetPageID)
        let changesPage = payload.sourcePageID != targetPageID

        return payload.records.map { copied in
            // Opened as a saved record is (X-042): the pasteboard outlives an update, and a
            // four-point Arc Length copied before it would fail the whole paste.
            let source = SavedMarkupRepair.opened(copied)
            var record = source
            record.id = idMap[source.id] ?? MarkupID(newID())
            record.documentID = DocumentID(targetDocumentID)
            record.pageID = page
            record.author = author
            record.locked = false
            record.hidden = false
            record.createdAt = now
            record.modifiedAt = now
            record.parentMarkupID = source.parentMarkupID.flatMap { idMap[$0] }
            record.cutoutMarkupIDs = source.cutoutMarkupIDs.compactMap { idMap[$0] }
            if let group = source.groupID {
                let mapped = markupGroupMap[group] ?? MarkupGroupID(newID())
                markupGroupMap[group] = mapped
                record.groupID = mapped
            }
            if let group = source.countGroupID {
                let mapped = groupMap[group] ?? CountGroupID(newID())
                groupMap[group] = mapped
                record.countGroupID = mapped
            }
            if var geometry = source.geometry {
                geometry = MarkupVertexEditing.translating(geometry, dx: dx, dy: dy)
                geometry.pageID = page
                geometry.countPoints = geometry.countPoints.map { point in
                    var point = point
                    point.id = CountPointID(newID())
                    if let group = point.groupID {
                        let mapped = groupMap[group] ?? CountGroupID(newID())
                        groupMap[group] = mapped
                        point.groupID = mapped
                    }
                    return point
                }
                record.geometry = geometry
            }
            if changesPage {
                record.scaleRegionID = nil
                record.scaleID = nil
                record.scaleVersion = nil
            }
            return record
        }
    }

    /// The copied set for a selection: every selected record, plus the cutouts of a selected
    /// parent, cutouts before parents so a parent's net area is right the moment it is added.
    /// A cutout copied without its parent is left out: a hole with nothing to be a hole in.
    public static func copiedRecords(selected ids: Set<MarkupID>, from all: [MarkupID: MarkupRecord]) -> [MarkupRecord] {
        var chosen: [MarkupRecord] = []
        var seen: Set<MarkupID> = []
        let parents = ids.compactMap { all[$0] }.filter { $0.parentMarkupID == nil }
            .sorted { $0.createdAt == $1.createdAt ? $0.id.rawValue.uuidString < $1.id.rawValue.uuidString : $0.createdAt < $1.createdAt }
        for parent in parents {
            for childID in parent.cutoutMarkupIDs {
                guard let child = all[childID], seen.insert(childID).inserted else { continue }
                chosen.append(child)
            }
        }
        for parent in parents where seen.insert(parent.id).inserted {
            chosen.append(parent)
        }
        return chosen
    }

    /// The delta that puts the copied group's top-left corner on `point`.
    public static func delta(placing payload: MarkupClipboardPayload, topLeftAt point: PDFPointValue) -> (dx: Double, dy: Double) {
        guard let bounds = payload.bounds else { return (0, 0) }
        // Page space is y-up, so the top-left corner is (minX, maxY).
        return (point.x - bounds.minX, point.y - bounds.maxY)
    }
}

extension AppCoreEnvironment {

    /// The clipboard payload for the selected markups, or `nil` when nothing copyable is selected.
    public func markupClipboardPayload(for ids: Set<UUID>) async -> MarkupClipboardPayload? {
        var all: [MarkupID: MarkupRecord] = [:]
        for record in await session.orderedMarkups { all[record.id] = record }
        let records = MarkupClipboard.copiedRecords(selected: Set(ids.map(MarkupID.init)), from: all)
        guard let first = records.last else { return nil }
        return MarkupClipboardPayload(
            sourceDocumentID: snapshot.documentID,
            sourcePageID: first.pageID.rawValue,
            records: records
        )
    }

    /// Pastes a payload onto one or more pages as **one** undo step, selecting what landed on
    /// the page in view.
    ///
    /// A measurement that lands on a sheet whose scale is not the one it was measured with is
    /// recomputed by the engine from the target scale — never carried across as a number — and
    /// the receipt counts it so the caller can say so (CORE_LOOP's "no silent wrongness").
    public func pasteMarkups(
        _ payload: MarkupClipboardPayload,
        onto pageIDs: [UUID],
        placement: MarkupPastePlacement,
        actionName: String? = nil,
        now: Date = Date()
    ) async -> MarkupPasteReceipt {
        let delta: (dx: Double, dy: Double)
        switch placement {
        case let .offset(dx, dy): delta = (dx, dy)
        case .inPlace: delta = (0, 0)
        case let .at(point): delta = MarkupClipboard.delta(placing: payload, topLeftAt: point)
        }
        var records: [MarkupRecord] = []
        for pageID in pageIDs {
            records += MarkupClipboard.prepared(
                payload,
                targetPageID: pageID,
                targetDocumentID: snapshot.documentID,
                dx: delta.dx,
                dy: delta.dy,
                now: now,
                author: AuthorIdentity.current(),
                newID: { UUID() }
            )
        }
        // `prepared` keeps the payload's order per page, so record i is source i mod n.
        let sources = records.indices.map { payload.records[$0 % payload.records.count] }
        let placed = await resolvingScaleRegions(Array(zip(records, sources)))
        let name = actionName ?? Self.pasteActionName(count: placed.pairs.count)
        if placed.held > 0 { reportPasteHeldForScaleDecision(count: placed.held) }
        guard !placed.pairs.isEmpty else {
            return MarkupPasteReceipt(heldForScaleDecisionCount: placed.held, actionName: name)
        }
        do {
            _ = try await commands.performBatch(placed.pairs.map { .addMarkup($0.record) }, actionName: name)
        } catch {
            return MarkupPasteReceipt(
                heldForScaleDecisionCount: placed.held, actionName: name, failureDescription: String(describing: error)
            )
        }
        // Which measurements the engine recomputed under another scale than the one they carried.
        var recalculated = 0
        for (record, source) in placed.pairs where record.tool != nil {
            guard let stored = await session.markup(record.id) else { continue }
            if stored.scaleID != source.scaleID || (stored.measurement == nil) != (source.measurement == nil) {
                recalculated += 1
            }
        }
        await refresh()
        let visiblePage = canvas.viewport.pageID
        let landed = placed.pairs.map(\.record).filter { $0.pageID.rawValue == visiblePage }.map(\.id.rawValue)
        if !landed.isEmpty { canvas.select(markupIDs: Set(landed), additive: false) }
        return MarkupPasteReceipt(
            pastedIDs: placed.pairs.map(\.record.id.rawValue),
            recalculatedCount: recalculated,
            heldForScaleDecisionCount: placed.held,
            actionName: name
        )
    }

    /// Every pasted measurement measured at the scale of **where it lands** (S-028).
    ///
    /// `prepared` cleared a record's Scale Region only when the page changed, so on the same
    /// sheet — an offset paste, Paste Here, Paste in Place, Duplicate — a copy of a 1:20 detail
    /// measurement kept the detail's scale wherever it landed: on the 1:100 plan its lengths
    /// read 5× and its areas 25× too large, with nothing recalculated and nothing said. On
    /// another sheet it took the page default even inside a Scale Region there. Each pasted
    /// measurement now goes through the same ``scaleRegionDecision(for:)`` a drawn one does:
    /// wholly inside one region takes that region's scale, outside every region the page
    /// default; one that spans regions is held back and counted, because only a person can
    /// choose (spec §10.4). A cutout follows its parent's decision, as `addCutout` does.
    func resolvingScaleRegions(
        _ pairs: [(record: MarkupRecord, source: MarkupRecord)]
    ) async -> (pairs: [(record: MarkupRecord, source: MarkupRecord)], held: Int) {
        var decisions: [MarkupID: (region: ScaleRegionID?, scale: ScaleID?)] = [:]
        var heldIDs: Set<MarkupID> = []
        for (record, _) in pairs where record.tool != nil && record.parentMarkupID == nil {
            // The one placement rule every non-drawn add takes (T-025).
            switch await scaleRegionPlacement(of: record) {
            case .pageDefault: decisions[record.id] = (nil, nil)
            case let .region(regionID, scaleID): decisions[record.id] = (regionID, scaleID)
            case .held: heldIDs.insert(record.id)
            }
        }
        var kept: [(record: MarkupRecord, source: MarkupRecord)] = []
        for (record, source) in pairs {
            var record = record
            if record.tool != nil {
                let owner = record.parentMarkupID ?? record.id
                if heldIDs.contains(owner) { continue }
                if let decision = decisions[owner] {
                    record.scaleRegionID = decision.region
                    record.scaleID = decision.scale
                    record.scaleVersion = nil
                }
            }
            kept.append((record, source))
        }
        return (kept, heldIDs.count)
    }

    /// The one identity of the "held for a scale decision" paste warning, so it replaces itself.
    static let pasteHeldForScaleDecisionWarningID = UUID(uuidString: "8B0C6E64-4E2A-4C3E-9F2E-4E9E2B7B1A07")!

    /// Says that pasted measurements spanning Scale Regions were left out, and what to do.
    func reportPasteHeldForScaleDecision(count: Int) {
        document.post(AppWarning(
            id: Self.pasteHeldForScaleDecisionWarningID,
            severity: .warning,
            title: count == 1
                ? NSLocalizedString(
                    "A pasted measurement was not placed.",
                    comment: "Paste warning title when one pasted measurement spans Scale Regions")
                : String(
                    format: NSLocalizedString(
                        "%ld pasted measurements were not placed.",
                        comment: "Paste warning title when several pasted measurements span Scale Regions"),
                    count),
            message: NSLocalizedString(
                "Where it would land spans more than one Scale Region, and only you can choose the scale. Paste it where it lies inside one region, or draw it and choose the scale when asked.",
                comment: "Paste warning detail when a pasted measurement spans Scale Regions"),
            source: NSLocalizedString("Paste", comment: "Warning source: the markup clipboard"),
            isDismissible: true,
            timestamp: Date()
        ))
    }

    /// Cut: the copied payload, and the markups removed as one undo step. A locked markup
    /// refuses the whole cut, as delete does.
    public func cutMarkups(_ ids: Set<UUID>) async -> (payload: MarkupClipboardPayload?, failure: String?) {
        guard let payload = await markupClipboardPayload(for: ids) else { return (nil, nil) }
        // Parents only: removing a parent removes its cutouts with it.
        let removals = payload.records.filter { $0.parentMarkupID == nil }.map { DocumentCommand.removeMarkup($0.id) }
        do {
            _ = try await commands.performBatch(
                removals,
                actionName: NSLocalizedString("Cut", comment: "Undo action name: markups cut to the clipboard")
            )
        } catch {
            return (nil, String(describing: error))
        }
        await refresh()
        return (payload, nil)
    }

    /// "Paste Markup" / "Paste 3 Markups".
    public static func pasteActionName(count: Int) -> String {
        count == 1
            ? NSLocalizedString("Paste Markup", comment: "Undo action name: one markup pasted")
            : String(
                format: NSLocalizedString("Paste %ld Markups", comment: "Undo action name: several markups pasted"),
                count
            )
    }
}
