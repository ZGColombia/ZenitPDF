import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation
import ZPDFUIWorkflows

/// Split Canvas, as the canvas pane shows it.
///
/// `SplitCanvasView` is generic over what one pane draws, because the workflows package must
/// not know what a Zenit canvas is. This is the shell's concrete filling: an **occupied** pane
/// asks `paneContent` — the app tier's live page renderer, injected through
/// ``ProjectShellEnvironment/splitCanvasPaneContent`` — and only when that is missing or
/// declines does it fall back to the labelled placeholder sheet, which is what the shell can
/// honestly draw on its own. An **empty** pane always shows the placeholder: its card is the
/// affordance ("drop a drawing here…"), not a failed render. Shipping the placeholder for
/// occupied panes too was LT-24 — the mode named the drawing and never drew it.
struct SplitCanvasModePane: View {

    let controller: SplitCanvasController
    let paneContent: (@MainActor (SplitCanvasPaneState) -> AnyView?)?
    let onClose: @MainActor () -> Void

    init(
        controller: SplitCanvasController,
        paneContent: (@MainActor (SplitCanvasPaneState) -> AnyView?)? = nil,
        onClose: @escaping @MainActor () -> Void
    ) {
        self.controller = controller
        self.paneContent = paneContent
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            SplitCanvasControls(controller: controller, onClose: onClose)
            ZPDFHairlineDivider(axis: .horizontal)
            SplitCanvasView(controller: controller) { pane in
                if !pane.isEmpty, let live = paneContent?(pane) {
                    live
                } else {
                    CanvasModePlaceholderPane(
                        title: pane.isEmpty
                            ? NSLocalizedString("Empty pane", comment: "Split Canvas placeholder title")
                            : pane.documentTitle,
                        detail: pane.isEmpty
                            ? NSLocalizedString(
                                "Drop a drawing here, or pick one from the document tabs.",
                                comment: "Split Canvas placeholder detail for an empty pane"
                            )
                            : String(
                                format: NSLocalizedString(
                                    "Page %1$@ · %2$d %%",
                                    comment: "Split Canvas placeholder detail: page label and zoom percent"
                                ),
                                pane.pageLabel,
                                Int((pane.zoom * 100).rounded())
                            )
                    )
                }
            }
        }
        .background(ZPDFColor.background)
    }
}

/// Revision Overlay, as the canvas pane shows it.
struct RevisionOverlayModePane: View {

    let model: RevisionOverlayModel
    let onClose: @MainActor () -> Void

    var body: some View {
        RevisionOverlayView(model: model, onClose: onClose) {
            CanvasModePlaceholderPane(
                title: NSLocalizedString("Overlay", comment: "Revision Overlay placeholder title"),
                detail: NSLocalizedString(
                    "The stacked revisions are drawn here once the drawings are registered.",
                    comment: "Revision Overlay placeholder detail"
                )
            )
        }
        .background(ZPDFColor.background)
    }
}

/// What a canvas view mode draws where a real page would go, when the shell is running without
/// an app-tier canvas behind it.
///
/// It names itself. A blank rectangle in a shipped mode reads as a broken render, and a person
/// who cannot tell the two apart files the wrong bug.
struct CanvasModePlaceholderPane: View {

    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: ZPDFSpacing.xs) {
            ZPDFGlyphView(.symbol(.pages), size: ZPDFSpacing.Control.iconLarge)
                .foregroundStyle(ZPDFColor.textSecondary)
            Text(title).zpdfText(.control, .textPrimary)
            Text(detail)
                .zpdfText(.caption, .textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(ZPDFSpacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ZPDFColor.canvasBackdrop)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(title). \(detail)"))
    }
}
