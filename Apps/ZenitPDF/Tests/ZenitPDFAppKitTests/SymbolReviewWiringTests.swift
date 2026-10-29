import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
import ZPDFUIWorkflows
@testable import ZenitPDFAppKit

/// NL-AUTO-02 / 05 / 06 through the window, prompt- and sheet-injected: the review lists
/// matches, near misses and already-counted places; accepting lands one count markup per page in
/// one undo; the tag beside the symbol is offered as its designation; hidden layers never match.
@MainActor
@Suite(.appTierSerialised)
struct SymbolReviewWiringTests {

    /// A door symbol's three strokes at (x, y): leaf 20, jamb 12, stop `stop`.
    static func door(_ x: Double, _ y: Double, stop: Double = 6) -> String {
        "\(x) \(y) m \(x + 20) \(y) l S \(x) \(y) m \(x) \(y + 12) l S \(x + 20) \(y) m \(x + 20) \(y + stop) l S"
    }

    /// Six doors, one drawn with a 12 stop (a near miss), a tag "D-12" beside the first, 30 stray strokes.
    static func doorSheet() -> String {
        var lines = ["1 w 0 0 0 RG"]
        for (x, y) in [(100.0, 100.0), (200, 100), (300, 100), (100, 300), (200, 300), (300, 300)] {
            lines.append(door(x, y))
        }
        lines.append(door(400, 200, stop: 12))
        for index in 0..<30 {
            let x = 50.0 + Double(index) * 12
            lines.append("\(x) 600 m \(x + 3) 605 l S")
        }
        lines.append("BT /F1 8 Tf 126 104 Td (D-12) Tj ET")
        return lines.joined(separator: "\n")
    }

    private struct Harness {
        let document: ZenitPDFProjectDocument
        let controller: ProjectWindowController
        let canvas: PDFCanvasViewController
        let core: AppCoreEnvironment

        @MainActor
        func tearDown() {
            document.close()
        }
    }

    private func open(_ url: URL) async throws -> Harness {
        let document = try AppTestSupport.makeDocument(opening: url)
        #expect(await AppTestSupport.wait { document.core != nil && document.drawing != nil })
        let core = try #require(document.core)
        let controller = ProjectWindowController(document: document)
        document.addWindowController(controller)
        #expect(await AppTestSupport.wait { controller.canvasController(for: document) != nil })
        let canvas = try #require(controller.canvasController(for: document))
        return Harness(document: document, controller: controller, canvas: canvas, core: core)
    }

    /// Installs the prompt and a presenter that captures the model; returns the capture box.
    @MainActor final class Capture {
        var model: SymbolCountReviewModel?
        var suggestion: String??
        var dismissed = false
    }

    private func inject(designation: String, scope: SymbolSearchScope, capture: Capture) {
        ProjectWindowController.symbolSearchPrompt = { _, suggestion in
            capture.suggestion = .some(suggestion)
            return SymbolSearchRequest(designation: designation, scope: scope)
        }
        ProjectWindowController.symbolReviewPresenter = { model, _ in
            capture.model = model
            return { capture.dismissed = true }
        }
    }

    private func runReview(_ harness: Harness, box: PDFRectValue, capture: Capture) async throws -> SymbolCountReviewModel {
        harness.controller.beginSymbolSchedule(for: harness.document)
        harness.canvas.onSnippetRegion?(box)
        #expect(await AppTestSupport.wait { capture.model != nil }, "the review never opened")
        let model = try #require(capture.model)
        #expect(await AppTestSupport.wait { !model.isSearching }, "the search never finished")
        return model
    }

    private func countMarkups(_ core: AppCoreEnvironment, subject: String) async -> [MarkupRecord] {
        await core.session.orderedMarkups.filter { $0.tool == .count && $0.subject == subject }
    }

