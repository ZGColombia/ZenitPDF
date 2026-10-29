import Foundation
import ZPDFContracts
import ZPDFMeasurementEngine

/// ⇧⌥-click with an area selected: the traced face is added to that area (NL-MEASURE-11, the
/// multi-click union). The union is the merge's own Clipper2 routine, so two faces that share a
/// wall come back as one ring with the wall between them gone; faces that are apart are refused
/// rather than stored as one markup that is secretly two shapes.
public enum TracedUnion {

    /// Why a union was refused.
    public enum Refusal: Error, Equatable, Sendable {
        /// The selected markup is not a plain area this can grow.
        case notAnArea
        /// The traced face does not touch the selected area.
        case apart
        /// The union would close around a gap. The area cannot keep a hole that is not a cutout,
        /// so storing it would count the gap as area (ADR-0030 §5.7).
        case enclosesGap
        /// The area has arc edges and the exact union could not be resolved (a tangent contact, a
        /// ring that crosses itself). Nothing is approximated (ADR-0030 §5.6).
        case curvedEdgeNotExact
    }

    /// Grows `target` by the traced `ring`, as one batch (K-10): the `editVertices`, and — for a
    /// plan area — one cutout per gap the union closes around, so the gap never counts as area.
    /// A perimeter or wall area has no cutouts to keep a gap in, and still refuses it.
    public static func plan(adding ring: [PDFPoint], to target: MarkupRecord) throws -> AreaMergePlan {
        guard let tool = target.tool, [.area, .rectangleArea, .volume, .trueSlopedArea, .perimeter, .wallArea].contains(tool),
              !target.locked, target.parentMarkupID == nil, target.cutoutMarkupIDs.isEmpty,
              let polygons = target.geometry?.polygons, polygons.count == 1, let existing = polygons.first,
              ring.count >= 3 else { throw Refusal.notAnArea }
        let traced = PolygonGeometry(outer: PolygonRing(points: ring, isClosed: true))
        // An area with arc edges (ADR-0030 §5.6) grows on its arcs, exactly; a union the exact
        // method cannot resolve is refused as such (ADR-0030 §5.7), not as "not an area".
        let union: [PolygonGeometry]
        if existing.outer.hasArcs {
            guard let exact = try? ArcRingBoolean.union([existing, traced]) else { throw Refusal.curvedEdgeNotExact }
            union = exact
        } else {
            union = try AreaMerge.union([existing, traced])
        }
        guard union.count == 1, let merged = union.first else { throw Refusal.apart }
        // Holes are rebuilt from cutout markups on every recompute: a hole stored in the outline
        // would be erased and the gap counted as area, so each goes in as a cutout (K-10).
        guard merged.holes.isEmpty || TakeoffSession.splittableTools.contains(tool) else { throw Refusal.enclosesGap }
        var commands: [DocumentCommand] = [.editVertices(id: target.id, geometry: MeasurementGeometry(
            pageID: target.pageID, polygons: [PolygonGeometry(outer: merged.outer)]
        ))]
        let stamp = Date()
        for gap in merged.holes {
            commands.append(.addCutout(parent: target.id, cutout: TakeoffSession.gapCutout(gap, of: target, at: stamp)))
        }
        return AreaMergePlan(commands: commands, keptGaps: merged.holes.count)
    }
}
