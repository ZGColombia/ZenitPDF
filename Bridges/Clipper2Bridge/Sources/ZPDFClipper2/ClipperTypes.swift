import CClipper2

/// Fill rule used to decide which regions of a polygon soup count as "inside".
public enum ClipperFillRule: Int32, Sendable, Hashable, CaseIterable {
    case evenOdd = 0
    case nonZero = 1
    case positive = 2
    case negative = 3

    var rawCValue: Int32 {
        switch self {
        case .evenOdd: ZPCLIPPER2_FILL_EVEN_ODD
        case .nonZero: ZPCLIPPER2_FILL_NON_ZERO
        case .positive: ZPCLIPPER2_FILL_POSITIVE
        case .negative: ZPCLIPPER2_FILL_NEGATIVE
        }
    }
}

/// Result of an exact point-in-polygon test.
public enum ClipperContainment: Sendable, Hashable, CaseIterable {
    case inside
    case outside
    /// The point lies exactly on an edge or vertex (after scaling).
    case onBoundary
}

/// Errors raised by the Clipper2 bridge. No `fatalError`, no trapping.
public enum ClipperError: Error, Equatable, Sendable {
    /// A required buffer pointer was null at the C boundary. Indicates a bridge bug.
    case nullArgument
    /// `scale` was not finite or not strictly positive.
    case invalidScale(Double)
    /// A negative path or vertex count reached the C boundary. Indicates a bridge bug.
    case invalidPathCount
    /// An input coordinate was NaN or infinite.
    case nonFiniteCoordinate
    /// A coordinate exceeded Clipper2's integer range once multiplied by `scale`.
    /// Lower `ClipperScale` or move the geometry closer to the origin.
    case coordinateOverflow
    /// An enum value could not be decoded at the C boundary. Indicates a bridge bug.
    case unsupportedOption
    /// Clipper2 itself raised a C++ exception (range/precision/undefined error).
    case clipperFailure
    /// Allocation failed inside the bridge or inside Clipper2.
    case outOfMemory
    /// The path lengths claimed more coordinates than the buffer holds. Refused at the
    /// C boundary before anything was read, and a bridge bug if it ever reaches Swift:
    /// this wrapper measures the buffer it passes (CR-141).
    case coordinateOverrun
    /// The C shim returned a status this Swift version does not know about.
    case unknownStatus(Int32)

    static func from(status: Int32, scale: Double) -> ClipperError? {
        switch status {
        case ZPCLIPPER2_OK: nil
        case ZPCLIPPER2_ERR_NULL_ARGUMENT: .nullArgument
        case ZPCLIPPER2_ERR_BAD_SCALE: .invalidScale(scale)
        case ZPCLIPPER2_ERR_BAD_PATH_COUNT: .invalidPathCount
        case ZPCLIPPER2_ERR_NON_FINITE: .nonFiniteCoordinate
        case ZPCLIPPER2_ERR_OVERFLOW: .coordinateOverflow
        case ZPCLIPPER2_ERR_BAD_ENUM: .unsupportedOption
        case ZPCLIPPER2_ERR_CLIPPER_THREW: .clipperFailure
        case ZPCLIPPER2_ERR_OUT_OF_MEMORY: .outOfMemory
        case ZPCLIPPER2_ERR_COORD_OVERRUN: .coordinateOverrun
        default: .unknownStatus(status)
        }
    }
}

/// The factor that converts caller-space `Double` coordinates into the exact
/// `Int64` lattice Clipper2 operates on.
///
/// ## Precision
///
/// Clipper2 is an exact integer clipper: it is robust precisely *because* it
/// never sees a floating-point coordinate. Everything crossing this bridge is
/// therefore quantised as `round(value * scale)` on the way in and divided by
/// `scale` on the way out.
///
/// The default, ``pagePoints`` (1e6), snaps PDF page-point coordinates to a
/// 1e-6 pt grid — about 0.35 nanometres at 1:1, roughly 3.5 µm on a 1:100
/// architectural drawing. That is several orders of magnitude below anything a
/// construction takeoff can resolve, so the quantisation is not observable in
/// measured quantities, but it *is* real: a round-trip through any boolean
/// operation may move a vertex by up to 0.5e-6 pt, and vertices closer together
/// than 1e-6 pt collapse onto each other.
///
/// The usable coordinate range is `±1.15e18 / scale` (the shim keeps headroom below
/// Clipper2's own `INT64_MAX >> 2` for intermediate cross products), i.e. about
/// ±1.15e12 pt at the default scale — vastly more than any page. (BH-399: this used to
/// claim ±2.3e12, twice what the shim accepts.)
///
/// Raising the scale buys resolution and costs range; lowering it does the
/// reverse. Boolean results are only comparable when produced at the same scale.
public struct ClipperScale: Sendable, Hashable {
    public let value: Double

    /// Creates a scale. Returns `nil` unless `value` is finite and positive.
    public init?(_ value: Double) {
        guard value.isFinite, value > 0 else { return nil }
        self.value = value
    }

    /// 1e6 — a 1e-6 pt lattice over PDF page points. The Zenit PDF default. Any other lattice is
    /// `ClipperScale(value)`: a coarser one buys range, a finer one resolution.
    public static let pagePoints = ClipperScale(1_000_000)!
}
