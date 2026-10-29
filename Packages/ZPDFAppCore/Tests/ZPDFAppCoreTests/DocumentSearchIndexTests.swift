import Foundation
import Testing
import ZPDFContracts
import ZPDFPDFKitBridge
import ZPDFPersistence

@testable import ZPDFAppCore

/// The parts of ``DocumentSearchIndex`` that are pure, and the identity mapping that decides
/// whether a hit lands on the right page or is dropped.
///
/// The end-to-end path — open a drawing, index it, search it, recognise a page, find the
/// recognised word — is asserted in the application package, against the shipping document.
/// What is here is what can be got wrong silently.
struct DocumentSearchIndexTests {

    // MARK: - Page ranges

    @Test("A contiguous selection is one engine call")
    func contiguousSelectionIsOneRange() {
        #expect(DocumentSearchIndex.contiguousRanges(of: [0, 1, 2, 3]) == [0..<4])
        #expect(DocumentSearchIndex.contiguousRanges(of: [7]) == [7..<8])
        #expect(DocumentSearchIndex.contiguousRanges(of: []) == [])
    }

    @Test("A gapped selection becomes one range per run, never one call per page")
    func gappedSelectionIsGrouped() {
        // "1-4, 7, 12-14" one-based is 0...3, 6, 11...13 zero-based.
        #expect(DocumentSearchIndex.contiguousRanges(of: [0, 1, 2, 3, 6, 11, 12, 13])
                == [0..<4, 6..<7, 11..<14])
    }

    @Test("The grouping never invents a page between two runs")
    func groupingCoversExactlyTheRequestedPages() {
        let requested = [2, 3, 9, 10, 11, 40]
        let covered = DocumentSearchIndex.contiguousRanges(of: requested).flatMap { Array($0) }
        // The engine reads what was asked for and nothing else. A range that swallowed the gap
        // would recognise pages the person did not select — twenty minutes of Vision on sheets
        // nobody asked about, and index rows they did not consent to.
        #expect(covered == requested)
    }

    // MARK: - Page keys

    @Test("Page keys are derived from the file, not from the session")
    func pageKeysAreStableAcrossSessions() {
        let sha = String(repeating: "a", count: 64)
        let first = DocumentSearchIndex.pageKey(documentKey: sha, pageIndex: 3)
        let second = DocumentSearchIndex.pageKey(documentKey: sha, pageIndex: 3)
        #expect(first == second)
        #expect(first != DocumentSearchIndex.pageKey(documentKey: sha, pageIndex: 4))
        #expect(first.hasPrefix(sha))
    }

    // MARK: - Identity mapping

    @Test("A hit resolves to the session's own page identity")
    func identityMapResolvesPages() async throws {
        let index = try await Self.makeIndex()
        defer { Task { await index.shutDown() } }

        let documentUUID = UUID()
        let pages = Self.pages(count: 3, documentID: DocumentID(documentUUID))
        let map = index.identityMap(
            documentUUID: documentUUID,
            documentTitle: "Plan A-101",
            pages: pages,
            currentPageIndex: 1
        )
        #expect(map.currentDocumentKey == index.documentKey)
        #expect(map.currentPageKey
                == DocumentSearchIndex.pageKey(documentKey: index.documentKey, pageIndex: 1))
    }

    // MARK: - Fixtures

    /// A one-page PDF with a text layer, and an index over it in a scratch directory.
    static func makeIndex() async throws -> DocumentSearchIndex {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-appcore-search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pdf = directory.appendingPathComponent("Plan.pdf")
        try Self.writeTextPDF(to: pdf)

        let documentID = DocumentID(UUID())
        return try await DocumentSearchIndex.open(
            databaseAt: directory.appendingPathComponent("search.sqlite"),
            drawingAt: pdf,
            displayName: "Plan",
            pages: Self.pages(count: 1, documentID: documentID)
        )
    }

    static func pages(count: Int, documentID: DocumentID) -> [ZPDFContracts.PageDescriptor] {
        (0..<count).map { index in
            ZPDFContracts.PageDescriptor(
                id: PageID(UUID()),
                documentID: documentID,
                index: index,
                label: "A-10\(index)",
                boxes: PageBoxes(
                    media: PDFRect(x: 0, y: 0, width: 595, height: 842),
                    crop: PDFRect(x: 0, y: 0, width: 595, height: 842)
                ),
                rotation: .degrees0
            )
        }
    }

    static func writeTextPDF(to url: URL) throws {
        let content = Data("BT /F1 18 Tf 72 700 Td (SCREED BAY 7) Tj ET\n".utf8)
        var objects: [Data] = [
            Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
            Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
            Data("""
            << /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R \
            /Resources << /Font << /F1 5 0 R >> >> >>
            """.utf8)
        ]
        var stream = Data("<< /Length \(content.count) >>\nstream\n".utf8)
        stream.append(content)
        stream.append(Data("\nendstream".utf8))
        objects.append(stream)
        objects.append(Data("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>".utf8))

        var bytes = Data("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(bytes.count)
            bytes.append(Data("\(index + 1) 0 obj\n".utf8))
            bytes.append(object)
            bytes.append(Data("\nendobj\n".utf8))
        }
        let xref = bytes.count
        bytes.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets {
            bytes.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
        }
        bytes.append(Data(
            "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8
        ))
        try bytes.write(to: url)
    }
}
