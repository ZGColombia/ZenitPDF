import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

/// Stand-in for the page renderer, used where no canvas provider is injected.
///
/// The application injects the real canvas — the PDF renderer plus the Zenit overlay —
/// through ``ProjectWindowLayoutController``'s canvas provider. Package tests and previews
/// inject none, and get this view: it draws the page box and the bounding geometry of the
/// presenter's markups so the surrounding shell — split proportions, selection round-trips,
/// status-bar cursor readout, Inspector binding — can be exercised and visually reviewed
/// against real proportions.
///
/// Two rules keep the stand-in honest:
/// 1. It only ever reads presenter values. It invents no geometry of its own.
/// 2. Nothing in the visible copy calls itself a placeholder or a preview. A user must never be
///    shown scaffolding vocabulary.
public struct CanvasHostPlaceholder: View {

    private let environment: ProjectShellEnvironment

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Creates the canvas host.
    public init(environment: ProjectShellEnvironment) {
        self.environment = environment
    }

    private var canvas: any CanvasPresenting { environment.canvas }

    public var body: some View {
        GeometryReader { proxy in
            let page = environment.document.currentPage
            ZStack {
                ZPDFColor.color(.canvasBackdrop)
                if let page {
                    pageContent(page: page, in: proxy.size)
                } else {
                    ZPDFEmptyState(
                        glyph: .symbol(.pages),
                        title: NSLocalizedString("No page to show", comment: "Canvas empty state title"),
                        message: NSLocalizedString(
                            "Open a drawing to start marking up and measuring.",
                            comment: "Canvas empty state message"
                        )
                    )
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(NSLocalizedString(
            "Page canvas",
            comment: "Accessibility label for the drawing canvas"
        )))
        .accessibilityValue(Text(canvasAccessibilityValue))
    }

    @ViewBuilder
    private func pageContent(page: PageDescriptor, in size: CGSize) -> some View {
        let layout = Self.pageLayout(page: page, viewport: size)
        ZStack(alignment: .topLeading) {
            // The page sheet.
            RoundedRectangle(cornerRadius: ZPDFRadius.hairline, style: .continuous)
                .fill(ZPDFColor.color(.surface))
                .overlay {
                    RoundedRectangle(cornerRadius: ZPDFRadius.hairline, style: .continuous)
                        .strokeBorder(ZPDFColor.border, lineWidth: ZPDFStroke.hairline)
                }
                .frame(width: layout.rect.width, height: layout.rect.height)
                .offset(x: layout.rect.minX, y: layout.rect.minY)
                .shadow(radius: reduceMotion ? 0 : 6, y: 2)

            markupLayer(page: page, layout: layout)
            snapLayer(page: page, layout: layout)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .overlay(alignment: .topLeading) {
            Text(page.label)
                .zpdfText(.caption, .textSecondary)
                .padding(ZPDFSpacing.s)
        }
    }

    /// The markups this page actually draws.
    ///
    /// The Navigator's markup-layer checkboxes reach the drawing here: one shared set on
    /// ``NavigatorLayerListModel``, written by whichever layer list is on screen and read by
    /// the canvas. Before it, visibility lived in two independent `@State` sets that disagreed
    /// with each other and reached nothing — unticking "Walls" hid no markups at all (CR-112).
    ///
    /// Static and value-only so the filter is assertable without a view tree.
    static func drawnMarkups(
        _ markups: [MarkupSummary],
        onPage pageID: PageDescriptor.ID,
        layers: NavigatorLayerListModel
    ) -> [MarkupSummary] {
        markups.filter { markup in
            markup.pageID == pageID
                && !markup.hidden
                && layers.drawsMarkup(onLayer: markup.layer)
        }
    }

    private func markupLayer(page: PageDescriptor, layout: PageLayout) -> some View {
        Canvas { context, _ in
            let selection = canvas.selectedMarkupIDs
            for markup in Self.drawnMarkups(
                canvas.visibleMarkups,
                onPage: page.id,
                layers: environment.navigatorLayers
            ) {
                let rect = layout.convert(markup.boundsInPageSpace)
                let stroke = Color(
                    .sRGB,
                    red: markup.colorRGBA.red,
                    green: markup.colorRGBA.green,
                    blue: markup.colorRGBA.blue,
                    opacity: markup.colorRGBA.alpha
                )
                let path = Path(roundedRect: rect, cornerRadius: 1)
                context.stroke(path, with: .color(stroke), lineWidth: ZPDFStroke.measurement)
                if selection.contains(markup.id) {
                    // Selection is a second, dashed ring rather than a colour change, so it
                    // survives a markup that is already drawn in the selection tint.
                    let ring = Path(roundedRect: rect.insetBy(dx: -3, dy: -3), cornerRadius: 2)
                    context.stroke(
                        ring,
                        with: .color(ZPDFColor.color(.selection)),
                        style: StrokeStyle(lineWidth: ZPDFStroke.emphasis, dash: [3, 2])
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func snapLayer(page: PageDescriptor, layout: PageLayout) -> some View {
        if let feedback = canvas.snapFeedback, feedback.pageID == page.id {
            let point = layout.convert(feedback.pagePoint)
            Circle()
                .strokeBorder(ZPDFColor.color(.snapHighlight), lineWidth: ZPDFStroke.emphasis)
                .frame(width: 12, height: 12)
                .offset(x: point.x - 6, y: point.y - 6)
                .allowsHitTesting(false)
        }
    }

    private var canvasAccessibilityValue: String {
        let selected = canvas.selectedMarkups
        guard !selected.isEmpty else {
            let format = NSLocalizedString(
                "%1$d markups on this page, nothing selected, zoom %2$@",
                comment: "Accessibility value describing the canvas with no selection"
            )
            return String(
                format: format,
                canvas.visibleMarkups.count,
                canvas.viewport.zoomDisplayString
            )
        }
        if selected.count == 1, let markup = selected.first {
            return markup.accessibilityLabel
        }
        let format = NSLocalizedString(
            "%1$d markups selected of %2$d on this page",
            comment: "Accessibility value describing a multiple canvas selection"
        )
        return String(format: format, selected.count, canvas.visibleMarkups.count)
    }

    // MARK: - Page mapping

    /// The mapping from PDF page space to view space for one laid-out page.
    struct PageLayout {
        let rect: CGRect
        let pageBox: PDFRectValue

        func convert(_ pageRect: PDFRectValue) -> CGRect {
            CGRect(
                x: rect.minX + (pageRect.minX - pageBox.minX) * scaleX,
                y: rect.minY + (pageBox.maxY - pageRect.maxY) * scaleY,
                width: pageRect.size.width * scaleX,
                height: pageRect.size.height * scaleY
            )
        }

        func convert(_ point: PDFPointValue) -> CGPoint {
            CGPoint(
                x: rect.minX + (point.x - pageBox.minX) * scaleX,
                y: rect.minY + (pageBox.maxY - point.y) * scaleY
            )
        }

        private var scaleX: CGFloat {
            pageBox.size.width > 0 ? rect.width / pageBox.size.width : 1
        }

        private var scaleY: CGFloat {
            pageBox.size.height > 0 ? rect.height / pageBox.size.height : 1
        }
    }

    /// Fits the page inside the viewport with a margin, preserving aspect ratio.
    static func pageLayout(page: PageDescriptor, viewport: CGSize) -> PageLayout {
        let box = page.visibleBox
        let margin: CGFloat = ZPDFSpacing.xxl
        let availableWidth = max(1, viewport.width - margin * 2)
        let availableHeight = max(1, viewport.height - margin * 2)
        let pageWidth = max(1, CGFloat(box.size.width))
        let pageHeight = max(1, CGFloat(box.size.height))
        let scale = min(availableWidth / pageWidth, availableHeight / pageHeight)
        let width = pageWidth * scale
        let height = pageHeight * scale
        let rect = CGRect(
            x: (viewport.width - width) / 2,
            y: (viewport.height - height) / 2,
            width: width,
            height: height
        )
        return PageLayout(rect: rect, pageBox: box)
    }
}

#if DEBUG
struct CanvasHost_Previews: PreviewProvider {
    static var previews: some View {
        CanvasHostPlaceholder(environment: .mock())
            .frame(width: 720, height: 520)
    }
}
#endif
