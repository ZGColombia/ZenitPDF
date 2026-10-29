import AppKit
import ImageIO
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZenitQuickLookCore
@testable import ZenitPDFAppKit

/// Loop iteration 1, persistence, the application half: scan auto-trace prepares a page's
/// linework once, not on every ⌥-click (R-195); a save writes the Space-bar preview's sheet and
/// totals (NL-PLAT-21).
@MainActor
@Suite("Iteration 1 — persistence, application", .appTierSerialised)
struct Iter1PersistenceLaneAppTests {

    /// Old output: every call re-ran `ScanLinework.primitives(in:)` and `RegionTracer.prepare`
    /// over the whole raster — two calls, two preparations (only the raster was cached).
    @Test("R-195: the scan's prepared trace is computed once per page and reused by every later trace")
    func scanPreparedTraceIsCached() async throws {
        let harness = try await Fix2Harness.make("R195.pdf", calibrate: false)
        defer { harness.tearDown() }
        let before = ScanTrace.preparationCountForTesting
        let first = await ScanTrace.preparedTrace(document: harness.document, pageIndex: 0)
        let second = await ScanTrace.preparedTrace(document: harness.document, pageIndex: 0)
        let third = await ScanTrace.preparedTrace(document: harness.document, pageIndex: 0)
        #expect(first != nil && second != nil && third != nil)
        #expect(ScanTrace.preparationCountForTesting - before == 1)
        // A page that does not exist has no raster and nothing to prepare.
        #expect(await ScanTrace.preparedTrace(document: harness.document, pageIndex: 99) == nil)
        #expect(ScanTrace.preparationCountForTesting - before == 1)
    }

    /// Hand-derived: the harness calibrates 100 pt = 1 m, so a length from x = 72 to x = 500 pt is
    /// 428 pt = 4.28 m.
    @Test("NL-PLAT-21: a save writes the preview's sheet and summary, and the extension builds the page from them")
    func saveWritesTheQuickLookPreview() async throws {
        let harness = try await Fix2Harness.make("NLPLAT21.pdf")
        defer { harness.tearDown() }
        _ = try await harness.addMarkup(tool: .length, geometry: { page in
            MeasurementGeometry(pageID: page, points: [PDFPoint(x: 72, y: 400), PDFPoint(x: 500, y: 400)])
        }, subject: "Wall")
        await harness.settle()
        let package = try await Iter1ShellGlueTests.saveAsProject(harness, name: "Preview.zpdfproj")
        let summaryURL = package.appendingPathComponent(ZenitPDFProjectDocument.quickLookSummaryMember)
        let imageURL = package.appendingPathComponent(ZenitPDFProjectDocument.quickLookPreviewImageMember)
        // A test process does not write them by default (package-format tests list exact members).
        #expect(!FileManager.default.fileExists(atPath: summaryURL.path))

        let previous = ZenitPDFProjectDocument.writesPackageThumbnail
        ZenitPDFProjectDocument.writesPackageThumbnail = true
        defer { ZenitPDFProjectDocument.writesPackageThumbnail = previous }
        harness.document.updateChangeCount(.changeDone)
        try await Iter1ShellGlueTests.save(harness.document, to: package, .saveOperation)
        // Old output: neither member existed, and a project had no Space-bar preview at all.
        #expect(await AppTestSupport.wait { FileManager.default.fileExists(atPath: summaryURL.path) })

        let summary = try JSONDecoder().decode(PackagePreviewSummary.self, from: Data(contentsOf: summaryURL))
        #expect(summary.formatVersion == PackagePreviewSummary.currentFormatVersion)
        #expect(summary.sheetCount == 1)
        #expect(summary.markupCount == 1)
        // The ledger's own grand totals, through the one reading Shortcuts shares.
        let projection = try await ProjectWindowController.projection(
            core: harness.core, documentName: summary.projectName, scaleDescription: harness.core.snapshot.documentScaleDescription,
            request: harness.core.ledger.request)
        #expect(summary.totals.map(\.text) == ZenitShortcutsBridge.totalRows(projection).map(\.text))
        // The plan length's grand total is the hand-derived 4.28 m, as the ledger displays it
        // (two decimals, the unit in the column's title) — in the ledger's own number locale
        // since L-46; it was the invariant "4.28" under a Swedish ledger's "4,28".
        let expected = projection.numberLocale.string(Decimal(string: "4.28")!, decimalPlaces: 2)
        let length = try #require(summary.totals.first { $0.text == expected }, "\(summary.totals)")
        #expect(!length.title.isEmpty)

        // The sheet at preview size: 595 × 842 pt at 1600 / 842 px per pt is 1131 × 1600.
        let source = try #require(CGImageSourceCreateWithURL(imageURL as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.height == 1_600)
        #expect(image.width == 1_131)

        // What the preview extension builds from what the app wrote.
        let content = try #require(PackagePreview.content(for: package))
        #expect(content.imageData == (try Data(contentsOf: imageURL)))
        #expect(content.html.contains(PackagePreview.escape(length.text)))
        #expect(content.html.contains("1 sheet · 1 markup"))
    }
}
