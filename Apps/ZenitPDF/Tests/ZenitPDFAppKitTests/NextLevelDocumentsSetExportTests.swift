import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFPDFKitBridge
import ZPDFTestingSupport
@testable import ZenitPDFAppKit

/// NL-DOCS-08 (export arranged set, extract, split by sheet number) with NL-DOCS-05/06 on export
/// (sheet numbers as page labels, bookmarks from sheet names). Headless: the panels are answered
/// through `ZenitModalPresenter`.
@MainActor
@Suite("Documents — the set as a PDF", .appTierSerialised)
struct NextLevelDocumentsSetExportTests {

    private func setHarness() async throws -> (Fix2Harness, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nl-docs-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = try ZPDFFixtures.make(.set30SheetsTitleBlocks, in: directory)
        let harness = try await Fix2Harness.make("Export.pdf", calibrate: false, fixture: fixture.url)
        return (harness, directory)
    }

    @Test("Export Arranged Set: set order and turns, sheet numbers as labels, sheet-name bookmarks by discipline")
    func exportArrangedSet() async throws {
        let (harness, directory) = try await setHarness()
        defer {
            ZenitModalPresenter.handler = nil
            harness.tearDown()
            try? FileManager.default.removeItem(at: directory)
        }
        let core = harness.core
        let ids = await core.session.pageOrderIDs
        let before = try Data(contentsOf: try #require(harness.document.drawing?.url))
        // Sheet 3 first, sheet 1 turned, and the first two sheets named.
        _ = try await core.commands.perform(.reorderPage(from: 2, to: 0))
        _ = try await core.commands.perform(.setPageViews([ids[0]: PageViewSettings(rotation: 90)]))
        _ = try await core.commands.perform(.setSheetIdentities([
            ids[0]: SheetIdentity(number: "Z-900", title: "COVER", source: .manual),
            ids[2]: SheetIdentity(number: "B-100", title: "BASEMENT", source: .manual)
        ], overwriteManual: true))

        let destination = directory.appendingPathComponent("arranged.pdf")
        ZenitModalPresenter.handler = { request in
            request.identifier == ZenitPDFProjectDocument.exportArrangedSetPanelIdentifier ? .urls([destination]) : .dismissed
        }
        harness.document.exportArrangedSet(window: nil)
        #expect(await AppTestSupport.wait(upTo: 20) { FileManager.default.fileExists(atPath: destination.path) })
        try await Task.sleep(nanoseconds: 300_000_000)

        let reader = PDFKitDocumentProvider()
        let result = try await reader.open(fileAt: destination)
        #expect(result.descriptor.pageCount == 30)
        let labels = try await reader.pageLabels(of: result.handle).allLabels()
        // Sheet 3 (named B-100) first, then sheet 1 (Z-900), then sheet 2 with its own label.
        #expect(Array(labels.prefix(3)) == ["B-100", "Z-900", "A-102"])
        let outline = try await reader.outline(of: result.handle)
        #expect(outline.roots.map(\.label) == ["B", "Z"], "one group per discipline, in set order")
        #expect(outline.roots[1].children.first?.label == "Z-900 · COVER")
        #expect(outline.roots[1].children.first?.destination?.pageIndex == 1)
        let pdf = try #require(SetExportRotationProbe.rotation(of: destination, page: 1))
        #expect(pdf == 90, "the turned sheet is turned in the file")
        #expect(try Data(contentsOf: try #require(harness.document.drawing?.url)) == before, "the drawing was never written")
    }

    @Test("Split: one file per sheet named by sheet number, all 30 in well under 20 s; a cancel leaves nothing")
    func splitBySheetNumber() async throws {
        let (harness, directory) = try await setHarness()
        defer {
            harness.tearDown()
            try? FileManager.default.removeItem(at: directory)
        }
        let core = harness.core
        let ids = await core.session.pageOrderIDs
        _ = try await core.commands.perform(.setSheetIdentities(
            [ids[0]: SheetIdentity(number: "A-101", title: nil, source: .manual),
             ids[1]: SheetIdentity(number: "A/102", title: nil, source: .manual)], overwriteManual: true
        ))
        let pages = await harness.document.setExportPages()
        let names = ZenitPDFProjectDocument.splitFileNames(pages)
        #expect(names[0] == "A-101.pdf")
        #expect(names[1] == "A-102.pdf", "a separator a file system refuses becomes a hyphen")
        #expect(Set(names.map { $0.lowercased() }).count == 30, "unique")

        let folder = directory.appendingPathComponent("split", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let started = Date()
        let written = await harness.document.writeSplit(pages, into: folder)
        #expect(written.count == 30)
        #expect(Date().timeIntervalSince(started) < 20)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("A-101.pdf").path))

        let cancelled = directory.appendingPathComponent("cancelled", isDirectory: true)
        try FileManager.default.createDirectory(at: cancelled, withIntermediateDirectories: true)
        let counter = Counter()
        let none = await harness.document.writeSplit(pages, into: cancelled, isCancelled: { counter.next() > 5 })
        #expect(none.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: cancelled.path).isEmpty, "no partial files")
    }

    @Test("Sheet-name bookmarks group by the letters of the number; unnamed sheets get none")
    func bookmarkGrouping() async throws {
        let (harness, directory) = try await setHarness()
        defer {
            harness.tearDown()
            try? FileManager.default.removeItem(at: directory)
        }
        let ids = await harness.core.session.pageOrderIDs
        _ = try await harness.core.commands.perform(.setSheetIdentities([
            ids[0]: SheetIdentity(number: "S-2", title: "FRAME", source: .manual),
            ids[1]: SheetIdentity(number: "A-1", title: nil, source: .manual),
            ids[2]: SheetIdentity(number: "S-3", title: nil, source: .manual)
        ], overwriteManual: true))
        let marks = ZenitPDFProjectDocument.sheetNameBookmarks(await harness.document.setExportPages())
        #expect(marks.map(\.title) == ["S", "A"])
        #expect(marks[0].children.map(\.title) == ["S-2 · FRAME", "S-3"])
        #expect(marks[0].children.map(\.resultPageIndex) == [0, 2])
    }
}

/// Counts calls, for the cancellation test.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}

/// Reads a page's `/Rotate` from a written file.
private enum SetExportRotationProbe {
    static func rotation(of url: URL, page: Int) -> Int? {
        guard let document = CGPDFDocument(url as CFURL), let pdfPage = document.page(at: page + 1) else { return nil }
        return Int(pdfPage.rotationAngle)
    }
}
