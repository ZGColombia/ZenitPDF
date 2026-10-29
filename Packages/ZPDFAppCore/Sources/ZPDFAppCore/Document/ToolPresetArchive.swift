import Foundation
import GRDB
import ZPDFPersistence
import ZPDFUIPresentation

/// The seam between the Tool Library and spec 8.2's `tool_preset` table.
///
/// `tool_preset` has existed since the first schema and had neither a reader nor a writer
/// anywhere in the repository until this file. The shape follows
/// ``TakeoffArchive``: one reader, one writer, both total over what the Tool Library can
/// produce, and the write lands in a single transaction so a kill mid-save leaves the old
/// library or the new one and never half of either.
///
/// **What the fixed columns carry, and what they do not.** `id`, `name`, `category`,
/// `markup_type` and `sort_order` are the row's own columns. `style_blob` is the preset's ink,
/// JSON-encoded with sorted keys — the same discipline `TakeoffStyleCodec` keeps for a markup's
/// style, and for the same reason: a blob a foreign reader cannot parse is a blob nobody can
/// migrate. Everything the schema has no column for — the panel, the measurement tool, the
/// takeoff defaults, the Count symbol, the star, the shortcut — is in `defaults_json`, versioned
/// by the preset's own `schemaVersion`.
///
/// **Where a preset lives.** `tool_preset.project_id` is documented as `nil` for a preset that
/// belongs to the application rather than to this project, and that is honoured: only
/// ``ToolLibraryPanel/projectTools`` presets carry the project id.
///
/// **The second store now exists.** When this file was written there was nowhere else to put a
/// preset, so `My Tools` was written into whichever project package was open and the column
/// recorded a claim rather than a location. ``ToolPresetContainerStore`` is the other place, and
/// ``ToolPresetLibraryStore`` is the one caller that splits a library between the two under
/// ``ToolPresetScopeRule``. This archive is now the **project** half only: its callers pass
/// project-scope presets, and container-scope rows still found in an older package are handled
/// by the loader's one-time migration rather than here.
public enum ToolPresetArchive {

    // MARK: - Read

    /// Reads every preset stored in the package, in `sort_order`.
    ///
    /// A row whose `defaults_json` cannot be decoded is skipped rather than throwing: one
    /// unreadable preset must not stop a project from opening, and a Tool Library that is missing
    /// a tool is recoverable in a way that a document that refuses to open is not. It stays in
    /// the package: ``write(_:into:)`` carries such rows through every save.
    public static func read(from package: ProjectPackage) async throws -> [ToolPresetSummary] {
        let rows = try await package.read { db in
            try ToolPresetRecord.fetchAll(
                db,
                sql: "SELECT * FROM tool_preset ORDER BY sort_order, id"
            )
        }
        return rows.compactMap(summary(from:))
    }

    // MARK: - Write

    /// Replaces the package's whole preset library, one transaction.
    ///
    /// Replacement rather than a diff because the presenter's array *is* the library while the
    /// document is open — the same rule ``TakeoffArchive/write(_:into:)`` follows for the takeoff.
    public static func write(
        _ presets: [ToolPresetSummary],
        into package: ProjectPackage
    ) async throws {
        let projectId = try await projectIdentifier(of: package)
        let rows = try presets.enumerated().map { order, preset in
            try record(from: preset, order: order, projectId: projectId)
        }
        let written = Set(rows.map(\.id))
        try await package.write { db in
            // A row this build could not read was skipped at open, so it is not in `presets`.
            // Deleting it with the rest erased a newer build's preset — or a damaged one the
            // person could still recover — from the package for good (BH-098). Rows that decode
            // and are not in the library were deleted by the person, and go.
            let kept = try ToolPresetRecord.fetchAll(db, sql: "SELECT * FROM tool_preset")
                .filter { !written.contains($0.id) && summary(from: $0) == nil }
            try db.execute(sql: "DELETE FROM tool_preset")
            for row in rows { try row.insert(db) }
            for row in kept { try row.insert(db) }
        }
    }

    /// The package's project row identifier.
    static func projectIdentifier(of package: ProjectPackage) async throws -> String {
        guard let id = try await package.read({ db in
            try String.fetchOne(db, sql: "SELECT id FROM project ORDER BY created_at, id LIMIT 1")
        }) else {
            throw ZPDFPersistenceError.packageMalformed(reason: "the package has no project row")
        }
        return id
    }

    // MARK: - Row mapping

    /// What `defaults_json` carries: everything spec 8.2 gave `tool_preset` no column for.
    struct PresetDefaults: Codable, Hashable, Sendable {
        var schemaVersion: Int
        var panel: String
        var measurementKind: String?
        var defaultSubject: String
        var defaultDepth: DecimalQuantity?
        var defaultHeight: DecimalQuantity?
        /// Everything else the calculation needs: the gable's second height, the slope
        /// magnitude and its fall-line azimuth, the cutout and perimeter policies and the volume
        /// depth reference (ADR-0004). Optional so a package written before this build decodes;
        /// `defaultDepth` and `defaultHeight` stay as their own keys for the same reason, and
        /// the summary's own decoder folds all three together.
        var measurementDefaults: ToolPresetMeasurementDefaults?
        var labelPattern: String?
        var defaultStatus: String?
        var provenance: ToolPresetProvenance?
        var displayLengthUnit: String
        var customDefaults: [String: String]
        var countSymbolName: String?
        /// The stamp this preset places, **without its artwork**.
        ///
        /// The box, the rotation, the revision and the dynamic fields are the template's own
        /// business and live here. The artwork descriptor does not: `tool_preset.symbol_data`
        /// is the column ADR-0011 §2.3 gives it, and a descriptor written in two places is a
        /// descriptor that can disagree with itself. ``summary(from:)`` puts the two halves
        /// back together. Optional, so a package written before this build still decodes.
        var stamp: StampTemplate?
        var isFavorite: Bool
        var shortcutDisplayString: String?
        /// The preset's position *within its category*, which is not the same number as
        /// `tool_preset.sort_order`: that column carries the position in the library as a whole,
        /// so `ORDER BY sort_order` reproduces the presenter's array rather than interleaving
        /// categories. Both are stored because both are read — the array order decides what the
        /// panel lists, `sortIndex` decides what a drag inside one category renumbers.
        var sortIndex: Int
        /// The whole look a markup preset places (NL-MARKUP-15). Optional, so a package written
        /// before round 2 decodes and its presets keep their colour-only look.
        var style: ToolStyleSelection?
    }

