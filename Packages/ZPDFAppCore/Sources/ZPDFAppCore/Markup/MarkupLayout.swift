import Foundation
import ZPDFContracts
import ZPDFUIPresentation

/// Align, distribute and same-size for a markup selection (NL-MARKUP-12), and the group and
/// arrange verbs around them (NL-MARKUP-11, NL-MARKUP-13; ADR-0029). Round 2, markup unit.
///
/// All of it is geometry over page-space bounding boxes, turned into ordinary document commands
/// — `.moveMarkup` and `.editVertices` — in **one** batch, so each verb is one undo step with
/// one audited entry per markup, exactly like a bulk edit.
public enum MarkupAlignment: String, Sendable, Hashable, CaseIterable, Identifiable {
    case left, centreHorizontally, right
    case top, middle, bottom
    case distributeHorizontally, distributeVertically
    case sameWidth, sameHeight

    public var id: String { rawValue }

    /// The menu title and the undo name.
    public var displayName: String {
        switch self {
        case .left: NSLocalizedString("Align Left", comment: "Align markups")
        case .centreHorizontally: NSLocalizedString("Align Centres", comment: "Align markups: horizontal centres")
        case .right: NSLocalizedString("Align Right", comment: "Align markups")
        case .top: NSLocalizedString("Align Top", comment: "Align markups")
        case .middle: NSLocalizedString("Align Middles", comment: "Align markups: vertical centres")
        case .bottom: NSLocalizedString("Align Bottom", comment: "Align markups")
        case .distributeHorizontally: NSLocalizedString("Distribute Horizontally", comment: "Distribute markups")
        case .distributeVertically: NSLocalizedString("Distribute Vertically", comment: "Distribute markups")
        case .sameWidth: NSLocalizedString("Make Same Width", comment: "Resize markups")
        case .sameHeight: NSLocalizedString("Make Same Height", comment: "Resize markups")
        }
    }

    /// How many markups the verb needs.
    public var minimumCount: Int {
        switch self {
        case .distributeHorizontally, .distributeVertically: 3
        default: 2
        }
    }
}

/// The pure half: which move or resize each markup gets.
public enum MarkupLayoutPlanner {

    /// One markup's change: a translation, and optionally a scale about its box's lower-left.
    public struct Change: Equatable, Sendable {
        public var id: MarkupID
        public var dx: Double
        public var dy: Double
        public var scaleX: Double = 1
        public var scaleY: Double = 1
    }

