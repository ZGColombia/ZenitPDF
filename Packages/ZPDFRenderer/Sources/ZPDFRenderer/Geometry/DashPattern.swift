import Foundation

/// A dash pattern reduced to at most four runs, with the one scaling rule both backends use.
///
/// # Why four runs
///
/// `solid`, `dashed`, `dotted` and `dashDot` — the whole of `ZPDFContracts.LineStyle` — need at
/// most four. Capping the count is what lets a dash live in a GPU instance as a `float4` and a
/// count byte, with no indirection and no per-instance buffer.
///
/// # The scaling rule
///
/// Runs are authored in page points. At 5 % zoom a 3 pt dash is 0.15 device pixels: the line
/// would render as a uniform 15 %-alpha wash and read as a thin solid line of the wrong colour.
/// Scaling each run independently up to a floor would change the pattern's shape — a 6/2 dash
/// would become 1.5/1.5 and read as dotted. So the whole pattern is scaled by **one** factor:
///
/// ```
/// scale = max(pixelsPerPagePoint, minimumRunPixels / smallestFlooredRun)
/// ```
///
/// which preserves every ratio in the pattern, guarantees the smallest floored run (every
/// positive run except a dot run, see ``dotRunFraction``) is at least ``minimumRunPixels``
/// wide, and reduces to plain `pixelsPerPagePoint` at any zoom where the pattern is already
/// legible, or when the pattern has no floored run. This is decoration, not geometry: the
/// centreline is untouched, so nothing measurable changes.
///
/// `MetalShaderSource` implements the identical two lines in MSL; the dashed-line golden scenes
/// at three zoom levels are what proves the two agree.
public struct DashPattern: Sendable, Hashable {

    /// Shortest dash or gap the renderer will paint, in device pixels.
    public static let minimumRunPixels: Double = 1.5

    /// Up to four runs, in page points, alternating on and off. Unused slots are `0`.
    public private(set) var runs: (Double, Double, Double, Double)
    /// How many of ``runs`` are live: `0` for solid, otherwise 2 or 4.
    public private(set) var runCount: Int
    /// Phase offset in page points.
    public private(set) var phase: Double
    /// The style asked for more runs than an instance carries (after PDF's doubling of an odd
    /// pattern), so only the first four are drawn. That changes the pattern's shape, so it is
    /// reported — `CompiledMarkup.dashTruncated`, `RenderStatistics.truncatedDashCount` —
    /// rather than done silently (BH-623). The kept runs are the first four of the real
    /// on/off sequence, never an odd count, so their on/off meaning is intact.
    public private(set) var isTruncated: Bool = false

    /// An on-run shorter than this fraction of the pattern's period is a **dot run**: it is drawn
    /// by its caps, not by its length — the `[0.01, 2.2]` round-capped dotted idiom, or PDF's
    /// `[0 2] 0 d`. It takes no part in the minimum-run floor, because scaling the whole pattern
    /// until a 0.01 pt run is 1.5 px wide turned a 2.2 pt gap into 330 px and the dotted line
    /// into one dot per screen (BH-624). The floor exists to keep runs from straddling a pixel;
    /// a dot's ink is its cap, which the line width already sizes.
    public static let dotRunFraction = 0.05

    public static let solid = DashPattern()

    public init() {
        runs = (0, 0, 0, 0)
        runCount = 0
        phase = 0
    }

    /// Builds the pattern from a style, collapsing anything unusable to ``solid``.
    public init(_ dash: RenderDash) {
        self.init()
        guard case let .pattern(rawRuns, rawPhase) = dash.sanitized else { return }
        let kept = Array(rawRuns.prefix(4))
        // An odd prefix would invert the on/off meaning of the tail, so keep an even count.
        let count = kept.count >= 4 ? 4 : 2
        guard kept.count >= 2 else { return }
        isTruncated = rawRuns.count > count
        runs = (
            kept[0],
            kept[1],
            count > 2 ? kept[2] : 0,
            count > 3 ? kept[3] : 0
        )
        runCount = count
        phase = rawPhase
    }

    public var isSolid: Bool { runCount == 0 }

    /// The runs as an array, in page points.
    public var runArray: [Double] {
        switch runCount {
        case 2: [runs.0, runs.1]
        case 4: [runs.0, runs.1, runs.2, runs.3]
        default: []
        }
    }

    /// Sum of the live runs, in page points. Never zero for a live pattern.
    public var period: Double { runArray.reduce(0, +) }

    /// The smallest run the minimum-run floor applies to: positive, and not a dot run (see
    /// ``dotRunFraction``). `0` when there is none. `MetalShaderSource` computes the same.
    public var smallestFlooredRun: Double {
        let runs = runArray
        let dotLimit = period * Self.dotRunFraction
        var smallest = Double.infinity
        for (index, run) in runs.enumerated() where run > 0 {
            if index % 2 == 0, run < dotLimit { continue }
            smallest = Swift.min(smallest, run)
        }
        return smallest.isFinite ? smallest : 0
    }

    /// Page points to device pixels for this pattern, per the rule in the type's discussion.
    public func deviceScale(pixelsPerPagePoint: Double) -> Double {
        guard !isSolid else { return pixelsPerPagePoint }
        let smallest = smallestFlooredRun
        guard smallest > 0, pixelsPerPagePoint > 0 else { return pixelsPerPagePoint }
        return Swift.max(pixelsPerPagePoint, Self.minimumRunPixels / smallest)
    }

    public static func == (lhs: DashPattern, rhs: DashPattern) -> Bool {
        lhs.runs == rhs.runs && lhs.runCount == rhs.runCount && lhs.phase == rhs.phase
            && lhs.isTruncated == rhs.isTruncated
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(runs.0); hasher.combine(runs.1)
        hasher.combine(runs.2); hasher.combine(runs.3)
        hasher.combine(runCount); hasher.combine(phase)
    }

    /// The pattern in device pixels at a given scale, ready for `CGContext.setLineDash`.
    public func devicePixelRuns(pixelsPerPagePoint: Double) -> [CGFloat] {
        let scale = deviceScale(pixelsPerPagePoint: pixelsPerPagePoint)
        return runArray.map { CGFloat($0 * scale) }
    }

    /// The phase in device pixels at a given scale.
    public func devicePixelPhase(pixelsPerPagePoint: Double, extraPagePoints: Double) -> CGFloat {
        let scale = deviceScale(pixelsPerPagePoint: pixelsPerPagePoint)
        return CGFloat((phase + extraPagePoints) * scale)
    }
}
