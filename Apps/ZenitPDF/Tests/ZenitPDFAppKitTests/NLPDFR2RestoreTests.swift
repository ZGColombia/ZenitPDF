import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFExport
import ZPDFMeasurementEngine
@testable import ZenitPDFAppKit

/// NL-PDF-03 restore: a PDF with markups saved into it reopens with its takeoff offered, and
/// Restore brings back every measurement bit for bit. No modal: the tray action is pressed by
/// calling its handler.
@MainActor
@Suite("Restore the takeoff a PDF carries (NL-PDF-03)", .appTierSerialised)
struct NLPDFR2RestoreTests {

    private static let offerPrefix = "This PDF carries its Zenit takeoff"

    /// A Quick PDF with a hand calibration (evidence) and two measurements, saved into itself.
    private func savedIntoPDF() async throws -> (url: URL, before: [MarkupRecord], state: TakeoffSession.TakeoffState) {
        let url = try AppTestSupport.writeFixturePDF(named: "Restore Me.pdf")
        let document = try AppTestSupport.makeDocument(opening: url)
        #expect(await AppTestSupport.wait { document.core != nil && document.drawing != nil })
        let core = try #require(document.core)
        let drawing = try #require(document.drawing)
        let page = try #require(drawing.pages.first)
        // 200 pt picked as 5.000 m: 0.025 m per point.
        try await core.commands.calibrate(
            page: page.id, first: PDFPoint(x: 100, y: 100), second: PDFPoint(x: 300, y: 100),
            knownLength: 5, knownLengthUnit: .metre
        )
        for (tool, points) in [
            (MeasurementTool.length, [PDFPoint(x: 100, y: 300), PDFPoint(x: 400, y: 300)]),
            (MeasurementTool.polylength, [PDFPoint(x: 100, y: 400), PDFPoint(x: 200, y: 450), PDFPoint(x: 260, y: 380)])
        ] {
            _ = try await core.commands.perform(.addMarkup(MarkupRecord(
                id: MarkupID(UUID()), documentID: drawing.documentID, pageID: page.id,
                kind: .measurement, tool: tool, label: tool.rawValue,
                geometry: MeasurementGeometry(pageID: page.id, points: points),
                createdAt: Date(), modifiedAt: Date()
            )))
        }
        await core.commands.settle()
        await core.refresh()
        let controller = ProjectWindowController(document: document)
        let job = try await StandardAnnotationExport.job(for: document)
        let result = try await controller.saveIntoPDF(job: job, document: document, destination: url, inPlace: true)
        #expect(result.outcome.takeoffEmbedded)
        let state = await core.session.takeoffState()
        let before = state.markups
        await document.drawing?.rasterSource.close()
        document.close()
        return (url, before, state)
    }

