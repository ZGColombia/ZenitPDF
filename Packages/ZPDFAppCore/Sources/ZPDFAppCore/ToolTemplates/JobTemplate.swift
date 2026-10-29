import Foundation
import ZPDFUIPresentation

/// A snapshot of a whole rig — tools, subjects, colours, ledger column preferences, display
/// units — that starts the next project the way the last one was set up.
///
/// # What a template is not
///
/// **A template has no place for a scale.** Not an empty field, not a reserved key, not an
/// optional that happens to be `nil` — the type cannot represent one. Invariant: a
/// template never applies a scale, and the strongest way to never apply one is to be
/// structurally unable to carry one: a scale belongs to a drawing, and a template is applied
/// to projects whose drawings this template has never seen. `JobTemplateTests` asserts the
/// encoded form key by key, and asserts that a file smuggling a `scale` key decodes to a
/// template identical to one decoded without it.
///
/// # Versioned coding
///
/// The coding keys below are format version 1 and are frozen: a later build may add keys
/// (read as optional, defaulted) and may bump ``currentFormatVersion``, but may never rename
/// or re-type a v1 key. ``JobTemplateStore`` and ``JobTemplateFile`` both refuse a version
/// newer than the one they were built to read, by number, before decoding the body — the
/// same posture ``ToolPresetContainerStore`` takes for the tool library.
public struct JobTemplate: Codable, Hashable, Sendable, Identifiable {

    /// The template format this build writes and the newest one it reads.
    public static let currentFormatVersion = 1

    /// Stable identity of the template.
    public let id: UUID
    /// The format version the template was decoded from, or ``currentFormatVersion`` for one
    /// built in memory.
    public var formatVersion: Int
    /// The template's user-visible name — the job type it captures, `"Groundwork"`, `"Roofing"`.
    public var name: String
    /// When the rig was captured.
    public var createdAt: Date
    /// The tool presets of the rig, in library order. Colours ride on the presets, as they do
    /// in the library itself.
    public var presets: [ToolPresetSummary]
    /// The takeoff subjects of the rig, each with the colour its markups carry.
    public var subjects: [JobTemplateSubject]
    /// Ledger column visibility, in the column order of the rig.
    public var columnPreferences: [JobTemplateColumnPreference]
    /// The display units the rig presents results in.
    public var units: JobTemplateUnits
    /// Export profiles that travel with the rig (NL-PLAT-08), each the `.zpdfprofile` JSON as
    /// written. Held as text because the profile type belongs to the export package; the app
    /// validates each through the profile's own reader before installing it, exactly as it does
    /// an opened file. Empty for every template written before this field, and then not written.
    public var exportProfiles: [JobTemplateAttachedFile] = []

    /// Creates a template from its parts.
    public init(
        id: UUID = UUID(),
        formatVersion: Int = JobTemplate.currentFormatVersion,
        name: String,
        createdAt: Date = Date(),
        presets: [ToolPresetSummary] = [],
        subjects: [JobTemplateSubject] = [],
        columnPreferences: [JobTemplateColumnPreference] = [],
        units: JobTemplateUnits = JobTemplateUnits()
    ) {
        self.id = id
        self.formatVersion = formatVersion
        self.name = name
        self.createdAt = createdAt
        self.presets = presets
        self.subjects = subjects
        self.columnPreferences = columnPreferences
        self.units = units
    }

    // MARK: - Versioned coding

    /// Format version 1, frozen. There is deliberately no key whose name or meaning is a
    /// scale, a calibration or a page transform, and there never will be one in v1: a decoder
    /// with an exhaustive key set reads a smuggled `scale` member as nothing at all.
    private enum CodingKeys: String, CodingKey {
        case id, formatVersion, name, createdAt, presets, subjects, columnPreferences, units
        // Added after v1 was frozen: optional, defaulted, written only when non-empty, so a v1
        // template's bytes are unchanged and an older build ignores it.
        case exportProfiles
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        formatVersion = try container.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        // A template body newer than this build is refused by number, as the header promises —
        // not decoded with its new keys dropped to defaults and written back as if it were v1
        // (BH-464). The envelope gates check only the envelope's own version.
        guard formatVersion <= Self.currentFormatVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .formatVersion,
                in: container,
                debugDescription: "template format version \(formatVersion) is newer than this build supports (\(Self.currentFormatVersion))"
            )
        }
        name = try container.decode(String.self, forKey: .name)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSinceReferenceDate: 0)
        presets = try container.decodeIfPresent([ToolPresetSummary].self, forKey: .presets) ?? []
        subjects = try container.decodeIfPresent([JobTemplateSubject].self, forKey: .subjects) ?? []
        columnPreferences = try container.decodeIfPresent(
            [JobTemplateColumnPreference].self, forKey: .columnPreferences
        ) ?? []
        units = try container.decodeIfPresent(JobTemplateUnits.self, forKey: .units) ?? JobTemplateUnits()
        exportProfiles = try container.decodeIfPresent([JobTemplateAttachedFile].self, forKey: .exportProfiles) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(name, forKey: .name)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(presets, forKey: .presets)
        try container.encode(subjects, forKey: .subjects)
        try container.encode(columnPreferences, forKey: .columnPreferences)
        try container.encode(units, forKey: .units)
        if !exportProfiles.isEmpty {
            try container.encode(exportProfiles, forKey: .exportProfiles)
        }
    }
}

