import CoreGraphics
import Foundation
import Testing
import ZPDFTestingSupport
@testable import ZPDFPDFKitBridge

/// Opening documents from the fixture corpus.
@Suite("Document opening")
struct DocumentOpeningTests {

    @Test("Every structurally valid fixture opens and reports the manifest's page count",
          arguments: FixtureKind.allCases.filter(\.isStructurallyValid))
    func opensEveryValidFixture(kind: FixtureKind) async throws {
        let manifest = try Corpus.manifest(kind)
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: Corpus.url(kind))
        #expect(opened.descriptor.pageCount == manifest.pageCount)
        #expect(opened.descriptor.digest.byteCount > 0)
        #expect(opened.descriptor.digest.sha256.count == 64)
        await provider.close(opened.handle)
    }

    @Test("The reported SHA-256 is the file's, checked against an independent implementation")
    func digestMatchesIndependentHash() async throws {
        let url = Corpus.url(.titleBlockSheet)
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: url)
        let independent = try FileDigestProbe.hex(of: url)
        #expect(opened.descriptor.digest.sha256 == independent)
        #expect(opened.descriptor.digest.byteCount == (try Data(contentsOf: url)).count)
    }

    @Test("Opening from Data gives the same digest and page count as opening from the file")
    func opensFromData() async throws {
        let url = Corpus.url(.mixedPageSizes)
        let bytes = try Data(contentsOf: url)
        let provider = PDFKitDocumentProvider()
        let fromFile = try await provider.open(.url(url), password: nil, limits: .standard)
        let fromData = try await provider.open(.data(bytes), password: nil, limits: .standard)
        #expect(fromFile.descriptor.digest == fromData.descriptor.digest)
        #expect(fromFile.descriptor.pageCount == fromData.descriptor.pageCount)
        #expect(fromData.descriptor.origin == .memory(byteCount: bytes.count))
        #expect(fromFile.descriptor.origin == .file(url))
    }

    @Test("Handles come from the injected generator, never from UUID()")
    func handlesAreDeterministic() async throws {
        let provider = PDFKitDocumentProvider(identifiers: FixedHandleIDGenerator([7, 9]))
        let first = try await provider.open(fileAt: Corpus.url(.rectangle))
        let second = try await provider.open(fileAt: Corpus.url(.lShape))
        #expect(first.handle == DocumentHandle(rawValue: 7))
        #expect(second.handle == DocumentHandle(rawValue: 9))
        #expect(first.handle.description == "PDFDocument#7")
    }

    @Test("Page boxes and rotation match the fixture manifest",
          arguments: [FixtureKind.rotation0, .rotation90, .rotation180, .rotation270,
                      .cropBoxSmallerThanMediaBox, .cropBoxNegativeOrigin, .mixedPageSizes])
    func pageGeometryMatchesManifest(kind: FixtureKind) async throws {
        let manifest = try Corpus.manifest(kind)
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: Corpus.url(kind))
        let pages = try await provider.pageDescriptors(of: opened.handle)
        #expect(pages.count == manifest.pageCount)
        for (page, expected) in zip(pages, manifest.pages) {
            #expect(page.rotation == expected.rotation)
            #expect(abs(page.boxes.media.minX - expected.mediaBox.llx) < 1e-6)
            #expect(abs(page.boxes.media.width - expected.mediaBox.width) < 1e-6)
            #expect(abs(page.boxes.media.height - expected.mediaBox.height) < 1e-6)
            #expect(abs(page.boxes.crop.minX - expected.cropBox.llx) < 1e-6)
            #expect(abs(page.boxes.crop.width - expected.cropBox.width) < 1e-6)
            #expect(abs(page.boxes.crop.height - expected.cropBox.height) < 1e-6)
        }
    }

    @Test("A rotated page's display size is transposed while its box is not")
    func displaySize() async throws {
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: Corpus.url(.rotation90))
        let page = try #require(try await provider.pageDescriptors(of: opened.handle).first)
        #expect(page.boxes.media == CGRect(x: 0, y: 0, width: 612, height: 792))
        #expect(page.displaySize == CGSize(width: 792, height: 612))
    }

    @Test("An ARCH-D sheet is exactly 1728 by 2592 points")
    func archDSheet() async throws {
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: Corpus.url(.sizeArchD))
        let page = try #require(try await provider.pageDescriptors(of: opened.handle).first)
        #expect(page.boxes.media.width == 1728)
        #expect(page.boxes.media.height == 2592)
    }

    @Test("Page labels default to one-based decimals when the file declares none")
    func implicitLabels() async throws {
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: Corpus.url(.mixedPageSizes))
        let labels = try await provider.pageLabels(of: opened.handle)
        #expect(labels.isExplicit == false)
        #expect(labels.allLabels() == ["1", "2", "3", "4"])
        let pages = try await provider.pageDescriptors(of: opened.handle)
        #expect(pages.map(\.index) == [0, 1, 2, 3])
        #expect(pages.map(\.label) == ["1", "2", "3", "4"])
        #expect(pages.allSatisfy { !$0.labelIsExplicit })
    }

    @Test("A page range limits the descriptors produced")
    func pageRange() async throws {
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: Corpus.url(.mixedPageSizes))
        let pages = try await provider.pageDescriptors(of: opened.handle, range: 1..<3)
        #expect(pages.map(\.index) == [1, 2])
        await #expect(throws: PDFBridgeError.pageIndexOutOfRange(index: 0, pageCount: 4)) {
            _ = try await provider.pageDescriptors(of: opened.handle, range: 0..<9)
        }
    }

    @Test("A file that is not there, and a file that is not a PDF, produce typed errors")
    func missingAndNonPDF() async throws {
        let scratch = try Corpus.scratchDirectory("not-a-pdf")
        let missing = scratch.appendingPathComponent("nope.pdf")
        let provider = PDFKitDocumentProvider()
        await #expect(throws: PDFBridgeError.fileNotFound(path: missing.path)) {
            _ = try await provider.open(fileAt: missing)
        }

        let text = scratch.appendingPathComponent("text.pdf")
        try Data("this is not a PDF at all".utf8).write(to: text)
        await #expect(throws: PDFBridgeError.damaged(.missingHeader)) {
            _ = try await provider.open(fileAt: text)
        }

        let empty = scratch.appendingPathComponent("empty.pdf")
        try Data().write(to: empty)
        await #expect(throws: PDFBridgeError.damaged(.empty)) {
            _ = try await provider.open(fileAt: empty)
        }
    }

    @Test("The file-size and page-count ceilings are enforced")
    func limitsAreEnforced() async throws {
        let provider = PDFKitDocumentProvider()
        var tiny = DocumentLimits.standard
        tiny.maximumFileByteCount = 100
        await #expect(throws: PDFBridgeError.self) {
            _ = try await provider.open(.url(Corpus.url(.titleBlockSheet)), password: nil, limits: tiny)
        }

        var fewPages = DocumentLimits.standard
        fewPages.maximumPageCount = 2
        await #expect(throws: PDFBridgeError.pageCountExceedsLimit(pageCount: 4, limit: 2)) {
            _ = try await provider.open(.url(Corpus.url(.mixedPageSizes)), password: nil, limits: fewPages)
        }
    }

    @Test("An unencrypted document reports every permission and no encryption")
    func permissionsOfPlainDocument() async throws {
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: Corpus.url(.rectangle))
        #expect(opened.descriptor.encryption == .none)
        #expect(opened.descriptor.permissions.contains(.printing))
        #expect(opened.descriptor.permissions.contains(.copying))
        #expect(opened.descriptor.integrity == .intact)
    }

    @Test("Version comes from the file header")
    func version() async throws {
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: Corpus.url(.rectangle))
        #expect(opened.descriptor.version >= PDFVersion(major: 1, minor: 0))
        #expect(opened.descriptor.version.major == 1)
    }

    @Test("Linearisation is reported, and the corpus is not linearised")
    func linearisation() async throws {
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: Corpus.url(.titleBlockSheet))
        #expect(opened.descriptor.isLinearized == false)

        // A synthetic header carrying the parameter dictionary is detected.
        var bytes = Data("%PDF-1.7\n1 0 obj\n<< /Linearized 1 /L 1000 >>\nendobj\n".utf8)
        bytes.append(Data(repeating: 0x20, count: 32))
        let probe = PDFFileProbe.probe(data: bytes, limits: .standard)
        #expect(probe.isLinearized)
        #expect(probe.headerVersion == PDFVersion(major: 1, minor: 7))
    }

    @Test("An unknown handle is refused, and closing twice is harmless")
    func handleLifecycle() async throws {
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: Corpus.url(.rectangle))
        await provider.close(opened.handle)
        await provider.close(opened.handle)
        await #expect(throws: PDFBridgeError.unknownHandle(opened.handle)) {
            _ = try await provider.descriptor(of: opened.handle)
        }
    }
}