    @Test("Reopening offers the takeoff; Restore brings back values, scale identity and version, evidence and provenance")
    func reopenRestoresBitIdentical() async throws {
        let saved = try await savedIntoPDF()
        defer { try? FileManager.default.removeItem(at: saved.url.deletingLastPathComponent()) }
        #expect(EmbeddedTakeoffReader.read(try Data(contentsOf: saved.url), named: EmbeddedSessionArchive.fileName)?.prefixVerified == true)

        // Old behaviour: the embedded takeoff was written and never read; the reopened PDF showed
        // the annotations as pictures and an empty ledger.
        let document = try AppTestSupport.makeDocument(opening: saved.url)
        defer { Task { await document.drawing?.rasterSource.close(); document.close() } }
        #expect(await AppTestSupport.wait { document.core != nil && document.drawing != nil })
        let core = try #require(document.core)
        #expect(await AppTestSupport.wait { core.document.warnings.contains { $0.title.hasPrefix(Self.offerPrefix) } })
        let offer = try #require(core.document.warnings.first { $0.title.hasPrefix(Self.offerPrefix) })
        #expect(offer.actionTitle == "Restore Takeoff")
        #expect(await core.session.takeoffState().markups.isEmpty, "offered, never restored on its own")

        #expect(EmbeddedTakeoffRestore.handleAction(offer.id, document: document))
        #expect(await AppTestSupport.wait(upTo: 10) { core.snapshot.markups.count == saved.before.count })
        let after = await core.session.takeoffState()
        let newPage = try #require(document.drawing?.pages.first?.id)
        let oldPage = try #require(saved.state.pages.first?.id)

        #expect(after.markups.map(\.id) == saved.before.map(\.id))
        for (old, new) in zip(saved.before, after.markups) {
            #expect(new.pageID == newPage)
            let a = try #require(old.measurement)
            let b = try #require(new.measurement)
            #expect(a.values == b.values, "values digit for digit")
            #expect(a.formulaVersion == b.formulaVersion)
            #expect(a.provenance?.scaleID == b.provenance?.scaleID)
            #expect(a.provenance?.scaleVersion == b.provenance?.scaleVersion)
            // The geometry is the same points; its digest covers the page identity, which a
            // Quick PDF mints per session, so it names the new page (GeometryDigest).
            #expect(old.geometry?.points == new.geometry?.points)
            #expect(b.provenance?.geometryDigest == new.geometry.map(GeometryDigest.digest(of:)))
            #expect(a.provenance?.scalePageID == oldPage && b.provenance?.scalePageID == newPage)
        }
        let oldScale = try #require(saved.state.scales.first)
        let newScale = try #require(after.scales.first)
        #expect(newScale.id == oldScale.id && newScale.version == oldScale.version && newScale.pageID == newPage)
        #expect(after.pageScaleIDs[newPage] == oldScale.id)
        #expect(after.calibrationEvidence[oldScale.id] == saved.state.calibrationEvidence[oldScale.id])
        #expect(core.document.warnings.allSatisfy { $0.id != offer.id })

        // Zenit's own annotations are bound to the hidden pseudo-layer, one per restored markup.
        let reading = try ReviewAnnotationReader.read(url: saved.url)
        let bindings = EmbeddedTakeoffRestore.ownAnnotationBindings(reading, restoredIDs: Set(after.markups.map(\.id.rawValue)))
        #expect(bindings.count == saved.before.count)
        #expect(bindings.allSatisfy { $0.layerID == EmbeddedTakeoffRestore.restoredLayer })
    }

    @Test("A drawing changed under the takeoff is refused in words, and a session with work is never overwritten")
    func refusals() async throws {
        let saved = try await savedIntoPDF()
        defer { try? FileManager.default.removeItem(at: saved.url.deletingLastPathComponent()) }
        let pages = saved.state.pages
        let documentID = DocumentID(UUID())
        let intact = EmbeddedTakeoffRestore.inspect(fileAt: saved.url, pages: pages, documentID: documentID)
        #expect(intact.finding == .restorable(markups: 2, sheets: 1))

        // A byte of the drawing itself changed: the prefix no longer hashes to the saved digest.
        var bytes = try Data(contentsOf: saved.url)
        bytes[bytes.startIndex + 40] = bytes[bytes.startIndex + 40] == 0x20 ? 0x0A : 0x20
        let tampered = saved.url.deletingLastPathComponent().appendingPathComponent("tampered.pdf")
        try bytes.write(to: tampered)
        #expect(EmbeddedTakeoffRestore.inspect(fileAt: tampered, pages: pages, documentID: documentID).finding == .tampered)

        // A different drawing (other page size) is refused by the archive itself.
        let archive = try #require(intact.archive)
        var other = pages
        other[0].boxes.crop = PDFRect(x: 0, y: 0, width: 100, height: 100)
        other[0].boxes.media = PDFRect(x: 0, y: 0, width: 100, height: 100)
        #expect(throws: EmbeddedSessionArchive.Refusal.differentDrawing) {
            try EmbeddedSessionArchive.restore(archive, onto: other, documentID: documentID)
        }

        // Work started before the press: the restore refuses and adds nothing.
        let document = try AppTestSupport.makeDocument(opening: saved.url)
        defer { Task { await document.drawing?.rasterSource.close(); document.close() } }
        #expect(await AppTestSupport.wait { document.core != nil && document.drawing != nil })
        let core = try #require(document.core)
        let drawing = try #require(document.drawing)
        let page = try #require(drawing.pages.first)
        _ = try await core.commands.perform(.addMarkup(MarkupRecord(
            id: MarkupID(UUID()), documentID: drawing.documentID, pageID: page.id, kind: .measurement, tool: .length,
            geometry: MeasurementGeometry(pageID: page.id, points: [PDFPoint(x: 50, y: 50), PDFPoint(x: 150, y: 50)]),
            createdAt: Date(), modifiedAt: Date()
        )))
        await core.commands.settle()
        #expect(await EmbeddedTakeoffRestore.restore(archive, into: document) == nil)
        #expect(await core.session.takeoffState().markups.count == 1)
    }
}
