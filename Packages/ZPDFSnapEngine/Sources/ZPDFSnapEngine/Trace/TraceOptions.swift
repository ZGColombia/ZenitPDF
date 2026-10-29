import Foundation

/// Everything ``RegionTracer`` is allowed to assume, and everything it is allowed to spend.
///
/// Two tolerances decide whether a boundary is closed, and they are deliberately different
/// numbers with different meanings. Getting them confused is how a tracer invents a wall.
///
/// - ``joinTolerance`` is a **construction** tolerance. Two endpoints closer together than this
///   are treated as one node. A CAD export writes the same corner twice with a last-bit
///   difference, and a PDF producer rounds coordinates to three decimals; at 0.75 pt (about
///   0.26 mm on paper, 13 mm at 1:50) this only ever fuses points a person drew as one point.
///   It is not a bridging distance: nothing new is drawn, two coincident things become one.
///
/// - ``gapTolerance`` is a **bridging** tolerance, and it is the only place this engine ever
///   adds geometry that was not in the drawing. A loose end within this distance of another
///   loose end — or of a wall it stops just short of — is joined, and the join is reported in
///   ``TracedRegion/largestBridgedGap`` so the interface can show the number it used. Anything
///   wider is refused, never bridged: closing an invented gap is the one thing this feature
///   must never do, because a room that quietly swallowed the corridor is a confident wrong
///   number.
///
/// The default of 3 pt is the width of a drawn line join, not the width of a door. A 2 pt break
/// where two wall strokes fail to meet is a join; a 900 mm door opening at 1:50 is 25 pt and is
/// a refusal.
public struct TraceOptions: Sendable, Hashable {

    /// Endpoints closer than this become one node. Page points.
    public var joinTolerance: Double

    /// The widest break in a boundary this engine will close. Page points. A wider break is
    /// refused with its location, never bridged.
    public var gapTolerance: Double

    /// Primitives accepted before the page is declared too complex to trace.
    public var maximumPrimitives: Int

    /// Line segments accepted after curves are flattened and rings are expanded.
    public var maximumSegments: Int

    /// Segment-pair and node-pair tests the arrangement may perform. A drawing that would need
    /// more is refused rather than traced slowly.
    public var maximumPairTests: Int

    /// Darts the face walk may follow before it is declared degenerate.
    public var maximumWalkSteps: Int

    /// Vertices one traced ring may hold.
    public var maximumRingVertices: Int

    /// Side of the first working window, in page points, before it starts doubling.
    public var initialWindowSide: Double

    /// How many times the working window may double before the whole page is used.
    public var maximumWindowGrowths: Int

    /// Maximum distance between a stored curve and the polyline that stands in for it while the
    /// arrangement is built. Curves are never stored flattened — `SNAP_CONTRACT` 13.4.
    public var curveFlatness: Double

    /// Drop a vertex that lies on the straight line between its neighbours. A wall crossed by a
    /// dimension line gains a node at the crossing; leaving it in the ring is harmless for the
    /// area and noise in the markup.
    public var simplifiesCollinearVertices: Bool

    /// Perpendicular distance under which a vertex counts as lying on the line between its
    /// neighbours. Deliberately at floating-point noise level: this step must never move a
    /// boundary, only drop a redundant point.
    public var collinearTolerance: Double

    public init(
        joinTolerance: Double = 0.75,
        gapTolerance: Double = 3.0,
        maximumPrimitives: Int = 200_000,
        maximumSegments: Int = 400_000,
        maximumPairTests: Int = 12_000_000,
        maximumWalkSteps: Int = 2_000_000,
        maximumRingVertices: Int = 200_000,
        initialWindowSide: Double = 192,
        maximumWindowGrowths: Int = 24,
        curveFlatness: Double = 0.05,
        simplifiesCollinearVertices: Bool = true,
        collinearTolerance: Double = 1e-9
    ) {
        self.joinTolerance = Self.positive(joinTolerance, fallback: 0.75)
        self.gapTolerance = Swift.max(
            Self.positive(gapTolerance, fallback: 3.0),
            self.joinTolerance
        )
        self.maximumPrimitives = Swift.max(1, maximumPrimitives)
        self.maximumSegments = Swift.max(1, maximumSegments)
        self.maximumPairTests = Swift.max(1, maximumPairTests)
        self.maximumWalkSteps = Swift.max(8, maximumWalkSteps)
        self.maximumRingVertices = Swift.max(3, maximumRingVertices)
        self.initialWindowSide = Self.positive(initialWindowSide, fallback: 192)
        self.maximumWindowGrowths = Swift.min(Swift.max(0, maximumWindowGrowths), 64)
        self.curveFlatness = Self.positive(curveFlatness, fallback: 0.05)
        self.simplifiesCollinearVertices = simplifiesCollinearVertices
        self.collinearTolerance = Swift.max(0, collinearTolerance.isFinite ? collinearTolerance : 0)
    }

    /// The defaults, which are the numbers the interface quotes.
    public static let standard = TraceOptions()

    private static func positive(_ value: Double, fallback: Double) -> Double {
        value.isFinite && value > 0 ? value : fallback
    }
}
