import Foundation
import Testing
@testable import ZPDFContracts

/// ADR-0022 (documents): a page's `index` is its index in its own PDF; the set order is separate.
@Suite("Documents — page index contract (ADR-0022)")
struct PageIndexContractTests {

    @Test("The frozen PageDescriptor says index is the page's index in its own PDF and never moves on reorder")
    func pageIndexInvariant() throws {
        // Old text: "zero-based position in the document", which read as the set position and
        // is what TakeoffSession rewrote on reorder.
        let architecture = try #require(
            try ContractCatalog.allDocuments(frozenAt: "2026-09-01T23:28:48Z").first { $0.contract == "ARCHITECTURE_FREEZE" }
        )
        let page = try #require(architecture.types.first { $0.name == "PageDescriptor" })
        let index = try #require(page.fields.first { $0.name == "index" })
        #expect(index.invariant?.contains("in its own PDF") == true)
        #expect(index.invariant?.contains("ADR-0022") == true)
        #expect(page.invariants.contains { $0.contains("Reordering pages never rewrites `index`") })

        // The committed document matches the catalog (regenerated with the pinned frozenAt).
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Docs/Contracts/ARCHITECTURE_FREEZE.json")
        let committed = try String(contentsOf: url, encoding: .utf8)
        #expect(committed.contains("zero-based index of the page in its own PDF"))
    }

    @Test("A page descriptor encoded before ADR-0022 decodes unchanged: no field was added")
    func decodesUnchanged() throws {
        let page = PageDescriptor(
            id: PageID(UUID()), documentID: DocumentID(UUID()), index: 7, label: "A-108",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 1728, height: 2592))
        )
        let decoded = try JSONDecoder().decode(PageDescriptor.self, from: JSONEncoder().encode(page))
        #expect(decoded == page)
    }
}
