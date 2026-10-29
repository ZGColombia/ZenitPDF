import Foundation

/// The twenty-two Zenit measurement tools.
///
/// The order of the cases is the order the measurement palette presents them in.
public enum MeasurementKind: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {

    /// A single straight segment between two points.
    case length
    /// A length annotated with dimension witness lines and extension ticks.
    case dimension
    /// A multi-segment open polyline length.
    case polylength
    /// The closed outline length of a shape.
    case perimeter
    /// A freeform polygon area.
    case area
    /// An axis-aligned or rotated rectangle area.
    case rectangleArea
    /// An ellipse area.
    case ellipseArea
    /// A polygonal opening subtracted from a parent area.
    case polygonCutout
    /// An elliptical opening subtracted from a parent area.
    case ellipseCutout
    /// A net area multiplied by a depth.
    case volume
    /// A length or perimeter multiplied by a wall height, minus openings.
    case wallArea
    /// A group of individual counted points sharing one symbol.
    case count
    /// The radius of a circle.
    case radius
    /// The diameter of a circle.
    case diameter
    /// A circle fitted through three non-collinear points.
    case threePointCircle
    /// The angle between two rays sharing a vertex.
    case angle
    /// A rise-over-run slope.
    case slope
    /// A per-segment rise or drop applied to a polyline.
    case riseDrop
    /// A plan length corrected for slope.
    case trueSlopedLength
    /// A plan area corrected for slope.
    case trueSlopedArea
    /// The length of a circular arc.
    case arcLength
    /// An overlay-only measurement that is never written to the project or the PDF.
    case temporaryMeasure

    /// Stable identity.
    public var id: String { rawValue }

    /// The dimension of the tool's primary result.
    public var dimension: QuantityDimension {
        switch self {
        case .length, .dimension, .polylength, .perimeter, .radius, .diameter,
             .threePointCircle, .riseDrop, .trueSlopedLength, .arcLength, .temporaryMeasure:
            return .length
        case .area, .rectangleArea, .ellipseArea, .polygonCutout, .ellipseCutout,
             .wallArea, .trueSlopedArea:
            return .area
        case .volume:
            return .volume
        case .count:
            return .count
        case .angle:
            return .angle
        case .slope:
            return .ratio
        }
    }

    /// The field the ledger shows as the tool's headline value.
    ///
    /// An area's headline is its **net** area, the number the ledger's Plan Area column reads
    /// (ADR-0016): the canvas pill, the annotated export, a snippet, VoiceOver, AppleScript and
    /// the clipboard all print this field, and they used to print the gross outline, so a slab
    /// with an opening read 100 m² on the drawing beside 84 m² in the ledger (X-037). An ellipse's
    /// net area equals its gross area. A cutout keeps the gross field: its own result carries
    /// `planArea` and no `netArea`, because the parent owns the subtraction.
    public var primaryField: MeasurementField {
        switch self {
        case .length, .dimension, .polylength, .temporaryMeasure: return .planLength
        case .perimeter: return .perimeter
        case .area, .rectangleArea, .ellipseArea: return .netArea
        case .polygonCutout, .ellipseCutout: return .planArea
        case .volume: return .volume
        case .wallArea: return .wallArea
        case .count: return .count
        case .radius, .threePointCircle: return .radius
        case .diameter: return .diameter
        case .angle: return .angle
        case .slope: return .slopeRatio
        case .riseDrop: return .rise
        case .trueSlopedLength: return .trueLength
        case .trueSlopedArea: return .trueArea
        case .arcLength: return .arcLength
        }
    }

    /// Whether the tool subtracts from a parent measurement rather than standing alone.
    public var isCutout: Bool { self == .polygonCutout || self == .ellipseCutout }

    /// Whether the result is discarded when the document closes.
    public var isTemporary: Bool { self == .temporaryMeasure }

    /// Whether the tool reads one radius off a drawn circle, which only a uniform scale allows.
    ///
    /// Under separate X and Y scales a circle on the page is an ellipse in real units, so it has
    /// no single radius, and the engine refuses rather than pick the x axis (L-102). The tool says
    /// so the moment it is armed on such a sheet, instead of accepting two clicks and failing.
    public var needsUniformScale: Bool { self == .radius || self == .diameter || self == .threePointCircle }

    /// The minimum number of placed points before the tool can be committed.
    public var minimumPointCount: Int {
        switch self {
        case .count: return 1
        // Temporary Measure is a scratch *length*: at one point the calculator has no segment,
        // returns a result with no fields, and promoting that empty entry later throws and
        // loses it (BH-767).
        case .length, .dimension, .polylength, .radius, .diameter, .slope,
             .trueSlopedLength, .riseDrop, .ellipseArea, .ellipseCutout,
             .wallArea, .temporaryMeasure:
            return 2
        // A Rectangle Area is three placed corners: two are an *edge*, the third its depth. Two
        // placed points are also what a drag's opposite corners look like, and at two the
        // presenter could not tell them apart: two clicks along a slanted edge and Return
        // committed the edge's axis-aligned bounding box (BH-257, T-055). The drag never needs
        // the two-point form: the canvas and the input machine hand the presenter all four
        // corners of the dragged box before the commit.
        case .rectangleArea:
            return 3
        // Volume is an *area* times a depth, so it needs an outline. At two points the
        // presenter built point geometry, `AreaCalculator` refused it, and the commit was
        // dropped — the same silence as the missing depth and part of the same defect
        // — a commit must never vanish in silence. Wall Area stays at two: its base is a run, and the calculator
        // accepts a polyline as readily as a polygon.
        // Arc Length is the same defect as Volume was: `ArcLengthCalculator` needs three
        // points to fit an arc and refused two with `unsupportedGeometry`, after the commit had
        // already been allowed (BH-270).
        case .perimeter, .area, .polygonCutout, .trueSlopedArea, .volume,
             .angle, .threePointCircle, .arcLength:
            return 3
        }
    }

