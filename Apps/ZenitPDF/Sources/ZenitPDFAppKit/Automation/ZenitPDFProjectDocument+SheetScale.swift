import Foundation
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation

/// The scale proposal per sheet (nl-automation; bug `ZenitPDFProjectDocument.swift:1118`).
extension ZenitPDFProjectDocument {

    /// Proposes a scale for the sheet with this identity, once per sheet per session.
    func proposeScale(forPageID id: UUID) {
        guard let page = loadedDrawing(forPage: id)?.pages.first(where: { $0.id.rawValue == id }) else { return }
        proposeScale(for: page)
    }

    /// Reads the sheet's positioned text and offers its scale through the warning tray — skipped
    /// when the sheet already has a scale (checked by ``presentScaleProposal(_:pageID:)``), and
    /// only once per sheet, so turning back and forth never repeats an offer the person dismissed.
    /// An offer for another sheet that is still waiting comes down: it belonged to that sheet.
    func proposeScale(for page: ZPDFContracts.PageDescriptor) {
        // The sheet's own drawing, in a project of several (NL-DOCS-04).
        guard let source = loadedDrawing(forPage: page.id.rawValue), core != nil else { return }
        withdrawScaleProposals(exceptPage: page.id)
        guard automation.scaleProposalConsideredPages.insert(page.id.rawValue).inserted else { return }
        Task { @MainActor [weak self] in
            guard let self, self.core != nil else { return }
            let lines = (try? await source.rasterSource.pageTextLines(pageIndex: page.index)) ?? []
            let box = page.visibleBox
            var recognised = lines.map { line in
                RecognisedTextLine(
                    text: line.text,
                    boundsInPageSpace: PDFRectValue(
                        x: line.boundsInPageSpace.origin.x, y: line.boundsInPageSpace.origin.y,
                        width: line.boundsInPageSpace.width, height: line.boundsInPageSpace.height
                    )
                )
            }
            if recognised.isEmpty {
                // A scanned sheet has no text layer. When the person has run text recognition on
                // the drawing (OCR is opt-in per project), its stored words stand in (NL-AUTO-03);
                // this automatic offer never starts a recognition run of its own. The sheet's own
                // drawing's words (T-006), never the primary drawing's same-index sheet.
                let words = await self.recognisedWords(onPage: page)
                recognised = BaselineLineMerger.merge(words.map {
                    RecognisedTextLine(
                        text: $0.text,
                        boundsInPageSpace: PDFRectValue(x: $0.bounds.origin.x, y: $0.bounds.origin.y, width: $0.bounds.width, height: $0.bounds.height)
                    )
                })
            }
            guard !recognised.isEmpty else { return }
            // `/UserUnit` (CR-128): the proposal's nominal ratio is per PDF point, and a page that
            // declares a user unit scales every point by it.
            guard let proposal = SheetScaleProposer().proposal(
                lines: recognised,
                pageBox: PDFRectValue(x: box.origin.x, y: box.origin.y, width: box.size.width, height: box.size.height),
                userUnit: page.userUnit
            ) else { return }
            // The person may have turned the page again while the text was read.
            guard self.core?.document.currentPageID == page.id.rawValue || self.core?.document.currentPageID == nil else {
                self.automation.scaleProposalConsideredPages.remove(page.id.rawValue)
                return
            }
            self.presentScaleProposal(proposal, pageID: page.id)
        }
    }

    /// Takes down waiting offers for other sheets, and lets each be offered again on return.
    private func withdrawScaleProposals(exceptPage keep: ZPDFContracts.PageID) {
        guard let core else { return }
        for (warningID, pending) in pendingScaleProposals where pending.pageID != keep {
            pendingScaleProposals[warningID] = nil
            automation.scaleProposalConsideredPages.remove(pending.pageID.rawValue)
            core.document.dismissWarning(id: warningID)
        }
    }
}
