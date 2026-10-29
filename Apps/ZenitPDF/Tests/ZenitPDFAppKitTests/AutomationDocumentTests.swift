import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// nl-automation: the per-sheet scale proposal (bug `ZenitPDFProjectDocument.swift:1118`) and
/// the printed room-area check (NL-AUTO-09), through the document and the window.
@MainActor
@Suite(.appTierSerialised)
struct AutomationDocumentTests {

    @Test("A cover sheet first: no offer on page 1, and page 2's own scale is offered when it is turned to")
    func scaleProposalFollowsTheSheet() async throws {
        let url = try AutomationFixtures.writePages(named: "Set with cover.pdf", mediaBox: "0 0 1191 842", contents: [
            "BT /F1 24 Tf 400 420 Td (PROJEKT EXEMPELVAGEN 12) Tj ET",
            "BT /F1 10 Tf 60 780 Td (DETALJ 3 SKALA 1:5) Tj ET BT /F1 10 Tf 950 40 Td (SKALA 1:50) Tj ET 1 w 100 100 m 500 100 l S"
        ])
        let document = try AppTestSupport.makeDocument(opening: url)
        defer { document.close() }
        #expect(await AppTestSupport.wait { document.core != nil })
        let core = try #require(document.core)
        try await Task.sleep(for: .milliseconds(500))
        // Old behaviour: page 0's text only — a cover sheet, so no proposal was ever made.
        #expect(!core.document.warnings.contains { $0.actionTitle?.hasPrefix("Apply 1:") == true })

        core.document.goToPage(index: 1)
        #expect(await AppTestSupport.wait(upTo: 20) {
            core.document.warnings.contains { $0.actionTitle == "Apply 1:50" }
        }, "page 2's title-block scale was never offered")
        // The detail's 1:5, read first, did not win: the title block's scale is the sheet's.
        #expect(!core.document.warnings.contains { $0.actionTitle == "Apply 1:5" })
        let warning = try #require(core.document.warnings.first { $0.actionTitle == "Apply 1:50" })
        #expect(document.holdsScaleProposal(warningID: warning.id))
        // The offer belongs to page 2: turning away takes it down.
        core.document.goToPage(index: 0)
        #expect(await AppTestSupport.wait { !core.document.warnings.contains { $0.id == warning.id } })
    }

    @Test("Check Against Drawn Dimensions warns when a room's printed area differs from its measured area")
    func printedAreaCheck() async throws {
        // Room 72…372 × 72…272 (6 m² at 100 pt/m) with "Rum 6,5 m²" printed inside it.
        let content = "1 w 0 0 0 RG 72 72 m 372 72 l 372 272 l 72 272 l h S BT /F1 10 Tf 180 170 Td (Rum 6,5 m2) Tj ET"
        let url = try AutomationFixtures.writeSinglePage(named: "Printed area.pdf", content: content)
        let document = try AppTestSupport.makeDocument(opening: url)
        defer { document.close() }
        #expect(await AppTestSupport.wait { document.core != nil && document.drawing != nil })
        let core = try #require(document.core)
        let controller = ProjectWindowController(document: document)
        document.addWindowController(controller)
        #expect(await AppTestSupport.wait { controller.canvasController(for: document) != nil })
        let pageID = try #require(await core.session.firstPageID)
        _ = try await core.commands.calibrate(
            page: pageID, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 1, knownLengthUnit: .metre
        )
        let canvas = try #require(controller.canvasController(for: document))
        document.shell?.perform(.measureArea)
        canvas.handleClick(at: PDFPointValue(x: 100, y: 100), additive: false, optionHeld: true)
        await canvas.settleAutoTrace()
        var landed = await core.session.orderedMarkups
        for _ in 0..<150 where landed.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
            landed = await core.session.orderedMarkups
        }
        #expect(landed.count == 1)

        controller.checkDrawnDimensions(for: document)
        #expect(await AppTestSupport.wait(upTo: 10) {
            core.document.warnings.contains { $0.id == ProjectWindowController.printedAreaWarningID }
        }, "a 6 m² room printed as 6,5 m² raised nothing")
        let warning = try #require(core.document.warnings.first { $0.id == ProjectWindowController.printedAreaWarningID })
        #expect(warning.message.contains("printed 6.5 m², measured 6 m²"), "\(warning.message)")
    }

    @Test("Reopening reads page geometry from disk, not from the extraction service; a changed drawing does not")
    func persistentExtractionStore() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "persist.pdf", pageCount: 3)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-geometry-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        let fetcher: AutomationExtractionStore.Fetcher = { url, page, password in
            try await AutomationExtractionStore.serviceFetcher(url, page, password)
        }
        let first = AutomationExtractionStore(fetcher: fetcher)
        first.persistent = PersistentExtractionStore(documentDigest: "abc123", root: root)
        for page in 0..<3 { _ = try await first.extraction(url: url, pageIndex: page, password: nil) }
        #expect(first.fetchCount == 3)
        let files = { (try? FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".zvx") }.count) ?? 0 }
        #expect(await AppTestSupport.wait { files() == 3 }, "the geometry was never written")

        // "Reopen": a fresh store over the same directory and drawing.
        let reopened = AutomationExtractionStore(fetcher: fetcher)
        reopened.persistent = PersistentExtractionStore(documentDigest: "abc123", root: root)
        for page in 0..<3 {
            let extraction = try await reopened.extraction(url: url, pageIndex: page, password: nil)
            #expect(!extraction.primitives.isEmpty)
        }
        // Old behaviour: every feature re-extracted over XPC (3 requests again).
        #expect(reopened.fetchCount == 0)

        // A changed drawing has another digest, and nothing stored for it is read.
        let changed = AutomationExtractionStore(fetcher: fetcher)
        changed.persistent = PersistentExtractionStore(documentDigest: "def456", root: root)
        _ = try await changed.extraction(url: url, pageIndex: 0, password: nil)
        #expect(changed.fetchCount == 1)
    }

    @Test("The byte budget removes the oldest entries first")
    func persistentBudget() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-geometry-budget-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (index, age) in [300.0, 200.0, 100.0].enumerated() {
            let file = root.appendingPathComponent("entry\(index).zvx")
            try Data(count: 1000).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: file.path)
        }
        PersistentExtractionStore(documentDigest: "x", root: root).enforceBudget(byteBudget: 2000)
        let left = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        #expect(left == ["entry1.zvx", "entry2.zvx"])
    }
}
