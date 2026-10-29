import Foundation
import ZPDFContracts
import ZPDFMeasurementEngine
import ZPDFUIPresentation

/// Why an area could not be split (NL-MEASURE-06), as a sentence the host can show.
public enum AreaSplitRefusal: Error, Equatable, Sendable {
    /// Only committed plan areas split: an area, rectangle, volume or sloped area.
    case notAnArea
    /// A locked markup is not edited.
    case locked
    /// The area has cutouts; splitting them along is not built yet, and dropping them would
    /// give their area back.
    case hasCutouts
    /// The line never divided the area.
    case lineMissesArea
    /// One part would be a sliver.
    case sliver
    /// The parts did not add up to the original within the engine's invariant tolerance; a
    /// split that could double count is never stored.
    case partsDoNotSum
    /// A merge needs two or more areas on one page with the same subject.
    case notMergeable
    /// The areas do not touch or overlap, so their union is two shapes, not one.
    case areasApart
    /// The edit involves a curved edge in a way the exact method cannot resolve (a line that
    /// only touches a curve, edges that meet along one tangent, a ring that crosses itself).
    /// Nothing is approximated: the edit is refused (ADR-0030 §5.6).
    case curvedEdgeNotExact
    /// The areas are measured differently — another tool, scale, Scale Region, parameters or
    /// Repeat × — so the union measured the first one's way would change the total by more than
    /// the overlap (T-023); or filed or valued differently — another Project Zone, Unit Cost,
    /// assembly or ledger value — so the union's row would carry only the first one's (V-030).
    case measuredDifferently(AreaMergeDifference)

    public var message: String {
        switch self {
        case .notAnArea:
            return NSLocalizedString("Only a measured area can be split.", comment: "Split refusal")
        case .locked:
            return NSLocalizedString("This area is locked. Unlock it to split it.", comment: "Split refusal")
        case .hasCutouts:
            return NSLocalizedString("This area has cutouts, and splitting cutouts along with it is not available yet.", comment: "Split refusal")
        case .curvedEdgeNotExact:
            return NSLocalizedString("A curved edge meets the line or another edge where the result cannot be made exact, so nothing was changed.", comment: "Split or merge refusal: an arc case the exact method cannot resolve")
        case .lineMissesArea:
            return NSLocalizedString("The line does not cross the area, so there is nothing to split.", comment: "Split refusal")
        case .sliver:
            return NSLocalizedString("The line is so close to an edge that one part would be a sliver.", comment: "Split refusal")
        case .partsDoNotSum:
            return NSLocalizedString("The parts did not add up to the area, so nothing was changed.", comment: "Split refusal")
        case .notMergeable:
            return NSLocalizedString("Select two or more unlocked areas on one page with the same subject and no cutouts.", comment: "Merge refusal")
        case .areasApart:
            return NSLocalizedString("These areas do not touch, so merging them would make one row out of two shapes.", comment: "Merge refusal")
        case .measuredDifferently(let difference):
            return difference.message
        }
    }
}

/// What differs between areas a merge refuses to fold together (T-023). The merged outline is
/// measured the first area's way, so each of these would change the total beyond the overlap.
public enum AreaMergeDifference: Equatable, Sendable {
    case tool
    case scale
    case scaleRegion
    case parameters
    case repeatCount
    /// The areas are filed in different Project Zones: the union would keep the first one's, so
    /// the others' quantity would leave its zone's subtotal and join the first's (V-030).
    case zone
    /// The areas hold different values in one ledger column — Unit Cost, an assembly, any user
    /// column. The union keeps the first area's values and deletes the others', so a priced total,
    /// an assembly's derived rows or a grouping would change (V-030). Carries the column's title.
    case values(column: String)

    public var message: String {
        switch self {
        case .tool:
            return NSLocalizedString("These areas are measured with different tools, so merging them would change what is measured.", comment: "Merge refusal: the areas use different measurement tools")
        case .scale:
            return NSLocalizedString("These areas are measured at different scales, so merging them would change the total.", comment: "Merge refusal: the areas are measured at different scales")
        case .scaleRegion:
            return NSLocalizedString("These areas lie in different Scale Regions, so merging them would change the total.", comment: "Merge refusal: the areas belong to different Scale Regions")
        case .parameters:
            return NSLocalizedString("These areas have different parameters, such as depth or height, so merging them would change the total.", comment: "Merge refusal: the areas have different measurement parameters")
        case .repeatCount:
            return NSLocalizedString("These areas have different Repeat × counts, so merging them would change the total.", comment: "Merge refusal: the areas have different repeat multipliers")
        case .zone:
            return NSLocalizedString("These areas are filed in different Project Zones, so merging them would move quantity from one zone into another.", comment: "Merge refusal: the areas are filed in different Project Zones")
        case .values(let column):
            return String(format: NSLocalizedString(
                "These areas have different values in the “%@” column, so merging them would keep only the first area's value.",
                comment: "Merge refusal: the areas differ in one ledger column; the placeholder is the column's title"
            ), column)
        }
    }
}

