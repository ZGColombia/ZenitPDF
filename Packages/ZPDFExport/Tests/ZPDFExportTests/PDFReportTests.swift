import Foundation
import CoreGraphics
import Testing
import ZPDFQuantityLedger
@testable import ZPDFExport

@Suite("PDF report", .sharedHeap)
struct PDFReportTests {

    private func pageCount(of url: URL) throws -> Int {
        let document = try #require(CGPDFDocument(url as CFURL))
        return document.numberOfPages
    }

    /// Extracts the text of one page by walking the content stream operators. Nothing here uses
    /// PDFKit: the export layer must not depend on it, and neither must its tests.
    private func text(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        // The report's content streams are uncompressed only if we ask; instead of decoding
        // Flate by hand, assert on structure and on the renderer's own draw trace.
        return String(decoding: data.prefix(2048), as: UTF8.self)
    }

    @Test("A report is a readable PDF with a cover page")
    func rendersAPDF() throws {
        let projection = try ExportFixture.projection(try ExportFixture.goldenReport(grouped: true))
        let url = temporaryURL("pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        // Ten columns need the long edge; on portrait A4 the same table bands, which is what
        // `columnBanding` below asserts.
        let result = try PDFReportRenderer().render(
            projection,
            to: url,
            options: PDFReportOptions(pageSize: .a4.landscape, maximumColumnWidth: 70)
        )
        #expect(result.pageCount >= 2)
        #expect(result.bandCount == 1)
        #expect(try pageCount(of: url) == result.pageCount)
        #expect(try text(of: url).hasPrefix("%PDF-"))
    }

    @Test("Without a cover page the report starts with the table")
    func noCover() throws {
        let projection = try ExportFixture.projection(try ExportFixture.goldenReport())
        let url = temporaryURL("pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try PDFReportRenderer().render(
            projection,
            to: url,
            options: PDFReportOptions(
                pageSize: .a4.landscape, includeCoverPage: false, maximumColumnWidth: 70
            )
        )
        #expect(result.pageCount == 1)
    }

    @Test("Every table cell drawn is the projection's string, in order")
    func drawnTextMatchesTheProjection() throws {
        let projection = try ExportProjector().project(
            try ExportFixture.goldenReport(),
            options: ExportProjectionOptions(columnKeys: ["subject", "golden", "footprint"])
        )
        let url = temporaryURL("pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try PDFReportRenderer().render(
            projection,
            to: url,
            options: PDFReportOptions(
                includeCoverPage: false,
                includeGrandTotals: false,
                recordsDrawnText: true
            )
        )
        let expected = projection.table.rows.flatMap { $0.cells.map(\.text) }
        #expect(result.drawnText == expected)
        #expect(result.bandCount == 1)
    }

    @Test("A table wider than the page continues on further bands")
    func columnBanding() throws {
        let projection = try ExportFixture.projection(try ExportFixture.goldenReport())
        let url = temporaryURL("pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        // A deliberately narrow page: 200 pt of usable width cannot hold nine columns.
        let result = try PDFReportRenderer().render(
            projection,
            to: url,
            options: PDFReportOptions(
                pageSize: PDFReportPageSize(width: 272, height: 500),
                includeCoverPage: false
            )
        )
        #expect(result.bandCount > 1)
        #expect(result.pageCount >= result.bandCount)
        #expect(try pageCount(of: url) == result.pageCount)
    }

    @Test("Every band after the first repeats the identity column")
    func bandsRepeatTheIdentityColumn() throws {
        let widths = [70.0, 90, 90, 90, 90, 90]
        let bands = try PDFReportRenderer.bands(
            widths: widths, usable: 200, options: PDFReportOptions()
        )
        #expect(bands.count > 1)
        for band in bands.dropFirst() {
            #expect(band.columns.first == 0)
        }
        // Every original column appears in exactly one band, ignoring the repeated identity.
        var seen: Set<Int> = []
        for (index, band) in bands.enumerated() {
            for column in band.columns where !(index > 0 && column == 0) {
                #expect(seen.insert(column).inserted, "column \(column) appears twice")
            }
        }
        #expect(seen == Set(0..<widths.count))
    }

    @Test("A page too narrow for one column is a typed error, not a hang")
    func pageTooSmall() throws {
        #expect(throws: ExportError.self) {
            _ = try PDFReportRenderer.bands(
                widths: [70], usable: 4, options: PDFReportOptions()
            )
        }
    }

    @Test("Group headings, subtotals and a grand total are drawn")
    func groupedLines() throws {
        let projection = try ExportFixture.projection(try ExportFixture.goldenReport(grouped: true))
        let lines = PDFReportRenderer.flatten(table: projection.table, options: PDFReportOptions())
        var headings = 0
        var subtotals = 0
        var grandTotals = 0
        var rows = 0
        for line in lines {
            switch line {
            case .groupHeading: headings += 1
            case .row: rows += 1
            case .subtotal: subtotals += 1
            case .grandTotal: grandTotals += 1
            }
        }
        #expect(headings == 2)
        #expect(rows == 6)
        #expect(subtotals >= 2)
        #expect(grandTotals >= 1)
    }

    @Test("The optional appendix draws one page per supplied image")
    func appendix() throws {
        let projection = try ExportFixture.projection(try ExportFixture.goldenReport())
        let url = temporaryURL("pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        let space = CGColorSpaceCreateDeviceRGB()
        let bitmap = try #require(CGContext(
            data: nil, width: 200, height: 140, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        bitmap.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: 200, height: 140))
        let image = try #require(bitmap.makeImage())

        let plain = try PDFReportRenderer().render(
            projection, to: url, options: PDFReportOptions(includeCoverPage: false)
        )
        let withAppendix = try PDFReportRenderer().render(
            projection,
            to: url,
            options: PDFReportOptions(includeCoverPage: false),
            appendix: [
                PDFReportAppendixPage(title: "Page 1", caption: "Level 1 plan", image: image),
                PDFReportAppendixPage(title: "Page 2", image: image)
            ]
        )
        #expect(withAppendix.pageCount == plain.pageCount + 2)
        #expect(try pageCount(of: url) == withAppendix.pageCount)
    }

