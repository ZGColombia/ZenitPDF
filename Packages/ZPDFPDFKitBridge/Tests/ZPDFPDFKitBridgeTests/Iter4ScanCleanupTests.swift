import CoreGraphics
import Foundation
import Testing
import ZPDFPDFKitBridge
import ZPDFTestingSupport

/// Iteration 4, U-053: Clean Up Scanned Sheets keeps every sheet of the drawing
/// in its place. No `@testable`: the release gate builds this package's tests, and the budgeted
/// entry point and ``ScanCleanup/renderingDPI(paper:requested:pixelBudget:)`` are `package`.
@Suite("Iteration 4 — scan clean-up keeps every sheet (U-053)", .serialized)
struct Iter4ScanCleanupTests {

    /// A PDF whose pages have the given sizes, each with a ruled line so it is not blank.
    static func drawing(pages sizes: [CGSize], at url: URL) throws {
        let context = try #require(CGContext(url as CFURL, mediaBox: nil, nil))
        for size in sizes {
            var box = CGRect(origin: .zero, size: size)
            context.beginPage(mediaBox: &box)
            context.setStrokeColor(CGColor(gray: 0, alpha: 1))
            context.setLineWidth(2)
            context.move(to: CGPoint(x: 10, y: size.height / 2))
            context.addLine(to: CGPoint(x: size.width - 10, y: size.height / 2))
            context.strokePath()
            context.endPage()
        }
        context.closePDF()
    }

    static func mediaBoxes(of url: URL) throws -> [CGSize] {
        let document = try #require(CGPDFDocument(url as CFURL))
        return (0..<document.numberOfPages).compactMap { document.page(at: $0 + 1)?.getBoxRect(.mediaBox).size }
    }

    @Test("U-053: the largest whole dpi within the budget, hand-derived for a 60 × 96 in sheet at 200 dpi")
    func renderingDPIFitsTheBudget() {
        // 4320 × 6912 pt = 29 859 840 pt². At 200 dpi: 12 000 × 19 200 = 230 400 000 px, over
        // 200 000 000. 72 × √(200 000 000 / 29 859 840) = 72 × 2.58805… = 186.34 → 186 dpi:
        // 11 160 × 17 856 = 199 272 960 px. Old: no dpi was looked for; the sheet was skipped.
        let sheet = CGSize(width: 4320, height: 6912)
        #expect(ScanCleanup.renderingDPI(paper: sheet, requested: 200, pixelBudget: ScanCleanup.pixelBudget) == 186)
        // A sheet that fits keeps the requested resolution exactly.
        #expect(ScanCleanup.renderingDPI(paper: CGSize(width: 612, height: 792), requested: 200, pixelBudget: ScanCleanup.pixelBudget) == 200)
        // Not even 1 dpi fits a budget of one pixel: 400 × 300 pt at 1 dpi is 6 × 4 px.
        #expect(ScanCleanup.renderingDPI(paper: CGSize(width: 400, height: 300), requested: 200, pixelBudget: 1) == nil)
    }

    @Test("U-053: a chosen sheet over the pixel budget is cleaned at a lower dpi and keeps its place")
    func oversizedSheetIsCleanedAtLowerResolution() throws {
        let directory = try Corpus.scratchDirectory("iter4-scan-budget")
        let input = directory.appendingPathComponent("large.pdf"), output = directory.appendingPathComponent("clean.pdf")
        try Self.drawing(pages: [CGSize(width: 2000, height: 1000), CGSize(width: 400, height: 300)], at: input)
        // Budget 2 000 000 px. Sheet 1 at 200 dpi: 5556 × 2778 = 15 434 568 px, over; at 72 dpi
        // (72 × √(2 000 000 / 2 000 000) = 72): 2000 × 1000 = 2 000 000 px, which fits.
        // Sheet 2 at 200 dpi: 1111 × 833 = 925 463 px, which fits.
        // Old (same rule at the shipping budget): sheet 1 skipped — one page written, one report,
        // sheet 2 moved up to page 1, and nothing said so.
        let reports = try ScanCleanup.cleanDocument(
            at: input, to: output, options: .init(straightens: false, enhancement: .none, dpi: 200), pixelBudget: 2_000_000
        )
        #expect(reports.map(\.pageIndex) == [0, 1])
        #expect(reports.map(\.renderedDPI) == [72, 200])
        #expect(reports[0].wasReduced(from: 200))
        #expect(!reports[1].wasReduced(from: 200))
        #expect(try Self.mediaBoxes(of: output) == [CGSize(width: 2000, height: 1000), CGSize(width: 400, height: 300)])
    }

    @Test("U-053: a chosen sheet that cannot be rendered at all is copied as it is, in its place, and says so")
    func unrenderableSheetIsCopiedAsIs() throws {
        let directory = try Corpus.scratchDirectory("iter4-scan-copy")
        let input = directory.appendingPathComponent("two.pdf"), output = directory.appendingPathComponent("clean.pdf")
        try Self.drawing(pages: [CGSize(width: 400, height: 300), CGSize(width: 500, height: 350)], at: input)
        // A one-pixel budget: no resolution fits sheet 1, chosen alone. Old: `continue` — the
        // copy had one page, sheet 2 in sheet 1's place, and no report for sheet 1.
        let reports = try ScanCleanup.cleanDocument(
            at: input, to: output, pages: [0], options: .init(straightens: false, enhancement: .none, dpi: 200), pixelBudget: 1
        )
        #expect(reports.count == 1)
        #expect(reports.first?.pageIndex == 0)
        #expect(reports.first?.renderedDPI == nil)
        #expect(reports.first?.wasCleaned == false)
        #expect(try Self.mediaBoxes(of: output) == [CGSize(width: 400, height: 300), CGSize(width: 500, height: 350)])
    }

    @Test("U-053: a drawing past 2,000 pages is refused whole, and nothing is written")
    func pastThePageLimitIsRefused() throws {
        let directory = try Corpus.scratchDirectory("iter4-scan-limit")
        let input = directory.appendingPathComponent("many.pdf"), output = directory.appendingPathComponent("clean.pdf")
        try Self.drawing(pages: Array(repeating: CGSize(width: 72, height: 72), count: ScanCleanup.pageLimit + 1), at: input)
        // Old: the copy stopped at page 2,000 and the 2,001st sheet was gone without a word.
        #expect(throws: ScanCleanup.Refusal.tooManyPages(count: 2_001, limit: 2_000)) {
            try ScanCleanup.cleanDocument(at: input, to: output, pages: [0], options: .init(straightens: false, enhancement: .none))
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }
}