extension TakeoffSession {

    static let splittableTools: Set<MeasurementTool> = [.area, .rectangleArea, .volume, .trueSlopedArea]

    /// The commands that split an area along a drawn line (NL-MEASURE-06): remove
    /// the parent and add one area per part, with the parent's subject, parameters, style and
    /// assignments. Run as one batch, so one ⌘Z brings the parent back and removes the parts.
    ///
    /// The engine's invariant is checked before anything is returned: the parts' net area must
    /// equal the parent's within `PolygonSplitter.invariantPDFTolerance`, so a split never counts
    /// the same area twice.
    public func splitCommands(markup id: MarkupID, along cut: [PDFPoint]) throws -> [DocumentCommand] {
        guard let parent = markup(id) else { throw DocumentCommandError.unknownMarkup(id) }
        guard let tool = parent.tool, Self.splittableTools.contains(tool), parent.parentMarkupID == nil,
              let polygon = parent.geometry?.polygons.first else { throw AreaSplitRefusal.notAnArea }
        guard !parent.locked else { throw AreaSplitRefusal.locked }
        guard parent.cutoutMarkupIDs.isEmpty else { throw AreaSplitRefusal.hasCutouts }
        let parts: [PolygonGeometry]
        if polygon.outer.hasArcs {
            // Arc segments (ADR-0030 §5.6): split on the arcs themselves, never on chords — each
            // piece of an arc keeps its circle, and the parts' exact areas sum to the parent's.
            parts = try Self.exactArcSplit(polygon, along: cut)
        } else {
            let splitter = PolygonSplitter()
            let result = try splitter.split(polygon, along: cut)
            switch result {
            case .parts(let found): parts = found
            case .lineMissesPolygon: throw AreaSplitRefusal.lineMissesArea
            case .degenerate: throw AreaSplitRefusal.sliver
            }
            let difference = try splitter.areaCheck(original: polygon, parts: parts)
            let tolerance = try splitter.invariantPDFTolerance(for: polygon)
            guard NumericPolicy.double(from: difference).magnitude <= tolerance else { throw AreaSplitRefusal.partsDoNotSum }
        }

        var commands: [DocumentCommand] = [.removeMarkup(parent.id)]
        let stamp = Date()
        for (index, part) in parts.enumerated() {
            var record = parent
            record.id = MarkupID(UUID())
            record.label = parent.label.isEmpty ? parent.label : "\(parent.label).\(index + 1)"
            record.geometry = MeasurementGeometry(pageID: parent.pageID, polygons: [part])
            record.measurement = nil
            record.createdAt = stamp
            record.modifiedAt = stamp
            commands.append(.addMarkup(record))
        }
        return commands
    }