/// A data file carried inside a template (an export profile), as its own JSON text. Untrusted
/// when read back: the app hands the text to that format's validator.
public struct JobTemplateAttachedFile: Codable, Hashable, Sendable {
    /// What the file is called, for the status note.
    public var name: String
    /// The file's JSON, as written by its own format.
    public var json: String

    public init(name: String, json: String) {
        self.name = name
        self.json = json
    }
}

/// One takeoff subject of a rig, and the colour its markups carry.
///
/// Subjects are otherwise implicit — a string on a preset, a string on a markup — and a
/// template is exactly the place they become explicit: the next project starts with the
/// subject vocabulary of the last one, not just with its tools.
public struct JobTemplateSubject: Codable, Hashable, Sendable, Identifiable {

    /// The subject text, as markups carry it.
    public var name: String
    /// The colour markups of this subject are drawn in.
    public var colorRGBA: ColorRGBA

    /// Stable identity: the subject text itself.
    public var id: String { name }

    /// Creates a subject entry.
    public init(name: String, colorRGBA: ColorRGBA) {
        self.name = name
        self.colorRGBA = colorRGBA
    }
}

/// One ledger column of the rig: which column, and whether it is shown.
///
/// Order is the array's order — a preference list is a statement about sequence, and storing
/// a position number beside a position in an array is two answers to one question.
public struct JobTemplateColumnPreference: Codable, Hashable, Sendable, Identifiable {

    /// The column's stable identifier, `LedgerColumnID.rawValue` verbatim.
    public var columnID: String
    /// Whether the column is shown.
    public var visible: Bool

    /// Stable identity: the column identifier.
    public var id: String { columnID }

    /// Creates a column preference.
    public init(columnID: String, visible: Bool) {
        self.columnID = columnID
        self.visible = visible
    }
}

/// The display units of the rig, in a serialisable form.
///
/// A codable mirror of ``DisplayUnitSelection``, field for field, so the template file format
/// does not depend on a bridge type staying `Codable`-free or otherwise. The two directions
/// are total: every selection is representable and every stored value resolves to a selection.
public struct JobTemplateUnits: Codable, Hashable, Sendable {

    /// Output unit for length-dimensioned fields.
    public var length: LengthUnit
    /// Output unit for area-dimensioned fields.
    public var area: AreaUnit
    /// Output unit for volume-dimensioned fields.
    public var volume: VolumeUnit
    /// How a slope is written.
    public var slope: SlopeDisplayMode
    /// Fraction denominator used when ``length`` is imperial.
    public var imperialPrecision: ImperialPrecision
    /// Decimal places used when ``length`` is metric.
    public var metricDecimalPlaces: Int

    /// Creates a unit block from its parts.
    public init(
        length: LengthUnit = .metre,
        area: AreaUnit = .squareMetre,
        volume: VolumeUnit = .cubicMetre,
        slope: SlopeDisplayMode = .percent,
        imperialPrecision: ImperialPrecision = .sixteenth,
        metricDecimalPlaces: Int = 2
    ) {
        self.length = length
        self.area = area
        self.volume = volume
        self.slope = slope
        self.imperialPrecision = imperialPrecision
        self.metricDecimalPlaces = metricDecimalPlaces
    }

    /// Captures a live selection.
    public init(selection: DisplayUnitSelection) {
        self.init(
            length: selection.length,
            area: selection.area,
            volume: selection.volume,
            slope: selection.slope,
            imperialPrecision: selection.imperialPrecision,
            metricDecimalPlaces: selection.metricDecimalPlaces
        )
    }

    /// The live selection this block stores.
    public var selection: DisplayUnitSelection {
        DisplayUnitSelection(
            length: length,
            area: area,
            volume: volume,
            slope: slope,
            imperialPrecision: imperialPrecision,
            metricDecimalPlaces: metricDecimalPlaces
        )
    }
}
