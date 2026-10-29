import AppKit
import Foundation
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation

/// Inserting and deleting vertices on a selected markup (NL-MEASURE-06).
///
/// ⌥-click on an edge of a selected markup inserts a vertex there; clicking a vertex handle
/// focuses it, and Delete then removes that vertex instead of the markup. Each is one
/// `DocumentCommand.editVertices` — the markup keeps its identity, its row and its audit
/// trail, and one ⌘Z takes it back. The shapes that allow it are
/// ``MarkupTopologyEditing/allowsTopologyEdits(_:)``'s: fixed-count tools never change count.
extension PDFCanvasViewController {

    /// How close an ⌥-click must land on an edge, in screen points, to insert a vertex.
    static let edgeInsertToleranceScreenPoints: Double = 6

    /// Inserts a vertex on the selected markup's edge under `point`.
    ///
    /// - Returns: whether the click was spent on an insertion (the caller then stops routing it).
    @discardableResult
    func insertVertexOnSelectedEdge(at point: PDFPointValue) -> Bool {
        let selected = core.canvas.selectedMarkupIDs
        guard selected.count == 1, let markupID = selected.first else { return false }
        let tolerance = core.canvas.viewport.pageDistance(forViewPoints: Self.edgeInsertToleranceScreenPoints)
        guard selectedEdgeIsNear(point, tolerance: tolerance) else { return false }
        // The drawn shape answered "is there an edge here" synchronously, so the click is spent
        // or not at once; the stored record, read from the session, is what is edited.
        let pagePoint = PDFPoint(shown: point)
        let session = core.session
        let commands = core.commands
        let environment = self.core
        Task { @MainActor [weak self] in
            guard let record = await session.markup(MarkupID(markupID)), let geometry = record.geometry else { return }
            // Said, never swallowed (ADR-0030 §5.7): the click was spent, so a refusal is named.
            guard let hit = MarkupTopologyEditing.nearestEdge(to: pagePoint, in: geometry, tool: record.tool, tolerance: tolerance) else {
                environment.status.setActiveToolNote(Self.insertRefusalNote(
                    MarkupTopologyEditing.allowsTopologyEdits(record.tool) && record.tool != .count ? nil : .fixedShape
                ))
                return
            }
            let edited: MeasurementGeometry
            switch MarkupTopologyEditing.insertion(hit.projected, afterVertex: hit.startVertexIndex, in: geometry, tool: record.tool) {
            case let .success(geometry):
                edited = geometry
            case let .failure(refusal):
                environment.status.setActiveToolNote(Self.insertRefusalNote(refusal))
                return
            }
            do {
                _ = try await commands.perform(.editVertices(id: record.id, geometry: edited))
                self?.focusedVertex = (markupID, hit.startVertexIndex + 1)
            } catch {
                ZenitPDFProjectDocument.reportRefusedEdit(error, core: environment)
            }
            self?.refresh()
        }
        return true
    }

    /// Whether `point` is on an edge of the single selected markup, as drawn.
    ///
    /// A ring's closing edge counts; for an open line it can only over-claim a click whose ⌥
    /// already asked for an edit. A markup with arc edges (NL-MEASURE-05) is asked on its exact
    /// outline — each arc where its curve is, never its chord, which is nothing drawn — exactly
    /// as ``MarkupTopologyEditing/nearestEdge(to:in:tool:tolerance:)`` will measure it. Asking the
    /// chords too took an ⌥-click on the empty diameter of a semicircle and then did nothing
    /// (ADR-0030 §5.7).
    func selectedEdgeIsNear(_ point: PDFPointValue, tolerance: Double) -> Bool {
        let selected = core.canvas.selectedMarkupIDs
        guard selected.count == 1, let markupID = selected.first,
              let shape = pageViewForTesting.shapes.first(where: { $0.id == markupID }), shape.vertices.count >= 2 else {
            return false
        }
        let outlines = shape.strokes.compactMap(\.arcOutline)
        guard !outlines.isEmpty else {
            return edgeIsNear(point, in: shape.vertices, tolerance: tolerance, closed: shape.vertices.count >= 3)
        }
        let p = PDFPoint(shown: point)
        return outlines.contains { ring in
            ring.bulgedEdges.contains { BulgeArc.nearestPoint(to: p, from: $0.start, to: $0.end, bulge: $0.bulge).distance <= tolerance }
        }
    }

    /// The status note for an insertion that was refused. `nil` is "no edge of this markup there".
    static func insertRefusalNote(_ refusal: MarkupTopologyEditing.TopologyRefusal?) -> String {
        switch refusal {
        case .curvedEdgeNotExact?:
            return NSLocalizedString(
                "That point is at the end of the curve, so there is nothing to split there. ⌥-click further along the curve.",
                comment: "Status note when ⌥-click insert lands on an arc's end"
            )
        case .fixedShape?, .atMinimum?:
            return NSLocalizedString(
                "This markup's vertex count is fixed, so no vertex was inserted.",
                comment: "Status note when ⌥-click insert is refused on a tool whose vertex count is fixed"
            )
        case nil:
            return NSLocalizedString(
                "No edge of the selected markup there, so no vertex was inserted.",
                comment: "Status note when ⌥-click insert finds no edge of the stored markup"
            )
        }
    }