    /// Merges areas into the first of them (NL-MEASURE-06): the first keeps its identity and row
    /// and takes the union (overlaps counted once); the others are removed. One batch, one ⌘Z.
    /// Refused unless every area is an unlocked plan area on one page with the same subject and no
    /// cutouts, and the union is one shape. The plan carries its commands and how many enclosed
    /// gaps it keeps as cutouts, so the host can say so (K-10). Before K-10 a merge that closed around a gap was refused: a hole
    /// in the stored outline is erased by the next recompute (holes are rebuilt from cutout
    /// markups), and the gap would have counted as area. Now each gap becomes a cutout markup of
    /// the merged area — its ring exactly the union's hole, arcs included — so the merged net area
    /// is the union's area exactly: 1000 + 112.5π, not 1200 + 112.5π, in the review's probe.
    public func mergePlan(markups ids: [MarkupID]) throws -> AreaMergePlan {
        let records = ids.compactMap { markup($0) }
        guard records.count >= 2, records.count == ids.count,
              let first = records.first,
              records.allSatisfy({ record in
                  guard let tool = record.tool, Self.splittableTools.contains(tool) else { return false }
                  return record.pageID == first.pageID && record.subject == first.subject
                      && !record.locked && record.parentMarkupID == nil && record.cutoutMarkupIDs.isEmpty
                      && record.geometry?.polygons.count == 1
              })
        else { throw AreaSplitRefusal.notMergeable }
        // The union is re-measured as the first area: its tool, scale, region, parameters and
        // Repeat ×. An area measured any other way would be silently re-measured — a 1:20 detail
        // area at the plan's 1:100, or 10a + b turned into 10(a + b) (T-023).
        // Filing and ledger values too: the union keeps the first area's zone and custom values and
        // deletes the others', so a Unit Cost, an assembly or a zone that differs would move money
        // and quantity silently (V-030).
        let titles = Self.columnTitles(ledgerColumns.columns + heldCustomColumns.map(\.definition))
        if let difference = Self.mergeDifference(records, columnTitles: titles) {
            throw AreaSplitRefusal.measuredDifferently(difference)
        }
        let polygons = records.compactMap { $0.geometry?.polygons.first }
        let merged: PolygonGeometry
        if polygons.contains(where: \.outer.hasArcs) {
            // Arc segments (ADR-0030 §5.6): the union is taken on the arcs, so every arc on the
            // merged boundary — and on every gap it encloses — is the arc that was drawn (or a
            // piece of it), never its chords.
            do {
                let union = try ArcRingBoolean.union(polygons)
                guard union.count == 1, let only = union.first else { throw AreaSplitRefusal.areasApart }
                merged = only
            } catch ArcEditRefusal.holes {
                // A gap closed before the last area joined: the fold that keeps gaps apart.
                merged = try Self.exactArcUnionKeepingGaps(polygons)
            } catch let refusal as AreaSplitRefusal {
                throw refusal
            } catch {
                throw AreaSplitRefusal.curvedEdgeNotExact
            }
        } else {
            let union = try AreaMerge.union(polygons)
            guard union.count == 1, let only = union.first else { throw AreaSplitRefusal.areasApart }
            merged = only
        }
        // The merged outline is stored without holes: the recompute rebuilds a parent's holes
        // from its cutout markups, so each gap goes in as one (ADR-0034 §2).
        var commands: [DocumentCommand] = [
            .editVertices(id: first.id, geometry: MeasurementGeometry(
                pageID: first.pageID, polygons: [PolygonGeometry(outer: merged.outer)]
            ))
        ]
        // L-70: merging the parts a split made gives the parent's label back — "Kitchen floor",
        // not "Kitchen floor.1" — in the same step, so one ⌘Z also restores the part's label.
        if let restored = Self.mergedLabel(records.map(\.label)), restored != first.label {
            commands.append(.editLabel(id: first.id, label: restored))
        }
        commands.append(contentsOf: records.dropFirst().map { DocumentCommand.removeMarkup($0.id) })
        let stamp = Date()
        for gap in merged.holes {
            commands.append(.addCutout(parent: first.id, cutout: Self.gapCutout(gap, of: first, at: stamp)))
        }
        return AreaMergePlan(commands: commands, keptGaps: merged.holes.count)
    }

    /// The label a merge gives back, or `nil` to keep the first area's (L-70).
    ///
    /// A split labels its parts `<label>.1`, `<label>.2`, … (``splitCommands(markup:along:)``).
    /// When every merged area is one of those parts — or the original itself — the union is the
    /// original again and gets its label back. Areas labelled independently keep the first one's.
    static func mergedLabel(_ labels: [String]) -> String? {
        var base: String?
        var sawPart = false
        for label in labels {
            let stem: String
            if let dot = label.lastIndex(of: "."),
               !label[label.index(after: dot)...].isEmpty,
               label[label.index(after: dot)...].allSatisfy({ ("0"..."9").contains($0) }),
               dot > label.startIndex {
                stem = String(label[..<dot])
                sawPart = true
            } else {
                stem = label
            }
            guard !stem.isEmpty, base == nil || base == stem else { return nil }
            base = stem
        }
        return sawPart ? base : nil
    }

