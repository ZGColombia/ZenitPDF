import Foundation

/// The measurement and snapping tools that have no honest SF Symbol.
///
/// Every glyph in this set is drawn from scratch as vector geometry in `ZPDFIconGeometry`.
/// Nothing here is traced, copied or adapted from another product's artwork; each one is a
/// plain geometric construction of the thing it measures.
///
/// Generic actions — select, pan, search, export and friends — deliberately do *not* live here.
/// They use SF Symbols through `ZPDFSymbol`, so Zenit keeps the system's visual language where
/// the system already has an answer.
public enum ZPDFIconKind: String, CaseIterable, Sendable, Hashable {
    /// Single straight distance between two points.
    case length
    /// Chained segments, total run.
    case polylength
    /// Closed outline length.
    case perimeter
    /// Free-form closed region.
    case area
    /// Axis-aligned rectangular region.
    case rectangleArea
    /// Elliptical region.
    case ellipseArea
    /// A region subtracted from a parent region.
    case cutout
    /// Region extruded by a depth.
    case volume
    /// Wall face: run multiplied by height.
    case wallArea
    /// Tally of discrete items.
    case count
    /// Rise over run.
    case slope
    /// Centre-to-edge distance.
    case radius
    /// Edge-to-edge distance through the centre.
    case diameter
    /// Angle between two rays.
    case angle
    /// Curved segment length.
    case arc
    /// Set the drawing scale from a known distance.
    case calibrate
    /// Snap to geometry recovered from the page's vector content.
    case vectorSnap
    /// Snap to the working grid.
    case gridSnap
    /// Snap to existing Zenit markup.
    case markupSnap

    /// VoiceOver description. Also used as the rendered `NSImage`'s accessibility description.
    public var accessibilityLabel: String {
        switch self {
        case .length:
            return NSLocalizedString("Length", comment: "Measurement tool: straight distance between two points")
        case .polylength:
            return NSLocalizedString("Polylength", comment: "Measurement tool: total length of chained segments")
        case .perimeter:
            return NSLocalizedString("Perimeter", comment: "Measurement tool: length around a closed outline")
        case .area:
            return NSLocalizedString("Area", comment: "Measurement tool: free-form closed region")
        case .rectangleArea:
            return NSLocalizedString("Rectangle Area", comment: "Measurement tool: rectangular region")
        case .ellipseArea:
            return NSLocalizedString("Ellipse Area", comment: "Measurement tool: elliptical region")
        case .cutout:
            return NSLocalizedString("Cutout", comment: "Measurement tool: region subtracted from a parent region")
        case .volume:
            return NSLocalizedString("Volume", comment: "Measurement tool: region extruded by a depth")
        case .wallArea:
            return NSLocalizedString("Wall Area", comment: "Measurement tool: wall face area from run and height")
        case .count:
            return NSLocalizedString("Count", comment: "Measurement tool: tally of discrete items")
        case .slope:
            return NSLocalizedString("Slope", comment: "Measurement tool: rise over run")
        case .radius:
            return NSLocalizedString("Radius", comment: "Measurement tool: centre to edge distance")
        case .diameter:
            return NSLocalizedString("Diameter", comment: "Measurement tool: edge to edge distance through the centre")
        case .angle:
            return NSLocalizedString("Angle", comment: "Measurement tool: angle between two rays")
        case .arc:
            return NSLocalizedString("Arc", comment: "Measurement tool: curved segment length")
        case .calibrate:
            return NSLocalizedString("Calibrate Scale", comment: "Tool: set the drawing scale from a known distance")
        case .vectorSnap:
            return NSLocalizedString("Vector Snap", comment: "Snapping mode: snap to vector geometry in the page")
        case .gridSnap:
            return NSLocalizedString("Grid Snap", comment: "Snapping mode: snap to the working grid")
        case .markupSnap:
            return NSLocalizedString("Markup Snap", comment: "Snapping mode: snap to existing markup")
        }
    }

    /// Short help-tag text shown on hover.
    public var helpText: String {
        switch self {
        case .length:
            return NSLocalizedString("Measure a straight distance", comment: "Help tag for the Length tool")
        case .polylength:
            return NSLocalizedString("Measure a chain of segments", comment: "Help tag for the Polylength tool")
        case .perimeter:
            return NSLocalizedString("Measure around a closed outline", comment: "Help tag for the Perimeter tool")
        case .area:
            return NSLocalizedString("Measure a free-form region", comment: "Help tag for the Area tool")
        case .rectangleArea:
            return NSLocalizedString("Measure a rectangular region", comment: "Help tag for the Rectangle Area tool")
        case .ellipseArea:
            return NSLocalizedString("Measure an elliptical region", comment: "Help tag for the Ellipse Area tool")
        case .cutout:
            return NSLocalizedString("Subtract a region from a measurement", comment: "Help tag for the Cutout tool")
        case .volume:
            return NSLocalizedString("Measure a region with a depth", comment: "Help tag for the Volume tool")
        case .wallArea:
            return NSLocalizedString("Measure a wall face from run and height", comment: "Help tag for the Wall Area tool")
        case .count:
            return NSLocalizedString("Tally discrete items", comment: "Help tag for the Count tool")
        case .slope:
            return NSLocalizedString("Measure rise over run", comment: "Help tag for the Slope tool")
        case .radius:
            return NSLocalizedString("Measure from centre to edge", comment: "Help tag for the Radius tool")
        case .diameter:
            return NSLocalizedString("Measure across through the centre", comment: "Help tag for the Diameter tool")
        case .angle:
            return NSLocalizedString("Measure the angle between two rays", comment: "Help tag for the Angle tool")
        case .arc:
            return NSLocalizedString("Measure a curved segment", comment: "Help tag for the Arc tool")
        case .calibrate:
            return NSLocalizedString("Set the scale from a known distance", comment: "Help tag for the Calibrate tool")
        case .vectorSnap:
            return NSLocalizedString("Snap to page vector geometry", comment: "Help tag for Vector Snap")
        case .gridSnap:
            return NSLocalizedString("Snap to the working grid", comment: "Help tag for Grid Snap")
        case .markupSnap:
            return NSLocalizedString("Snap to existing markup", comment: "Help tag for Markup Snap")
        }
    }
}