    /// Forgets a focused vertex that no longer belongs to the single selected markup (T-001).
    ///
    /// Run on every live refresh, which every selection change reaches, so a focus cannot sleep
    /// through a change of selection and come back to life when its markup is selected again.
    func dropStaleVertexFocus() {
        guard let focus = focusedVertex, core.canvas.selectedMarkupIDs != [focus.markupID] else { return }
        focusedVertex = nil
    }

    /// Whether a Select click or drag on this handle focuses it, so that Delete removes the vertex
    /// (T-001, iteration 3). Answered at once from the stored geometry the scene was drawn from.
    ///
    /// A handle takes the focus only when Delete can remove its vertex: the tool's vertex count
    /// can change (``MarkupTopologyEditing/allowsTopologyEdits(_:)``) and the vertex's chain is
    /// above its minimum. A Length, an Angle, a one-mark Count, a stamp, and a text or shape markup
    /// have handles that can be dragged but never removed. A click on one of them is a click on
    /// the markup, and Delete deletes the markup. Focusing such a handle turned Delete into a
    /// refusal note and left the markup where it was. A vertex that joins a curve to a straight
    /// edge still takes the focus. The markup can lose vertices, just not that one exactly, and
    /// Delete names the curve instead of deleting the whole area.
    func vertexTakesFocus(markupID: UUID, index: Int) -> Bool {
        guard let record = sceneRecords.first(where: { $0.id.rawValue == markupID }),
              let geometry = record.geometry else { return false }
        switch MarkupTopologyEditing.removal(vertexAt: index, in: geometry, tool: record.tool) {
        case .success, .failure(.curvedEdgeNotExact):
            return true
        case .failure(.fixedShape), .failure(.atMinimum):
            return false
        }
    }

    /// Removes the focused vertex of the selected markup.
    ///
    /// - Returns: whether Delete was spent on a vertex (the caller then does not delete the
    ///   markup). A focused vertex that no longer belongs to the single selected markup is
    ///   forgotten, and Delete falls through to deleting the selection. So is a focus on a
    ///   markup whose vertex count is fixed. That decision is made here, synchronously, because
    ///   the edit below runs later and cannot hand Delete back once the caller has moved on.
    @discardableResult
    func removeFocusedVertex() -> Bool {
        guard let focus = focusedVertex else { return false }
        let selected = core.canvas.selectedMarkupIDs
        guard selected == [focus.markupID],
              let shape = pageViewForTesting.shapes.first(where: { $0.id == focus.markupID }),
              shape.vertices.indices.contains(focus.index),
              MarkupTopologyEditing.allowsTopologyEdits(sceneRecords.first(where: { $0.id.rawValue == focus.markupID })?.tool) else {
            focusedVertex = nil
            return false
        }
        focusedVertex = nil
        let session = core.session
        let commands = core.commands
        let environment = self.core
        Task { @MainActor [weak self] in
            guard let record = await session.markup(MarkupID(focus.markupID)),
                  let geometry = record.geometry else { return }
            let edited: MeasurementGeometry
            switch MarkupTopologyEditing.removal(vertexAt: focus.index, in: geometry, tool: record.tool) {
            case let .success(geometry):
                edited = geometry
            case let .failure(refusal):
                // Said, not swallowed, with the reason that applies (ADR-0030 §5.7).
                environment.status.setActiveToolNote(Self.removeRefusalNote(refusal))
                return
            }
            do {
                _ = try await commands.perform(.editVertices(id: record.id, geometry: edited))
            } catch {
                ZenitPDFProjectDocument.reportRefusedEdit(error, core: environment)
            }
            self?.refresh()
        }
        return true
    }

    /// The status note for a vertex removal that was refused.
    static func removeRefusalNote(_ refusal: MarkupTopologyEditing.TopologyRefusal) -> String {
        switch refusal {
        case .curvedEdgeNotExact:
            return NSLocalizedString(
                "This vertex joins a straight edge to a curve, or two different curves, and no single edge can replace them exactly, so it was not removed.",
                comment: "Status note when Delete on a vertex was refused because it ends an arc"
            )
        case .fixedShape, .atMinimum:
            return NSLocalizedString(
                "This vertex cannot be removed: the shape would no longer be a measurement of its kind.",
                comment: "Status note when Delete on a vertex was refused"
            )
        }
    }

    /// Whether `point` is within `tolerance` of an edge of the drawn vertex list.
    private func edgeIsNear(_ point: PDFPointValue, in vertices: [PDFPointValue], tolerance: Double, closed: Bool) -> Bool {
        let p = PDFPoint(shown: point)
        let points = vertices.map { PDFPoint(shown: $0) }
        let count = closed ? points.count : points.count - 1
        guard count > 0 else { return false }
        for index in 0..<count {
            let a = points[index], b = points[(index + 1) % points.count]
            if MarkupTopologyEditing.project(p, ontoSegmentFrom: a, to: b).distance(to: p) <= tolerance { return true }
        }
        return false
    }
}
