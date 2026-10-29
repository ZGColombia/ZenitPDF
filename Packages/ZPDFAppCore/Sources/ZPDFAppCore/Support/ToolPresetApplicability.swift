import Foundation
import ZPDFUIPresentation

/// One property a preset can write onto an existing markup in Apply mode.
///
/// Closed on purpose. Apply mode is a bulk mutation, and the only way to promise "it changed
/// exactly these things and skipped exactly those" is for the list of things it could change
/// to be enumerable rather than implied by whatever the code happens to copy.
public enum ToolPresetProperty: String, Hashable, Sendable, CaseIterable, Identifiable {

    /// Stroke colour.
    case color
    /// Takeoff subject — the ledger's primary grouping key.
    case subject
    /// Ledger label.
    case label
    /// Review status.
    case status
    /// Custom ledger column values.
    case customValues
    /// Volume depth or slab thickness.
    case depth
    /// Wall height.
    case wallHeight
    /// Wall height at the far end of the run.
    case wallHeightAtEnd
    /// Slope magnitude.
    case slope
    /// Fall-line azimuth.
    case slopeAzimuth
    /// Cutout policy.
    case cutoutPolicy
    /// Perimeter policy.
    case perimeterPolicy
    /// Volume depth reference.
    case volumeDepthReference

    /// Stable identity.
    public var id: String { rawValue }

    /// Whether the property is an input to the calculation, and therefore forces a recompute.
    ///
    /// This is the list that makes Apply mode a takeoff operation rather than a recolour. A
    /// change to any of these goes through ``DocumentCommand/editParameters(id:parameters:)``
    /// and comes back with a new number and a new provenance.
    public var feedsTheMaths: Bool {
        switch self {
        case .depth, .wallHeight, .wallHeightAtEnd, .slope, .slopeAzimuth,
             .cutoutPolicy, .perimeterPolicy, .volumeDepthReference:
            return true
        case .color, .subject, .label, .status, .customValues:
            return false
        }
    }

    /// A localized name, used in the "applied these, skipped those" report.
    public var displayName: String {
        switch self {
        case .color: return NSLocalizedString("Colour", comment: "Tool preset property")
        case .subject: return NSLocalizedString("Subject", comment: "Tool preset property")
        case .label: return NSLocalizedString("Label", comment: "Tool preset property")
        case .status: return NSLocalizedString("Status", comment: "Tool preset property")
        case .customValues: return NSLocalizedString("Ledger columns", comment: "Tool preset property")
        case .depth: return NSLocalizedString("Depth", comment: "Tool preset property")
        case .wallHeight: return NSLocalizedString("Wall height", comment: "Tool preset property")
        case .wallHeightAtEnd: return NSLocalizedString("Wall height at end", comment: "Tool preset property")
        case .slope: return NSLocalizedString("Slope", comment: "Tool preset property")
        case .slopeAzimuth: return NSLocalizedString("Slope direction", comment: "Tool preset property")
        case .cutoutPolicy: return NSLocalizedString("Cutout policy", comment: "Tool preset property")
        case .perimeterPolicy: return NSLocalizedString("Perimeter policy", comment: "Tool preset property")
        case .volumeDepthReference:
            return NSLocalizedString("Volume depth reference", comment: "Tool preset property")
        }
    }
}

/// One property the preset carried and the target could not take, and why.
public struct ToolPresetSkip: Hashable, Sendable, Identifiable {

    /// The property that was not written.
    public let property: ToolPresetProperty
    /// The tool the target markup was made with, named for the message.
    public let targetToolName: String

    /// Stable identity.
    public var id: String { "\(property.rawValue)|\(targetToolName)" }

    /// Creates a skip.
    public init(property: ToolPresetProperty, targetToolName: String) {
        self.property = property
        self.targetToolName = targetToolName
    }

    /// A localized sentence naming the property and the reason.
    public var message: String {
        String(
            format: NSLocalizedString(
                "%1$@ was not applied: a %2$@ has none.",
                comment: "Apply-mode skip. %1$@ is a property name, %2$@ is a tool name"
            ),
            property.displayName,
            targetToolName
        )
    }
}

