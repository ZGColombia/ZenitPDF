import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// The regression guard for the multi-page Navigator spin: a window opens on a multi-page drawing and
/// settles.
///
/// Until this file existed, **no test in this target opened a window on a multi-page document**.
/// `PageRasterSourceTests` uses a multi-page fixture and never builds a window, so the whole of
/// the Navigator's multi-page path was unexercised — which is how 21.7 survived.
///
/// What this does **not** cover is 21.7 itself: adding a markup to a multi-page document spins
/// the Navigator at 99 % CPU indefinitely, so the case that reproduces it cannot live in a suite
/// that has to finish. Its reproducer was first kept out of the suite instead of being
/// committed as a test that hangs the build.
@MainActor
@Suite(.appTierSerialised, .serialized)
struct MultiPageWindowProbeTests {

    private func writePDF(pages: Int, box: String = "[0 0 595 842]") throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenitpdf-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Probe.pdf")

        var objects: [Data] = []
        let kids = (0..<pages).map { "\(3 + $0 * 2) 0 R" }.joined(separator: " ")
        objects.append(Data("<< /Type /Catalog /Pages 2 0 R >>".utf8))
        objects.append(Data("<< /Type /Pages /Kids [\(kids)] /Count \(pages) >>".utf8))
        for index in 0..<pages {
            let contentsRef = 4 + index * 2
            objects.append(Data("""
            << /Type /Page /Parent 2 0 R /MediaBox \(box) /Contents \(contentsRef) 0 R >>
            """.utf8))
            let content = Data("0 0 1 RG 4 w 50 50 m 500 700 l S\n".utf8)
            var stream = Data("<< /Length \(content.count) >>\nstream\n".utf8)
            stream.append(content)
            stream.append(Data("\nendstream".utf8))
            objects.append(stream)
        }

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
        bytes.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF".utf8))
        try bytes.write(to: url)
        return url
    }

    @Test(
        "A well-formed three-page drawing opens a window without spinning",
        arguments: ["[0 0 595 842]", "[0 0 2384 1684]"]
    )
    func threePageWindowOpens(box: String) async throws {
        let url = try writePDF(pages: 3, box: box)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = ZenitPDFProjectDocument()
        try document.read(from: url, ofType: UTType.pdf.identifier)
        document.makeWindowControllers()
        let controller = try #require(document.windowControllers.first as? ProjectWindowController)
        // Cleared before closing: these tests commit markups, so the document is dirty, and
        // `close()` on a dirty document reaches `presentUnsavedTakeoffAlert` and waits for an
        // answer nobody is there to give. That is how this file first wedged the app gate for
        // 600 s in `TabbedWindowTests`, one suite later, on the shared document controller.
        defer {
            document.updateChangeCount(.changeCleared)
            document.close()
        }
        #expect(await AppTestSupport.wait(upTo: 30) { controller.contentViewController is ProjectWindowLayoutController })
        #expect(await AppTestSupport.wait(upTo: 30) { document.core != nil && document.shell != nil })
        controller.window?.layoutIfNeeded()
        #expect(document.core?.snapshot.pages.count == 3)
    }

    /// **The case that used to never return.**
    ///
    /// This is the reproducer that was deliberately not committed at first, because a test that
    /// never returns is a build that never returns. It is committed now because it
    /// returns: `NavigatorThumbnailLoader.order` is no longer an observed stored property, so
    /// reading a cached thumbnail from inside `NavigatorPageThumbnail.body` stops invalidating the
    /// body that read it.
    ///
    /// Three A1 pages, one plain rectangle committed on each through the shipping command bus,
    /// then `refresh()` — which is where the 99.4 % CPU spin lived, for nine minutes twice before
    /// it was killed. The window is kept alive across a settle so the Navigator's thumbnails have
    /// time to land: an empty cache cannot start the loop, which is exactly why the earlier
    /// no-markup probes passed and this one did not.
    @Test("A markup on every page of a multi-page drawing settles instead of spinning")
    func markupsOnAMultiPageDrawingSettle() async throws {
        let url = try writePDF(pages: 3, box: "[0 0 2384 1684]")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = ZenitPDFProjectDocument()
        try document.read(from: url, ofType: UTType.pdf.identifier)
        document.makeWindowControllers()
        let controller = try #require(document.windowControllers.first as? ProjectWindowController)
        defer {
            document.updateChangeCount(.changeCleared)
            document.close()
        }
        #expect(await AppTestSupport.wait(upTo: 30) {
            controller.contentViewController is ProjectWindowLayoutController
        })
        #expect(await AppTestSupport.wait(upTo: 30) { document.core != nil && document.shell != nil })
        controller.window?.layoutIfNeeded()
        let core = try #require(document.core)
        #expect(core.snapshot.pages.count == 3)

        // A filled thumbnail cache is a *precondition* of the loop — `image(for:)` returns before
        // touching the LRU array when nothing is cached, which is why the two no-markup probes
        // above always passed. Waiting for it, and asserting it, is what makes this test able to
        // fail for the reason it exists.
        let shell = try #require(document.shell)
        // The thumbnails come from the Pages rows, so the Navigator must be showing Pages: a
        // section persisted by an earlier window (Files, Search, Zones) shows no page rows and
        // requests no thumbnail at all — that, not a slow render, was the 30 s timeout.
        let layout = try #require(controller.layoutController(for: document))
        layout.panelState.navigatorSection = .pages
        controller.window?.layoutIfNeeded()
        #expect(await AppTestSupport.wait(upTo: 30) { shell.navigatorThumbnails.cachedCount > 0 },
                "no thumbnail ever landed, so this run could not have reproduced 21.7")

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for page in core.snapshot.pages {
            let pageID = PageID(page.id)
            try await core.commands.perform(.addMarkup(ZPDFContracts.MarkupRecord(
                id: MarkupID(UUID()),
                documentID: DocumentID(core.snapshot.documentID),
                pageID: pageID,
                kind: .rectangle,
                subject: "Probe",
                geometry: MeasurementGeometry(pageID: pageID, points: [
                    PDFPoint(x: 100, y: 100), PDFPoint(x: 300, y: 200)
                ]),
                createdAt: now,
                modifiedAt: now
            )))
        }
        // The line the gap marked "never returns".
        await core.refresh()
        #expect(core.snapshot.markups.count == 3)
        controller.window?.layoutIfNeeded()
    }
}
