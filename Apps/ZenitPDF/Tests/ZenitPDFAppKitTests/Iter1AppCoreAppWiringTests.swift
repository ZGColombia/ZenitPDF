import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFGeometry
@testable import ZenitPDFAppKit

/// Quality loop iteration 1, appcore: the app half of K-01, R-055 and R-065.
@MainActor
@Suite("Iteration 1 appcore — app wiring", .appTierSerialised)
struct Iter1AppCoreAppWiringTests {

    // MARK: K-01

    /// A three-page fixture; page n strokes the rectangle from (72 + 20n, 72 + 20n) to (372, 272)
    /// (`AppTestSupport.writeFixturePDF`). On page 2 (n = 1) the bottom-right corner is (372, 92).
    /// Old output: no snap index for page 2 existed, `resolveSnap` threw `unknownPage`, and a click
    /// 3 pt from the corner stayed where it was.
    @Test("Turning to page 2 of an open drawing builds its snap index, and a corner snaps exactly")
    func vectorSnapOnPageTwo() async throws {
        let url = try AppTestSupport.writeFixturePDF(pageCount: 3)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try AppTestSupport.makeDocument(opening: url)
        defer { document.close() }
        #expect(await AppTestSupport.wait { document.core != nil && !document.isLoading })
        let core = try #require(document.core)
        let pages = await core.session.pageDescriptors
        #expect(pages.count == 3)
        #expect(await AppTestSupport.wait(upTo: 30) { document.firstPageSnapIndexResult != nil }, "the first sheet still builds at open")
        core.document.goToPage(id: pages[1].id.rawValue)
        var built = false
        for _ in 0..<1_500 where !built {
            built = await core.session.snapAvailability(page: pages[1].id) != nil
            if !built { try? await Task.sleep(for: .milliseconds(20)) }
        }
        #expect(built, "page 2's snap index was built on the page turn")
        let resolution = try await core.session.resolveSnap(
            pageID: pages[1].id, pagePoint: PDFPoint(x: 369, y: 95), layout: PageViewLayout(zoom: 1, backingScale: 2)
        )
        #expect(resolution.winner?.kind == .endpoint)
        #expect(Swift.abs(resolution.resolvedPagePoint.x - 372) < 1e-9)
        #expect(Swift.abs(resolution.resolvedPagePoint.y - 92) < 1e-9)
        #expect(await AppTestSupport.wait { core.canvas.isVectorSnapAvailable })
        await document.shutDownStorage()
    }

    // MARK: R-055

    @Test("Import Table is one batch: its columns first, then its rows")
    func tableImportIsOneBatch() {
        let column = LedgerColumnDefinition(id: ColumnID(UUID()), key: "custom.room", title: "Room", kind: .text)
        let page = PageID(UUID())
        let row = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: DocumentID(UUID()), pageID: page, kind: .text, subject: "D1",
            geometry: MeasurementGeometry(pageID: page, points: [PDFPoint(x: 0, y: 0)]),
            createdAt: Date(timeIntervalSince1970: 0), modifiedAt: Date(timeIntervalSince1970: 0)
        )
        let landing = ProjectWindowController.TableImportLanding(definitions: [column], records: [row], keptAsText: [])
        let commands = ProjectWindowController.tableImportCommands(landing)
        #expect(commands.count == 2)
        guard case .addCustomColumns(let added) = commands.first, case .addMarkup(let landed) = commands.last else {
            Issue.record("expected the columns, then the row: \(commands)")
            return
        }
        #expect(added == [column])
        #expect(landed.id == row.id)
        // No columns, no column command.
        let rowsOnly = ProjectWindowController.tableImportCommands(.init(definitions: [], records: [row], keptAsText: []))
        #expect(rowsOnly.count == 1)
    }

    // MARK: R-065

    private struct State: ZenitAppCommandState {
        var hasActiveDocument = true
        var isQuickPDF = false
        var hasDrawing = true
        var hasSearchIndex = true
        var hasLoadedCore = true
        var hasPagesAndStampPreset = true
        var hasMarkupSelection = true
        var hasGroupedMarkupSelection = false
        var selectionIsLocked = false
        var hasHiddenMarkups = false
        var tabCount = 1
        var isSaveActivityBusy = false
        var isBatchProcessing = false
    }

    /// Old output: Ungroup (⇧⌘G) was enabled for any selection and did nothing on an ungrouped one.
    @Test("Ungroup is enabled only for a selection that touches a group; Group stays enabled")
    func ungroupNeedsAGroup() {
        var state = State()
        #expect(!ZenitAppCommandTable.validate(.ungroupMarkups, item: nil, state: state))
        #expect(ZenitAppCommandTable.validate(.groupMarkups, item: nil, state: state))
        state.hasGroupedMarkupSelection = true
        #expect(ZenitAppCommandTable.validate(.ungroupMarkups, item: nil, state: state))
        state.hasMarkupSelection = false
        state.hasGroupedMarkupSelection = false
        #expect(!ZenitAppCommandTable.validate(.ungroupMarkups, item: nil, state: state))
    }
}