/// What Apply mode would write onto one markup, and what it would leave alone.
public struct ToolPresetApplicationPlan: Hashable, Sendable {

    /// The properties that genuinely overlap and will be written.
    public let applicable: Set<ToolPresetProperty>
    /// The properties the preset carried that the target cannot take, each with a reason.
    public let skipped: [ToolPresetSkip]

    /// Creates a plan.
    public init(applicable: Set<ToolPresetProperty>, skipped: [ToolPresetSkip]) {
        self.applicable = applicable
        self.skipped = skipped
    }

    /// Whether anything at all would be written.
    public var isEmpty: Bool { applicable.isEmpty }

    /// Whether any writable property changes a number.
    public var recomputes: Bool { applicable.contains { $0.feedsTheMaths } }
}

/// The rule for what a preset may write onto a markup that already exists.
///
/// # Why this is a type and not four `if`s inside the apply loop
///
/// Apply mode has three hard rules, and this file is the second and third
/// of them made checkable:
///
/// - **Geometry is never touched.** There is no ``ToolPresetProperty`` for it. Not "we do not
///   set it" — there is no name for it to be set through, so no later edit can add one by
///   accident. Moving a markup is Select's job.
/// - **An incompatible preset applies only what genuinely overlaps, and says what it
///   skipped.** A Length preset dropped on an Area writes the colour, the subject and the
///   status, and reports that the depth and the wall height were not written and why. The
///   alternative — refusing outright — throws away the four fifths of the preset that were
///   perfectly applicable; the worse alternative is half-applying in silence.
///
/// The tool itself is never applied. A preset cannot turn an Area into a Length: that is not a
/// property change, it is a different measurement of a shape that was drawn to be an area, and
/// the number it produced would be meaningless. So a mismatched tool is the *reason* for a
/// skip, never a thing that gets written.
public enum ToolPresetApplicability {

    /// What one preset may write onto one target.
    ///
    /// - Parameters:
    ///   - preset: the armed preset.
    ///   - targetKind: the target markup's family.
    ///   - targetTool: the measurement tool that produced the target, or `nil`.
    public static func plan(
        preset: ToolPresetSummary,
        targetKind: MarkupKind,
        targetTool: MeasurementKind?
    ) -> ToolPresetApplicationPlan {
        let toolName = targetTool?.displayName ?? targetKind.displayName
        var applicable: Set<ToolPresetProperty> = []
        var skipped: [ToolPresetSkip] = []

        // The universal five. Every markup has ink, a subject, a label, a status and a row of
        // ledger cells, so these overlap whatever the preset was made for. This is the "applies
        // only what genuinely overlaps" half of the rule, and it is most of a re-classification
        // pass: "these forty areas are all Foundation" changes nothing else.
        applicable.insert(.color)
        // A subject is written only when the preset has one. A name-only preset used to
        // blank the subject of every markup it was applied over — the very subjects they were
        // grouped by — while the label beside it was guarded exactly like this (BH-115).
        if !preset.defaultSubject.isEmpty { applicable.insert(.subject) }
        if !preset.labelPattern.isEmpty { applicable.insert(.label) }
        if preset.defaultStatus != .none { applicable.insert(.status) }
        if !preset.customDefaults.isEmpty { applicable.insert(.customValues) }

        // The Count symbol is deliberately absent from ``ToolPresetProperty``. A markup has
        // nowhere to keep one: `MarkupRecord` is a frozen contract and has no symbol field, and
        // the count glyph is a tool option resolved at draw time. Adding a case that could never
        // be written would put a name in the report for something the product does not store.

        let defaults = preset.measurementDefaults
        // Each measurement parameter is offered only when the preset actually carries one:
        // reporting that a preset with no depth "skipped the depth" is noise in the one place
        // noise is expensive, and it would make every ordinary apply look like a failure.
        consider(
            .depth,
            carried: defaults.depth != nil,
            accepted: acceptsDepth(targetTool),
            toolName: toolName,
            into: &applicable,
            skipped: &skipped
        )
        consider(
            .wallHeight,
            carried: defaults.wallHeight != nil,
            accepted: acceptsWallHeight(targetTool),
            toolName: toolName,
            into: &applicable,
            skipped: &skipped
        )
        consider(
            .wallHeightAtEnd,
            carried: defaults.wallHeightAtEnd != nil,
            accepted: acceptsWallHeight(targetTool),
            toolName: toolName,
            into: &applicable,
            skipped: &skipped
        )
        consider(
            .slope,
            carried: defaults.slopePercent != nil,
            accepted: acceptsSlope(targetTool),
            toolName: toolName,
            into: &applicable,
            skipped: &skipped
        )
        consider(
            .slopeAzimuth,
            carried: defaults.slopeAzimuthDegrees != nil,
            accepted: acceptsSlope(targetTool),
            toolName: toolName,
            into: &applicable,
            skipped: &skipped
        )
        consider(
            .volumeDepthReference,
            carried: defaults.volumeDepthReference != nil,
            accepted: targetTool == .volume,
            toolName: toolName,
            into: &applicable,
            skipped: &skipped
        )
        // The two policies always have a value, so "carried" is whether the preset departs from
        // the engine's own default. A preset that never touched them must not silently reset a
        // markup somebody configured by hand.
        consider(
            .cutoutPolicy,
            carried: defaults.cutoutPolicy != .subtractFromArea,
            accepted: acceptsCutoutPolicy(targetTool),
            toolName: toolName,
            into: &applicable,
            skipped: &skipped
        )
        consider(
            .perimeterPolicy,
            carried: defaults.perimeterPolicy != .outerOnly,
            accepted: acceptsPerimeterPolicy(targetTool),
            toolName: toolName,
            into: &applicable,
            skipped: &skipped
        )

        return ToolPresetApplicationPlan(
            applicable: applicable,
            skipped: skipped.sorted { $0.property.rawValue < $1.property.rawValue }
        )
    }

