import AppKit
import Foundation
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation

/// The measurement-geometry rows of the canvas context menu (ADR-0030 §5.7).
///
/// Split Area, Merge Areas, Curve an Edge and Continue Measurement were reachable only from the
/// Measure menu, and inserting or removing one vertex only by ⌥-click and by focusing a handle and
/// pressing Delete. Right-click is where a person looks first, so the menu offers each of them when
/// it applies to what was right-clicked — through the same commands and the same edits the menu
/// bar and the keyboard use, so nothing here is a second path.
extension PDFCanvasViewController {

    /// The tools Split Area and Merge Areas take (`TakeoffSession.splittableTools`).
    static let splittableContextTools: Set<MeasurementTool> = [.area, .rectangleArea, .volume, .trueSlopedArea]

    /// Adds the rows that apply to `markups`, right-clicked at `point`, after a separator.
    func addGeometryEditItems(to menu: NSMenu, markups: [MarkupSummary], at point: PDFPointValue?) {
        let tools = markups.map { $0.measurementKind.map(MeasurementTool.init(shown:)) }
        let locked = markups.contains(where: \.locked)
        var items: [NSMenuItem] = []

        if markups.count == 1, let markup = markups.first, let tool = tools.first ?? nil {
            let editable = MarkupTopologyEditing.allowsTopologyEdits(tool)
            if let point, editable, let handle = vertexHandle(at: point), handle.markupID == markup.id {
                items.append(ContextMenuItem(
                    title: NSLocalizedString("Remove Vertex", comment: "Canvas context menu: remove the vertex under the pointer"),
                    enabled: !locked
                ) { [weak self] in
                    self?.focusedVertex = handle
                    self?.removeFocusedVertex()
                })
            } else if let point, editable, tool != .count,
                      selectedEdgeIsNear(point, tolerance: core.canvas.viewport.pageDistance(forViewPoints: Self.edgeInsertToleranceScreenPoints)) {
                items.append(ContextMenuItem(
                    title: NSLocalizedString("Insert Vertex Here", comment: "Canvas context menu: add a vertex on the edge under the pointer"),
                    enabled: !locked
                ) { [weak self] in
                    self?.insertVertexOnSelectedEdge(at: point)
                })
            }
            if Self.splittableContextTools.contains(tool) { items.append(appItem(.splitArea)) }
            if MarkupTopologyEditing.allowsArcEdges(tool) { items.append(appItem(.curveEdge)) }
            if tool == .polylength || tool == .count { items.append(appItem(.continueMeasurement)) }
        }
        if markups.count >= 2, tools.allSatisfy({ $0.map(Self.splittableContextTools.contains) == true }) {
            items.append(appItem(.mergeAreas))
        }
        guard !items.isEmpty else { return }
        menu.addItem(.separator())
        for item in items {
            if locked { item.isEnabled = false }
            menu.addItem(item)
        }
    }
}
