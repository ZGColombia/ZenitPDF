import Foundation

/// How cutouts inside a preset's areas are counted (mirrors the domain `CutoutPolicy`).
public enum ToolPresetCutoutPolicy: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {

    /// Net area = outer area − union(cutouts). The default.
    case subtractFromArea
    /// Cutouts are drawn but do not change the parent's quantity.
    case ignore
    /// Cutouts are subtracted and also reported as their own ledger rows.
    case subtractAndReportSeparately

    /// Stable identity.
    public var id: String { rawValue }

    /// A localized name for the editor.
    public var displayName: String {
        switch self {
        case .subtractFromArea:
            return NSLocalizedString("Subtract from area", comment: "Cutout policy")
        case .ignore:
            return NSLocalizedString("Draw but do not subtract", comment: "Cutout policy")
        case .subtractAndReportSeparately:
            return NSLocalizedString("Subtract and report separately", comment: "Cutout policy")
        }
    }
}

/// Which edges a preset's perimeter counts (mirrors the domain `PerimeterPolicy`).
public enum ToolPresetPerimeterPolicy: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {

    /// Outer ring only.
    case outerOnly
    /// Outer ring plus every cutout edge.
    case outerPlusCutoutEdges

    /// Stable identity.
    public var id: String { rawValue }

    /// A localized name for the editor.
    public var displayName: String {
        switch self {
        case .outerOnly:
            return NSLocalizedString("Outer edge only", comment: "Perimeter policy")
        case .outerPlusCutoutEdges:
            return NSLocalizedString("Outer edge plus cutouts", comment: "Perimeter policy")
        }
    }
}

/// Which direction a preset's volume depth is measured in (ADR-0004 §2).
///
/// There is deliberately no default in the domain type, and there is none here either: a
/// preset that has not been told is `nil`, and a Volume placed on a sloped markup will ask.
public enum ToolPresetVolumeDepthReference: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {

    /// Depth measured vertically, plumb.
    case verticalDepth
    /// Thickness measured perpendicular to the sloped surface, as a slab or a screed is.
    case perpendicularThickness

    /// Stable identity.
    public var id: String { rawValue }

    /// A localized name for the editor.
    public var displayName: String {
        switch self {
        case .verticalDepth:
            return NSLocalizedString("Vertical depth", comment: "Volume depth reference")
        case .perpendicularThickness:
            return NSLocalizedString("Perpendicular thickness", comment: "Volume depth reference")
        }
    }
}

/// The measurement parameters a tool preset carries — the part that makes this a takeoff
/// library rather than a palette of colours.
///
/// A preset called `Roof 6:12` that does not carry the pitch is a coloured pencil. Capturing
/// the styling and dropping the parameters is precisely the mistake that makes a tool library
/// feel useless.
///
/// # Units
///
/// Lengths are SI base units — metres — like every other stored quantity in the product.
/// ``ToolPresetSummary/displayLengthUnit`` decides what the estimator types and reads; it
/// never changes what is stored.
///
/// # The azimuth is not optional decoration
///
/// ADR-0004 §1: a slope is a vector. Without the fall-line azimuth a sloped *area* can still
/// be computed — orthographic projection scales every planar region by `cos θ` regardless of
/// orientation — but a sloped *length* or perimeter cannot, and the engine raises a typed
/// error rather than guessing. A preset that stores a magnitude and no azimuth is therefore
/// honest but incomplete, and the editor says so.
public struct ToolPresetMeasurementDefaults: Codable, Hashable, Sendable {

    /// Extrusion depth or slab thickness for Volume, in metres.
    public var depth: DecimalQuantity?
    /// Wall height for Wall Area, measured vertically, in metres.
    public var wallHeight: DecimalQuantity?
    /// Wall height at the far end of the run, for a gable, in metres (ADR-0004 §2).
    public var wallHeightAtEnd: DecimalQuantity?
    /// Slope magnitude as a percentage: 100 % is 45 degrees.
    public var slopePercent: Double?
    /// Fall-line azimuth in degrees counter-clockwise from the page-space +x axis, `[0, 360)`.
    public var slopeAzimuthDegrees: Double?
    /// Which direction a volume's depth is measured in, or `nil` when the preset has not said.
    public var volumeDepthReference: ToolPresetVolumeDepthReference?
    /// How cutouts count.
    public var cutoutPolicy: ToolPresetCutoutPolicy
    /// Which edges a perimeter counts.
    public var perimeterPolicy: ToolPresetPerimeterPolicy

