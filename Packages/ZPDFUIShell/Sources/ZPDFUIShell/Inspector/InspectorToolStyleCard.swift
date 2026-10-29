import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

/// The Inspector with nothing selected and a markup tool armed: the style that tool will draw
/// with, editable in place.
///
/// This is the "chosen" half of the tool-style fix. `ZenitToolbarModel.setStyle(_:)` had no
/// caller, so Text, Callout and the Shapes always drew the default blue at 1.5 pt. The card
/// writes the toolbar's tool style directly — no document change, nothing on the undo stack —
/// and the canvas picks it up through the armed selection it already observes. The same swatch
/// and number controls as the Markup tab, so the palette, the mixed rules and the hit targets
/// are the ones the probe checks.
extension InspectorPanel {

    /// The markup kind whose style the card edits, or `nil` when the armed tool draws none.
    static func styleableTool(_ selection: ZenitToolSelection) -> MarkupKind? {
        guard let kind = selection.mode.markupKind, ZenitToolMode.isDrawable(kind) else { return nil }
        return kind
    }

    /// Whether the kind has an interior a fill colours.
    static func toolAcceptsFill(_ kind: MarkupKind) -> Bool {
        [.rectangle, .ellipse, .polygon, .cloud, .callout].contains(kind)
    }

    @ViewBuilder
    func toolStyleCard(kind: MarkupKind) -> some View {
        let toolbar = environment.toolbar
        let style = toolbar.activeSelection.style
        let services = InspectorColourServices(environment: environment)
        InspectorCard {
            VStack(alignment: .leading, spacing: ZPDFSpacing.xs) {
                Text(String(
                    format: NSLocalizedString(
                        "New %@", comment: "Inspector tool style card title; the markup kind the armed tool draws"
                    ),
                    kind.displayName
                ))
                .zpdfText(.cardTitle, .textPrimary)
                .accessibilityAddTraits(.isHeader)
                Text(NSLocalizedString(
                    "The style the next markup you draw takes. Nothing is selected, so nothing on the page changes.",
                    comment: "Inspector tool style card explanation"
                ))
                .zpdfText(.caption, .textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            if Self.toolAcceptsFill(kind) {
                InspectorInlineRow(label: NSLocalizedString("Fill Colour", comment: "Inspector row label: the markup's interior colour")) {
                    InspectorColourControl(
                        value: style.fill,
                        isMixed: false,
                        isEnabled: true,
                        showsHex: false,
                        accessibilityTitle: NSLocalizedString(
                            "Tool fill colour", comment: "Accessibility label of the tool style card's fill swatch"
                        ),
                        role: "tool.fill",
                        noneChoice: style.fill == nil ? nil : (
                            title: NSLocalizedString("No Fill", comment: "Colour palette: removes the markup's fill"),
                            action: { toolbar.setStyle(ZenitToolbarModel.style(toolbar.activeSelection.style, applying: MarkupStyleEdit(removesFill: true))) }
                        ),
                        services: services
                    ) { picked in
                        var fill = picked
                        fill.alpha = style.fill?.alpha ?? InspectorMarkupFormatting.derivedFillAlpha
                        toolbar.setStyle(ZenitToolbarModel.style(toolbar.activeSelection.style, applying: MarkupStyleEdit(fill: fill)))
                    }
                    .id(kind)
                }
            }

            InspectorInlineRow(label: NSLocalizedString("Border", comment: "Inspector row label: the stroke colour and width")) {
                HStack(spacing: ZPDFSpacing.l) {
                    InspectorColourControl(
                        value: style.stroke,
                        isMixed: false,
                        isEnabled: true,
                        showsHex: false,
                        accessibilityTitle: NSLocalizedString(
                            "Tool border colour", comment: "Accessibility label of the tool style card's stroke swatch"
                        ),
                        role: "tool.border",
                        services: services
                    ) { picked in
                        toolbar.setStyle(ZenitToolbarModel.style(toolbar.activeSelection.style, applying: MarkupStyleEdit(color: picked)))
                    }
                    .id(kind)
                    InspectorNumberControl(
                        value: style.lineWidth,
                        isMixed: false,
                        isEnabled: true,
                        range: InspectorStyleEditing.lineWidthRange,
                        step: 0.25,
                        suffix: NSLocalizedString("pt", comment: "Points, the PDF unit"),
                        accessibilityLabel: NSLocalizedString("Tool line width in points", comment: "Accessibility label")
                    ) { width in
                        toolbar.setStyle(ZenitToolbarModel.style(toolbar.activeSelection.style, applying: MarkupStyleEdit(lineWidth: width)))
                    }
                }
            }

            if Self.carriesText(kind) {
                InspectorInlineRow(label: NSLocalizedString("Text size", comment: "Inspector row label")) {
                    InspectorNumberControl(
                        value: style.fontSize,
                        isMixed: false,
                        isEnabled: true,
                        range: InspectorStyleEditing.fontSizeRange,
                        step: 1,
                        suffix: NSLocalizedString("pt", comment: "Points, the PDF unit"),
                        accessibilityLabel: NSLocalizedString("Tool text size in points", comment: "Accessibility label")
                    ) { size in
                        toolbar.setStyle(ZenitToolbarModel.style(toolbar.activeSelection.style, applying: MarkupStyleEdit(fontSize: size)))
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(NSLocalizedString("Tool style", comment: "Accessibility label of the Inspector's tool style card")))
    }
}
