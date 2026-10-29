import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIWorkflows

/// R-140. The OCR sheet reads a typed page list with ``PageRangeParser``, the grammar every
/// sheet shares, instead of a private copy that had drifted from it.
@Suite("OCR page list grammar", .workflowsTierSerialised)
@MainActor
struct OCRPageRangeGrammarTests {

    private func pages(_ count: Int) -> [PageDescriptor] {
        (0..<count).map { index in
            PageDescriptor(
                id: UUID(), index: index, label: "A-\(101 + index)",
                mediaBox: PDFRectValue(x: 0, y: 0, width: 842, height: 595),
                cropBox: PDFRectValue(x: 0, y: 0, width: 842, height: 595),
                rotation: .degrees0
            )
        }
    }

    /// Old output: `3-` and `-3` split into `["3"]` (the default split drops empty pieces) and
    /// ran recognition on page 3 — index 2 — with nothing said back.
    @Test("A half-open range names no page and is said back")
    func halfOpenRangeIsRejected() {
        for text in ["3-", "-3"] {
            #expect(OCRPageRangeSelection.custom(text).resolvedIndices(pageCount: 10, currentPageIndex: 0).isEmpty, "\(text)")
        }
        let model = OCRRunModel(pages: pages(10), preferredLanguages: ["en-US"])
        model.rangeSelection = .custom("")
        model.customRangeText = "1, 3-, -5, 7-8"
        // 1 → index 0; 7-8 → indices 6 and 7; the two half-open fragments are named.
        #expect(model.resolvedPageIndices == IndexSet([0, 6, 7]))
        #expect(model.rejectedRangeFragments == ["3-", "-5"])
    }

    /// Old output: a trap on `1...0` — the copy checked `(1...pageCount).contains(single)` with
    /// no `pageCount > 0` guard, and `rejectedRangeFragments` reached it with an empty document.
    @Test("A page list in a document with no pages is rejected, not a trap")
    func emptyDocumentDoesNotTrap() {
        let model = OCRRunModel(pages: [], preferredLanguages: ["en-US"])
        model.rangeSelection = .custom("")
        model.customRangeText = "3, 1-2"
        #expect(model.rejectedRangeFragments == ["3", "1-2"])
        #expect(model.resolvedPageIndices.isEmpty)
    }

    /// The shared grammar and the sheet agree fragment for fragment.
    @Test("The sheet resolves exactly what the shared parser resolves")
    func sheetMatchesSharedParser() {
        for text in ["1-4, 7, 12-14", "5-2", "0-3", "1-99", "banana, -, ,", "2; 4", " 6 "] {
            #expect(
                OCRPageRangeSelection.custom(text).resolvedIndices(pageCount: 20, currentPageIndex: 0)
                    == PageRangeParser.indices(in: text, pageCount: 20),
                "\(text)"
            )
        }
    }
}
