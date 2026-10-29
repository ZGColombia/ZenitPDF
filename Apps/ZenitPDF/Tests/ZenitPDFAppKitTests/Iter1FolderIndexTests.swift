import AppKit
import CoreText
import Foundation
import PDFKit
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// NL-DOCS-15: the folder index of closed drawings — granted, indexed per drawing by SHA-256,
/// searched without opening a drawing, opened at the sheet a hit is on, and forgotten. Headless:
/// the folder is a temporary directory, the index root is a temporary directory, the defaults are
/// a scratch store and the search sheet's presenter is injected.
@MainActor
@Suite("Folder index of closed drawings (NL-DOCS-15)", .appTierSerialised)
struct Iter1FolderIndexTests {

    /// A PDF whose pages carry real text — `words[i]` on page i — so the text layer, not OCR, finds it.
    static func textPDF(at url: URL, words: [String]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var box = CGRect(x: 0, y: 0, width: 612, height: 396)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        let font = CTFontCreateWithName("Helvetica" as CFString, 36, nil)
        for word in words {
            context.beginPDFPage(nil)
            context.textPosition = CGPoint(x: 72, y: 200)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(
                string: word, attributes: [.init(kCTFontAttributeName as String): font]
            )), context)
            context.endPDFPage()
        }
        context.closePDF()
    }

    struct Fixture {
        let root: URL
        let folder: URL
        let index: FolderIndex
    }

    static func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nl-docs-15-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("Drawings", isDirectory: true)
        try textPDF(at: folder.appendingPathComponent("A-101 Plan.pdf"), words: ["FOUNDATION PLAN"])
        try textPDF(at: folder.appendingPathComponent("Elevations/A-201.pdf"), words: ["SOUTH ELEVATION", "NORTH ELEVATION"])
        try Data("notes".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        try textPDF(at: folder.appendingPathComponent(".hidden.pdf"), words: ["HIDDEN"])
        // A project package: its drawings are the project's, not the folder's.
        try textPDF(at: folder.appendingPathComponent("Tower.zpdfproj/documents/original.pdf"), words: ["PACKAGED"])
        let locked = try #require(PDFDocument(url: folder.appendingPathComponent("A-101 Plan.pdf")))
        #expect(locked.write(to: folder.appendingPathComponent("Locked.pdf"), withOptions: [.userPasswordOption: "x", .ownerPasswordOption: "y"]))
        let index = FolderIndex()
        index.defaults = ZenitScratchDefaults()
        index.root = root.appendingPathComponent("Index", isDirectory: true)
        index.grant(folder)
        return Fixture(root: root, folder: folder, index: index)
    }

    @Test("The folder's PDFs are found recursively; hidden files, other files and project packages are left out")
    func findsTheDrawings() throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (files, truncated) = FolderIndex.drawings(in: fixture.folder)
        let base = fixture.folder.standardizedFileURL.resolvingSymlinksInPath().path
        #expect(files.map { FolderIndex.relativePath(of: $0, base: base) } == ["A-101 Plan.pdf", "Elevations/A-201.pdf", "Locked.pdf"])
        #expect(!truncated)
        #expect(FolderIndex.drawings(in: fixture.folder, limit: 2).truncated)
    }

    @Test("Indexing reads each drawing into its own index; search finds text in closed drawings, grouped by file and sheet")
    func indexAndSearch() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let report = try #require(await fixture.index.rebuild())
        #expect(report.indexed == 2)
        #expect(report.unchanged == 0)
        #expect(report.skipped.map(\.relativePath) == ["Locked.pdf"])
        #expect(report.skipped.first?.reason == "locked with a password")
        let catalogue = try #require(fixture.index.loadCatalogue())
        #expect(catalogue.entries.map(\.relativePath) == ["A-101 Plan.pdf", "Elevations/A-201.pdf"])
        #expect(catalogue.entries.map(\.pageCount) == [1, 2])
        for entry in catalogue.entries {
            #expect(FileManager.default.fileExists(atPath: FolderIndex.indexURL(sha256: entry.sha256, root: fixture.index.root).path))
        }

        let elevations = await fixture.index.search("elevation")
        #expect(elevations.map(\.relativePath) == ["Elevations/A-201.pdf"])
        #expect(elevations.first?.hits.map(\.pageIndex) == [0, 1], "both sheets, in page order")
        let north = await fixture.index.search("NORTH")
        #expect(north.first?.hits.map(\.pageIndex) == [1])
        let plan = await fixture.index.search("FOUNDATION")
        #expect(plan.map(\.relativePath) == ["A-101 Plan.pdf"])
        #expect(plan.first?.hits.first?.snippet.uppercased().contains("FOUNDATION") == true)
        #expect(await fixture.index.search("HIDDEN").isEmpty, "a hidden file is not indexed")
        #expect(await fixture.index.search("PACKAGED").isEmpty, "a project's drawings are not the folder's")
        #expect(await fixture.index.search("   ").isEmpty)
    }

    @Test("A second pass reads only what changed, and an index no file names any more is deleted")
    func incrementalRebuild() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = await fixture.index.rebuild()
        let first = try #require(fixture.index.loadCatalogue())
        let again = try #require(await fixture.index.rebuild())
        #expect(again.indexed == 0)
        #expect(again.unchanged == 2)
        // A-101 is replaced by a new revision; A-201 is deleted.
        let plan = fixture.folder.appendingPathComponent("A-101 Plan.pdf")
        try Self.textPDF(at: plan, words: ["FOUNDATION PLAN REVISION B"])
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: plan.path)
        try FileManager.default.removeItem(at: fixture.folder.appendingPathComponent("Elevations/A-201.pdf"))
        let third = try #require(await fixture.index.rebuild())
        #expect(third.indexed == 1)
        #expect(third.unchanged == 0)
        #expect(await fixture.index.search("elevation").isEmpty)
        #expect(await fixture.index.search("REVISION").map(\.relativePath) == ["A-101 Plan.pdf"])
        for old in first.entries {
            #expect(!FileManager.default.fileExists(atPath: FolderIndex.indexURL(sha256: old.sha256, root: fixture.index.root).path),
                    "the old revision's and the deleted file's indexes are gone")
        }
    }

    @Test("Forget deletes every index and the grant")
    func forgetDeletesEverything() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = await fixture.index.rebuild()
        #expect(fixture.index.folder != nil)
        fixture.index.revoke()
        #expect(fixture.index.folder == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.index.root.path))
        #expect(await fixture.index.rebuild() == nil, "nothing to index once forgotten")
        #expect(await fixture.index.search("elevation").isEmpty)
    }

    @Test("A hit opens its drawing through the drop opener and turns to its sheet once the drawing is on screen")
    func openAtHit() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let previousIndex = FolderIndexCommand.index
        FolderIndexCommand.index = fixture.index
        var opened: [URL] = []
        let previousOpener = ProjectWindowController.dropOpener
        ProjectWindowController.dropOpener = { opened.append(contentsOf: $0) }
        defer {
            FolderIndexCommand.index = previousIndex
            ProjectWindowController.dropOpener = previousOpener
            ProjectWindowController.pendingPagesOnOpen = [:]
        }
        let harness = try await Fix2Harness.make("A-301.pdf", pageCount: 3, calibrate: false)
        defer { harness.tearDown() }
        let file = harness.directory.appendingPathComponent("A-301.pdf")
        let hit = FolderIndex.Hit(fileURL: file, relativePath: "A-301.pdf", pageIndex: 2, pageLabel: "3", snippet: "")
        FolderIndexCommand.open(hit)
        #expect(opened == [file])
        #expect(ProjectWindowController.pendingPagesOnOpen[file.path] == 2)
        // The drawing arrives (the harness opened it without a URL; a real open has one).
        harness.document.fileURL = file
        harness.controller.applyPendingSessionViewport(for: harness.document)
        #expect(await AppTestSupport.wait { harness.core.document.currentPageID == harness.core.document.pages[2].id })
        #expect(ProjectWindowController.pendingPagesOnOpen.isEmpty)
    }

    @Test("File menu: Index, Search and Forget; Search opens the sheet over the window and finds the text; with nothing indexed it says so")
    func commandsAndSheet() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let bar = ZenitMenuBar.make()
        let file = try #require(bar.items.compactMap(\.submenu).first { $0.title == ZPDFCommandGroup.file.displayName })
        // In the File menu or its Indexed Drawings submenu (L-02 grouped the three under one row).
        func titles(_ menu: NSMenu) -> [String] { menu.items.flatMap { [$0.title] + ($0.submenu.map(titles) ?? []) } }
        let titles = titles(file)
        for command in [ZenitAppCommand.indexDrawingFolder, .searchDrawingFolder, .forgetDrawingFolder] {
            #expect(titles.contains(ZenitAppCommandTable.spec(for: command).title))
        }
        let harness = try await Fix2Harness.make("Folder search.pdf", calibrate: false)
        defer { harness.tearDown() }
        let previousIndex = FolderIndexCommand.index
        let previousPresenter = FolderIndexCommand.searchPresenter
        defer {
            FolderIndexCommand.index = previousIndex
            FolderIndexCommand.searchPresenter = previousPresenter
        }
        // Nothing indexed: refused in words.
        let empty = FolderIndex()
        empty.defaults = ZenitScratchDefaults()
        empty.root = fixture.root.appendingPathComponent("Empty", isDirectory: true)
        FolderIndexCommand.index = empty
        let refused = await ZenitModalPresenter.answeringAsync { _ in .button(0) } perform: {
            #expect(FolderIndexCommand.presentSearch(controller: harness.controller, document: harness.document) == nil)
        }
        #expect(refused.map(\.identifier) == [FolderIndexCommand.refusalIdentifier])

        FolderIndexCommand.index = fixture.index
        let report = try #require(await FolderIndexCommand.rebuild(document: harness.document, window: nil))
        #expect(report.indexed == 2)
        #expect(harness.core.document.warnings.contains { $0.id == FolderIndexCommand.noteID && $0.message.contains("Locked.pdf (locked with a password)") })
        var presented: FolderSearchModel?
        var dismissed = false
        FolderIndexCommand.searchPresenter = { model, _ in presented = model; return { dismissed = true } }
        let model = try #require(FolderIndexCommand.presentSearch(controller: harness.controller, document: harness.document))
        #expect(presented === model)
        model.query = "elevation"
        await model.search()
        #expect(model.results.map(\.relativePath) == ["Elevations/A-201.pdf"])
        // L-42: it read "2 hits in 1 drawings.".
        #expect(model.summary == "2 hits in 1 drawing.")
        model.onClose?()
        #expect(dismissed)
        // The default presenter hangs the sheet through the one modal door.
        FolderIndexCommand.searchPresenter = previousPresenter
        let recorded = await ZenitModalPresenter.answeringAsync { _ in .dismissed } perform: {
            let shown = FolderIndexCommand.presentSearch(controller: harness.controller, document: harness.document)
            shown?.onClose?()
        }
        #expect(recorded.contains { $0.identifier == FolderIndexCommand.searchSheetIdentifier })
        FolderIndexCommand.forget(document: harness.document, window: nil)
        #expect(fixture.index.folder == nil)
        #expect(harness.core.document.warnings.contains { $0.id == FolderIndexCommand.noteID && $0.title.hasPrefix("Forgot") })
    }
}
