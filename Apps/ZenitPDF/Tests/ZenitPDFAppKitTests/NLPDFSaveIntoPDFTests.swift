import AppKit
import CryptoKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFExport
import ZPDFServiceWire
@testable import ZenitPDFAppKit

/// NL-PDF-03 (ADR-0023) and the qpdf copy command (NL-PDF-08/09), from the window controller's
/// own methods to bytes read back. No modal is drawn: the presenter is answered by injection.
@MainActor
@Suite(.appTierSerialised)
struct NLPDFSaveIntoPDFTests {

    private func quickDocument(named name: String = "Save Into.pdf") async throws -> (ZenitPDFProjectDocument, URL) {
        let url = try AppTestSupport.writeFixturePDF(named: name)
        let document = try AppTestSupport.makeDocument(opening: url)
        #expect(await AppTestSupport.wait { document.core != nil && document.drawing != nil })
        let core = try #require(document.core)
        let drawing = try #require(document.drawing)
        let page = try #require(drawing.pages.first)
        _ = try await core.commands.perform(.addMarkup(MarkupRecord(
            id: MarkupID(UUID()),
            documentID: drawing.documentID,
            pageID: page.id,
            kind: .measurement,
            tool: .length,
            label: "Wall",
            geometry: MeasurementGeometry(pageID: page.id, points: [PDFPoint(x: 100, y: 300), PDFPoint(x: 400, y: 300)]),
            createdAt: Date(),
            modifiedAt: Date()
        )))
        await core.commands.settle()
        await core.refresh()
        return (document, url)
    }

    private func close(_ document: ZenitPDFProjectDocument, _ url: URL) async {
        await document.drawing?.rasterSource.close()
        document.close()
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    @Test("The command asks first, and Cancel writes nothing")
    func confirmationIsAskedAndCancelWritesNothing() async throws {
        let (document, url) = try await quickDocument()
        defer { Task { await close(document, url) } }
        let before = try Data(contentsOf: url)
        let controller = ProjectWindowController(document: document)

        ZenitModalPresenter.reset()
        let previous = ZenitModalPresenter.handler
        ZenitModalPresenter.handler = { _ in .button(1) }
        defer { ZenitModalPresenter.handler = previous }
        controller.saveMarkupsIntoPDF(for: document)
        #expect(await AppTestSupport.wait { ZenitModalPresenter.didRequest(SaveMarkupsIntoPDF.confirmIdentifier) })
        let request = try #require(ZenitModalPresenter.recorded.last { $0.identifier == SaveMarkupsIntoPDF.confirmIdentifier })
        #expect(request.buttons.count == 2)
        #expect(request.detail.contains("start of the file"))
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(try Data(contentsOf: url) == before, "Cancel must leave the drawing byte for byte")
    }

    @Test("Saving into the Quick PDF keeps the original as the file's prefix, embeds the takeoff, and never duplicates")
    func savesIntoThePDFIncrementally() async throws {
        let (document, url) = try await quickDocument()
        defer { Task { await close(document, url) } }
        let original = try Data(contentsOf: url)
        let controller = ProjectWindowController(document: document)
        let job = try await StandardAnnotationExport.job(for: document)

        let first = try await controller.saveIntoPDF(job: job, document: document, destination: url, inPlace: true)
        let afterFirst = try Data(contentsOf: url)
        #expect(afterFirst.prefix(original.count) == original)
        #expect(first.outcome.writtenAnnotationCount == 1)
        #expect(first.outcome.takeoffEmbedded)
        let found = try #require(EmbeddedTakeoffReader.read(afterFirst))
        #expect(found.prefixVerified)
        #expect(!found.takeoff.payload.isEmpty)

        // A second save supersedes: still one Zenit annotation, still the original prefix.
        let second = try await controller.saveIntoPDF(job: job, document: document, destination: url, inPlace: true)
        let afterSecond = try Data(contentsOf: url)
        #expect(afterSecond.prefix(original.count) == original)
        #expect(second.outcome.supersededAnnotationCount == 1)
        #expect(AnnotationProbe.annotations(in: afterSecond, page: 0).count == 1)
    }

    @Test("A drawing edited underneath the document is refused, not written onto")
    func aReplacedDrawingIsRefused() async throws {
        let (document, url) = try await quickDocument()
        defer { Task { await close(document, url) } }
        let controller = ProjectWindowController(document: document)
        let job = try await StandardAnnotationExport.job(for: document)
        // Another application rewrites the file.
        var bytes = try Data(contentsOf: url)
        bytes[bytes.startIndex + 20] = bytes[bytes.startIndex + 20] == 0x20 ? 0x0A : 0x20
        try bytes.write(to: url)
        await #expect(throws: ExportError.self) {
            _ = try await controller.saveIntoPDF(job: job, document: document, destination: url, inPlace: true)
        }
        #expect(try Data(contentsOf: url) == bytes)
    }