    /// A localized tool name for the palette, menus and VoiceOver.
    public var displayName: String {
        switch self {
        case .length: return NSLocalizedString("Length", comment: "Measurement tool name")
        case .dimension: return NSLocalizedString("Dimension", comment: "Measurement tool name")
        case .polylength: return NSLocalizedString("Polylength", comment: "Measurement tool name")
        case .perimeter: return NSLocalizedString("Perimeter", comment: "Measurement tool name")
        case .area: return NSLocalizedString("Area", comment: "Measurement tool name")
        case .rectangleArea: return NSLocalizedString("Rectangle Area", comment: "Measurement tool name")
        case .ellipseArea: return NSLocalizedString("Ellipse Area", comment: "Measurement tool name")
        case .polygonCutout: return NSLocalizedString("Polygon Cutout", comment: "Measurement tool name")
        case .ellipseCutout: return NSLocalizedString("Ellipse Cutout", comment: "Measurement tool name")
        case .volume: return NSLocalizedString("Volume", comment: "Measurement tool name")
        case .wallArea: return NSLocalizedString("Wall Area", comment: "Measurement tool name")
        case .count: return NSLocalizedString("Count", comment: "Measurement tool name")
        case .radius: return NSLocalizedString("Radius", comment: "Measurement tool name")
        case .diameter: return NSLocalizedString("Diameter", comment: "Measurement tool name")
        case .threePointCircle: return NSLocalizedString("Three-Point Circle", comment: "Measurement tool name")
        case .angle: return NSLocalizedString("Angle", comment: "Measurement tool name")
        case .slope: return NSLocalizedString("Slope", comment: "Measurement tool name")
        case .riseDrop: return NSLocalizedString("Rise/Drop", comment: "Measurement tool name")
        case .trueSlopedLength: return NSLocalizedString("True Sloped Length", comment: "Measurement tool name")
        case .trueSlopedArea: return NSLocalizedString("True Sloped Area", comment: "Measurement tool name")
        case .arcLength: return NSLocalizedString("Arc Length", comment: "Measurement tool name")
        case .temporaryMeasure: return NSLocalizedString("Temporary Measure", comment: "Measurement tool name")
        }
    }

    /// A localized one-line hint shown under the tool name and as the accessibility hint.
    public var shortHelp: String {
        switch self {
        case .length: return NSLocalizedString("Measure a straight distance between two points.", comment: "Measurement tool help")
        case .dimension: return NSLocalizedString("Place a dimension line with witness ticks.", comment: "Measurement tool help")
        case .polylength: return NSLocalizedString("Add segments to measure a running length.", comment: "Measurement tool help")
        case .perimeter: return NSLocalizedString("Measure the outline length of a closed shape.", comment: "Measurement tool help")
        case .area: return NSLocalizedString("Trace a polygon to measure its area.", comment: "Measurement tool help")
        case .rectangleArea: return NSLocalizedString("Drag a rectangle to measure its area.", comment: "Measurement tool help")
        case .ellipseArea: return NSLocalizedString("Drag an ellipse to measure its area.", comment: "Measurement tool help")
        case .polygonCutout: return NSLocalizedString("Subtract a polygonal opening from an area.", comment: "Measurement tool help")
        case .ellipseCutout: return NSLocalizedString("Subtract an elliptical opening from an area.", comment: "Measurement tool help")
        case .volume: return NSLocalizedString("Multiply a net area by a depth.", comment: "Measurement tool help")
        case .wallArea: return NSLocalizedString("Multiply a length by a wall height, minus openings.", comment: "Measurement tool help")
        case .count: return NSLocalizedString("Click each item to build a running count.", comment: "Measurement tool help")
        case .radius: return NSLocalizedString("Measure a radius from centre to edge.", comment: "Measurement tool help")
        case .diameter: return NSLocalizedString("Measure a diameter across a circle.", comment: "Measurement tool help")
        case .threePointCircle: return NSLocalizedString("Fit a circle through three points on an arc.", comment: "Measurement tool help")
        case .angle: return NSLocalizedString("Measure the angle between two rays.", comment: "Measurement tool help")
        case .slope: return NSLocalizedString("Measure rise over run.", comment: "Measurement tool help")
        case .riseDrop: return NSLocalizedString("Apply a rise or drop to each segment.", comment: "Measurement tool help")
        case .trueSlopedLength: return NSLocalizedString("Correct a plan length for slope.", comment: "Measurement tool help")
        case .trueSlopedArea: return NSLocalizedString("Correct a plan area for slope.", comment: "Measurement tool help")
        case .arcLength: return NSLocalizedString("Measure the length along a circular arc.", comment: "Measurement tool help")
        case .temporaryMeasure: return NSLocalizedString("Measure without saving anything to the project.", comment: "Measurement tool help")
        }
    }
}
