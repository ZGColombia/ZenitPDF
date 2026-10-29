#if DEBUG
import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

/// Builds the workflow surfaces over the mock presenters, so every screen in this package can be
/// looked at without the core engines. Nothing here ships in a release build.
@MainActor
enum WorkflowPreviewFixtures {

    static let environment = MockPresenters.makeEnvironment()

    static var toolLibraryModel: ToolLibraryEditingModel {
        ToolLibraryEditingModel(presets: environment.project.presets)
    }

    static var overlayModel: RevisionOverlayModel {
        let model = RevisionOverlayModel(revisions: environment.project.revisions)
        model.capturePair(baseline: PDFPointValue(x: 40, y: 40), comparison: PDFPointValue(x: 42, y: 39))
        model.capturePair(baseline: PDFPointValue(x: 700, y: 60), comparison: PDFPointValue(x: 703, y: 58))
        model.capturePair(baseline: PDFPointValue(x: 380, y: 520), comparison: PDFPointValue(x: 381, y: 523))
        return model
    }

    static var ocrModel: OCRRunModel {
        let pages = environment.project.pages
        let model = OCRRunModel(pages: pages)
        for (offset, page) in pages.prefix(4).enumerated() {
            model.record(OCRPageStatusSummary(
                id: page.id,
                pageLabel: page.label,
                pageIndex: page.index,
                status: offset == 3 ? .noTextFound : .indexed,
                confidence: offset == 3 ? nil : 0.94 - Double(offset) * 0.14,
                recognizedWordCount: offset == 3 ? 0 : 180 - offset * 40,
                languageIDs: ["en-US"]
            ))
        }
        return model
    }

    static var splitCanvasController: SplitCanvasController {
        let controller = SplitCanvasController(layout: .twoColumns, syncOptions: .locked)
        let pages = environment.project.pages
        if let first = pages.first {
            controller.setContent(
                documentID: environment.project.documentID,
                documentTitle: environment.project.documentTitle,
                page: first,
                in: .first
            )
        }
        if pages.count > 1 {
            controller.setContent(
                documentID: environment.project.documentID,
                documentTitle: environment.project.documentTitle,
                page: pages[1],
                in: .second
            )
        }
        return controller
    }

    /// A stand-in for a page, so a preview shows the arrangement rather than a blank rectangle.
    struct PagePlaceholder: View {
        var label: String

        var body: some View {
            ZStack {
                Rectangle().fill(ZPDFColor.surface)
                Text(label).zpdfText(.monoNumeric, .textSecondary)
            }
        }
    }
}

struct ToolLibraryPanelView_Previews: PreviewProvider {
    static var previews: some View {
        ToolLibraryPanelView(
            presenter: WorkflowPreviewFixtures.environment.toolLibrary,
            model: WorkflowPreviewFixtures.toolLibraryModel,
            selectedMarkup: WorkflowPreviewFixtures.environment.project.markups.first,
            onClose: {}
        )
        .frame(width: 620, height: 520)
        .previewDisplayName("Tool Library")
    }
}

struct ToolSetImportReviewSheet_Previews: PreviewProvider {
    static var previews: some View {
        ToolSetImportReviewSheet(
            review: ToolSetImportValidator().review(
                document: ToolSetDocument(
                    name: "Shared Concrete Tools",
                    author: "A. Surveyor",
                    exporting: WorkflowPreviewFixtures.environment.project.presets
                ),
                fileName: "Shared Concrete Tools.zpdftools"
            ),
            onImport: {},
            onCancel: {}
        )
        .previewDisplayName("Tool set import review")
    }
}

struct OCRRunSheet_Previews: PreviewProvider {
    static var previews: some View {
        OCRRunSheet(model: WorkflowPreviewFixtures.ocrModel, onClose: {})
            .previewDisplayName("Read scanned pages")
    }
}

struct SplitCanvasView_Previews: PreviewProvider {
    static var previews: some View {
        let controller = WorkflowPreviewFixtures.splitCanvasController
        return VStack(spacing: 0) {
            SplitCanvasControls(controller: controller, onClose: {})
                .padding(ZPDFSpacing.m)
            SplitCanvasView(controller: controller) { pane in
                WorkflowPreviewFixtures.PagePlaceholder(label: pane.pageLabel)
            }
        }
        .frame(width: 760, height: 480)
        .previewDisplayName("Split Canvas")
    }
}

struct RevisionCompareView_Previews: PreviewProvider {
    static var previews: some View {
        RevisionCompareView(
            presenter: WorkflowPreviewFixtures.environment.compare,
            model: RevisionCompareModel(),
            onClose: {}
        ) { role in
            WorkflowPreviewFixtures.PagePlaceholder(label: role.displayName)
        }
        .frame(width: 900, height: 700)
        .previewDisplayName("Revision Compare")
    }
}

struct RevisionOverlayView_Previews: PreviewProvider {
    static var previews: some View {
        RevisionOverlayView(model: WorkflowPreviewFixtures.overlayModel, onClose: {}) {
            WorkflowPreviewFixtures.PagePlaceholder(label: "A-101")
        }
        .frame(width: 900, height: 620)
        .previewDisplayName("Revision Overlay")
    }
}

struct OnboardingFlow_Previews: PreviewProvider {
    static var previews: some View {
        WorkflowPreviewFixtures.PagePlaceholder(label: "A-101")
            .zpdfOnboarding(OnboardingModel(store: InMemoryOnboardingProgressStore()))
            .frame(width: 700, height: 560)
            .previewDisplayName("Getting started")
    }
}
#endif