    private static func consider(
        _ property: ToolPresetProperty,
        carried: Bool,
        accepted: Bool,
        toolName: String,
        into applicable: inout Set<ToolPresetProperty>,
        skipped: inout [ToolPresetSkip]
    ) {
        guard carried else { return }
        if accepted {
            applicable.insert(property)
        } else {
            skipped.append(ToolPresetSkip(property: property, targetToolName: toolName))
        }
    }

    /// Volume is the one tool that extrudes an area by a depth.
    static func acceptsDepth(_ tool: MeasurementKind?) -> Bool { tool == .volume }

    /// Wall Area is the one tool that multiplies a run by a height.
    static func acceptsWallHeight(_ tool: MeasurementKind?) -> Bool { tool == .wallArea }

    /// The tools whose result changes when the plane tilts.
    ///
    /// The two true-sloped tools by definition, and Volume because a perpendicular thickness
    /// over a tilted plane is `A_plan * sqrt(1 + s^2) * t` (ADR-0004 §2). Everything else
    /// measures the plan, and a slope written onto it would be stored and never used — which
    /// looks exactly like a slope that was applied and did nothing.
    static func acceptsSlope(_ tool: MeasurementKind?) -> Bool {
        switch tool {
        case .trueSlopedLength, .trueSlopedArea, .volume: return true
        default: return false
        }
    }

    /// Cutouts subtract from something with an area.
    ///
    /// Not a cutout itself: a cutout's area has the dimension of an area, but its calculator
    /// fixes both policies and never reads either, so a policy "applied" to one did nothing
    /// and was reported as recomputed (BH-458).
    static func acceptsCutoutPolicy(_ tool: MeasurementKind?) -> Bool {
        guard let tool, !tool.isCutout else { return false }
        switch tool.dimension {
        case .area, .volume: return true
        default: return false
        }
    }

    /// A perimeter policy needs a boundary to have a policy about.
    static func acceptsPerimeterPolicy(_ tool: MeasurementKind?) -> Bool {
        guard let tool, !tool.isCutout else { return false }
        if tool == .perimeter { return true }
        switch tool.dimension {
        case .area, .volume: return true
        default: return false
        }
    }
}
