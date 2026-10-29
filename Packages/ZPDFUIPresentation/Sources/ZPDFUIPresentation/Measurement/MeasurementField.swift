import Foundation

/// A named output of the measurement engine.
///
/// One tool produces several fields; the ledger promotes each field to its own column
/// so that, for example, plan area and true area are never conflated.
public enum MeasurementField: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {

    /// Number of counted items.
    case count
    /// Length measured in the plane of the drawing.
    case planLength
    /// Length corrected for slope.
    case trueLength
    /// Closed outline length.
    case perimeter
    /// Area measured in the plane of the drawing, before cutouts — the outline, which the
    /// ledger calls Gross Area (ADR-0018).
    case planArea
    /// ``planArea`` minus the union of its cutouts — the number the ledger's Plan Area column
    /// reads (ADR-0016), and an area tool's headline.
    case netArea
    /// Area corrected for slope.
    case trueArea
    /// Wall area, that is length or perimeter times wall height, minus openings.
    case wallArea
    /// Net area times depth.
    case volume
    /// Vertical component of a slope.
    case rise
    /// Horizontal component of a slope.
    case run
    /// Dimensionless `rise / run`.
    case slopeRatio
    /// `100 × rise / run`.
    case slopePercent
    /// `atan(rise / run)`, in radians.
    case slopeAngle
    /// Depth used by the Volume tool.
    case depth
    /// Height used by the Wall Area tool.
    case height
    /// Circle radius.
    case radius
    /// Circle diameter.
    case diameter
    /// Full circle circumference.
    case circumference
    /// Length along an arc.
    case arcLength
    /// Angle between two rays, in radians.
    case angle

    /// Stable identity.
    public var id: String { rawValue }

    /// The dimension of the field's value.
    public var dimension: QuantityDimension {
        switch self {
        case .count: return .count
        case .planLength, .trueLength, .perimeter, .rise, .run, .depth, .height,
             .radius, .diameter, .circumference, .arcLength:
            return .length
        case .planArea, .netArea, .trueArea, .wallArea: return .area
        case .volume: return .volume
        case .slopeRatio, .slopePercent: return .ratio
        case .slopeAngle, .angle: return .angle
        }
    }

    /// A localized field name for the inspector, the ledger header and VoiceOver.
    ///
    /// The two area fields take the ledger's column names, so a field and the column that reads
    /// it never disagree: ``netArea`` is "Plan Area" and the outline ``planArea`` is "Gross Area"
    /// (ADR-0016, ADR-0018). The gross field used to be "Plan Area", so the Inspector and the
    /// caption picker gave the ledger's name for the net number to the gross one (X-037).
    public var displayName: String {
        switch self {
        case .count: return NSLocalizedString("Count", comment: "Measurement field name")
        case .planLength: return NSLocalizedString("Plan Length", comment: "Measurement field name")
        case .trueLength: return NSLocalizedString("True Length", comment: "Measurement field name")
        case .perimeter: return NSLocalizedString("Perimeter", comment: "Measurement field name")
        case .planArea: return NSLocalizedString("Gross Area", comment: "Measurement field name: the outline area before cutouts, as the ledger column is called")
        case .netArea: return NSLocalizedString("Plan Area", comment: "Measurement field name: the area after cutouts, as the ledger column is called")
        case .trueArea: return NSLocalizedString("True Area", comment: "Measurement field name")
        case .wallArea: return NSLocalizedString("Wall Area", comment: "Measurement field name")
        case .volume: return NSLocalizedString("Volume", comment: "Measurement field name")
        case .rise: return NSLocalizedString("Rise", comment: "Measurement field name")
        case .run: return NSLocalizedString("Run", comment: "Measurement field name")
        case .slopeRatio: return NSLocalizedString("Slope Ratio", comment: "Measurement field name")
        case .slopePercent: return NSLocalizedString("Slope Percent", comment: "Measurement field name")
        case .slopeAngle: return NSLocalizedString("Slope Angle", comment: "Measurement field name")
        case .depth: return NSLocalizedString("Depth", comment: "Measurement field name")
        case .height: return NSLocalizedString("Height", comment: "Measurement field name")
        case .radius: return NSLocalizedString("Radius", comment: "Measurement field name")
        case .diameter: return NSLocalizedString("Diameter", comment: "Measurement field name")
        case .circumference: return NSLocalizedString("Circumference", comment: "Measurement field name")
        case .arcLength: return NSLocalizedString("Arc Length", comment: "Measurement field name")
        case .angle: return NSLocalizedString("Angle", comment: "Measurement field name")
        }
    }
}

