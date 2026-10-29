import AppKit
import CoreGraphics
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFExport
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// NL-COLLAB-16, the round-2 remainder: the review report as an Excel workbook, and a snapshot of
/// each markup in the PDF and the workbook.
@MainActor
@Suite(.appTierSerialised, .serialized)
struct NLQuantitiesR2ReviewReportTests {

    @Test("A real cloud on a real sheet gets a snapshot; the PDF draws it and the workbook embeds it")
    func snapshotsReachBothFormats() async throws {
        let fixture = try AppTestSupport.writeFixturePDF(named: "Review Snap.pdf")
        let harness = try await Fix2Harness.make("Review Snap.pdf", calibrate: false, fixture: fixture)
        let xlsx = FileManager.default.temporaryDirectory.appendingPathComponent("review-\(UUID().uuidString).xlsx")
        defer {
            harness.tearDown()
            try? FileManager.default.removeItem(at: xlsx)
        }
        let page = try #require(harness.core.snapshot.pages.first)
        let cloud = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: DocumentID(harness.core.snapshot.documentID), pageID: PageID(page.id),
            kind: .cloud, subject: "Walls", comment: "=HYPERLINK(\"http://x\")", author: "Ada",
            geometry: MeasurementGeometry(pageID: PageID(page.id), polygons: [PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: 100, y: 100), PDFPoint(x: 200, y: 100), PDFPoint(x: 200, y: 200)
            ], isClosed: true))]),
            createdAt: Date(), modifiedAt: Date()
        )
        try await harness.core.commands.perform(.addMarkup(cloud))
        await harness.core.refresh()
        let review = try #require(harness.document.shell?.review)
        var entries = ReviewReportExport.entries(for: [cloud.id.rawValue], review: review)
        #expect(entries.count == 1)

        let pictures = await ReviewReportSnapshots.snapshots(for: entries, document: harness.document)
        let png = try #require(pictures[cloud.id.rawValue], "the cloud has a snapshot")
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        // The cloud's 100 × 100 pt box plus 24 pt padding each side is at least 148 pt square
        // (its scallops and stroke widen it); at 1.5 px/pt, at least 222 px, and square.
        #expect(image.width >= 222 && image.height >= 222)
        #expect(image.width == image.height)
        #expect(image.width < 400, "a crop of the markup, not the sheet")
        entries[0].snapshot = png

        let report = ReviewReportExport.renderPDF(entries, title: "Tower")
        #expect(report.drawnSnapshots == 1)
        #expect(report.pageCount == 1)
        #expect(CGPDFDocument(CGDataProvider(data: report.data as CFData)!)?.numberOfPages == 1)

        try ReviewReportExport.write(entries, title: "Tower", to: xlsx)
        let sheet = try XLSXCellReader.entry("xl/worksheets/sheet1.xml", of: xlsx)
        #expect(!sheet.contains("<f>"), "the note is text, never a formula")
        #expect(!(try XLSXCellReader.entry("xl/media/image1.png", of: xlsx)).isEmpty, "the snapshot is in the workbook")
        let shared = try XLSXCellReader.entry("xl/sharedStrings.xml", of: xlsx)
        #expect(shared.contains("HYPERLINK"))
        #expect(shared.contains("Snapshot"))
        let workbook = ReviewReportExport.workbook(entries)
        #expect(workbook.header == ReviewReportExport.header)
        #expect(workbook.rows[0] == ReviewReportExport.cells(for: entries[0]), "the CSV and the workbook carry the same rows")
    }
}

/// Reads one part of a written workbook, the way a spreadsheet would find it.
enum XLSXCellReader {
    static func entry(_ name: String, of url: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path(percentEncoded: false), name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
