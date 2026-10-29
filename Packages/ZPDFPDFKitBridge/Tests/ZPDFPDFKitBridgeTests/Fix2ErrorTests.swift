import Foundation
import Testing
@testable import ZPDFPDFKitBridge

/// IM-007: bridge errors reach an alert as the sentence written for them, not as
/// "error N".
struct Fix2ErrorTests {

    @Test("IM-007: a bridge error bridged to NSError keeps its sentence and offers a suggestion")
    func bridgeErrorIsLocalized() {
        let error = PDFBridgeError.pageCountExceedsLimit(pageCount: 12_000, limit: 5_000)
        let bridged = error as NSError
        // Old output: "The operation couldn't be completed. (ZPDFPDFKitBridge.PDFBridgeError error 5.)"
        #expect(bridged.localizedDescription == "12000 pages, limit is 5000.")
        #expect(!bridged.localizedDescription.contains("couldn't be completed"))
        #expect(bridged.localizedRecoverySuggestion?.isEmpty == false)
        #expect((PDFBridgeError.cancelled as NSError).localizedDescription == "Cancelled.")
        #expect((PDFBridgeError.cancelled as NSError).localizedRecoverySuggestion == nil)
    }
}
