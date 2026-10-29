import Foundation
import ZPDFContracts
import ZPDFPersistence
import ZPDFUIPresentation

// The row bridge for Scale Regions and Project Zones.
//
// It lives in its own file for one boring, load-bearing reason: `ZPDFContracts` and
// `ZPDFUIPresentation` both declare `LedgerCellValue` and `MeasurementField`, so a file that
// imports both cannot name either without qualification. `TakeoffArchive.swift` needs the
// contract spellings; this file needs the presentation ones. Keeping them apart is cheaper
// than qualifying every use in a 600-line codec.

extension ScaleRegionDefinition {

    /// The `scale_region` row for this region.
    ///
    /// An unencodable boundary would be a region with no polygon, which cannot be created —
    /// the panel refuses fewer than three points and the core validates the ring — so the
    /// encoder's failure falls back to an empty blob rather than failing the whole save. A
    /// region that reads back with no boundary is visible as a defect; a save that refuses is
    /// a lost afternoon.
    func persistenceRow() -> ScaleRegionRecord {
        ScaleRegionRecord(
            id: id.rawValue.uuidString,
            pageId: pageID.rawValue.uuidString,
            name: name,
            polygonBlob: ProjectStructureColor.blob(boundary),
            scaleId: scaleID.rawValue.uuidString,
            priority: priority,
            colorRgba: ProjectStructureColor.packed(colorRGBA),
            visible: isVisible,
            locked: locked
        )
    }

    /// Rebuilds a region from its row, or `nil` when the row's identifiers are unreadable.
    init?(persistenceRow row: ScaleRegionRecord) {
        guard let id = UUID(uuidString: row.id),
              let pageUUID = UUID(uuidString: row.pageId),
              let scaleUUID = UUID(uuidString: row.scaleId)
        else { return nil }
        self.init(
            id: ScaleRegionID(id),
            pageID: PageID(pageUUID),
            name: row.name,
            boundary: ProjectStructureColor.points(row.polygonBlob),
            scaleID: ScaleID(scaleUUID),
            priority: row.priority,
            locked: row.locked,
            isVisible: row.visible,
            colorRGBA: ProjectStructureColor.unpacked(row.colorRgba)
        )
    }

}

extension ProjectZoneDefinition {

    /// The `project_zone` row for this zone.
    ///
    /// - Parameters:
    ///   - sortOrder: the zone's place in the panel's order, written rather than derived so
    ///     reopening keeps the order the person arranged.
    ///   - anchorPageId: the page a boundary-less zone is anchored to, because
    ///     `project_zone.page_id` is `NOT NULL`. The companion row's `spans_pages` flag is
    ///     what stops the reopen from believing the anchor.
    func persistenceRow(sortOrder: Int, anchorPageId: String) -> ProjectZoneRecord {
        ProjectZoneRecord(
            id: id.rawValue.uuidString,
            pageId: pageID?.rawValue.uuidString ?? anchorPageId,
            name: name,
            polygonBlob: ProjectStructureColor.blob(boundary),
            sortOrder: sortOrder,
            colorRgba: ProjectStructureColor.packed(colorRGBA),
            visible: isVisible,
            locked: false
        )
    }

    /// The `project_zone_extra` row: kind, nesting, and whether the page anchor is real.
    func persistenceExtraRow() -> ProjectZoneExtraRecord {
        ProjectZoneExtraRecord(
            zoneId: id.rawValue.uuidString,
            kind: kind.rawValue,
            parentZoneId: parentID?.rawValue.uuidString,
            spansPages: pageID == nil
        )
    }

    /// Rebuilds a zone from its row and companion.
    init?(persistenceRow row: ProjectZoneRecord, extra: ProjectZoneExtraRecord?) {
        guard let id = UUID(uuidString: row.id) else { return nil }
        let spansPages = extra?.spansPages ?? false
        self.init(
            id: ZoneID(id),
            name: row.name,
            // An unrecognised kind from a newer build degrades to the neutral grouping
            // rather than failing the open: the zone's identity, name and members are all
            // still true, and only the icon beside it is a guess.
            kind: extra.flatMap { ProjectZoneKind(rawValue: $0.kind) } ?? .quantityGroup,
            parentID: extra?.parentZoneId.flatMap(UUID.init(uuidString:)).map(ZoneID.init),
            pageID: spansPages ? nil : UUID(uuidString: row.pageId).map(PageID.init),
            boundary: spansPages ? [] : ProjectStructureColor.points(row.polygonBlob),
            sortOrder: row.sortOrder,
            isVisible: row.visible,
            colorRGBA: ProjectStructureColor.unpacked(row.colorRgba)
        )
    }
}

/// The two conversions both structure rows need: the packed colour column and the polygon blob.
enum ProjectStructureColor {

    /// `ColorRGBA` (unit components) to the schema's `0xRRGGBBAA` integer.
    static func packed(_ color: ColorRGBA) -> PackedRGBA {
        PackedRGBA(
            unitRed: color.red,
            unitGreen: color.green,
            unitBlue: color.blue,
            unitAlpha: color.alpha
        )
    }

    /// The schema's packed colour back to unit components.
    static func unpacked(_ color: PackedRGBA) -> ColorRGBA {
        let components = color.unitComponents
        return ColorRGBA(
            red: components.red,
            green: components.green,
            blue: components.blue,
            alpha: components.alpha
        )
    }

    /// A closed boundary as the schema's `polygon_blob`. An empty boundary encodes as empty
    /// data, which is how a zone with no drawn area is stored.
    static func blob(_ points: [PDFPoint]) -> Data {
        guard !points.isEmpty else { return Data() }
        let ring = points.map { GeometryPoint(x: $0.x, y: $0.y) }
        return (try? GeometryBlob(kind: .polygon, points: ring).encode()) ?? Data()
    }

    /// The `polygon_blob` back to page-space points. Unreadable data reads as no boundary
    /// rather than as a throw: one damaged region should not stop a project opening.
    static func points(_ data: Data) -> [PDFPoint] {
        guard !data.isEmpty, let blob = try? GeometryBlob.decode(data) else { return [] }
        return (blob.rings.first ?? []).map { PDFPoint(x: $0.x, y: $0.y) }
    }
}
