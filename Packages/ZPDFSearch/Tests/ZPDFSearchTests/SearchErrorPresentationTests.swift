import Foundation
import Testing
@testable import ZPDFSearch

/// IM-007: a search error bridged to NSError keeps a readable sentence.
struct SearchErrorPresentationTests {
    /// Old output: "The operation couldn’t be completed. (ZPDFSearch.ZPDFSearchError error 9.)"
    @Test("IM-007: a search error bridged to NSError keeps its sentence and a suggestion")
    func bridgedErrorIsReadable() {
        let errors: [ZPDFSearchError] = [
            .cancelled, .unknownDocument(documentId: "d"), .pageRangeOutOfBounds(lowerBound: 0, upperBound: 9, pageCount: 3),
            .recognitionFailed(pageIndex: 4, reason: "r"), .pageRenderFailed(pageIndex: 2, reason: "r"),
            .storage("disk"), .engine("pdf"),
        ]
        for error in errors {
            let bridged = error as NSError
            #expect(!bridged.localizedDescription.contains("ZPDFSearchError"), "\(error)")
            #expect(!bridged.localizedDescription.contains("couldn’t be completed"), "\(error)")
            #expect(bridged.localizedFailureReason == error.description)
        }
        #expect((ZPDFSearchError.recognitionFailed(pageIndex: 4, reason: "x") as NSError)
            .localizedDescription.contains("page 5"))
        #expect((ZPDFSearchError.storage("disk") as NSError).localizedRecoverySuggestion != nil)
    }
}