    /// The first way in which `records` are not measured alike, or `nil` when they are.
    ///
    /// An Area and a Rectangle Area measure the same plan area, so they merge (ArcReview finding
    /// 1); a Volume or a True Sloped Area measures something else and merges only with its own
    /// kind. Display units are how a row reads, not what it measures, so they never refuse.
    static func mergeDifference(
        _ records: [MarkupRecord],
        columnTitles: [ColumnID: (order: Int, title: String)] = [:]
    ) -> AreaMergeDifference? {
        guard let first = records.first else { return nil }
        let planAreaTools: Set<MeasurementTool> = [.area, .rectangleArea]
        func measuredParameters(_ record: MarkupRecord) -> MeasurementParameters {
            var parameters = record.parameters ?? .default
            parameters.display = MeasurementParameters.default.display
            parameters.displayOverride = nil
            return parameters
        }
        for record in records.dropFirst() {
            let sameTool = record.tool == first.tool
                || (record.tool.map(planAreaTools.contains) ?? false) && (first.tool.map(planAreaTools.contains) ?? false)
            if !sameTool { return .tool }
            if record.scaleRegionID != first.scaleRegionID { return .scaleRegion }
            if record.scaleID != first.scaleID { return .scale }
            if measuredParameters(record) != measuredParameters(first) { return .parameters }
            if RepetitionColumn.count(of: record) != RepetitionColumn.count(of: first) { return .repeatCount }
            if record.zoneID != first.zoneID { return .zone }
            if let column = differingValueColumn(record, first, columnTitles: columnTitles) {
                return .values(column: column)
            }
        }
        return nil
    }

    /// The title of the first column (in ledger order) whose value differs between `a` and `b`,
    /// or `nil` when every value the ledger keeps agrees (V-030).
    ///
    /// An absent value and `.empty` are the same cell. `Repeat ×` is compared by its count above,
    /// so "1" and no value agree. A formula column's cached result is derived from the row and is
    /// recomputed after the merge, so it never refuses. A value in a column the session neither
    /// installs nor holds is shown nowhere and totals nothing, so it does not refuse either.
    static func differingValueColumn(
        _ a: MarkupRecord,
        _ b: MarkupRecord,
        columnTitles: [ColumnID: (order: Int, title: String)]
    ) -> String? {
        func stored(_ record: MarkupRecord, _ column: ColumnID) -> ZPDFContracts.LedgerCellValue? {
            switch record.customValues[column] {
            case nil, .empty?, .formulaResult?: nil
            case let value?: value
            }
        }
        let differing = Set(a.customValues.keys).union(b.customValues.keys)
            .filter { $0 != RepetitionColumn.columnID && columnTitles[$0] != nil && stored(a, $0) != stored(b, $0) }
        return differing
            .compactMap { columnTitles[$0] }
            .min { ($0.order, $0.title) < ($1.order, $1.title) }?
            .title
    }

    /// Each ledger column's position and the title a person reads for it: a built-in's shown
    /// title (Unit Cost), a runtime column's own. Formula columns are left out — their values are
    /// derived from the row, never typed.
    static func columnTitles(_ definitions: [LedgerColumnDefinition]) -> [ColumnID: (order: Int, title: String)] {
        var titles: [ColumnID: (order: Int, title: String)] = [:]
        for (order, definition) in definitions.enumerated() where definition.kind != .formula && titles[definition.id] == nil {
            titles[definition.id] = (order, LedgerBridge.title(of: definition))
        }
        return titles
    }

    /// The cutout that keeps one enclosed gap open (K-10): a polygon cutout whose ring is the
    /// gap's, on the merged area's page, drawn like it, and saying why it exists.
    static func gapCutout(_ gap: PolygonRing, of parent: MarkupRecord, at stamp: Date) -> MarkupRecord {
        MarkupRecord(
            id: MarkupID(UUID()),
            documentID: parent.documentID,
            pageID: parent.pageID,
            kind: .polygon,
            tool: .polygonCutout,
            subject: Shown.Kind.polygonCutout.displayName,
            comment: AreaMergePlan.gapNote,
            author: parent.author,
            style: parent.style,
            geometry: MeasurementGeometry(pageID: parent.pageID, polygons: [PolygonGeometry(outer: gap)]),
            createdAt: stamp,
            modifiedAt: stamp
        )
    }

