import AppKit
import Foundation
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation

/// Measure ▸ Curve an Edge (NL-MEASURE-05, first slice): with one polylength or area selected,
/// click the edge, then the point the curve must pass through — the edge becomes the circular arc
/// through that point, measured exactly (r·θ, and the circular segment for an area). A point on
/// the chord straightens the edge again. One `editVertices`, one undo.
extension ProjectWindowController {

    func beginCurveEdge(for document: ZenitPDFProjectDocument) {
        guard let core = document.core else { return }
        let selected = core.canvas.selectedMarkupIDs
        guard selected.count == 1, let id = selected.first else {
            core.status.setActiveToolNote(NSLocalizedString(
                "Select one polylength or area to curve one of its edges.",
                comment: "Curve an Edge refusal: nothing or several selected"
            ))
            return
        }
        // An Ellipse Cutout is an ellipse, with no edge to curve. Said before the two clicks, not
        // after. A Polygon Cutout's edges may be curved since ADR-0037 (C-08): its parent removes
        // the hole on its arcs.
        if let summary = core.snapshot.markups.first(where: { $0.id == id }),
           let kind = summary.measurementKind, kind == .ellipseCutout {
            core.status.setActiveToolNote(CurveEdgePick.cutoutRefusal)
            return
        }
        CurveEdgePick.arm(document, markup: id)
        document.pendingScaleCalibration = nil
        beginCalibration(for: document)
        core.status.setActiveToolNote(NSLocalizedString(
            "Curve an Edge: click the edge, then the point the curve passes through.",
            comment: "Status note while picking an edge to curve"
        ))
    }
}

/// The two clicks of Curve an Edge.
@MainActor
enum CurveEdgePick {

    /// The markup waiting for its two clicks, and how far from an edge the first click may land
    /// in page points — converted at the zoom the pick was armed at, then again at the zoom the
    /// edge click lands at (``noteEdgeClick(_:)``).
    private static var pending: [UUID: (markup: UUID, tolerance: Double)] = [:]

    /// How far from an edge its click may land, in view points: the same on screen at every
    /// zoom, like the edge-insert grab (R-014). It was 12 page points, which is 3 screen points
    /// at 25 % (the pick refused an edge the person was plainly on) and 96 at 800 %.
    static let edgeToleranceViewPoints = 8.0

    /// Why an Ellipse Cutout is not curved (ADR-0030 §5.7, ADR-0037).
    static var cutoutRefusal: String {
        NSLocalizedString(
            "An ellipse cutout has no straight edge to curve.",
            comment: "Curve an Edge refusal: the selected markup is an ellipse cutout"
        )
    }

    static func arm(_ document: ZenitPDFProjectDocument, markup: UUID) {
        PendingPointPicks.disarmAll(document)
        pending[document.documentIdentity] = (markup, currentTolerance(document))
    }

    /// The edge click landed: its tolerance is converted at the zoom it was clicked at (S-007).
    /// Zoom stays live while the pick waits, and the tolerance converted at arm time judged the
    /// click at the old zoom — armed at 800 %, zoomed out to 100 %, a click three screen points
    /// off the edge was refused, the zoom-dependent tolerance R-014 set out to remove.
    static func noteEdgeClick(_ document: ZenitPDFProjectDocument) {
        guard let armed = pending[document.documentIdentity] else { return }
        pending[document.documentIdentity] = (armed.markup, currentTolerance(document))
    }

    /// ``edgeToleranceViewPoints`` in page points at the viewport's zoom right now.
    private static func currentTolerance(_ document: ZenitPDFProjectDocument) -> Double {
        document.core?.canvas.viewport.pageDistance(forViewPoints: edgeToleranceViewPoints) ?? edgeToleranceViewPoints
    }

    /// The page-space tolerance the armed pick will use; `nil` when nothing is armed.
    static func armedTolerance(_ document: ZenitPDFProjectDocument) -> Double? { pending[document.documentIdentity]?.tolerance }

    static func isArmed(_ document: ZenitPDFProjectDocument) -> Bool { pending[document.documentIdentity] != nil }

    /// Forgets a pending curve (Escape, or another pick armed) — R-001.
    static func disarm(_ document: ZenitPDFProjectDocument) { pending[document.documentIdentity] = nil }

    /// The edge click and the through point arrived.
    static func finish(points: [PDFPointValue], document: ZenitPDFProjectDocument) async {
        guard let armed = pending.removeValue(forKey: document.documentIdentity), points.count == 2,
              let core = document.core, let record = await core.session.markup(MarkupID(armed.markup)),
              let geometry = record.geometry else { return }
        let edgeClick = PDFPoint(shown: points[0]), through = PDFPoint(shown: points[1])
        guard record.parentMarkupID == nil || MarkupTopologyEditing.allowsArcEdges(record.tool) else {
            core.status.setActiveToolNote(cutoutRefusal)
            return
        }
        guard let edge = MarkupTopologyEditing.nearestEdge(to: edgeClick, in: geometry, tool: record.tool, tolerance: armed.tolerance),
              let bent = MarkupTopologyEditing.bending(edgeAfter: edge.startVertexIndex, through: through, in: geometry, tool: record.tool) else {
            core.status.setActiveToolNote(NSLocalizedString(
                "No edge of the selected polylength or area there. Click on an edge first.",
                comment: "Curve an Edge refusal: the first click was not on an edge"
            ))
            return
        }
        do {
            try await core.commands.perform(.editVertices(id: record.id, geometry: bent))
            core.status.setActiveToolNote(NSLocalizedString("Edge curved.", comment: "Status note after Curve an Edge"))
        } catch {
            ZenitPDFProjectDocument.reportRefusedEdit(error, core: core)
        }
    }
}
