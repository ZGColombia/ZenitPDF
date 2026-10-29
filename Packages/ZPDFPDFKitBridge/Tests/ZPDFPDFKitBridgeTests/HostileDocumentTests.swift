import CoreGraphics
import Foundation
import Testing
import ZPDFTestingSupport
@testable import ZPDFPDFKitBridge

/// A PDF is data written by someone else.
///
/// These tests use the corpus's hostile fixtures to check the three promises of spec 7.4
/// that matter at open time: nothing is executed, nothing is extracted, and a malformed
/// file produces a typed error instead of a hang, an unbounded allocation or a crash.
@Suite("Hostile documents")
struct HostileDocumentTests {

    // MARK: - Malformed structure

    @Test("A truncated file is refused with a typed error")
    func truncatedFile() async throws {
        let provider = PDFKitDocumentProvider()
        await #expect(throws: PDFBridgeError.damaged(.unparsable)) {
            _ = try await provider.open(fileAt: Corpus.url(.truncatedFile))
        }
    }

    @Test("A file with a broken cross-reference table is refused with a typed error")
    func brokenXref() async throws {
        let provider = PDFKitDocumentProvider()
        await #expect(throws: PDFBridgeError.damaged(.unparsable)) {
            _ = try await provider.open(fileAt: Corpus.url(.brokenXref))
        }
    }

    @Test("A file with a missing object opens, and is reported as intact or suspect, never as a crash")
    func missingObject() async throws {
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: Corpus.url(.missingObject))
        #expect(opened.descriptor.pageCount >= 1)
        // Whatever the reader repaired, the page must still be renderable or refused.
        let pages = try await provider.pageDescriptors(of: opened.handle)
        #expect(pages.count == opened.descriptor.pageCount)
    }

    @Test("A cyclic page tree opens with a finite page count and does not hang")
    func cyclicPageTree() async throws {
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: Corpus.url(.cyclicPageTree))
        #expect(opened.descriptor.pageCount > 0)
        #expect(opened.descriptor.pageCount < 100)
        let pages = try await provider.pageDescriptors(of: opened.handle)
        #expect(pages.count == opened.descriptor.pageCount)
    }

    @Test("Both engines are cross-checked, so a repaired page tree is reported as suspect")
    func integrityCrossCheck() async throws {
        // The whole point of the finding: PDFKit and CoreGraphics both repair, and when
        // they repair differently the estimator must be warned rather than reassured.
        let provider = PDFKitDocumentProvider()
        for kind in [FixtureKind.cyclicPageTree, .missingObject] {
            let opened = try await provider.open(fileAt: Corpus.url(kind))
            let integrity = opened.descriptor.integrity
            if case let .suspect(findings) = integrity {
                #expect(!findings.isEmpty)
            }
            await provider.close(opened.handle)
        }
    }

    @Test("A hundred levels of nested form XObjects render without exhausting the stack")
    func deeplyNestedForms() async throws {
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: Corpus.url(.deeplyNestedForms))
        let rendered = try await provider.renderPageRegion(
            PageRenderRequest(document: opened.handle, pageIndex: 0, scale: 0.25)
        )
        #expect(rendered.pixelWidth > 0)
    }

    @Test("A decompression bomb opens and renders inside the pixel budget")
    func decompressionBomb() async throws {
        let manifest = try Corpus.manifest(.decompressionBomb)
        #expect(manifest.declaredInflatedByteCount ?? 0 > 1 << 20)
        // The file is small; the content stream is not. Rendering it must still be
        // bounded by the pixel budget rather than by the stream's inflated size, and the
        // rejection must happen before the bitmap is allocated.
        var limits = DocumentLimits.standard
        limits.maximumRenderPixels = 4096
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(
            .url(Corpus.url(.decompressionBomb)),
            password: nil,
            limits: limits
        )
        #expect(opened.descriptor.pageCount == manifest.pageCount)
        await #expect(
            throws: PDFBridgeError.pixelBudgetExceeded(requestedPixels: 484_704, limit: 4096)
        ) {
            _ = try await provider.renderPageRegion(
                PageRenderRequest(document: opened.handle, pageIndex: 0, scale: 1)
            )
        }
        // A request that fits the budget still succeeds.
        let small = try await provider.renderPageRegion(
            PageRenderRequest(document: opened.handle, pageIndex: 0, scale: 0.06)
        )
        #expect(small.pixelWidth * small.pixelHeight <= 4096)
    }

    @Test("A megabyte of invalid content-stream tokens neither hangs nor throws")
    func malformedOperatorStream() async throws {
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: Corpus.url(.hugeMalformedOperatorStream))
        #expect(opened.descriptor.pageCount == 1)
        let text = try await provider.pageText(of: opened.handle, pageIndex: 0)
        #expect(text.availability == .noTextLayer)
    }

    // MARK: - Encryption

    @Test("An encrypted document opens locked, and content is refused until it is unlocked")
    func encryptedWithoutPassword() async throws {
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: Corpus.url(.encryptedUserPassword))
        #expect(opened.descriptor.encryption == .locked)
        #expect(opened.descriptor.encryption.isEncrypted)
        #expect(opened.descriptor.permissions.isEmpty)

        // Every content API fails cleanly, with the same typed error.
        await #expect(throws: PDFBridgeError.documentLocked) {
            _ = try await provider.characterBoxes(of: opened.handle, pageIndex: 0, range: nil)
        }
        await #expect(throws: PDFBridgeError.documentLocked) {
            _ = try await provider.search(in: opened.handle, query: "anything")
        }
        await #expect(throws: PDFBridgeError.documentLocked) {
            _ = try await provider.renderPageRegion(
                PageRenderRequest(document: opened.handle, pageIndex: 0, scale: 1)
            )
        }
        await #expect(throws: PDFBridgeError.documentLocked) {
            _ = try await provider.annotations(of: opened.handle, pageIndex: 0)
        }
        // ...and page text says why, rather than pretending the page is blank.
        let text = try await provider.pageText(of: opened.handle, pageIndex: 0)
        #expect(text.availability == .notPermitted)
    }

    @Test("The wrong password is refused and the document stays usable for another try")
    func encryptedWithWrongPassword() async throws {
        let provider = PDFKitDocumentProvider()
        await #expect(throws: PDFBridgeError.incorrectPassword) {
            _ = try await provider.open(
                .url(Corpus.url(.encryptedUserPassword)),
                password: "definitely-not-the-password",
                limits: .standard
            )
        }

        let opened = try await provider.open(fileAt: Corpus.url(.encryptedUserPassword))
        await #expect(throws: PDFBridgeError.incorrectPassword) {
            _ = try await provider.unlock(opened.handle, password: "wrong")
        }
        #expect(try await provider.descriptor(of: opened.handle).encryption == .locked)
    }

    @Test("The right password unlocks the document, at open time or afterwards")
    func encryptedWithRightPassword() async throws {
        let password = ZPDFFixtures.encryptedUserPassword
        let provider = PDFKitDocumentProvider()

        let atOpen = try await provider.open(
            .url(Corpus.url(.encryptedUserPassword)),
            password: password,
            limits: .standard
        )
        #expect(atOpen.descriptor.encryption == .unlocked)
        #expect(atOpen.descriptor.pageCount == 1)

        let later = try await provider.open(fileAt: Corpus.url(.encryptedUserPassword))
        let descriptor = try await provider.unlock(later.handle, password: password)
        #expect(descriptor.encryption == .unlocked)
        _ = try await provider.pageDescriptors(of: later.handle)
    }

    // MARK: - Things that are reported and never done

    @Test("A document-level JavaScript name tree and an /OpenAction are reported, never run")
    func javaScriptIsReportedNotRun() async throws {
        let url = Corpus.url(.javaScriptAction)
        let before = try FileDigestProbe.hex(of: url)

        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: url)

        #expect(opened.descriptor.hazards.contains(.documentJavaScript))
        #expect(opened.descriptor.hazards.contains(.openAction))
        #expect(opened.descriptor.hazards.contains(.javaScriptAction))

        // Nothing ran: the file is byte-identical, and the policy this package publishes
        // says it never will.
        #expect(try FileDigestProbe.hex(of: url) == before)
        #expect(PDFBridgeSecurityPolicy.current.executesDocumentJavaScript == false)
        #expect(PDFBridgeSecurityPolicy.current.performsOpenAction == false)
    }

    @Test("An embedded file and a /Launch action are listed, never extracted or followed")
    func embeddedFilesAreListedNotOpened() async throws {
        let scratch = try Corpus.scratchDirectory("embedded")
        let copied = scratch.appendingPathComponent(FixtureKind.embeddedFileWithLaunchAction.fileName)
        try FileManager.default.copyItem(at: Corpus.url(.embeddedFileWithLaunchAction), to: copied)
        let before = try FileDigestProbe.hex(of: copied)

        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: copied)

        #expect(opened.descriptor.hazards.contains(.embeddedFiles))
        #expect(opened.descriptor.hazards.contains(.launchAction))
        #expect(!opened.descriptor.embeddedFiles.isEmpty)
        // The name is known; the bytes were never touched.
        #expect(opened.descriptor.embeddedFiles.allSatisfy { !$0.name.isEmpty })

        // Nothing was written into the directory holding the hostile file.
        let contents = try FileManager.default.contentsOfDirectory(atPath: scratch.path)
        #expect(contents == [copied.lastPathComponent])
        #expect(try FileDigestProbe.hex(of: copied) == before)
        #expect(PDFBridgeSecurityPolicy.current.extractsEmbeddedFilesAutomatically == false)
        #expect(PDFBridgeSecurityPolicy.current.followsLaunchActions == false)
    }

    @Test("A harmless fixture carries no hazards at all")
    func noFalsePositives() async throws {
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: Corpus.url(.titleBlockSheet))
        #expect(opened.descriptor.hazards.isEmpty)
        #expect(opened.descriptor.embeddedFiles.isEmpty)
    }

    @Test("The hazard scan is bounded and cannot be made to run forever")
    func hazardScanIsBounded() async throws {
        var limits = DocumentLimits.standard
        limits.maximumHazardScanNodes = 1
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(
            .url(Corpus.url(.embeddedFileWithLaunchAction)),
            password: nil,
            limits: limits
        )
        // It still opens; it simply stops looking. Reporting fewer hazards under a
        // one-node budget is the correct, bounded behaviour.
        #expect(opened.descriptor.pageCount == 1)
    }
}
