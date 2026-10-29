import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

/// The Inspector's Layer row as a popup (ADR-0032, unit r2-layers): every markup layer of the
/// project, the selection's layer ticked, and New Layer… — which creates a layer and moves the
/// selection onto it in one step.
///
/// nl-ux left the row a plain value because no project stored markup layers (NL-UX-08). The
/// routes here are the layer model's; nothing writes the document from the view.
extension InspectorPanel {

    /// Moves the selection onto a layer; nothing when the layer model's rule refuses it.
    func assignLayer(_ layerID: UUID, for summary: InspectorSelectionSummary) {
        environment.markupLayers.assign(summary.markups, to: layerID)
    }

    /// Creates a layer and moves the selection onto it.
    func newLayer(for summary: InspectorSelectionSummary) {
        environment.markupLayers.newLayer(moving: summary.markups)
    }

    /// Why the Layer row cannot move the selection anywhere, or `nil` when it can — the rule
    /// the row's enabled state and its help both read (W-052). It can when something is
    /// selected, the project's layers are installed, and nothing selected is locked — by its own
    /// lock or its layer's. Each layer in the popup is then asked on its own, so a locked layer
    /// is offered but off (V-046: the one rule ``MarkupLayerPanelModel/assignRefusal(_:to:)``).
    func layerRefusal(_ summary: InspectorSelectionSummary) -> MarkupLayerPanelModel.AssignRefusal? {
        environment.markupLayers.assignRefusal(summary.markups, to: nil)
    }

    /// The Layer popup.
    @ViewBuilder
    func layerControl(_ summary: InspectorSelectionSummary) -> some View {
        let model = environment.markupLayers
        let current: UUID?? = summary.common(\.layerID)
        let title = Self.layerText(summary)
        // W-052: whether the row is on and why it is off come from the one rule, so they cannot
        // drift — the hand-written reason left the help empty when the layers were not installed.
        let popupRefusal = layerRefusal(summary)
        let enabled = popupRefusal == nil
        InspectorPopup(title: title, isEnabled: enabled) {
            ForEach(model.rows) { row in
                let refusal = model.assignRefusal(summary.markups, to: row.id)
                Button {
                    assignLayer(row.id, for: summary)
                } label: {
                    if case .some(.some(let id)) = current, id == row.id {
                        Label(row.name, systemImage: "checkmark")
                    } else {
                        Text(row.name)
                    }
                }
                // V-046: a locked layer takes nothing, here as in the Navigator's layer menu.
                .disabled(refusal != nil)
                .help(refusal.map(MarkupLayerPanelModel.reason) ?? "")
            }
            Divider()
            Button(NSLocalizedString("New Layer…", comment: "Inspector Layer popup: create a layer and move the selection onto it")) {
                newLayer(for: summary)
            }
        }
        .disabled(!enabled)
        .help(popupRefusal.map(MarkupLayerPanelModel.reason) ?? "")
        .accessibilityLabel(Text(NSLocalizedString("Layer", comment: "Inspector row label")))
        .accessibilityValue(Text(title))
    }
}