    /// The exact union of plain areas with arc edges, with every gap it encloses as a hole
    /// (K-10). `ArcRingBoolean.union` refuses a gap that closes before the last area joins; this
    /// fold keeps the filled outline and the gaps apart instead: each area that joins is unioned
    /// with the filled outline, whose new holes are new gaps, and is taken out of the gaps it
    /// covers (an exact difference on the arcs). An area that sits wholly inside a gap would make
    /// the merge two shapes, and is refused as such.
    static func exactArcUnionKeepingGaps(_ polygons: [PolygonGeometry]) throws -> PolygonGeometry {
        var rings: [ArcRing] = []
        for polygon in polygons {
            guard let ring = ArcRing(polygon.outer) else { throw AreaSplitRefusal.curvedEdgeNotExact }
            rings.append(ring.counterClockwise)
        }
        guard !rings.isEmpty else { throw AreaSplitRefusal.notMergeable }
        var outline = rings.removeFirst()
        var gaps: [ArcRing] = []
        do {
            while !rings.isEmpty {
                var joined = false
                for index in rings.indices {
                    let result = try ArcRingBoolean.apply(.union, outline, rings[index])
                    let outers = result.filter { $0.signedArea > 0 }
                    guard outers.count == 1, let outer = outers.first else { continue }
                    var remaining: [ArcRing] = []
                    for gap in gaps {
                        let pieces = try ArcRingBoolean.apply(.difference, gap, rings[index])
                        // A piece turning clockwise is an island of area inside a gap.
                        guard pieces.allSatisfy({ $0.signedArea > 0 }) else { throw AreaSplitRefusal.areasApart }
                        remaining.append(contentsOf: pieces)
                    }
                    gaps = remaining + result.filter { $0.signedArea < 0 }.map(\.counterClockwise)
                    outline = outer
                    rings.remove(at: index)
                    joined = true
                    break
                }
                guard joined else { throw AreaSplitRefusal.areasApart }
            }
        } catch let refusal as AreaSplitRefusal {
            throw refusal
        } catch {
            throw AreaSplitRefusal.curvedEdgeNotExact
        }
        return PolygonGeometry(outer: outline.polygonRing, holes: gaps.map(\.polygonRing))
    }
}

/// A merge of areas as it will be applied (K-10): one batch, and how many enclosed gaps it keeps
/// open as cutouts of the merged area.
public struct AreaMergePlan: Sendable {
    public var commands: [DocumentCommand]
    public var keptGaps: Int

    /// The note a gap cutout carries, and the host's status line after a merge that kept gaps.
    public static var gapNote: String {
        NSLocalizedString(
            "Kept open when the areas were merged: the areas close around this gap, so it is a cutout and does not count as area.",
            comment: "Note on a cutout Merge Areas created for a gap the merged areas enclose"
        )
    }

    /// The status line after a merge, or `nil` when it kept no gap.
    public var statusNote: String? {
        switch keptGaps {
        case 0: return nil
        case 1:
            return NSLocalizedString(
                "The areas close around a gap, so it was kept open as a cutout of the merged area.",
                comment: "Status note after Merge Areas kept one enclosed gap as a cutout"
            )
        default:
            return String(
                format: NSLocalizedString(
                    "The areas close around %d gaps, so each was kept open as a cutout of the merged area.",
                    comment: "Status note after Merge Areas kept several enclosed gaps as cutouts; the count"
                ),
                keptGaps
            )
        }
    }
}

extension TakeoffSession {

    /// The exact split of an area with arc edges (ADR-0030 §5.6), or the refusal to say.
    ///
    /// The engine checks that the parts sum to the parent before it returns them; the check is
    /// repeated here on the stored form, so what reaches the document is what was checked.
    static func exactArcSplit(_ polygon: PolygonGeometry, along cut: [PDFPoint]) throws -> [PolygonGeometry] {
        let result: SplitResult
        do {
            result = try ArcAreaSplitter.split(polygon, along: cut)
        } catch {
            throw AreaSplitRefusal.curvedEdgeNotExact
        }
        let parts: [PolygonGeometry]
        switch result {
        case .parts(let found): parts = found
        case .lineMissesPolygon: throw AreaSplitRefusal.lineMissesArea
        case .degenerate: throw AreaSplitRefusal.sliver
        }
        let whole = Swift.abs(polygon.outer.exactSignedArea)
        let sum = parts.reduce(0.0) { $0 + Swift.abs($1.outer.exactSignedArea) }
        guard Swift.abs(sum - whole) <= Swift.max(1e-12 * whole, 1e-12) * 16 else { throw AreaSplitRefusal.partsDoNotSum }
        return parts
    }
}
