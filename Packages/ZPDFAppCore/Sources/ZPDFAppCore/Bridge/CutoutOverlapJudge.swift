import Foundation
import ZPDFContracts
import ZPDFMeasurementEngine

/// How much of a cutout lies inside the area it is subtracted from, as the engine judges it.
enum CutoutParentOverlap: Equatable, Sendable {
    /// No shared area: the engine refuses the cutout (ADR-0015).
    case disjoint
    /// Part of the cutout lies outside: the engine subtracts the part inside and warns.
    case partial
    /// The whole cutout lies inside.
    case contained
}

/// The engine's cutout rule, asked before a commit (X-cutout-ui).
///
/// The interface used to decide "outside the parent" with containment geometry of its own: every
/// polygon cutout corner had to stay inside the area and an elliptical cutout had to fit inside
/// it. The engine accepts a cutout that only partly overlaps its area and subtracts the part
/// inside, so the interface refused cutouts the engine measures correctly. This asks the engine
/// instead, with nothing of its own: the cutout is measured as a hole in its parent exactly as
/// `DocumentCommand.addCutout` will measure it — the hole rings from `TakeoffSession.cutoutRings`,
/// the parent's stored outer ring with its arcs — and the answer is read from what the engine did.
/// Refused with `cutoutOutsideParent` is ``CutoutParentOverlap/disjoint``; accepted with the
/// `cutoutOutsideParent` warning is ``CutoutParentOverlap/partial``; accepted without it is
/// ``CutoutParentOverlap/contained``.
enum CutoutOverlapJudge {

    /// Containment is decided in page space, so neither the page nor the scale changes the
    /// answer; fixing both keeps the judge a pure function of its arguments.
    private static let pageID = PageID(UUID(uuidString: "C0770000-0000-4000-8000-000000000001") ?? UUID())
    private static let scale = ScaleTransform(
        id: ScaleID(UUID(uuidString: "C0770000-0000-4000-8000-000000000002") ?? UUID()),
        version: 1,
        matrix: AffineScaleMatrix(a: Decimal(string: "0.01") ?? 1, b: 0, c: 0, d: Decimal(string: "0.01") ?? 1),
        units: .metric,
        source: .preset
    )
    /// The shipping options, as the session measures with.
    private static let engine = MeasurementEngine()

    /// How much of `cutout` lies inside `parentOuter`, or `nil` when the engine refuses the shape
    /// for another reason (too few points, no extent): the commit then says why.
    ///
    /// - Parameters:
    ///   - cutout: the cutout's geometry as the presenter commits it.
    ///   - tool: the cutout tool, which decides the hole ring (an ellipse is the ring inscribed in
    ///     its box, not the box).
    ///   - parentOuter: the parent's stored outer ring.
    static func overlap(
        cutout: MeasurementGeometry,
        tool: MeasurementTool,
        parentOuter: PolygonRing
    ) -> CutoutParentOverlap? {
        guard parentOuter.points.count >= 3 else { return nil }
        let holes = TakeoffSession.cutoutRings(of: cutout, tool: tool)
        guard !holes.isEmpty else { return nil }
        var outer = parentOuter
        outer.isClosed = true
        let parent = MeasurementGeometry(pageID: pageID, polygons: [PolygonGeometry(outer: outer, holes: holes)])
        do {
            let result = try engine.calculate(tool: .area, geometry: parent, scale: scale)
            return result.warnings.contains { $0.code == .cutoutOutsideParent } ? .partial : .contained
        } catch MeasurementEngineError.measurement(.cutoutOutsideParent) {
            return .disjoint
        } catch {
            return nil
        }
    }
}
