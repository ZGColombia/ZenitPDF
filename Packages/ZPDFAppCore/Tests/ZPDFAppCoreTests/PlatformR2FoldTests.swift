import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts

/// The save's fold of removed sheets keeps every project-level setting.
@Suite("Folding removed sheets keeps the project's layers and captures")
struct PlatformR2FoldTests {

    @Test("A project with a removed sheet folds with its layer list, active layer, units and set-aside captures")
    func foldKeepsProjectSettings() {
        let document = DocumentID(UUID())
        func page(_ index: Int) -> ZPDFContracts.PageDescriptor {
            ZPDFContracts.PageDescriptor(id: PageID(UUID()), documentID: document, index: index, label: "A-\(index)",
                                         boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 100, height: 100)))
        }
        var state = TakeoffSession.TakeoffState(pages: [page(0)], markups: [], scales: [], pageScaleIDs: [:])
        state.excludedPages = [page(1)]
        let layer = MarkupLayer.makeDefault()
        state.markupLayers = [layer]
        state.activeMarkupLayerID = layer.id
        let captured = MarkupID(UUID())
        state.uncalibratedCaptures = [captured: CaptureMethod(kind: .roomDetected)]
        let folded = state.foldingArrangement()
        #expect(folded.pages.count == 2, "the removed sheet is folded back in")
        #expect(folded.markupLayers == [layer])
        #expect(folded.activeMarkupLayerID == layer.id)
        #expect(folded.uncalibratedCaptures[captured]?.kind == .roomDetected)
    }
}
