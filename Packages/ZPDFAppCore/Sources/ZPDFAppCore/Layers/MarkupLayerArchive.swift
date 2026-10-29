import Foundation
import GRDB
import ZPDFContracts
import ZPDFPersistence
import ZPDFUIPresentation

/// The project-level half of the takeoff archive that ADR-0032 adds: the markup layer
/// list, the active layer and the display units, in schema v18's `markup_layer` and
/// `project_setting`. Written inside ``TakeoffArchive/write(_:into:documentId:)``'s transaction
/// whenever the state carries them, read beside the custom columns.
enum MarkupLayerArchive {

    /// `project_setting` keys.
    static let displayUnitsKey = "display_units"
    static let activeLayerKey = "active_markup_layer"

    /// Everything this archive writes, built before the transaction so a bad value fails the
    /// save before anything is touched.
    struct Rows: Sendable {
        let layers: [MarkupLayerRecord]
        let activeLayerJSON: String?
        let displayUnitsJSON: String?
    }

    /// The rows for `state`, or `nil` when the state does not carry the project-level list.
    static func rows(of state: TakeoffSession.TakeoffState, project projectId: String) throws -> Rows? {
        guard let layers = state.markupLayers else { return nil }
        let set = MarkupLayerSet(layers)
        let records = set.layers.map { layer in
            MarkupLayerRecord(
                projectId: projectId,
                id: layer.id.rawValue.uuidString,
                name: layer.name,
                sortOrder: layer.order,
                visible: layer.visible,
                locked: layer.locked,
                printable: layer.printable
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let active = state.activeMarkupLayerID.map { set.resolve($0) }
        let activeJSON = try active.map { String(decoding: try encoder.encode($0.rawValue.uuidString), as: UTF8.self) }
        let unitsJSON = try state.displayUnits.map {
            String(decoding: try encoder.encode(StoredDisplayUnits($0)), as: UTF8.self)
        }
        return Rows(layers: records, activeLayerJSON: activeJSON, displayUnitsJSON: unitsJSON)
    }

    /// Writes `rows` inside the caller's transaction. A database without the v18 tables (the
    /// migrator always adds them; this is defence) is left alone.
    static func write(_ rows: Rows?, project projectId: String, in db: Database) throws {
        guard let rows, try db.tableExists(MarkupLayerRecord.databaseTableName) else { return }
        try MarkupLayerStore.replace(rows.layers, project: projectId, in: db)
        try MarkupLayerStore.setSetting(activeLayerKey, json: rows.activeLayerJSON, project: projectId, in: db)
        try MarkupLayerStore.setSetting(displayUnitsKey, json: rows.displayUnitsJSON, project: projectId, in: db)
    }

    /// What a package holds: the layers (empty before v18), the active layer and the units.
    struct Stored: Sendable {
        var layers: [MarkupLayer] = []
        var activeLayerID: LayerID?
        var displayUnits: DisplayUnitSelection?
    }

    /// Reads the project-level layer facts. A row this build cannot read — a malformed id, an
    /// unknown unit a newer build wrote — is skipped, never a reason to refuse the project.
    static func read(project projectId: String, in db: Database) throws -> Stored {
        var stored = Stored()
        stored.layers = try MarkupLayerStore.layers(project: projectId, in: db).compactMap { row in
            guard let uuid = UUID(uuidString: row.id) else { return nil }
            return MarkupLayer(
                id: LayerID(uuid), name: row.name, order: row.sortOrder,
                visible: row.visible, locked: row.locked, printable: row.printable
            )
        }
        let decoder = JSONDecoder()
        if let json = try MarkupLayerStore.setting(activeLayerKey, project: projectId, in: db),
           let text = try? decoder.decode(String.self, from: Data(json.utf8)),
           let uuid = UUID(uuidString: text) {
            stored.activeLayerID = LayerID(uuid)
        }
        if let json = try MarkupLayerStore.setting(displayUnitsKey, project: projectId, in: db),
           let units = try? decoder.decode(StoredDisplayUnits.self, from: Data(json.utf8)) {
            stored.displayUnits = units.selection
        }
        return stored
    }
}

/// The takeoff's display units as the project file stores them (ADR-0032): every choice a person
/// can make in the units menu, by the enums' stored spellings.
struct StoredDisplayUnits: Codable, Hashable, Sendable {
    var length: ZPDFUIPresentation.LengthUnit
    var area: ZPDFUIPresentation.AreaUnit
    var volume: ZPDFUIPresentation.VolumeUnit
    var slope: SlopeDisplayMode
    var imperialPrecision: ImperialPrecision
    var metricDecimalPlaces: Int
    var imperialLengthStyle: ImperialLengthStyle?

    init(_ selection: DisplayUnitSelection) {
        length = selection.length
        area = selection.area
        volume = selection.volume
        slope = selection.slope
        imperialPrecision = selection.imperialPrecision
        metricDecimalPlaces = selection.metricDecimalPlaces
        imperialLengthStyle = selection.imperialLengthStyle
    }

    var selection: DisplayUnitSelection {
        var selection = DisplayUnitSelection(
            length: length, area: area, volume: volume, slope: slope,
            imperialPrecision: imperialPrecision, metricDecimalPlaces: metricDecimalPlaces
        )
        selection.imperialLengthStyle = imperialLengthStyle ?? .feetInches
        return selection
    }
}

extension TakeoffSession.TakeoffState {

    /// This state carrying the project-level layer list, active layer and display units.
    func layering(_ layers: [MarkupLayer], active: LayerID, units: DisplayUnitSelection) -> Self {
        var state = self
        state.markupLayers = layers
        state.activeMarkupLayerID = active
        state.displayUnits = units
        return state
    }
}
