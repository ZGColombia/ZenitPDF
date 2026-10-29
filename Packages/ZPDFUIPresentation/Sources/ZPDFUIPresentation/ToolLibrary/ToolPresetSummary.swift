import Foundation

/// The panels of the Tool Library sidebar.
public enum ToolLibraryPanel: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {

    /// Presets owned by the current user, shared across projects.
    case myTools
    /// Presets stored inside the open project.
    case projectTools
    /// Recently activated presets, newest first.
    case recent
    /// Presets the user starred.
    case favorites
    /// Ordered runs of presets that advance automatically.
    case sequences
    /// Symbols available to the Count tool.
    case countSymbols
    /// Read-only libraries imported from a file.
    case importedLibraries

    /// Stable identity.
    public var id: String { rawValue }

    /// Whether presets in the panel can be edited.
    public var isEditable: Bool {
        switch self {
        case .myTools, .projectTools, .favorites, .sequences, .countSymbols: return true
        case .recent, .importedLibraries: return false
        }
    }

    /// A localized panel title.
    public var displayName: String {
        switch self {
        case .myTools: return NSLocalizedString("My Tools", comment: "Tool Library panel")
        case .projectTools: return NSLocalizedString("Project Tools", comment: "Tool Library panel")
        case .recent: return NSLocalizedString("Recent", comment: "Tool Library panel")
        case .favorites: return NSLocalizedString("Favorites", comment: "Tool Library panel")
        case .sequences: return NSLocalizedString("Sequences", comment: "Tool Library panel")
        case .countSymbols: return NSLocalizedString("Count Symbols", comment: "Tool Library panel")
        case .importedLibraries: return NSLocalizedString("Imported Libraries", comment: "Tool Library panel")
        }
    }

    /// SF Symbol name for the panel row.
    public var symbolName: String {
        switch self {
        case .myTools: return "wrench.and.screwdriver"
        case .projectTools: return "folder"
        case .recent: return "clock.arrow.circlepath"
        case .favorites: return "star"
        case .sequences: return "list.number"
        case .countSymbols: return "circle.grid.3x3"
        case .importedLibraries: return "square.and.arrow.down"
        }
    }
}


/// A saved measurement or markup tool the user can re-apply.
///
/// The stored preset is a versioned JSON document with no executable content. This
/// summary is the flattened form the sidebar renders.
///
/// # What it must carry, and why the list is longer than it looks
///
/// Style alone is not enough. Beyond colour and markup
/// kind a preset carries its **measurement parameters** (``measurementDefaults``), its
/// **ledger identity** (``defaultSubject``, ``labelPattern``, ``defaultStatus``,
/// ``customDefaults``), its **symbol artwork** for Place mode and Count marks, and its own
/// **provenance**. A preset that carries the first and not the rest makes the estimator
/// re-specify depth, cost code and status on every markup — which is the whole thing a tool
/// library exists to stop.
public struct ToolPresetSummary: Codable, Hashable, Sendable, Identifiable {

    /// Stable identity of the preset.
    public let id: UUID
    /// Version of the preset document schema this summary was decoded from.
    public var schemaVersion: Int
    /// User-visible name, for example `"Concrete Area"`.
    public var name: String
    /// Grouping category inside a panel, for example `"Concrete"`.
    public var category: String
    /// The panel the preset lives in.
    public var panel: ToolLibraryPanel
    /// The markup family the preset places.
    public var markupKind: MarkupKind
    /// The measurement tool the preset activates, or `nil` for non-measuring presets.
    public var measurementKind: MeasurementKind?
    /// Stroke colour of the placed markup.
    public var colorRGBA: ColorRGBA
    /// Default takeoff subject.
    public var defaultSubject: String
    /// Everything the calculation needs that the drawing does not contain: depth, wall
    /// height, slope magnitude *and* azimuth, the cutout and perimeter policies, and the
    /// volume depth reference (ADR-0004).
    public var measurementDefaults: ToolPresetMeasurementDefaults
    /// The ledger label a markup made with this preset starts with. Plain text today; the
    /// name says "pattern" because the field is where a numbering scheme will live, and
    /// renaming a persisted field later is worse than naming it once.
    public var labelPattern: String
    /// The review status a markup made with this preset starts in.
    public var defaultStatus: MarkupStatus
    /// Default display unit for length results.
    public var displayLengthUnit: LengthUnit
    /// Default custom column values, keyed by column identifier raw value.
    public var customDefaults: [String: String]
    /// SF Symbol name for a Count preset's symbol, or `nil`.
    public var countSymbolName: String?
    /// The stamp this preset places, for a `.stamp` preset.
    ///
    /// `nil` on every other preset. It carries the artwork descriptor — vector or raster,
    /// and the digest its bytes are stored under — and the dynamic fields that resolve at
    /// placement time. Until this existed a `.stamp` preset placed a stamp-kind markup with
    /// no image and no fields on it.
    public var stamp: StampTemplate?
    /// Where the preset came from, so an imported set's origin stays visible.
    public var provenance: ToolPresetProvenance
    /// Whether the preset is starred.
    public var isFavorite: Bool
    /// Whether the preset came from a read-only shared library.
    public var isReadOnly: Bool
    /// Keyboard shortcut label such as `"⌥1"`, or `nil` when unassigned.
    public var shortcutDisplayString: String?
    /// Position within its category.
    public var sortIndex: Int
    /// The whole look a markup preset places (NL-MARKUP-15, round 2): width, fill, line style,
    /// ends, opacity, text. `nil` for a preset saved before round 2, which places its colour
    /// with the tool's defaults as it always did.
    public var style: ToolStyleSelection?