    /// The changes that align, distribute or resize `boxes` (page space, y up).
    ///
    /// - Align: every box moves to the selection's extreme (left = the smallest minX, top =
    ///   the largest maxY) or its centre line.
    /// - Distribute: the first and last boxes (by centre) stay; the centres between are spaced
    ///   equally.
    /// - Same width/height: every box takes the **first** box's size (the key object, the one
    ///   selected first), scaled about its own lower-left corner.
    public static func changes(_ alignment: MarkupAlignment, boxes: [(MarkupID, PDFRect)]) -> [Change] {
        guard boxes.count >= alignment.minimumCount else { return [] }
        let minX = boxes.map { $0.1.minX }.min() ?? 0
        let maxX = boxes.map { $0.1.maxX }.max() ?? 0
        let minY = boxes.map { $0.1.minY }.min() ?? 0
        let maxY = boxes.map { $0.1.maxY }.max() ?? 0
        func midX(_ r: PDFRect) -> Double { (r.minX + r.maxX) / 2 }
        func midY(_ r: PDFRect) -> Double { (r.minY + r.maxY) / 2 }
        switch alignment {
        case .left:
            return boxes.map { Change(id: $0.0, dx: minX - $0.1.minX, dy: 0) }
        case .right:
            return boxes.map { Change(id: $0.0, dx: maxX - $0.1.maxX, dy: 0) }
        case .centreHorizontally:
            let centre = (minX + maxX) / 2
            return boxes.map { Change(id: $0.0, dx: centre - midX($0.1), dy: 0) }
        case .top:
            return boxes.map { Change(id: $0.0, dx: 0, dy: maxY - $0.1.maxY) }
        case .bottom:
            return boxes.map { Change(id: $0.0, dx: 0, dy: minY - $0.1.minY) }
        case .middle:
            let centre = (minY + maxY) / 2
            return boxes.map { Change(id: $0.0, dx: 0, dy: centre - midY($0.1)) }
        case .distributeHorizontally:
            let sorted = boxes.sorted { midX($0.1) < midX($1.1) }
            let first = midX(sorted[0].1), last = midX(sorted[sorted.count - 1].1)
            let step = (last - first) / Double(sorted.count - 1)
            return sorted.enumerated().map { index, entry in
                Change(id: entry.0, dx: first + step * Double(index) - midX(entry.1), dy: 0)
            }
        case .distributeVertically:
            let sorted = boxes.sorted { midY($0.1) < midY($1.1) }
            let first = midY(sorted[0].1), last = midY(sorted[sorted.count - 1].1)
            let step = (last - first) / Double(sorted.count - 1)
            return sorted.enumerated().map { index, entry in
                Change(id: entry.0, dx: 0, dy: first + step * Double(index) - midY(entry.1))
            }
        case .sameWidth:
            let width = boxes[0].1.maxX - boxes[0].1.minX
            return boxes.dropFirst().compactMap { entry in
                let own = entry.1.maxX - entry.1.minX
                guard own > 1e-9 else { return nil }
                return Change(id: entry.0, dx: 0, dy: 0, scaleX: width / own)
            }
        case .sameHeight:
            let height = boxes[0].1.maxY - boxes[0].1.minY
            return boxes.dropFirst().compactMap { entry in
                let own = entry.1.maxY - entry.1.minY
                guard own > 1e-9 else { return nil }
                return Change(id: entry.0, dx: 0, dy: 0, scaleY: height / own)
            }
        }
    }

    /// A geometry scaled about `origin` — every stored coordinate, so the drawn shape and the
    /// stored shape stay one object.
    public static func scaled(_ geometry: MeasurementGeometry, about origin: PDFPoint, sx: Double, sy: Double) -> MeasurementGeometry {
        func map(_ p: PDFPoint) -> PDFPoint {
            PDFPoint(x: origin.x + (p.x - origin.x) * sx, y: origin.y + (p.y - origin.y) * sy)
        }
        var out = geometry
        out.points = geometry.points.map(map)
        out.segments = geometry.segments.map { SegmentGeometry(start: map($0.start), end: map($0.end)) }
        out.polygons = geometry.polygons.map { polygon in
            PolygonGeometry(
                outer: PolygonRing(points: polygon.outer.points.map(map), isClosed: polygon.outer.isClosed),
                holes: polygon.holes.map { PolygonRing(points: $0.points.map(map), isClosed: $0.isClosed) }
            )
        }
        out.countPoints = geometry.countPoints.map { point in
            var moved = point
            moved.position = map(point.position)
            return moved
        }
        return out
    }
}

extension AppCoreEnvironment {

