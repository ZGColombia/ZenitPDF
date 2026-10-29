import CoreGraphics
import Foundation
import Testing
import ZPDFPDFKitBridge

/// The protocol is the seam.
///
/// These tests exercise a call site written against ``PDFDocumentProviding`` and run it
/// twice: once on the PDFKit implementation and once on a fake with no PDF engine at
/// all. Nothing in the call site changes between the two.
@Suite("Protocol substitution")
struct ProtocolSubstitutionTests {

    /// A tiny piece of application logic: build a sheet index from labels and a search.
    struct SheetIndexBuilder {
        let provider: any PDFDocumentProviding

        func build(searchingFor query: String, in handle: DocumentHandle) async throws -> [String] {
            let pages = try await provider.pageDescriptors(of: handle)
            let results = try await provider.search(in: handle, query: query)
            let hitPages = Set(results.hits.map(\.pageIndex))
            return pages.filter { hitPages.contains($0.index) }.map(\.label)
        }
    }

    @Test("A call site written against the protocol runs unchanged on the fake")
    func fakeSubstitution() async throws {
        var script = FakeDocumentProvider.Script()
        script.pageCount = 3
        script.labels = PageLabelTable(
            pageCount: 3,
            ranges: [PageLabelRange(startPageIndex: 0, style: .decimal, prefix: "A-", firstNumber: 101)],
            isExplicit: true
        )
        script.text = [
            1: PageText(pageIndex: 1, availability: .available, string: "ROOM 101 CORRIDOR",
                        characterCount: 17, wasTruncated: false)
        ]
        let fake = FakeDocumentProvider(script: script)
        let opened = try await fake.open(.data(Data()), password: nil, limits: .standard)
        let builder = SheetIndexBuilder(provider: fake)
        #expect(try await builder.build(searchingFor: "CORRIDOR", in: opened.handle) == ["A-102"])
    }

    @Test("The same call site runs on the PDFKit implementation")
    func pdfKitSubstitution() async throws {
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: Corpus.url(.titleBlockSheet))
        let builder = SheetIndexBuilder(provider: provider)
        #expect(try await builder.build(searchingFor: "CORRIDOR", in: opened.handle) == ["1"])
    }

    @Test("Both implementations reject the same invalid page batch, with the same error")
    func sharedValidation() async throws {
        let fake = FakeDocumentProvider()
        let fakeHandle = try await fake.open(.data(Data()), password: nil, limits: .standard).handle
        await #expect(throws: PDFBridgeError.pageOperation(.resultWouldBeEmpty)) {
            _ = try await fake.planPageOperations([.delete(pageIndices: [0, 1, 2])], on: fakeHandle)
        }

        let real = PDFKitDocumentProvider()
        let realHandle = try await real.open(fileAt: Corpus.url(.rectangle)).handle
        await #expect(throws: PDFBridgeError.pageOperation(.resultWouldBeEmpty)) {
            _ = try await real.planPageOperations([.delete(pageIndices: [0])], on: realHandle)
        }
    }

    @Test("An unknown handle is the same typed error on both sides")
    func sharedHandleValidation() async throws {
        let stranger = DocumentHandle(rawValue: 4242)
        let fake = FakeDocumentProvider()
        await #expect(throws: PDFBridgeError.unknownHandle(stranger)) {
            _ = try await fake.descriptor(of: stranger)
        }
        let real = PDFKitDocumentProvider()
        await #expect(throws: PDFBridgeError.unknownHandle(stranger)) {
            _ = try await real.descriptor(of: stranger)
        }
    }
}
