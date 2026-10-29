import CoreGraphics
import ImageIO
import Foundation
import Testing
@testable import ZenitQuickLookCore

/// NL-PLAT-21: the Space-bar preview — the first sheet with its markups and the ledger's grand
/// totals — built from what the application saved, and nothing from the package trusted.
@Suite("Project previews for Quick Look (NL-PLAT-21)")
struct PackagePreviewTests {

    private static func writeSummary(_ summary: PackagePreviewSummary, in package: URL) throws {
        try JSONEncoder().encode(summary).write(to: package.appendingPathComponent(PackagePreview.summaryMember))
    }

    private static let summary = PackagePreviewSummary(
        projectName: "Tower A", savedAt: "2026-09-26T10:00:00Z", sheetCount: 3, markupCount: 1,
        totals: [.init(title: "Plan Length", text: "12.500 m"), .init(title: "Plan Area", text: "40.25 m²")]
    )

    @Test("The saved sheet and totals make the page: the image attached by cid, every total a row")
    func savedSummaryAndSheet() throws {
        let package = try PackageThumbnailTests.package()
        defer { try? FileManager.default.removeItem(at: package.deletingLastPathComponent()) }
        try Self.writeSummary(Self.summary, in: package)
        try PackageThumbnailTests.writePNG(width: 300, height: 200, gray: 0.4,
                                           to: package.appendingPathComponent(PackagePreview.imageMember))
        let content = try #require(PackagePreview.content(for: package))
        let saved = try Data(contentsOf: package.appendingPathComponent(PackagePreview.imageMember))
        #expect(content.imageData == saved, "the application's picture, byte for byte")
        #expect(content.html.contains("<h1>Tower A</h1>"))
        #expect(content.html.contains("3 sheets · 1 markup · saved 2026-09-26T10:00:00Z"))
        #expect(content.html.contains("<img src=\"cid:sheet.png\""))
        #expect(content.html.contains("<tr><td>Plan Length</td><td class=\"value\">12.500 m</td></tr>"))
        #expect(content.html.contains("<tr><td>Plan Area</td><td class=\"value\">40.25 m²</td></tr>"))
    }

    @Test("Text from the package is escaped: a name or a total cannot become markup")
    func textIsEscaped() throws {
        let package = try PackageThumbnailTests.package()
        defer { try? FileManager.default.removeItem(at: package.deletingLastPathComponent()) }
        var hostile = Self.summary
        hostile.projectName = "<script>alert(1)</script>"
        hostile.totals = [.init(title: "\"><img src=x onerror=alert(1)>", text: "1 & 2 < 3")]
        try Self.writeSummary(hostile, in: package)
        let html = try #require(PackagePreview.content(for: package)).html
        #expect(!html.contains("<script>"))
        #expect(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        #expect(!html.contains("<img src=x"))
        #expect(html.contains("1 &amp; 2 &lt; 3"))
    }

    @Test("A summary too large, from an unknown format, or behind a link is not read")
    func untrustedSummariesRefused() throws {
        let package = try PackageThumbnailTests.package()
        defer { try? FileManager.default.removeItem(at: package.deletingLastPathComponent()) }
        let member = package.appendingPathComponent(PackagePreview.summaryMember)

        var future = Self.summary
        future.formatVersion = 99
        try Self.writeSummary(future, in: package)
        #expect(PackagePreview.summary(in: package) == nil, "a format this build does not know")

        try Data(repeating: 0x20, count: PackagePreview.maximumSummaryBytes + 1).write(to: member)
        #expect(PackagePreview.summary(in: package) == nil, "past the size cap")

        try FileManager.default.removeItem(at: member)
        let outside = package.deletingLastPathComponent().appendingPathComponent("elsewhere.json")
        try JSONEncoder().encode(Self.summary).write(to: outside)
        try FileManager.default.createSymbolicLink(at: member, withDestinationURL: outside)
        #expect(PackagePreview.summary(in: package) == nil, "a link out of the package is not followed")
    }

    @Test("Counts and strings are bounded: no negative count, no endless title, at most 200 totals")
    func summaryIsBounded() throws {
        let package = try PackageThumbnailTests.package()
        defer { try? FileManager.default.removeItem(at: package.deletingLastPathComponent()) }
        var wide = Self.summary
        wide.sheetCount = -4
        wide.projectName = String(repeating: "A", count: 5_000)
        wide.totals = (0..<500).map { .init(title: "C\($0)", text: "\($0)") }
        try Self.writeSummary(wide, in: package)
        let read = try #require(PackagePreview.summary(in: package))
        #expect(read.sheetCount == 0)
        #expect(read.projectName.count == PackagePreview.maximumStringLength)
        #expect(read.projectName.hasSuffix("…"))
        #expect(read.totals.count == PackagePreview.maximumTotals)
    }

    @Test("A project saved before previews shows its thumbnail picture and says when totals appear")
    func olderProjectFallsBack() throws {
        let package = try PackageThumbnailTests.package()
        defer { try? FileManager.default.removeItem(at: package.deletingLastPathComponent()) }
        try PackageThumbnailTests.writeDrawing(to: package.appendingPathComponent("documents/working.pdf"))
        let content = try #require(PackagePreview.content(for: package))
        // Drawn here from the first sheet: 842 × 595 pt fits inside 1200 and is never enlarged,
        // so 842 × 595 px at one pixel per point.
        let image = try #require(content.imageData.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }
            .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(image.width == 842 && image.height == 595)
        #expect(content.html.contains("<h1>Plan</h1>"), "the package's own name stands in")
        #expect(content.html.contains("after the project is next saved"))
        #expect(!content.html.contains("<table>"))
    }

    @Test("A package with nothing readable has no preview")
    func emptyPackageHasNone() throws {
        let package = try PackageThumbnailTests.package()
        defer { try? FileManager.default.removeItem(at: package.deletingLastPathComponent()) }
        #expect(PackagePreview.content(for: package) == nil)
    }

    @Test("The empty ledger says so rather than showing an empty table")
    func emptyLedger() throws {
        let package = try PackageThumbnailTests.package()
        defer { try? FileManager.default.removeItem(at: package.deletingLastPathComponent()) }
        var empty = Self.summary
        empty.totals = []
        try Self.writeSummary(empty, in: package)
        let html = try #require(PackagePreview.content(for: package)).html
        #expect(html.contains("The ledger has no totals yet."))
        #expect(!html.contains("<table>"))
    }
}