/// A warning the measurement engine attached to a result.
///
/// Warnings are surfaced with an icon *and* text, never colour alone.
public enum MeasurementWarningSummary: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {

    /// The polygon crosses itself.
    case selfIntersecting
    /// The geometry collapsed to zero area or zero length.
    case degenerateGeometry
    /// Three points used for a circle are almost collinear.
    case nearlyCollinear
    /// A slope run of zero, so the slope is vertical rather than infinite.
    case verticalRun
    /// The markup spans more than one Scale Region.
    case crossesScaleRegions
    /// No scale has been calibrated for the page.
    case missingScale
    /// The markup was measured against an older scale version.
    case staleScaleVersion
    /// A cutout lies partly outside the area it is subtracted from; only the part inside is
    /// subtracted. The engine accepts it with this warning (ADR-0015, QUALITY_BAR 2.5). A cutout
    /// with no overlap at all is ``cutoutDoesNotOverlapParent``.
    case cutoutOutsideParent
    /// The cutout being drawn shares no area with the area it is subtracted from. The engine
    /// refuses such a cutout, so Finish refuses it too and says why (X-cutout-ui). Never on a
    /// stored markup: only the measurement presenter raises it, live, from the engine's verdict.
    case cutoutDoesNotOverlapParent
    /// The page has no vector content, so Vector Snap is unavailable.
    case vectorSnapUnavailable
    /// The outline has too many points to be checked for self-crossings, so its area was
    /// measured as drawn (ADR-0018).
    case selfIntersectionUnchecked
    /// A circle tool is armed on a sheet whose X and Y scales differ, where a drawn circle has no
    /// single radius (L-102). Never on a stored markup: only the measurement presenter raises it,
    /// from the armed tool and the sheet's scale, before the first click.
    case circleNeedsUniformScale
    /// A circle tool was clicked on the part of a sheet whose scale has separate X and Y — outside
    /// a uniform Scale Region on an X/Y sheet, or inside an X/Y region on a uniform one — while
    /// another part of the sheet can measure circles (L-102). Raised only by the measurement
    /// presenter, at the refused click.
    case circleNeedsUniformScaleHere

    /// Stable identity.
    public var id: String { rawValue }

    /// Whether the condition blocks committing the measurement.
    public var isBlocking: Bool {
        switch self {
        // A cutout the engine refuses has no number to commit, like a shape with no extent.
        case .degenerateGeometry, .missingScale, .cutoutDoesNotOverlapParent: return true
        // No circle can be committed on the sheet, or where it is drawn (L-102).
        case .circleNeedsUniformScale, .circleNeedsUniformScaleHere: return true
        // A partial overlap is a measurement the engine accepts and states correctly — the area
        // inside, subtracted — so it informs rather than blocks. It used to block, with copy
        // for the refusal ("must overlap"), on a value the engine had already accepted (X-044).
        case .selfIntersecting, .nearlyCollinear, .verticalRun, .crossesScaleRegions,
             .staleScaleVersion, .cutoutOutsideParent, .vectorSnapUnavailable, .selfIntersectionUnchecked:
            return false
        }
    }

