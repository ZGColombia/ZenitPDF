import Foundation

/// A point in DXF drawing units (model space, y up).
public struct DXFPoint: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// One drawn primitive, already in model space (blocks expanded).
public enum DXFShape: Sendable, Equatable {
    /// A polyline; `bulges[i]` bends the segment from vertex i to i+1 (DXF bulge = tan(θ/4)).
    case polyline(points: [DXFPoint], bulges: [Double], closed: Bool)
    /// A circular arc, angles in radians, counter-clockwise from `start` to `end`.
    case arc(center: DXFPoint, radius: Double, start: Double, end: Double)
    case circle(center: DXFPoint, radius: Double)
    /// An elliptical arc: `majorAxis` is the endpoint of the major axis relative to the centre,
    /// `ratio` the minor/major ratio, parameters in radians.
    case ellipse(center: DXFPoint, majorAxis: DXFPoint, ratio: Double, start: Double, end: Double)
    /// A line of text: `rotation` is the direction its baseline runs in model space, radians
    /// counter-clockwise from +x, after every placement and object coordinate system.
    ///
    /// A text placed mirrored (extrusion (0, 0, −1), or an INSERT with a negative scale) keeps
    /// its position and the direction of its baseline, but its glyphs cannot be mirrored: this
    /// shape has no handedness, so they are drawn reading forwards along that baseline.
    case text(position: DXFPoint, height: Double, rotation: Double, string: String)
}

/// A shape on a layer.
public struct DXFEntity: Sendable, Equatable {
    public var layer: String
    public var shape: DXFShape
}

/// The drawing's linear unit, from `$INSUNITS`.
public enum DXFUnit: Int, Sendable, CaseIterable {
    case unitless = 0, inches = 1, feet = 2, miles = 3, millimetres = 4, centimetres = 5, metres = 6,
         kilometres = 7, microinches = 8, mils = 9, yards = 10, angstroms = 11, nanometres = 12,
         microns = 13, decimetres = 14, decametres = 15, hectometres = 16

    /// Millimetres per drawing unit, exactly as the unit is defined; `nil` for unitless.
    public var millimetres: Double? {
        switch self {
        case .unitless: return nil
        case .inches: return 25.4
        case .feet: return 304.8
        case .miles: return 1_609_344
        case .millimetres: return 1
        case .centimetres: return 10
        case .metres: return 1_000
        case .kilometres: return 1_000_000
        case .microinches: return 0.000_025_4
        case .mils: return 0.025_4
        case .yards: return 914.4
        case .angstroms: return 0.000_000_1
        case .nanometres: return 0.000_001
        case .microns: return 0.001
        case .decimetres: return 100
        case .decametres: return 10_000
        case .hectometres: return 100_000
        }
    }

    public var name: String {
        switch self {
        case .unitless: return "unitless"
        case .inches: return "inches"
        case .feet: return "feet"
        case .miles: return "miles"
        case .millimetres: return "millimetres"
        case .centimetres: return "centimetres"
        case .metres: return "metres"
        case .kilometres: return "kilometres"
        case .microinches: return "microinches"
        case .mils: return "mils"
        case .yards: return "yards"
        case .angstroms: return "ångströms"
        case .nanometres: return "nanometres"
        case .microns: return "microns"
        case .decimetres: return "decimetres"
        case .decametres: return "decametres"
        case .hectometres: return "hectometres"
        }
    }
}

/// A parsed drawing: its unit, layers in table order, and every entity with blocks expanded.
public struct DXFDrawing: Sendable, Equatable {
    public var unit: DXFUnit
    /// `$INSUNITS` was present in the header (absent reads as unitless, never guessed).
    public var unitDeclared: Bool
    public var layers: [String]
    public var entities: [DXFEntity]
    /// Entity types the reader met and does not draw, with counts (HATCH fills, 3D solids…).
    public var skipped: [String: Int]
}

/// Why a DXF was refused.
public enum DXFError: Error, Equatable, Sendable, CustomStringConvertible {
    case binaryDXF
    case tooLarge(bytes: Int, limit: Int)
    case notDXF
    case tooManyEntities(limit: Int)
    /// More points of geometry and text than ``DXFLimits/maximumPoints`` once blocks are expanded.
    case tooManyPoints(limit: Int)
    case blockNestingTooDeep(limit: Int)
    case nothingToDraw

    public var description: String {
        switch self {
        case .binaryDXF: return "This is a binary DXF; Zenit PDF reads the text form. Save it as an ASCII DXF."
        case let .tooLarge(bytes, limit): return "The file is \(bytes) bytes; Zenit PDF reads DXF files up to \(limit) bytes."
        case .notDXF: return "The file is not a DXF drawing."
        case let .tooManyEntities(limit): return "The drawing has more than \(limit) entities once its blocks are expanded."
        case let .tooManyPoints(limit): return "The drawing has more than \(limit) points of geometry and text once its blocks are expanded."
        case let .blockNestingTooDeep(limit): return "Blocks are nested more than \(limit) deep."
        case .nothingToDraw: return "The drawing has nothing Zenit PDF can draw in model space."
        }
    }
}

/// The counter-clockwise sweep from `start` to `end` in (0, 2π], or 0 for a non-finite angle. A
/// hostile file's angle of 1e306 must not turn into a loop that never ends or a step count that
/// overflows.
func dxfSweep(from start: Double, to end: Double) -> Double {
    guard start.isFinite, end.isFinite else { return 0 }
    var sweep = (end - start).truncatingRemainder(dividingBy: 2 * .pi)
    if sweep <= 0 { sweep += 2 * .pi }
    return sweep.isFinite ? sweep : 0
}

/// An angle reduced to [0, 2π), so cos/sin stay meaningful for any input; 0 when not finite.
func dxfAngle(_ angle: Double) -> Double {
    guard angle.isFinite else { return 0 }
    let reduced = angle.truncatingRemainder(dividingBy: 2 * .pi)
    return reduced < 0 ? reduced + 2 * .pi : reduced
}
