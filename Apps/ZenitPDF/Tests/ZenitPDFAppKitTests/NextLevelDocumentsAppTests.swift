import AppKit
import CoreGraphics
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFPersistence
import ZPDFTestingSupport
import ZPDFPDFKitBridge
import ZPDFUIPresentation
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// Documents, app tier: the honest Navigator drop (bug 2 / NL-DOCS-03), revisions
/// kept with the project and paired by sheet number (bug 7), and arranging the set (NL-DOCS-07).
/// Headless: windows are built, never shown; the drop opener is injected.
@MainActor
@Suite("Documents — app tier", .appTierSerialised)
struct NextLevelDocumentsAppTests {

    private func save(_ document: ZenitPDFProjectDocument, to url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            document.save(to: url, ofType: ZenitAppInfo.projectTypeIdentifier, for: .saveAsOperation) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    // MARK: Bug 7 — pairing

    /// Old output: page index `current` clamped, whatever the labels said — on a revision with
    /// A-100 inserted first, sheet A-102 (index 1) was overlaid on A-101.
    @Test("A revision page pairs by sheet number, and a contradicting position is flagged")
    func pairsBySheetNumber() {
        let revision = ["A-100", "A-101", "A-102", "A-103"]
        #expect(ZenitPDFProjectDocument.pairRevisionPage(
            currentIndex: 1, baselineLabel: "A-102", revisionLabels: revision, revisionPageCount: 4
        ) == .label(2))
        // The sheet is gone from the revision: position, and said.
        #expect(ZenitPDFProjectDocument.pairRevisionPage(
            currentIndex: 3, baselineLabel: "A-199", revisionLabels: revision, revisionPageCount: 4
        ) == .mismatch(3))
        // Bare numbers are no evidence: position, clamped.
        #expect(ZenitPDFProjectDocument.pairRevisionPage(
            currentIndex: 7, baselineLabel: "8", revisionLabels: ["1", "2"], revisionPageCount: 2
        ) == .position(1))
        #expect(ZenitPDFProjectDocument.pairRevisionPage(
            currentIndex: 0, baselineLabel: "a-101 ", revisionLabels: revision, revisionPageCount: 4
        ) == .label(1), "case and trailing space do not hide a sheet")
    }

    @Test("Stored pairings name their evidence: label, position or added")
    func storedPairings() {
        let set = [(id: "p1", label: "A-101"), (id: "p2", label: "A-102")]
        let pairs = ZenitPDFProjectDocument.sheetPairings(revisionLabels: ["A-100", "A-102", "A-101"], setPages: set)
        #expect(pairs.map(\.pageId) == [nil, "p2", "p1"])
        #expect(pairs.map(\.evidence) == ["added", "label", "label"])
        let unlabelled = ZenitPDFProjectDocument.sheetPairings(revisionLabels: ["1", "2", "3"], setPages: set)
        #expect(unlabelled.map(\.evidence) == ["position", "position", "added"])
    }

    // MARK: NL-DOCS-07 — arranging

    @Test("A block move becomes the fewest reorder steps, left to right")
    func reorderCommands() {
        let ids = (0..<5).map { _ in PageID(UUID()) }
        let commands = ZenitPDFProjectDocument.reorderCommands(from: ids, moving: [ids[1], ids[3]], to: 0)
        var order = ids
        for case let .reorderPage(from, to) in commands { order.insert(order.remove(at: from), at: to) }
        #expect(order == [ids[1], ids[3], ids[0], ids[2], ids[4]])
        #expect(commands.count == 2)
        #expect(ZenitPDFProjectDocument.reorderCommands(from: ids, moving: [ids[0]], to: 0).isEmpty)
    }

    @Test("Moving pages through the Navigator hook is one undo step and keeps each sheet's PDF page")
    func moveThroughHook() async throws {
        let harness = try await Fix2Harness.make("Arrange.pdf", pageCount: 3, calibrate: false)
        defer { harness.tearDown() }
        let move = try #require(harness.shell.onMovePages, "the window wires the arrange hook")
        let before = harness.core.document.pages
        #expect(before.count == 3)
        move([before[2].id], 0)
        #expect(await AppTestSupport.wait { harness.core.document.pages.first?.id == before[2].id })
        #expect(harness.core.document.pages.map(\.index) == [2, 0, 1], "each sheet keeps its PDF page")
        await harness.core.commands.undo()
        await harness.core.refresh()
        #expect(harness.core.document.pages.map(\.id) == before.map(\.id))
    }

    // MARK: Bug 2 — the honest drop
    //
    // Superseded in round 2 by NL-DOCS-04: a PDF dropped on a project's Navigator now joins the
    // project at the drop line (`NextLevelDocumentsMultiDrawingTests.dropJoinsProject`).

    // MARK: Bug 7 — persistence

    /// Old behaviour: "A dropped revision lives in this session only; nothing is persisted" —
    /// reopening the project had one revision (the drawing) and the dropped one was gone.
    @Test("A dropped revision is kept in the project and comes back on reopen")
    func revisionSurvivesReopen() async throws {
        let harness = try await Fix2Harness.make("Keep A-201.pdf", calibrate: false)
        let package = harness.directory.appendingPathComponent("Keep.zpdfproj")
        try await save(harness.document, to: package)
        let revision = try AppTestSupport.writeFixturePDF(named: "Keep A-201 Rev B.pdf")
        defer { try? FileManager.default.removeItem(at: revision.deletingLastPathComponent()) }
        var added = false
        harness.document.addRevision(fromDroppedFile: revision) { added = $0 }
        #expect(await AppTestSupport.wait(upTo: 30) { added })
        #expect(await AppTestSupport.wait { !harness.document.persistedRevisionIDs.isEmpty }, "the revision was not stored")
        #expect(harness.document.revisionPageLabels.count == 1)
        try await save(harness.document, to: package)
        harness.controller.window?.close()
        harness.document.close()

        let reopened = ZenitPDFProjectDocument()
        try reopened.read(from: package, ofType: ZenitAppInfo.projectTypeIdentifier)
        reopened.startLoadingIfNeeded()
        defer {
            reopened.close()
            try? FileManager.default.removeItem(at: harness.directory)
        }
        #expect(await AppTestSupport.wait { reopened.core != nil })
        #expect(await AppTestSupport.wait(upTo: 30) { (reopened.comparePresenter?.revisions.count ?? 0) == 2 },
                "baseline plus the kept revision")
        #expect(reopened.comparePresenter?.revisions.contains { $0.revisionLabel == "Keep A-201 Rev B" } == true)
        #expect(!reopened.isDocumentEdited, "restoring does not store twice or mark the project edited")
    }

    // MARK: NL-DOCS-06 — bookmarks

    @Test("The drawing's bookmarks resolve to page identities; one pointing nowhere keeps its title")
    func bookmarksResolve() {
        let first = UUID(), second = UUID()
        let outline: [String: Any] = [
            kCGPDFOutlineChildren as String: [
                [
                    kCGPDFOutlineTitle as String: "ARCHITECTURAL",
                    kCGPDFOutlineDestination as String: 1,
                    kCGPDFOutlineChildren as String: [
                        [kCGPDFOutlineTitle as String: "A-101 SITE PLAN", kCGPDFOutlineDestination as String: 1],
                        [kCGPDFOutlineTitle as String: "A-102 FLOOR", kCGPDFOutlineDestination as String: 2]
                    ]
                ],
                [kCGPDFOutlineTitle as String: "Gone", kCGPDFOutlineDestination as String: 9],
                [kCGPDFOutlineTitle as String: "   "]
            ]
        ]
        let bookmarks = DocumentSessionLoader.bookmarks(from: outline, pageIDs: [0: first, 1: second])
        #expect(bookmarks.map(\.title) == ["ARCHITECTURAL", "Gone"])
        #expect(bookmarks[0].children.map(\.pageID) == [first, second])
        #expect(bookmarks[1].pageID == nil)
        #expect(bookmarks[0].children[1].id == "0.1")
    }

    @Test("Moving a tab reorders the window's documents, clamped")
    func tabOrder() {
        let ids = (0..<4).map { _ in UUID() }
        #expect(ProjectWindowController.reordered(ids, moving: ids[3], to: 0) == [ids[3], ids[0], ids[1], ids[2]])
        #expect(ProjectWindowController.reordered(ids, moving: ids[0], to: 99) == [ids[1], ids[2], ids[3], ids[0]])
        #expect(ProjectWindowController.reordered(ids, moving: UUID(), to: 1) == ids)
    }

    // MARK: NL-DOCS-08 — extract pages

    @Test("Extract writes the chosen sheets, in order, with their labels; the drawing is untouched")
    func extractPages() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nl-docs-extract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try ZPDFFixtures.make(.set30SheetsTitleBlocks, in: directory)
        let before = try Data(contentsOf: fixture.url)

        let document = ZenitPDFProjectDocument()
        let destination = directory.appendingPathComponent("extract.pdf")
        let receipt = try #require(await document.writeExtract(indices: [10, 0, 1], from: fixture.url, password: nil, to: destination))
        #expect(receipt.pageCount == 3)
        #expect(receipt.sourceIsUnchanged)
        #expect(try Data(contentsOf: fixture.url) == before)
        let reader = PDFKitDocumentProvider(thumbnailCacheCapacity: 0)
        let opened = try await reader.open(fileAt: destination)
        #expect(try await reader.pageLabels(of: opened.handle).allLabels() == ["S-201", "A-101", "A-102"])
        await reader.close(opened.handle)
        #expect(ZenitPDFProjectDocument.pdfIndices(of: [], in: []) == [])
    }

    // MARK: NL-DOCS-09 — the drawing's own links

    @Test("The smallest link under the point wins; only web and mail addresses are openable")
    func linkHitTest() {
        let big = DrawingLink(bounds: CGRect(x: 0, y: 0, width: 100, height: 100), target: .page(3))
        let small = DrawingLink(bounds: CGRect(x: 40, y: 40, width: 10, height: 10), target: .page(7))
        #expect(DrawingLink.hit(CGPoint(x: 45, y: 45), in: [big, small])?.target == .page(7))
        #expect(DrawingLink.hit(CGPoint(x: 5, y: 5), in: [big, small])?.target == .page(3))
        #expect(DrawingLink.hit(CGPoint(x: 500, y: 5), in: [big, small]) == nil)
        #expect(DrawingLink.isOpenableAddress("https://example.invalid/spec"))
        #expect(!DrawingLink.isOpenableAddress("file:///etc/passwd"))
        #expect(!DrawingLink.isOpenableAddress("javascript:alert(1)"))
    }

    /// Before: the canvas is Zenit's own renderer and a click on a drawing's link did nothing.
    @Test("A click on a sheet link turns to that sheet; a web link asks first; a script is never run")
    func followLinks() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nl-docs-links-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = try ZPDFFixtures.make(.set30SheetsTitleBlocks, in: directory)
        let harness = try await Fix2Harness.make("links", calibrate: false, fixture: fixture.url)
        defer { harness.tearDown() }
        ZenitModalPresenter.reset()
        defer { ZenitModalPresenter.reset() }

        let source = try #require(harness.document.drawing?.rasterSource)
        let links = try await source.links(pageIndex: 0)
        #expect(links.count == 3, "SEE S-201 (GoTo), 3/A-102 (named), SPECIFICATION (URI)")
        #expect(await source.namedDestinationPage("A-105") == 4)

        // Click inside "SEE S-201" on A-101 (text at 200, 2200): sheet S-201 is page index 10.
        #expect(harness.core.document.currentPage?.index == 0)
        harness.canvas.handleClick(at: PDFPointValue(x: 210, y: 2205), additive: false)
        #expect(await AppTestSupport.wait { harness.core.document.currentPage?.index == 10 }, "the sheet link did not turn the page")

        ZenitModalPresenter.handler = { _ in .button(1) }   // Cancel
        harness.controller.follow(.uri("https://example.invalid/specification"), shell: harness.shell, document: harness.document)
        #expect(ZenitModalPresenter.didRequest(ProjectWindowController.openLinkAlertIdentifier))
        harness.controller.follow(.script, shell: harness.shell, document: harness.document)
        #expect(harness.core.status.snapshot.activeToolNote?.contains("never runs") == true)
    }
}