    /// A localized message for the inspector banner and VoiceOver.
    public var message: String {
        switch self {
        case .selfIntersecting:
            return NSLocalizedString("This outline crosses itself. Fix the shape or let Zenit normalise it.", comment: "Measurement warning")
        case .degenerateGeometry:
            return NSLocalizedString("This shape has no measurable extent.", comment: "Measurement warning")
        case .nearlyCollinear:
            return NSLocalizedString("These three points are almost in a straight line, so no reliable circle fits them.", comment: "Measurement warning")
        case .verticalRun:
            return NSLocalizedString("The run is zero, so this slope is vertical.", comment: "Measurement warning")
        case .crossesScaleRegions:
            return NSLocalizedString("This markup crosses two Scale Regions. Choose which scale applies.", comment: "Measurement warning")
        case .missingScale:
            return NSLocalizedString("This page has no calibrated scale yet.", comment: "Measurement warning")
        case .staleScaleVersion:
            return NSLocalizedString("The scale changed after this measurement was taken.", comment: "Measurement warning")
        case .cutoutOutsideParent:
            return NSLocalizedString(
                "Part of a cutout lies outside this area. Only the part inside is subtracted.",
                comment: "Measurement warning: a cutout partly overlaps its parent area; the engine subtracts only the overlapping part"
            )
        case .cutoutDoesNotOverlapParent:
            return NSLocalizedString(
                "A cutout must overlap the area it is subtracted from.",
                comment: "Measurement refusal: the cutout being drawn shares no area with its parent area, so it cannot be finished"
            )
        case .vectorSnapUnavailable:
            return NSLocalizedString("Vector Snap is unavailable on this page because it has no vector content.", comment: "Measurement warning")
        case .selfIntersectionUnchecked:
            return NSLocalizedString("This outline has too many points to check whether it crosses itself. The area assumes it does not.", comment: "Measurement warning")
        case .circleNeedsUniformScale:
            return NSLocalizedString(
                "This sheet has separate X and Y scales, so a circle drawn on it has no single radius. Calibrate one scale for both directions to measure circles.",
                comment: "Measurement refusal: Radius, Diameter or Three-Point Circle armed on a sheet with a non-uniform scale"
            )
        case .circleNeedsUniformScaleHere:
            return NSLocalizedString(
                "Here the sheet has separate X and Y scales, so a circle drawn here has no single radius. Draw circles where the sheet has one scale for both directions.",
                comment: "Measurement refusal: a circle tool clicked where the scale is non-uniform, on a sheet where another part (a Scale Region or the sheet itself) has one scale"
            )
        }
    }

    /// SF Symbol name paired with the message so meaning never depends on colour.
    public var symbolName: String {
        isBlocking ? "exclamationmark.octagon" : "exclamationmark.triangle"
    }
}

/// One measured field, already resolved into both a raw quantity and display text.
///
/// The presenter owns the formatting so that the ledger, the inspector and the canvas
/// caption cannot drift apart.
public struct MeasurementFieldSummary: Codable, Hashable, Sendable, Identifiable {

    /// Stable identity, equal to ``field``.
    public var id: MeasurementField { field }
    /// Which output this is.
    public let field: MeasurementField
    /// The raw SI value. Never rounded.
    public var quantity: DecimalQuantity
    /// The value formatted in the active display unit and precision.
    public var displayText: String
    /// The symbol of the active display unit, empty for counts and ratios.
    public var displayUnitSymbol: String
    /// Whether the value came from another field rather than from the geometry, for
    /// example a true length derived from a plan length and a slope.
    public var isDerived: Bool
    /// A warning attached to this field, if any.
    public var warning: MeasurementWarningSummary?

    /// Creates a measured field summary.
    public init(
        field: MeasurementField,
        quantity: DecimalQuantity,
        displayText: String,
        displayUnitSymbol: String,
        isDerived: Bool = false,
        warning: MeasurementWarningSummary? = nil
    ) {
        self.field = field
        self.quantity = quantity
        self.displayText = displayText
        self.displayUnitSymbol = displayUnitSymbol
        self.isDerived = isDerived
        self.warning = warning
    }

    /// `"12.40 m"` — the value and its unit, ready for a caption.
    ///
    /// A feet-and-inches length — `12'-6"`, `6 1/2"` — already carries its own marks and reads
    /// alone, the rule the application's `QuantityFormatter.textWithUnit` and the exports apply
    /// (U-054). X-023: it used to append the unit too, so the Inspector, the live readout and
    /// the canvas pills printed `12'-6" ft`. A decimal foot (`12.50 ft`) keeps its symbol: only
    /// the inch mark that ends a feet-and-inches text says the unit already.
    public var displayTextWithUnit: String {
        guard !displayUnitSymbol.isEmpty, !carriesImperialMarks else { return displayText }
        return "\(displayText) \(displayUnitSymbol)"
    }

    /// Whether ``displayText`` is a length written in feet-and-inches marks: a foot or inch
    /// length whose text ends in the inch mark. Grouping marks (a Swiss `1'234.50`) never end a
    /// number, so a decimal text is never taken for one.
    private var carriesImperialMarks: Bool {
        quantity.dimension == .length
            && (displayUnitSymbol == LengthUnit.foot.symbol || displayUnitSymbol == LengthUnit.inch.symbol)
            && displayText.hasSuffix("\"")
    }

    /// A localized `"Plan Length, 12.40 metres"` string for VoiceOver.
    public var accessibilityValue: String {
        let format = NSLocalizedString(
            "%1$@, %2$@",
            comment: "VoiceOver value for a measured field: field name, formatted value with unit"
        )
        return String(format: format, field.displayName, displayTextWithUnit)
    }
}