    /// Extrusion depth or slab thickness, in SI base units.
    ///
    /// A forwarder onto ``measurementDefaults``. The two spellings existed before the rest of
    /// measurement parameters did; keeping this one means the depth has exactly one storage
    /// location, which is what stops a preset from carrying two depths that disagree.
    public var defaultDepth: DecimalQuantity? {
        get { measurementDefaults.depth }
        set { measurementDefaults.depth = newValue }
    }

    /// Wall height for Wall Area presets, in SI base units. A forwarder, as ``defaultDepth`` is.
    public var defaultHeight: DecimalQuantity? {
        get { measurementDefaults.wallHeight }
        set { measurementDefaults.wallHeight = newValue }
    }

    /// Creates a tool preset summary.
    public init(
        id: UUID,
        schemaVersion: Int = 1,
        name: String,
        category: String,
        panel: ToolLibraryPanel,
        markupKind: MarkupKind,
        measurementKind: MeasurementKind? = nil,
        colorRGBA: ColorRGBA,
        defaultSubject: String,
        defaultDepth: DecimalQuantity? = nil,
        defaultHeight: DecimalQuantity? = nil,
        measurementDefaults: ToolPresetMeasurementDefaults = .none,
        labelPattern: String = "",
        defaultStatus: MarkupStatus = .none,
        displayLengthUnit: LengthUnit = .metre,
        customDefaults: [String: String] = [:],
        countSymbolName: String? = nil,
        stamp: StampTemplate? = nil,
        provenance: ToolPresetProvenance = ToolPresetProvenance(origin: .createdHere),
        isFavorite: Bool = false,
        isReadOnly: Bool = false,
        shortcutDisplayString: String? = nil,
        sortIndex: Int = 0,
        style: ToolStyleSelection? = nil
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.name = name
        self.category = category
        self.panel = panel
        self.markupKind = markupKind
        self.measurementKind = measurementKind
        self.colorRGBA = colorRGBA
        self.defaultSubject = defaultSubject
        var defaults = measurementDefaults
        // The two convenience arguments win when they were supplied, so the older call shape
        // — `defaultDepth:` with no `measurementDefaults:` — keeps meaning what it meant.
        if let defaultDepth { defaults.depth = defaultDepth }
        if let defaultHeight { defaults.wallHeight = defaultHeight }
        self.measurementDefaults = defaults
        self.labelPattern = labelPattern
        self.defaultStatus = defaultStatus
        self.displayLengthUnit = displayLengthUnit
        self.customDefaults = customDefaults
        self.countSymbolName = countSymbolName
        self.stamp = stamp
        self.provenance = provenance
        self.isFavorite = isFavorite
        self.isReadOnly = isReadOnly
        self.shortcutDisplayString = shortcutDisplayString
        self.sortIndex = sortIndex
        self.style = style
    }

    /// The style a markup this preset places takes: the stored look, its stroke kept in step
    /// with ``colorRGBA`` (the colour the grid cell shows and the editor edits), or the colour
    /// alone over the Zenit defaults for a preset saved before round 2.
    public var placementStyle: ToolStyleSelection {
        guard var full = style else { return ToolStyleSelection(stroke: colorRGBA, fill: nil) }
        full.stroke = colorRGBA
        return full
    }

    // MARK: - Codable