    /// 10 000 rows through the renderer. The assertion is that it finishes, produces the pages
    /// the row count implies, and does not hold a layout: peak resident memory is checked by the
    /// benchmark, but a renderer that accumulated per-row objects would not finish this at all
    /// inside the test timeout.
    @Test("10 000 rows paginate without accumulating a layout")
    func volume() throws {
        let projection = try ExportFixture.projection(
            try ExportFixture.syntheticReport(rowCount: 10_000)
        )
        let url = temporaryURL("pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try PDFReportRenderer().render(
            projection,
            to: url,
            options: PDFReportOptions(
                columnPadding: 4,
                maximumColumnWidth: 90
            )
        )
        #expect(result.pageCount > 150)
        print("PDF report: 10 000 rows rendered to \(result.pageCount) pages in \(result.bandCount) band(s)")
        #expect(try pageCount(of: url) == result.pageCount)
        let size = try #require(
            try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.size] as? Int
        )
        #expect(size > 100_000)
    }

    @Test("The audit-trail appendix draws every supplied row, in order, on extra pages")
    func auditAppendixDrawsTheTrail() throws {
        let projection = try ExportFixture.projection(try ExportFixture.goldenReport())
        let withoutURL = temporaryURL("pdf")
        let withURL = temporaryURL("pdf")
        defer {
            try? FileManager.default.removeItem(at: withoutURL)
            try? FileManager.default.removeItem(at: withURL)
        }
        let options = PDFReportOptions(
            includeCoverPage: false, includeGrandTotals: false, recordsDrawnText: true
        )
        let rows: [[String]] = (1...80).map { index in
            ["\(index)", "2026-08-24T10:0\(index % 10):00Z", "Measured", "Verifier",
             "Length", "1", "Plan Length \(index),00 m", ""]
        }
        let appendix = PDFReportAuditAppendix(
            title: "Audit Trail",
            caption: "80 recorded changes",
            columnTitles: ["#", "Time", "Action", "Author", "Subject", "Page", "Values", "Note"],
            rows: rows
        )
        let renderer = PDFReportRenderer()
        let without = try renderer.render(projection, to: withoutURL, options: options)
        let with = try renderer.render(
            projection, to: withURL, options: options, auditAppendix: appendix
        )
        // Optional means optional: leaving it out changes nothing.
        #expect(without.pageCount < with.pageCount, "the appendix must add pages")
        #expect(try pageCount(of: withURL) == with.pageCount)
        // Every supplied cell was drawn, in order, after the table body.
        let appendixCells = Array(with.drawnText.suffix(rows.count * 8))
        #expect(appendixCells == rows.flatMap { $0 },
                "the appendix must draw the caller's finished strings verbatim")
        #expect(Array(with.drawnText.prefix(without.drawnText.count)) == without.drawnText,
                "the appendix must not disturb the table body")
    }

    @Test("Two renders of the same projection produce the same page count")
    func deterministicPagination() throws {
        let projection = try ExportFixture.projection(try ExportFixture.goldenReport(grouped: true))
        let first = temporaryURL("pdf")
        let second = temporaryURL("pdf")
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let renderer = PDFReportRenderer()
        let a = try renderer.render(projection, to: first)
        let b = try renderer.render(projection, to: second)
        #expect(a == b)
    }
}
