import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFPDFKitBridge
import ZPDFTestingSupport
import ZPDFUIPresentation
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// NL-DOCS-09 (links land where they point, ⌘[ / ⌘] history, hover tooltip) and NL-DOCS-06
/// (a bookmark keeps the axis its destination leaves open). Headless.
@MainActor
@Suite("Documents — places on the sheet", .appTierSerialised)
struct NextLevelDocumentsNavigationTests {

    private func setHarness() async throws -> (Fix2Harness, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nl-docs-nav-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = try ZPDFFixtures.make(.set30SheetsTitleBlocks, in: directory)
        let harness = try await Fix2Harness.make("Nav.pdf", calibrate: false, fixture: fixture.url)
        return (harness, directory)
    }

    private func key(_ characters: String) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0,
            context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0
        )!
    }

    @Test("A sheet link lands on its top; ⌘[ returns to the sheet and viewport it left; ⌘] goes again")
    func linkAndHistory() async throws {
        let (harness, directory) = try await setHarness()
        defer {
            harness.tearDown()
            try? FileManager.default.removeItem(at: directory)
        }
        let canvas = harness.canvas
        harness.core.canvas.setZoom(1)
        await harness.settle()
        let start = try #require(canvas.currentPlace())
        let s201 = harness.core.document.pages[10].id

        // A link to S-201 with only a top: the left stays where the reader was.
        harness.controller.follow(.page(10), left: nil, top: 900, shell: harness.shell, document: harness.document)
        #expect(await AppTestSupport.wait { canvas.currentPlace()?.pageID == s201 && abs((canvas.currentPlace()?.top ?? 0) - 900) < 1 },
                "lands with 900 pt at the top")
        #expect(!harness.document.navigationHistory.back.isEmpty)

        #expect(canvas.handleNavigationKey(key("[")), "⌘[ is the canvas's")
        #expect(await AppTestSupport.wait {
            canvas.currentPlace()?.pageID == start.pageID && abs((canvas.currentPlace()?.top ?? 0) - (start.top ?? 0)) < 1
        })
        let back = try #require(canvas.currentPlace())
        #expect(abs((back.top ?? 0) - (start.top ?? 0)) < 1, "the viewport it left, not the page top: \(back) vs \(start)")
        #expect(canvas.handleNavigationKey(key("]")))
        #expect(await AppTestSupport.wait { canvas.currentPlace()?.pageID == s201 })
        #expect(!canvas.handleNavigationKey(key("x")))
    }

    @Test("A link says where it goes on hover; a script link says it will not run")
    func hoverDescription() async throws {
        let (harness, directory) = try await setHarness()
        defer {
            harness.tearDown()
            try? FileManager.default.removeItem(at: directory)
        }
        #expect(ProjectWindowController.linkDescription(.page(10), shell: harness.shell, document: harness.document) == "Go to S-201")
        #expect(ProjectWindowController.linkDescription(.uri("https://example.invalid"), shell: harness.shell, document: harness.document)
            == "https://example.invalid")
        #expect(ProjectWindowController.linkDescription(.script, shell: harness.shell, document: harness.document).contains("will not run"))
    }

    @Test("A bookmark with /XYZ null 612 keeps the horizontal position and lands 612 at the top")
    func bookmarkKeepsOpenAxis() async throws {
        let (harness, directory) = try await setHarness()
        defer {
            harness.tearDown()
            try? FileManager.default.removeItem(at: directory)
        }
        let pages = harness.core.document.pages
        let outline = DocumentOutline(roots: [
            OutlineNode(
                id: OutlinePath([0]), label: "A-105 DETAIL",
                destination: DestinationTarget(pageIndex: 4, pageLabel: "A-105", left: nil, top: 612, zoom: nil),
                isOpen: false, children: []
            )
        ], wasTruncated: false, nodeCount: 1)
        let marks = DocumentSessionLoader.bookmarks(from: outline, pageIDs: [4: pages[4].id])
        let mark = try #require(marks.first)
        #expect(mark.left == nil && mark.top == 612 && mark.pageID == pages[4].id)

        harness.core.canvas.setZoom(1)
        await harness.settle()
        let before = try #require(harness.canvas.currentPlace())
        let open = try #require(harness.shell.onOpenBookmark, "the window wires bookmark opening")
        open(mark)
        #expect(await AppTestSupport.wait {
            harness.canvas.currentPlace()?.pageID == pages[4].id && abs((harness.canvas.currentPlace()?.top ?? 0) - 612) < 1
        })
        #expect(abs((harness.canvas.currentPlace()?.left ?? -1) - (before.left ?? 0)) < 1, "the horizontal position is kept")
        #expect(!harness.document.navigationHistory.back.isEmpty, "a bookmark is a jump ⌘[ undoes")
    }
}
