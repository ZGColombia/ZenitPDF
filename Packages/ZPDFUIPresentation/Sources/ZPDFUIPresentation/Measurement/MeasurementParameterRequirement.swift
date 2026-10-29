import Foundation

/// The one number a measurement tool needs from the estimator before it can produce a
/// quantity at all.
///
/// Five of the twenty-two tools measure something the drawing does not contain. A slab's
/// volume is its outline times a depth, and the depth is not on the sheet; a wall's area is
/// its run times a height, and the height is not on the sheet either. The engine has always
/// said so — `MeasurementEngineError.measurement(.missingParameter(...))` — but nothing in
/// the product ever asked for the value, so `AppMeasurementToolPresenter.setParameters` had
/// no caller, the calculator threw, and a `try?` in `AppCoreEnvironment` swallowed it. The
/// user clicked, watched a live preview, pressed Return, and nothing appeared with no
/// message.
///
/// This type is the question the tool options bar asks. It is deliberately *one* value per
/// tool: the richer forms — per-segment rise/drop, a gable's second height, a fall line
/// picked from two points — live in ``MeasurementParameters`` and belong to the Inspector,
/// not to a strip above the canvas.
public enum MeasurementParameterRequirement: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {

    /// Extrusion depth or slab thickness, for Volume.
    case depth
    /// Wall height, measured vertically, for Wall Area.
    case wallHeight
    /// A uniform plane's steepness as a percentage, for Slope and the two true-sloped tools.
    case slopePercent
    /// A single rise or drop applied across the whole run, for Rise/Drop.
    case totalRiseDrop

    /// Stable identity.
    public var id: String { rawValue }

    /// Whether the value is a length, and therefore entered in the active length unit.
    ///
    /// `false` means the value is a bare percentage and carries its own `%`.
    public var isLength: Bool {
        switch self {
        case .depth, .wallHeight, .totalRiseDrop: return true
        case .slopePercent: return false
        }
    }

    /// The field label in the tool options bar.
    public var displayName: String {
        switch self {
        case .depth:
            return NSLocalizedString("Depth", comment: "Measurement parameter field label")
        case .wallHeight:
            return NSLocalizedString("Height", comment: "Measurement parameter field label")
        case .slopePercent:
            return NSLocalizedString("Slope", comment: "Measurement parameter field label")
        case .totalRiseDrop:
            return NSLocalizedString("Rise/Drop", comment: "Measurement parameter field label")
        }
    }

    /// What the tool will do with the number, in one line. Shown as the field's help and
    /// as its accessibility hint.
    public var shortHelp: String {
        switch self {
        case .depth:
            return NSLocalizedString(
                "The thickness the outlined area is extruded by.",
                comment: "Measurement parameter help"
            )
        case .wallHeight:
            return NSLocalizedString(
                "The wall's vertical height, multiplied by the run you draw.",
                comment: "Measurement parameter help"
            )
        case .slopePercent:
            return NSLocalizedString(
                "The plane's steepness as a percentage: 100% is 45 degrees.",
                comment: "Measurement parameter help"
            )
        case .totalRiseDrop:
            return NSLocalizedString(
                "The total fall over the whole run you draw.",
                comment: "Measurement parameter help"
            )
        }
    }

    /// What the status bar and the options bar say while the value is still missing.
    ///
    /// The rule shared by every tool — a tool must never be armed and silently produce
    /// nothing — is satisfied by naming the value rather than by an apology.
    public var missingValueNote: String {
        switch self {
        case .depth:
            return NSLocalizedString(
                "Enter a depth before finishing: a volume is an area times a thickness.",
                comment: "Status note while a Volume has no depth"
            )
        case .wallHeight:
            return NSLocalizedString(
                "Enter a height before finishing: a wall area is a run times a height.",
                comment: "Status note while a Wall Area has no height"
            )
        case .slopePercent:
            return NSLocalizedString(
                "Enter a slope before finishing: the drawing does not show how steep the plane is.",
                comment: "Status note while Slope, True Sloped Length or True Sloped Area has no slope"
            )
        case .totalRiseDrop:
            return NSLocalizedString(
                "Enter a rise or drop before finishing: the run alone is only the plan length.",
                comment: "Status note while Rise/Drop has no fall"
            )
        }
    }
}

public extension MeasurementKind {

    /// The value the tool options bar must collect before this tool can be committed, or
    /// `nil` for the tools that measure only what is drawn.
    ///
    /// The set is exactly the six the engine's `missingParameter` errors name:
    /// `VolumeCalculator` needs `depth`, `WallAreaCalculator` needs `height`,
    /// `RiseDropCalculator` needs a rise/drop mode, and `SlopeCalculator` and both true-sloped
    /// calculators need a slope magnitude. Slope was missing (BH-052): every Slope commit was
    /// refused with `missingParameter(.riseRun)` and there was no field to type one into.
    var requiredParameter: MeasurementParameterRequirement? {
        switch self {
        case .volume: return .depth
        case .wallArea: return .wallHeight
        case .slope, .trueSlopedLength, .trueSlopedArea: return .slopePercent
        case .riseDrop: return .totalRiseDrop
        default: return nil
        }
    }
}
