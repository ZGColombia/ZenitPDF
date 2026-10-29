import Foundation
import ZPDFUIPresentation

/// The one rule for what a tool preset's measurement parameters may hold, shared by the preset
/// editor and the tool set importer.
///
/// The editor used to accept a depth of zero or below and the importer used to refuse a wall
/// height at the far end of zero — so a tool the editor saved was not a tool the importer would
/// accept, and a wall that tapers to grade did not survive its own export (IM-036, BH-321).
/// Both now ask this type.
public enum ToolPresetParameterRule {

    /// The largest length a preset may carry, in metres. A hundred kilometres: no slab is that
    /// thick and no wall is that tall, so a value past it is corrupt or hostile either way.
    public static let maximumLengthMetres: Double = 100_000

    /// The largest slope percentage or azimuth a preset may carry. Generous rather than
    /// opinionated — ADR-0004 §5 accepts a slope above 100 % with a warning — because the bound
    /// exists to refuse nonsense, not to have a second opinion about roofs.
    public static let maximumSlopeMagnitude: Double = 100_000

    /// One parameter of a preset.
    public enum Field: String, Hashable, Sendable, CaseIterable {
        case depth
        case wallHeight
        case wallHeightAtEnd
        case slopePercent
        case slopeAzimuthDegrees
        case volumeDepthReference
        case cutoutPolicy
        case perimeterPolicy

        /// Whether a length in this field may be exactly zero.
        ///
        /// A depth or wall height of zero is a tool that reports a volume or an area of nothing,
        /// which is the "empty means no value" failure the length field exists to prevent. A wall
        /// height *at the far end* of zero is a real shape — a retaining wall tapering to grade —
        /// and the engine's trapezoid form `(height + heightAtEnd) / 2` accepts it. Finding
        /// BH-321.
        public var allowsZero: Bool { self == .wallHeightAtEnd }

        /// The field's name as the editor labels it.
        public var displayName: String {
            switch self {
            case .depth: return NSLocalizedString("Depth", comment: "Tool preset field")
            case .wallHeight: return NSLocalizedString("Wall height", comment: "Tool preset field")
            case .wallHeightAtEnd: return NSLocalizedString("Height at end", comment: "Tool preset field")
            case .slopePercent: return NSLocalizedString("Slope %", comment: "Tool preset field")
            case .slopeAzimuthDegrees: return NSLocalizedString("Slope direction °", comment: "Tool preset field")
            case .volumeDepthReference: return NSLocalizedString("Volume depth", comment: "Tool preset field")
            case .cutoutPolicy: return NSLocalizedString("Cutouts", comment: "Tool preset field")
            case .perimeterPolicy: return NSLocalizedString("Perimeter", comment: "Tool preset field")
            }
        }
    }

    /// One thing wrong with a preset's parameters, in the person's words.
    public struct Issue: Hashable, Sendable, Identifiable {
        /// The parameter concerned.
        public let field: Field
        /// What to type instead.
        public let message: String

        public var id: Field { field }
    }

    /// Whether a length, in metres, may be stored in `field`.
    public static func isStorableLength(_ metres: Double, in field: Field) -> Bool {
        guard metres.isFinite, metres <= maximumLengthMetres else { return false }
        return field.allowsZero ? metres >= 0 : metres > 0
    }

    /// Whether a bare number (a slope percentage, an azimuth) may be stored.
    public static func isStorableMagnitude(_ value: Double) -> Bool {
        value.isFinite && abs(value) <= maximumSlopeMagnitude
    }

    /// Everything wrong with `defaults`, in field order. Empty means the parameters are ones
    /// the importer would accept back unchanged.
    public static func issues(in defaults: ToolPresetMeasurementDefaults) -> [Issue] {
        var issues: [Issue] = []
        func check(_ quantity: DecimalQuantity?, _ field: Field) {
            guard let quantity else { return }
            let metres = NSDecimalNumber(decimal: quantity.value).doubleValue
            guard !isStorableLength(metres, in: field) else { return }
            issues.append(Issue(field: field, message: lengthMessage(for: field)))
        }
        check(defaults.depth, .depth)
        check(defaults.wallHeight, .wallHeight)
        check(defaults.wallHeightAtEnd, .wallHeightAtEnd)
        if let slope = defaults.slopePercent, !isStorableMagnitude(slope) {
            issues.append(Issue(field: .slopePercent, message: NSLocalizedString(
                "Type a slope as a percentage, e.g. 50.",
                comment: "Preset editor issue under an out-of-range slope field"
            )))
        }
        if let azimuth = defaults.slopeAzimuthDegrees, !isStorableMagnitude(azimuth) {
            issues.append(Issue(field: .slopeAzimuthDegrees, message: NSLocalizedString(
                "Type a direction in degrees, e.g. 90.",
                comment: "Preset editor issue under an out-of-range azimuth field"
            )))
        }
        return issues
    }

    /// The message shown under a length field that holds something the rule refuses.
    public static func lengthMessage(for field: Field) -> String {
        field.allowsZero
            ? NSLocalizedString(
                "Type a length of zero or more, e.g. 0.2.",
                comment: "Preset editor issue under a length field that may be zero"
            )
            : NSLocalizedString(
                "Type a positive length, e.g. 0.2.",
                comment: "Preset editor issue under a length field that must be positive"
            )
    }

    /// The message shown under a field whose text does not read as a number at all.
    public static let unparsedMessage = NSLocalizedString(
        "This is not a number. Type a value such as 0.2, or clear the field.",
        comment: "Preset editor issue under a parameter field holding unparseable text"
    )

    /// The parameters the editor shows for a tool, the same rule the options bar applies: a
    /// Length tool never asks for a wall height (IM-157). A preset that does not measure shows
    /// none; hidden values are left exactly as they are.
    public static func displayedFields(for kind: MeasurementKind?) -> Set<Field> {
        guard let kind else { return [] }
        var fields: Set<Field> = []
        switch kind {
        case .volume:
            fields.formUnion([.depth, .volumeDepthReference])
        case .wallArea:
            fields.formUnion([.wallHeight, .wallHeightAtEnd])
        case .slope, .riseDrop, .trueSlopedLength, .trueSlopedArea:
            fields.formUnion([.slopePercent, .slopeAzimuthDegrees])
        default:
            break
        }
        switch kind.dimension {
        case .area, .volume:
            fields.formUnion([.cutoutPolicy, .perimeterPolicy])
        default:
            break
        }
        return fields
    }
}