    /// `source` names where the preset came from, which is what decides whether it can be edited.
    enum PresetSource {
        /// The person's own preset, editable.
        static let user = "user"
        /// A preset out of a read-only imported library.
        static let library = "library"
    }

    static func record(
        from preset: ToolPresetSummary,
        order: Int,
        projectId: String
    ) throws -> ToolPresetRecord {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let defaults = PresetDefaults(
            schemaVersion: preset.schemaVersion,
            panel: preset.panel.rawValue,
            measurementKind: preset.measurementKind?.rawValue,
            defaultSubject: preset.defaultSubject,
            defaultDepth: preset.defaultDepth,
            defaultHeight: preset.defaultHeight,
            measurementDefaults: preset.measurementDefaults,
            labelPattern: preset.labelPattern,
            defaultStatus: preset.defaultStatus.rawValue,
            provenance: preset.provenance,
            displayLengthUnit: preset.displayLengthUnit.rawValue,
            customDefaults: preset.customDefaults,
            countSymbolName: preset.countSymbolName,
            stamp: {
                guard var template = preset.stamp else { return nil }
                template.artwork = nil
                return template
            }(),
            isFavorite: preset.isFavorite,
            shortcutDisplayString: preset.shortcutDisplayString,
            sortIndex: preset.sortIndex,
            style: preset.style
        )
        // `symbol_data` has been in the schema since v1 and had neither a writer nor a reader
        // until here. It holds a descriptor and never bytes: the artwork a
        // stamp preset points at, or the built-in glyph a count preset chose.
        let symbolData = try CountSymbolCatalogue.payload(for: preset).map { try encoder.encode($0) }
        return ToolPresetRecord(
            id: preset.id.uuidString,
            projectId: preset.panel == .projectTools ? projectId : nil,
            name: preset.name,
            category: preset.category,
            markupType: preset.markupKind.rawValue,
            styleBlob: try encoder.encode(preset.colorRGBA),
            defaultsJson: String(decoding: try encoder.encode(defaults), as: UTF8.self),
            symbolData: symbolData,
            source: preset.isReadOnly ? PresetSource.library : PresetSource.user,
            sortOrder: order
        )
    }

    static func summary(from row: ToolPresetRecord) -> ToolPresetSummary? {
        guard let id = UUID(uuidString: row.id),
              let markupKind = MarkupKind(rawValue: row.markupType),
              let defaults = try? JSONDecoder().decode(
                  PresetDefaults.self,
                  from: Data(row.defaultsJson.utf8)
              ),
              let panel = ToolLibraryPanel(rawValue: defaults.panel)
        else { return nil }
        // A style that will not decode falls back to the Zenit measurement ink rather than
        // refusing the preset — a tool with the wrong colour is fixable on screen in a second,
        // a tool that vanished is not (the rule `TakeoffStyleCodec.decode` already keeps).
        let color = (try? JSONDecoder().decode(ColorRGBA.self, from: row.styleBlob))
            ?? ToolStyleSelection.zenitInk.stroke
        // The two halves of a stamp preset, rejoined: the template out of `defaults_json`, the
        // artwork it points at out of `symbol_data`. A row whose `symbol_data` this build
        // cannot read yields no artwork rather than a guess, and the stamp comes back as the
        // fields-only stamp it will draw as.
        let symbolPayload = row.symbolData.flatMap {
            try? JSONDecoder().decode(ToolPresetSymbolDescriptor.self, from: $0)
        }
        let stamp: StampTemplate? = defaults.stamp.map { template in
            var joined = template
            joined.artwork = symbolPayload?.artworkDescriptor
            return joined
        }
        return ToolPresetSummary(
            id: id,
            schemaVersion: defaults.schemaVersion,
            name: row.name,
            category: row.category,
            panel: panel,
            markupKind: markupKind,
            measurementKind: defaults.measurementKind.flatMap(MeasurementKind.init(rawValue:)),
            colorRGBA: color,
            defaultSubject: defaults.defaultSubject,
            defaultDepth: defaults.defaultDepth,
            defaultHeight: defaults.defaultHeight,
            measurementDefaults: defaults.measurementDefaults ?? .none,
            labelPattern: defaults.labelPattern ?? "",
            defaultStatus: defaults.defaultStatus.flatMap(MarkupStatus.init(storedValue:)) ?? .none,
            displayLengthUnit: LengthUnit(rawValue: defaults.displayLengthUnit) ?? .metre,
            customDefaults: defaults.customDefaults,
            countSymbolName: defaults.countSymbolName
                ?? symbolPayload?.builtInGlyph.flatMap(CountSymbolCatalogue.symbolName(forGlyphNamed:)),
            stamp: stamp,
            provenance: defaults.provenance ?? ToolPresetProvenance(origin: .createdHere),
            isFavorite: defaults.isFavorite,
            isReadOnly: row.source == PresetSource.library,
            shortcutDisplayString: defaults.shortcutDisplayString,
            sortIndex: defaults.sortIndex,
            style: defaults.style
        )
    }
}