    /// Aligns, distributes or resizes the markups as one undo step, and returns a refusal to
    /// show, or `nil` on success. Only markups on one page take part; a locked markup refuses
    /// the whole step, as a bulk edit does; resizing never touches a measurement (its geometry
    /// *is* its quantity).
    public func layOutMarkups(_ ids: [UUID], _ alignment: MarkupAlignment) async -> String? {
        var records: [MarkupRecord] = []
        for id in ids {
            if let record = await session.markup(MarkupID(id)) { records.append(record) }
        }
        if Set(records.map(\.pageID)).count > 1 {
            return NSLocalizedString(
                "Only markups on one sheet can be aligned together.",
                comment: "Align refusal: the selection spans sheets"
            )
        }
        if let locked = records.first(where: \.locked) {
            return String(
                format: NSLocalizedString("Nothing was changed: “%@” is locked.", comment: "Align refusal: a locked markup; the placeholder is its name"),
                locked.label.isEmpty ? Shown.Markup(domain: locked.kind).displayName : locked.label
            )
        }
        let resizes = alignment == .sameWidth || alignment == .sameHeight
        let eligible = records.filter { !resizes || $0.tool == nil }
        let boxes = eligible.compactMap { record in record.geometry?.bounds.map { (record.id, $0.standardized) } }
        guard boxes.count >= alignment.minimumCount else {
            return String(
                format: NSLocalizedString("Select at least %ld markups to use %@.", comment: "Align refusal: too few markups"),
                alignment.minimumCount, alignment.displayName
            )
        }
        var batch: [DocumentCommand] = []
        let byID = Dictionary(uniqueKeysWithValues: eligible.map { ($0.id, $0) })
        for change in MarkupLayoutPlanner.changes(alignment, boxes: boxes) {
            if change.scaleX != 1 || change.scaleY != 1 {
                guard let record = byID[change.id], let geometry = record.geometry, let box = geometry.bounds else { continue }
                let scaled = MarkupLayoutPlanner.scaled(
                    geometry, about: PDFPoint(x: box.standardized.minX, y: box.standardized.minY),
                    sx: change.scaleX, sy: change.scaleY
                )
                if scaled != geometry { batch.append(.editVertices(id: change.id, geometry: scaled)) }
            } else if abs(change.dx) > 1e-12 || abs(change.dy) > 1e-12 {
                batch.append(.moveMarkup(id: change.id, dx: change.dx, dy: change.dy))
            }
        }
        guard !batch.isEmpty else { return nil }
        do {
            _ = try await commands.performBatch(batch, actionName: alignment.displayName)
        } catch {
            return String(describing: error)
        }
        return nil
    }

    /// Puts the markups in one new group (⌘G), one undo step. Needs two or more.
    @discardableResult
    public func groupMarkups(_ ids: [UUID], newID: () -> UUID = { UUID() }) async -> String? {
        guard ids.count >= 2 else {
            return NSLocalizedString("Select two or more markups to group them.", comment: "Group refusal: too few markups")
        }
        do {
            _ = try await commands.perform(.setMarkupGroup(ids: ids.map(MarkupID.init), groupID: MarkupGroupID(newID())))
        } catch {
            return String(describing: error)
        }
        return nil
    }

    /// Takes every member of the selected markups' groups out of their group (⌘⇧G).
    @discardableResult
    public func ungroupMarkups(_ ids: [UUID]) async -> String? {
        let members = expandingGroups(Set(ids))
        guard !members.isEmpty else { return nil }
        do {
            _ = try await commands.perform(.setMarkupGroup(ids: members.map(MarkupID.init).sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }, groupID: nil))
        } catch {
            return String(describing: error)
        }
        return nil
    }

    /// Moves the markups (with their groups) in their page's draw order, one undo step.
    @discardableResult
    public func arrangeMarkups(_ ids: [UUID], _ arrangement: MarkupArrangement) async -> String? {
        let members = expandingGroups(Set(ids))
        guard !members.isEmpty else { return nil }
        do {
            _ = try await commands.perform(.arrangeMarkups(ids: members.map(MarkupID.init).sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }, arrangement: arrangement))
        } catch {
            return String(describing: error)
        }
        return nil
    }

    /// The selection with every member of every group it touches (NL-MARKUP-11): clicking one
    /// member of a group selects the group.
    public func expandingGroups(_ ids: Set<UUID>) -> Set<UUID> {
        let markups = snapshot.markups
        let groups = Set(markups.filter { ids.contains($0.id) }.compactMap(\.groupID))
        guard !groups.isEmpty else { return ids }
        return ids.union(markups.filter { $0.groupID.map(groups.contains) ?? false }.map(\.id))
    }

    /// Whether any selected markup is in a group — Ungroup's validation.
    public func selectionHasGroup(_ ids: Set<UUID>) -> Bool {
        snapshot.markups.contains { ids.contains($0.id) && $0.groupID != nil }
    }
}