    /// Written by hand rather than synthesized, for one reason: ``defaultDepth`` and
    /// ``defaultHeight`` used to be *stored* properties and are on disk under those names in
    /// every container library and every project package written before this build. A
    /// synthesized decoder would silently drop them — every saved "Slab 200 mm" would come
    /// back as a slab with no thickness, which is the exact failure carrying the parameters prevents.
    private enum CodingKeys: String, CodingKey {
        case id, schemaVersion, name, category, panel, markupKind, measurementKind
        case colorRGBA, defaultSubject, measurementDefaults, labelPattern, defaultStatus
        case displayLengthUnit, customDefaults, countSymbolName, stamp, provenance
        case isFavorite, isReadOnly, shortcutDisplayString, sortIndex
        case style
        /// Legacy spellings, read and never written.
        case defaultDepth, defaultHeight
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        name = try container.decode(String.self, forKey: .name)
        category = try container.decode(String.self, forKey: .category)
        panel = try container.decode(ToolLibraryPanel.self, forKey: .panel)
        markupKind = try container.decode(MarkupKind.self, forKey: .markupKind)
        measurementKind = try container.decodeIfPresent(MeasurementKind.self, forKey: .measurementKind)
        colorRGBA = try container.decode(ColorRGBA.self, forKey: .colorRGBA)
        defaultSubject = try container.decodeIfPresent(String.self, forKey: .defaultSubject) ?? ""
        var defaults = try container.decodeIfPresent(
            ToolPresetMeasurementDefaults.self, forKey: .measurementDefaults
        ) ?? .none
        if let legacyDepth = try container.decodeIfPresent(DecimalQuantity.self, forKey: .defaultDepth) {
            defaults.depth = legacyDepth
        }
        if let legacyHeight = try container.decodeIfPresent(DecimalQuantity.self, forKey: .defaultHeight) {
            defaults.wallHeight = legacyHeight
        }
        measurementDefaults = defaults
        labelPattern = try container.decodeIfPresent(String.self, forKey: .labelPattern) ?? ""
        defaultStatus = try container.decodeIfPresent(MarkupStatus.self, forKey: .defaultStatus) ?? .none
        displayLengthUnit = try container.decodeIfPresent(LengthUnit.self, forKey: .displayLengthUnit) ?? .metre
        customDefaults = try container.decodeIfPresent([String: String].self, forKey: .customDefaults) ?? [:]
        countSymbolName = try container.decodeIfPresent(String.self, forKey: .countSymbolName)
        stamp = try container.decodeIfPresent(StampTemplate.self, forKey: .stamp)
        provenance = try container.decodeIfPresent(ToolPresetProvenance.self, forKey: .provenance)
            ?? ToolPresetProvenance(origin: .createdHere)
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        isReadOnly = try container.decodeIfPresent(Bool.self, forKey: .isReadOnly) ?? false
        shortcutDisplayString = try container.decodeIfPresent(String.self, forKey: .shortcutDisplayString)
        sortIndex = try container.decodeIfPresent(Int.self, forKey: .sortIndex) ?? 0
        // Round 2: absent in every preset saved before it, which keeps its colour-only look.
        style = try container.decodeIfPresent(ToolStyleSelection.self, forKey: .style)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(name, forKey: .name)
        try container.encode(category, forKey: .category)
        try container.encode(panel, forKey: .panel)
        try container.encode(markupKind, forKey: .markupKind)
        try container.encodeIfPresent(measurementKind, forKey: .measurementKind)
        try container.encode(colorRGBA, forKey: .colorRGBA)
        try container.encode(defaultSubject, forKey: .defaultSubject)
        try container.encode(measurementDefaults, forKey: .measurementDefaults)
        try container.encode(labelPattern, forKey: .labelPattern)
        try container.encode(defaultStatus, forKey: .defaultStatus)
        try container.encode(displayLengthUnit, forKey: .displayLengthUnit)
        try container.encode(customDefaults, forKey: .customDefaults)
        try container.encodeIfPresent(countSymbolName, forKey: .countSymbolName)
        try container.encodeIfPresent(stamp, forKey: .stamp)
        try container.encode(provenance, forKey: .provenance)
        try container.encode(isFavorite, forKey: .isFavorite)
        try container.encode(isReadOnly, forKey: .isReadOnly)
        try container.encodeIfPresent(shortcutDisplayString, forKey: .shortcutDisplayString)
        try container.encode(sortIndex, forKey: .sortIndex)
        try container.encodeIfPresent(style, forKey: .style)
    }

    /// Whether the preset places a stamp whose artwork will blur when magnified.
    ///
    /// Surfaced on the summary so the grid cell and the editor ask the same question of the
    /// same value; a warning computed twice is a warning that eventually disagrees with
    /// itself.
    public var placesRasterStamp: Bool { stamp?.artworkIsRaster ?? false }

    /// A localized VoiceOver label: name, tool and category.
    public var accessibilityLabel: String {
        let toolName = measurementKind?.displayName ?? markupKind.displayName
        let format = NSLocalizedString(
            "%1$@, %2$@ tool, %3$@",
            comment: "VoiceOver label for a Tool Library preset: preset name, tool name, category"
        )
        return String(format: format, name, toolName, category)
    }
}
