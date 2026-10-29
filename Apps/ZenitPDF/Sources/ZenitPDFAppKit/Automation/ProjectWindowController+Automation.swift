import AppKit
import Foundation
import ZPDFAppCore
import ZPDFContracts
import ZPDFSnapEngine
import ZPDFVectorExtraction

/// Connects a document's canvas to the facts automation needs (nl-automation).
extension ProjectWindowController {

    func wireAutomation(canvas: PDFCanvasViewController, for document: ZenitPDFProjectDocument) {
        canvas.automationContext = CanvasAutomationContext(
            traceHiddenLayerIDs: { [weak document] pageID, _ in
                // The snap index's set: hidden layers, and every other layer under a measure
                // lock. A trace follows exactly what the person can measure on — on the primary
                // drawing's sheets; the panel hides nothing on another drawing's (U-012).
                guard let document, let page = document.pageDescriptor(forPage: pageID) else { return [] }
                return document.hiddenLayerNames(for: page, snap: true)
            },
            traceChoices: { [weak document] in
                document?.automation.traceChoices ?? .none
            },
            extraction: { [weak self, weak document] pageID, _ in
                // The page's own drawing and its own store (U-007).
                guard let self, let document, let page = document.pageDescriptor(forPage: pageID) else { return nil }
                return try? await self.automationExtraction(for: document, page: page)
            },
            underlayIsLayerComplete: { [weak document] in
                document?.layerVisibility.items.isEmpty ?? true
            },
            offerIslands: { [weak document] pageID, ring, islands, metresPerPoint in
                document?.offerIslandCutouts(pageID: pageID, ring: ring, islands: islands, metresPerPoint: metresPerPoint)
            },
            scanPreparedTrace: { [weak document] pageID, pageIndex in
                guard let document else { return nil }
                return await ScanTrace.preparedTrace(document: document, pageIndex: pageIndex, pageID: pageID)
            }
        )
    }

    /// The page's extraction for a feature that needs the error when there is one: the canvas's
    /// own when it is this page's and the drawing has no layers, otherwise the store.
    func automationExtraction(
        for document: ZenitPDFProjectDocument,
        page: ZPDFContracts.PageDescriptor
    ) async throws -> VectorPageExtraction {
        // The page's own drawing and its own store, in a project of several (NL-DOCS-04).
        guard let resolved = document.automationExtractionStore(forPage: page.id.rawValue) else {
            throw AutomationError.noDrawing
        }
        let store = resolved.store
        if let canvas = canvasController(for: document),
           let held = canvas.heldExtraction(forPageID: page.id.rawValue) {
            store.adopt(held, pageIndex: page.index, drawingHasLayers: !document.layerVisibility.items.isEmpty)
        }
        return try await store.extraction(url: resolved.drawing.url, pageIndex: page.index, password: resolved.password)
    }

    enum AutomationError: Error {
        case noDrawing
    }
}
