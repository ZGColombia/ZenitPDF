import Foundation
import Testing
import ZPDFUIPresentation

/// Live test 5, L-20: words read by Tools ▸ Read Text from Scanned Pages were never found by
/// search, because the default scope left recognised text out and nothing added it.
@Suite("Search scope default includes recognised text (L-20)")
struct LV5SearchScopeDefaultTests {

    @Test("L-20: the default scope searches recognised text alongside the PDF text and markups")
    func defaultScopeSearchesRecognisedText() {
        // Old: `[.pdfText, .markups, .comments, .labels]` — no `.ocrText`, so a recognised scan
        // answered "No results" for words plainly on it.
        #expect(SearchScope().sources.contains(.ocrText))
        #expect(SearchScope.default.sources.contains(.ocrText))
        #expect(SearchScope.default.sources == [.pdfText, .ocrText, .markups, .comments, .labels])
        // Custom fields stay opt-in: they are ledger values, not words on the drawing.
        #expect(!SearchScope.default.sources.contains(.customFields))
    }

    @Test("L-20: the default scope's summary names OCR Text")
    func defaultSummaryNamesRecognisedText() {
        // Old: "Current Document · PDF Text, Markups, Comments, Labels".
        #expect(SearchScope.default.summary == "Current Document · PDF Text, OCR Text, Markups, Comments, Labels")
    }
}
