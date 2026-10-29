import CoreGraphics
import Foundation
import Testing
import ZPDFPDFKitBridge
@testable import ZPDFSearch

/// NL-PDF-19: a file recognised without an index, for the batch processor's Make Searchable step.
@Suite("OCR of a file without an index (NL-PDF-19)", .serialized)
struct OCRFileRecognitionTests {

    @Test("The scanned fixture's words come back in page space, with no database anywhere")
    func recognisesAFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("zpdf-ocr-file-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try ScannedSheetFixture.write(into: directory)
        let provider = PDFKitDocumentProvider(thumbnailCacheCapacity: 0)
        let opened = try await provider.open(fileAt: url)
        // Old behaviour: recognition existed only through a project database.
        let recognition = try await OCRService.recogniseFile(handle: opened.handle, provider: provider)
        await provider.close(opened.handle)
        let tokens = recognition.tokens
        #expect(recognition.unreadablePages.isEmpty, "every page was read")
        let words = (tokens[0] ?? []).map { $0.text.uppercased() }
        #expect(words.contains("CORRIDOR"), "\(words)")
        #expect(words.contains("A-102") || words.contains("DRAWING"))
        let page = CGRect(origin: .zero, size: ScannedSheetFixture.pageSize)
        #expect((tokens[0] ?? []).allSatisfy { page.insetBy(dx: -1, dy: -1).contains($0.bounds) }, "boxes are in page space")
    }
}