    // MARK: - Optimize or Protect a Copy

    @Test("The copy command's choices become the service request, and bad passwords are refused in words")
    func copyChoicesMapToTheRequest() throws {
        var choices = DocumentCopyTransform.Choices()
        let plain = try DocumentCopyTransform.transform(for: choices)
        #expect(plain.compresses && !plain.sanitizes && plain.protection == nil)

        choices.reducesSize = false
        #expect(throws: DocumentCopyTransform.Refusal.nothingChosen) { try DocumentCopyTransform.transform(for: choices) }

        choices.protects = true
        #expect(throws: DocumentCopyTransform.Refusal.missingPermissionsPassword) {
            try DocumentCopyTransform.transform(for: choices)
        }
        choices.openPassword = "same"
        choices.permissionsPassword = "same"
        #expect(throws: DocumentCopyTransform.Refusal.passwordsMatch) { try DocumentCopyTransform.transform(for: choices) }
        choices.permissionsPassword = "owner"
        choices.allowsPrinting = false
        let locked = try DocumentCopyTransform.transform(for: choices)
        #expect(locked.protection?.printing == 0)
        #expect(locked.protection?.openPassword == "same")

        // The accessory reads back exactly what is ticked.
        let accessory = OptimizeCopyAccessory(choices: choices)
        #expect(accessory.choices == choices)
        #expect(accessory.openPassword.isEnabled)
    }

    @Test("The result note states the sizes and that pictures were not re-encoded")
    func copyNoteStatesSizes() {
        let reply = RepairWireReply(
            message: "", warnings: [], warningCount: 0, outputByteCount: 400_000,
            transformSummary: RepairWireTransformSummary(
                flattenedAnnotationCount: 2, removedJavaScript: true, removedEmbeddedFiles: false,
                removedActionCount: 1, removedMetadata: true, inputByteCount: 1_000_000
            )
        )
        let note = DocumentCopyTransform.resultNote(
            for: reply, output: URL(fileURLWithPath: "/tmp/Plan — Optimized.pdf"), choices: .init(downsamplesPictures: false)
        )
        #expect(note.message.contains("60"))
        #expect(note.message.contains("2 of the drawing"))
        #expect(note.message.contains("re-encoded"))
    }

    @Test("NL-PDF-08: the picture choice becomes the service's target, and the note counts the reduced pictures")
    func pictureDownsamplingChoice() throws {
        var choices = DocumentCopyTransform.Choices()
        // Old behaviour: no picture choice existed; every copy kept its pictures at full size.
        #expect(try DocumentCopyTransform.transform(for: choices).pictureTargetDPI == 150)
        choices.pictureDPI = 300
        #expect(try DocumentCopyTransform.transform(for: choices).pictureTargetDPI == 300)
        choices.downsamplesPictures = false
        #expect(try DocumentCopyTransform.transform(for: choices).pictureTargetDPI == nil)
        choices.downsamplesPictures = true
        choices.reducesSize = false
        choices.protects = true
        choices.permissionsPassword = "owner"
        #expect(try DocumentCopyTransform.transform(for: choices).pictureTargetDPI == nil, "pictures only with Reduce file size")

        let accessory = OptimizeCopyAccessory(choices: .init(pictureDPI: 200))
        #expect(accessory.choices.pictureDPI == 200)
        #expect(accessory.pictureDPI.numberOfItems == DocumentCopyTransform.pictureResolutions.count)
        accessory.reduceSize.performClick(nil)
        #expect(!accessory.pictureDPI.isEnabled && !accessory.downsample.isEnabled)

        let reply = RepairWireReply(
            message: "", warnings: [], warningCount: 0, outputByteCount: 300_000,
            transformSummary: RepairWireTransformSummary(
                flattenedAnnotationCount: 0, removedJavaScript: false, removedEmbeddedFiles: false,
                removedActionCount: 0, removedMetadata: false, inputByteCount: 1_000_000,
                downsampledImageCount: 12, offeredImageCount: 13
            )
        )
        let note = DocumentCopyTransform.resultNote(for: reply, output: URL(fileURLWithPath: "/tmp/Scan.pdf"), choices: .init())
        #expect(note.message.contains("12 pictures were reduced to 150 dpi"))
        #expect(note.message.contains("1 pictures could not be decoded"))
        #expect(!note.message.contains("re-encoded"))
    }
}