    /// Creates a set of measurement defaults.
    public init(
        depth: DecimalQuantity? = nil,
        wallHeight: DecimalQuantity? = nil,
        wallHeightAtEnd: DecimalQuantity? = nil,
        slopePercent: Double? = nil,
        slopeAzimuthDegrees: Double? = nil,
        volumeDepthReference: ToolPresetVolumeDepthReference? = nil,
        cutoutPolicy: ToolPresetCutoutPolicy = .subtractFromArea,
        perimeterPolicy: ToolPresetPerimeterPolicy = .outerOnly
    ) {
        self.depth = depth
        self.wallHeight = wallHeight
        self.wallHeightAtEnd = wallHeightAtEnd
        self.slopePercent = slopePercent
        self.slopeAzimuthDegrees = slopeAzimuthDegrees
        self.volumeDepthReference = volumeDepthReference
        self.cutoutPolicy = cutoutPolicy
        self.perimeterPolicy = perimeterPolicy
    }

    /// Nothing specified: the policies the engine already defaults to, and no numbers.
    public static let none = ToolPresetMeasurementDefaults()

    /// A depth in metres.
    public static func depth(metres value: Decimal) -> ToolPresetMeasurementDefaults {
        ToolPresetMeasurementDefaults(depth: .metres(value))
    }

    /// A wall height in metres.
    public static func wallHeight(metres value: Decimal) -> ToolPresetMeasurementDefaults {
        ToolPresetMeasurementDefaults(wallHeight: .metres(value))
    }

    /// Whether the preset carries any number at all, as opposed to only the two policies.
    ///
    /// The policies are always present — they have engine defaults — so "does this preset say
    /// anything about the maths?" cannot be answered by comparing against ``none``.
    public var carriesAnyValue: Bool {
        depth != nil
            || wallHeight != nil
            || wallHeightAtEnd != nil
            || slopePercent != nil
            || slopeAzimuthDegrees != nil
            || volumeDepthReference != nil
    }

    /// True when a slope magnitude is stored without the azimuth a directional quantity needs.
    ///
    /// Surfaced by the editor as a note, never as a refusal: an area preset is perfectly usable
    /// without one, and a length preset will be told by the engine rather than by a guess.
    public var slopeIsMissingAzimuth: Bool {
        slopePercent != nil && slopeAzimuthDegrees == nil
    }
}

/// Where a preset came from, so an imported set's origin stays visible.
public struct ToolPresetProvenance: Codable, Hashable, Sendable {

    /// The four origins a preset can have.
    public enum Origin: String, Codable, Hashable, Sendable, CaseIterable {
        /// Shipped with the application.
        case builtIn
        /// Created on this machine, from scratch or from a selected markup.
        case createdHere
        /// Duplicated from another preset.
        case duplicated
        /// Read out of a `.zpdftools` file.
        case imported
    }

    /// How the preset came to exist.
    public var origin: Origin
    /// The file it was imported from, as the file was named. Untrusted display text.
    public var sourceFileName: String?
    /// When the preset entered this library.
    public var recordedAt: Date?

    /// Creates a provenance record.
    public init(origin: Origin, sourceFileName: String? = nil, recordedAt: Date? = nil) {
        self.origin = origin
        self.sourceFileName = sourceFileName
        self.recordedAt = recordedAt
    }

    /// Shipped with the application.
    public static let builtIn = ToolPresetProvenance(origin: .builtIn)

    /// A localized sentence naming the origin, for the editor and the panel's inspector row.
    public var displayDescription: String {
        switch origin {
        case .builtIn:
            return NSLocalizedString("Built in", comment: "Tool preset origin")
        case .createdHere:
            return NSLocalizedString("Created here", comment: "Tool preset origin")
        case .duplicated:
            return NSLocalizedString("Duplicated", comment: "Tool preset origin")
        case .imported:
            guard let sourceFileName, !sourceFileName.isEmpty else {
                return NSLocalizedString("Imported", comment: "Tool preset origin")
            }
            return String(
                format: NSLocalizedString(
                    "Imported from %@",
                    comment: "Tool preset origin. %@ is a file name"
                ),
                sourceFileName
            )
        }
    }
}
