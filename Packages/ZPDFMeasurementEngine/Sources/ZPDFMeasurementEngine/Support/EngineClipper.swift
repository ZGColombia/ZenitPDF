import CoreGraphics
import Foundation
import os
import ZPDFClipper2
import ZPDFContracts
import ZPDFGeometry

/// The one bridge from the engine's error space to Clipper2's, and the one ordering rule for the
/// polygons a boolean hands back (IM-004).
///
/// Until IM-004 there were three identical `clip` wrappers (CutoutSolver, CoverageRegions,
/// PolygonSplitter) and two identical copies of the area-then-corner total order. They are one
/// now, so a change to how a Clipper2 failure is reported, or to how equal-area parts are
/// ordered, cannot land in one path and not the others.
enum EngineClipper {

    // MARK: - Error bridging

    /// Runs a Clipper2 call and re-raises its typed error in the engine's error space.
    static func run<T>(
        _ body: () throws(ClipperError) -> T
    ) throws(MeasurementEngineError) -> T {
        CallCounter.current?.increment()
        do {
            return try body()
        } catch {
            throw MeasurementEngineError.clipper(error)
        }
    }

    /// Counts Clipper2 boolean calls made through ``run(_:)`` inside a task-local scope.
    ///
    /// Only tests install one. It exists so that a performance claim about "fewer booleans" is a
    /// number a test asserts rather than a sentence in a comment (IM-004, IM-069, IM-071).
    final class CallCounter: Sendable {
        @TaskLocal static var current: CallCounter?

        private let storage = OSAllocatedUnfairLock(initialState: 0)

        init() {}

        var count: Int { storage.withLock { $0 } }

        func increment() { storage.withLock { $0 += 1 } }
    }

    // MARK: - Net region

    /// A resolved polygon's net region as Clipper2 paths: the difference ``CutoutSolver/resolve``
    /// already computed when cutouts took part, else the outer ring normalised so every region
    /// carries Clipper2's own ring orientation.
    ///
    /// CoverageRegions and PolygonSplitter used to call `resolve` and then run the same union
    /// and difference again on the same input — two extra booleans per polygon with holes.
    static func netPaths(
        of resolved: CutoutSolver.Resolved,
        scale: ClipperScale
    ) throws(MeasurementEngineError) -> ClipperPaths {
        if let paths = resolved.netPaths { return paths }
        let outerPaths = resolved.outerRings.map { $0.map(CutoutSolver.cgPoint) }
        return try run { () throws(ClipperError) -> ClipperPaths in
            try Clipper2.normalized(outerPaths, fillRule: .nonZero, scale: scale)
        }
    }

    // MARK: - Determinism

    /// Descending area, then ascending minimum x, then ascending minimum y of the outer ring.
    ///
    /// A rectangle cut down the middle gives two parts of exactly equal area, and without the
    /// tie-breakers the order would be whatever Clipper2's ring order happened to be that run.
    static func ordered(_ measured: [(polygon: PolygonGeometry, area: Double)]) -> [PolygonGeometry] {
        measured
            .map { (polygon: $0.polygon, area: $0.area, corner: corner(of: $0.polygon)) }
            .sorted { left, right in
                if left.area != right.area { return left.area > right.area }
                if left.corner.x != right.corner.x { return left.corner.x < right.corner.x }
                return left.corner.y < right.corner.y
            }
            .map(\.polygon)
    }

    private static func corner(of polygon: PolygonGeometry) -> (x: Double, y: Double) {
        var minX = Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude
        for point in polygon.outer.uniquePoints {
            minX = Swift.min(minX, point.x)
            minY = Swift.min(minY, point.y)
        }
        return (x: minX, y: minY)
    }
}