    @Test("Six doors and one off: six ticked, one near miss unticked; unticking one lands five")
    func reviewThenAccept() async throws {
        let previousPrompt = ProjectWindowController.symbolSearchPrompt
        let previousPresenter = ProjectWindowController.symbolReviewPresenter
        defer {
            ProjectWindowController.symbolSearchPrompt = previousPrompt
            ProjectWindowController.symbolReviewPresenter = previousPresenter
        }
        let harness = try await open(try AutomationFixtures.writeSinglePage(named: "Doors.pdf", content: Self.doorSheet()))
        defer { harness.tearDown() }
        let capture = Capture()
        inject(designation: "D-12", scope: .thisPage, capture: capture)

        let model = try await runReview(harness, box: PDFRectValue(x: 95, y: 95, width: 30, height: 22), capture: capture)
        // Nothing lands before the person accepts.
        #expect(await countMarkups(harness.core, subject: "D-12").isEmpty)
        #expect(model.confirmedCount == 6, "\(model.rows.map(\.status))")
        #expect(model.nearMissCount == 1)
        #expect(model.selectedRowIDs.count == 6)
        // The strays are a number in the summary, not a warning.
        #expect(model.summaryText.contains("6 confirmed, 1 near miss shown"), "V-068: it read \"1 near miss(es)\"")
        #expect(!harness.core.document.warnings.contains { $0.id == ProjectWindowController.symbolScheduleWarningID })
        // The canvas marks what was found: six hits, one dashed near miss.
        let overlay = try #require(harness.canvas.automationOverlayForTesting)
        #expect(overlay.hits.count == 6 && overlay.nearMisses.count == 1)
        // The tag beside the boxed door was offered as the designation (NL-AUTO-06).
        #expect(capture.suggestion == .some("D-12"))

        let confirmed = model.rows.filter { $0.status == .confirmed }
        model.toggle(try #require(confirmed.last))
        model.accept()
        #expect(capture.dismissed)
        #expect(await AppTestSupport.wait { harness.canvas.automationOverlayForTesting == nil })
        var landed: [MarkupRecord] = []
        for _ in 0..<100 {
            landed = await countMarkups(harness.core, subject: "D-12")
            if !landed.isEmpty { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(landed.count == 1)
        #expect(landed.first?.geometry?.countPoints.count == 5)
    }

    @Test("Rerunning D-12 on the same page lands nothing new and says why")
    func rerunDoesNotDoubleCount() async throws {
        let previousPrompt = ProjectWindowController.symbolSearchPrompt
        let previousPresenter = ProjectWindowController.symbolReviewPresenter
        defer {
            ProjectWindowController.symbolSearchPrompt = previousPrompt
            ProjectWindowController.symbolReviewPresenter = previousPresenter
        }
        let harness = try await open(try AutomationFixtures.writeSinglePage(named: "Doors.pdf", content: Self.doorSheet()))
        defer { harness.tearDown() }
        let first = Capture()
        inject(designation: "D-12", scope: .thisPage, capture: first)
        let model = try await runReview(harness, box: PDFRectValue(x: 95, y: 95, width: 30, height: 22), capture: first)
        model.accept()
        var landed: [MarkupRecord] = []
        for _ in 0..<100 {
            landed = await countMarkups(harness.core, subject: "D-12")
            if !landed.isEmpty { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(landed.first?.geometry?.countPoints.count == 6)

        // Old output: a second count markup with the same six points.
        let second = Capture()
        inject(designation: "D-12", scope: .thisPage, capture: second)
        let rerun = try await runReview(harness, box: PDFRectValue(x: 95, y: 95, width: 30, height: 22), capture: second)
        #expect(rerun.confirmedCount == 0)
        #expect(rerun.alreadyCountedCount == 6)
        #expect(rerun.selectedRowIDs.isEmpty)
        #expect(!rerun.canAccept)
        #expect(rerun.summaryText.contains("Already counted: 6"))
        rerun.cancel()
        #expect(await countMarkups(harness.core, subject: "D-12").count == 1)
    }

    @Test("Across the set: per-page results, one count markup per page, one undo takes both back")
    func setWideCount() async throws {
        let previousPrompt = ProjectWindowController.symbolSearchPrompt
        let previousPresenter = ProjectWindowController.symbolReviewPresenter
        defer {
            ProjectWindowController.symbolSearchPrompt = previousPrompt
            ProjectWindowController.symbolReviewPresenter = previousPresenter
        }
        // Page 1: two doors. Page 2: none. Page 3: three doors.
        let url = try AutomationFixtures.writePages(named: "Set.pdf", contents: [
            "1 w " + Self.door(100, 100) + " " + Self.door(300, 100),
            "1 w 50 50 m 60 50 l S",
            "1 w " + Self.door(100, 400) + " " + Self.door(200, 400) + " " + Self.door(300, 400)
        ])
        let harness = try await open(url)
        defer { harness.tearDown() }
        let capture = Capture()
        inject(designation: "D-12", scope: .allPages, capture: capture)
        let model = try await runReview(harness, box: PDFRectValue(x: 95, y: 95, width: 30, height: 22), capture: capture)
        #expect(model.pages.map(\.pageIndex) == [0, 1, 2])
        #expect(model.rows.filter { $0.pageIndex == 0 }.count == 2)
        #expect(model.rows.filter { $0.pageIndex == 1 }.isEmpty)
        #expect(model.rows.filter { $0.pageIndex == 2 }.count == 3)
        model.accept()

        var landed: [MarkupRecord] = []
        for _ in 0..<100 {
            landed = await countMarkups(harness.core, subject: "D-12")
            if landed.count == 2 { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(landed.count == 2, "one count markup per page")
        #expect(Set(landed.map { $0.geometry?.countPoints.count ?? 0 }) == [2, 3])

        // One ⌘Z takes the whole batch back.
        harness.document.undoManager?.undo()
        var afterUndo: [MarkupRecord] = landed
        for _ in 0..<100 {
            afterUndo = await countMarkups(harness.core, subject: "D-12")
            if afterUndo.isEmpty { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(afterUndo.isEmpty)
    }

    @Test("Stopping or cancelling a set-wide search leaves nothing committed")
    func cancelCommitsNothing() async throws {
        let previousPrompt = ProjectWindowController.symbolSearchPrompt
        let previousPresenter = ProjectWindowController.symbolReviewPresenter
        defer {
            ProjectWindowController.symbolSearchPrompt = previousPrompt
            ProjectWindowController.symbolReviewPresenter = previousPresenter
        }
        let url = try AutomationFixtures.writePages(named: "Set.pdf", contents: Array(repeating: "1 w " + Self.door(100, 100), count: 6))
        let harness = try await open(url)
        defer { harness.tearDown() }
        let capture = Capture()
        inject(designation: "D-12", scope: .allPages, capture: capture)
        harness.controller.beginSymbolSchedule(for: harness.document)
        harness.canvas.onSnippetRegion?(PDFRectValue(x: 95, y: 95, width: 30, height: 22))
        #expect(await AppTestSupport.wait { capture.model != nil })
        let model = try #require(capture.model)
        model.cancel()
        #expect(capture.dismissed)
        try await Task.sleep(for: .milliseconds(300))
        #expect(await countMarkups(harness.core, subject: "D-12").isEmpty)
    }

    @Test("A door on a hidden layer is not matched, and the held page is not extracted again")
    func hiddenLayerAndNoReExtraction() async throws {
        let previousPrompt = ProjectWindowController.symbolSearchPrompt
        let previousPresenter = ProjectWindowController.symbolReviewPresenter
        defer {
            ProjectWindowController.symbolSearchPrompt = previousPrompt
            ProjectWindowController.symbolReviewPresenter = previousPresenter
        }
        let content = """
        1 w /OC /A BDC \(Self.door(100, 100)) \(Self.door(200, 100)) EMC
        /OC /H BDC \(Self.door(300, 100)) EMC
        """
        let url = try AutomationFixtures.writePDF(
            named: "Layered Doors.pdf",
            objects: [
                "<< /Type /Catalog /Pages 2 0 R /OCProperties << /OCGs [5 0 R 6 0 R] /D << /ON [5 0 R 6 0 R] >> >> >>",
                "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R /Resources << /Properties << /A 5 0 R /H 6 0 R >> >> >>",
                "",
                "<< /Type /OCG /Name (Doors) >>",
                "<< /Type /OCG /Name (Demolished) >>"
            ],
            streams: [4: content]
        )
        let harness = try await open(url)
        defer { harness.tearDown() }
        let layers = harness.document.layerVisibility
        #expect(await AppTestSupport.wait { layers.items.count == 2 })
        layers.setVisible(false, layerID: try #require(layers.items.first { $0.name == "Demolished" }).id)
        let capture = Capture()
        inject(designation: "D-12", scope: .thisPage, capture: capture)
        let model = try await runReview(harness, box: PDFRectValue(x: 95, y: 95, width: 30, height: 22), capture: capture)
        // Old output: 3 — the extraction took the document default and ignored the person's toggle.
        #expect(model.confirmedCount == 2, "\(model.rows.map(\.status))")
        model.cancel()
    }

    @Test("On a drawing without layers the page the canvas holds is reused: no second extraction")
    func heldExtractionIsReused() async throws {
        let previousPrompt = ProjectWindowController.symbolSearchPrompt
        let previousPresenter = ProjectWindowController.symbolReviewPresenter
        defer {
            ProjectWindowController.symbolSearchPrompt = previousPrompt
            ProjectWindowController.symbolReviewPresenter = previousPresenter
        }
        let url = try AutomationFixtures.writeSinglePage(named: "Doors.pdf", content: Self.doorSheet())
        let harness = try await open(url)
        defer { harness.tearDown() }
        // The canvas holds page 1's extraction, the way the document hands it over after open.
        let page = try #require(harness.document.drawing?.pages.first)
        let loaded = await DocumentSessionLoader.buildSnapIndex(for: page, documentURL: url, session: harness.core.session)
        harness.canvas.prepareVectorUnderlay(page: page, extraction: try #require(loaded.extraction))
        let capture = Capture()
        inject(designation: "D-12", scope: .thisPage, capture: capture)
        let model = try await runReview(harness, box: PDFRectValue(x: 95, y: 95, width: 30, height: 22), capture: capture)
        #expect(model.confirmedCount == 6)
        // Old behaviour: one more XPC extraction of the page the canvas already had.
        #expect(harness.document.automation.extractions.fetchCount == 0)
        model.cancel()
    }

    @Test("Two types boxed in one run: every place both match is contested, and picking one counts it once")
    func multiTypeContested() async throws {
        let previousPrompt = ProjectWindowController.symbolSearchPrompt
        let previousPresenter = ProjectWindowController.symbolReviewPresenter
        defer {
            ProjectWindowController.symbolSearchPrompt = previousPrompt
            ProjectWindowController.symbolReviewPresenter = previousPresenter
        }
        let harness = try await open(try AutomationFixtures.writeSinglePage(named: "Doors.pdf", content: Self.doorSheet()))
        defer { harness.tearDown() }
        var answers = [
            SymbolSearchRequest(designation: "D-12", scope: .thisPage, addAnotherType: true),
            SymbolSearchRequest(designation: "D-13", scope: .thisPage)
        ]
        ProjectWindowController.symbolSearchPrompt = { _, _ in answers.isEmpty ? nil : answers.removeFirst() }
        var captured: SymbolCountReviewModel?
        ProjectWindowController.symbolReviewPresenter = { model, _ in
            captured = model
            return {}
        }
        harness.controller.beginSymbolSchedule(for: harness.document)
        harness.canvas.onSnippetRegion?(PDFRectValue(x: 95, y: 95, width: 30, height: 22))
        // The second box, once the first type is named.
        #expect(await AppTestSupport.wait { answers.count == 1 })
        #expect(await AppTestSupport.wait { (harness.core.status.snapshot.activeToolNote ?? "").contains("1 type(s) boxed") })
        harness.canvas.onSnippetRegion?(PDFRectValue(x: 195, y: 95, width: 30, height: 22))
        #expect(await AppTestSupport.wait { captured != nil && captured?.isSearching == false })
        let model = try #require(captured)
        // Six doors, each claimed by both types; the off door is a near miss for both and not listed.
        #expect(model.rows.count == 12, "\(model.rows.map { "\($0.designation ?? "-") \($0.status)" })")
        #expect(model.rows.allSatisfy { $0.exclusiveGroup != nil })
        #expect(model.selectedRowIDs.isEmpty, "a contested place must not start ticked")
        #expect(model.summaryText.contains("6 places match more than one type; 6 still need a pick."), "V-068: it read \"6 place(s)\"")
        for row in model.rows where row.designation == "D-12" { model.setSelected(true, for: row) }
        // Old behaviour: two single-type runs landed both D-12 and D-13 at the same six places.
        #expect(model.selectedRowIDs.count == 6)
        model.accept()
        var landed: [MarkupRecord] = []
        for _ in 0..<100 {
            landed = await harness.core.session.orderedMarkups.filter { $0.tool == .count }
            if !landed.isEmpty { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(landed.count == 1)
        #expect(landed.first?.subject == "D-12")
        #expect(landed.first?.geometry?.countPoints.count == 6)
    }

    @Test("A door Form XObject drawn on two pages: every drawing is an exact block, on both pages")
    func exactBlocksAcrossPages() async throws {
        let previousPrompt = ProjectWindowController.symbolSearchPrompt
        let previousPresenter = ProjectWindowController.symbolReviewPresenter
        defer {
            ProjectWindowController.symbolSearchPrompt = previousPrompt
            ProjectWindowController.symbolReviewPresenter = previousPresenter
        }
        let door = "1 w 0 0 m 20 0 l S 0 0 m 0 12 l S 20 0 m 20 6 l S"
        let first = (0..<5).map { "q 1 0 0 1 \(100 + $0 * 60) 100 cm /D Do Q" }.joined(separator: " ")
        let second = ["q 1 0 0 1 100 300 cm /D Do Q", "q 0 1 -1 0 300 300 cm /D Do Q", "q -1 0 0 1 400 300 cm /D Do Q"].joined(separator: " ")
        let url = try AutomationFixtures.writePDF(named: "Blocks.pdf", objects: [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 5 0 R /Resources << /XObject << /D 7 0 R >> >> >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 6 0 R /Resources << /XObject << /D 7 0 R >> >> >>",
            "", "",
            "<< /Type /XObject /Subtype /Form /BBox [-5 -5 40 40] /Length \(door.utf8.count) >>\nstream\n\(door)\nendstream"
        ], streams: [5: first, 6: second])
        let harness = try await open(url)
        defer { harness.tearDown() }
        let capture = Capture()
        inject(designation: "D-12", scope: .allPages, capture: capture)
        let model = try await runReview(harness, box: PDFRectValue(x: 95, y: 95, width: 30, height: 22), capture: capture)
        #expect(model.rows.count == 8, "\(model.rows.map(\.detail))")
        #expect(model.rows.allSatisfy { $0.detail.hasPrefix("exact block") })
        #expect(model.rows.filter(\.isExemplar).count == 1)
        #expect(model.rows.filter { $0.detail.contains("mirrored") }.count == 1)
    }
}
