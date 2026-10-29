import AppKit
import CoreGraphics
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFTestingSupport
import ZPDFUIPresentation
import ZPDFUIWorkflows
@testable import ZenitPDFAppKit

/// Automation regressions: L-72 (symbol schedule on a heavy roof plan), L-74 (Find Walls ticks
/// every class) and L-75 (Prepare This Set stalls on the last sheet). Every review is answered by
/// injection; nothing reaches the screen. The sheets are the synthetic drawing sheets of
/// `ZPDFTestingSupport` (`FIXTURES.md`), each generated into a fresh directory per test, because
/// a window's tear-down deletes its document's directory.
@MainActor
@Suite("l8-automation app tier", .appTierSerialised)
struct L8AutomationTests {

    /// A scratch copy of a synthetic sheet in a fresh temporary directory.
    static func scratchSheet(_ kind: FixtureKind) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-l8-automation-\(UUID().uuidString)", isDirectory: true)
        return try ZPDFFixtures.make(kind, in: directory).url
    }

    /// The three-sheet set: Plan-A (the roof plan), Plan-B (a second, much larger
    /// sheet, 2 700 × 3 100 mm, of rooms and a title block at 1:100) and Plan-A-rev (the roof plan
    /// with a rectangle and a line added to its content). Sheets 1 and 3 draw the roof plan's own
    /// content stream object, text included (`SyntheticRoofPlanFixtures.threeSheetSet`).
    static func writeThreeSheetSet() throws -> URL {
        try scratchSheet(.syntheticRoofPlanSet)
    }

    @MainActor final class Outcome<T> {
        var value: T?
    }

    /// Runs `body` and stops waiting after `seconds`, so a run that never finishes fails the
    /// test instead of hanging the suite. `nil` when it did not finish in time.
    static func finishing<T>(within seconds: Double, _ body: @escaping @MainActor () async -> T) async -> T? {
        let outcome = Outcome<T>()
        let task = Task { @MainActor in outcome.value = await body() }
        _ = await AppTestSupport.wait(upTo: seconds) { outcome.value != nil }
        if outcome.value == nil { task.cancel() }
        return outcome.value
    }

    // MARK: - L-75

    @Test("L-75: Prepare This Set on the three-sheet set finishes and says so in the status note")
    func prepareThisSetFinishesOnTheThreeSheetSet() async throws {
        let url = try Self.writeThreeSheetSet()
        let window = try await R2AutomationAppTests.open(url, calibrate: false)
        defer { window.tearDown() }
        #expect(try #require(window.document.drawing).pages.count == 3)
        let filed = await Self.finishing(within: 300) {
            await window.controller.runTakeoffAssistant(for: window.document)
        }
        let inbox = window.document.automation.inbox
        let note = window.core.status.snapshot.activeToolNote ?? ""
        #expect(filed != nil, "the run never finished; the note reads \(note)")
        // Old output: the note stayed "Preparing sheet 3 of 3…" after the run — its result went
        // only to the notices tray — so the run looked stalled with the Inbox at 0.
        #expect(note != "Preparing sheet 3 of 3…")
        #expect(note.hasPrefix("Prepared 3 of 3 sheets."), "\(note)")
        // Both copies of the roof plan propose the SKALA field's 1:50; the large sheet its 1:100.
        let scales = inbox.proposals.filter { $0.kind == .scale }.sorted { $0.pageIndex < $1.pageIndex }
        #expect(scales.map(\.pageIndex) == [0, 1, 2], "\(inbox.proposals.map(\.summary))")
        #expect(scales.map(\.scaleDisplay) == ["1:50", "1:100", "1:50"])
        if let filed {
            #expect(filed == inbox.openProposals.count)
            #expect(note.contains("\(filed) to review in the Takeoff Assistant Inbox."), "\(note)")
        }
        #expect(window.document.automation.isPreparingSet == false)
    }

    /// Holds the continuation of a reader that never answers, so the test can release it.
    @MainActor final class StuckReader {
        var continuation: CheckedContinuation<Void, Never>?
        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    @Test("L-75: a sheet whose reading never finishes is passed over and named; the run still ends and files the rest")
    func stuckSheetDoesNotStallTheRun() async throws {
        let sheet = "BT /F1 8 Tf 700 20 Td (SCALE 1:50) Tj ET 0.5 w 0 0 0 RG 72 72 m 300 72 l S"
        let url = try AutomationFixtures.writePages(named: "Stuck.pdf", mediaBox: "0 0 842 595", contents: [sheet, sheet, sheet])
        let window = try await R2AutomationAppTests.open(url, calibrate: false)
        let stuck = StuckReader()
        let previousReader = ProjectWindowController.assistantSheetReader
        let previousDeadline = ProjectWindowController.assistantSheetReadDeadline
        defer {
            stuck.release()
            ProjectWindowController.assistantSheetReader = previousReader
            ProjectWindowController.assistantSheetReadDeadline = previousDeadline
            window.tearDown()
        }
        let pages = try #require(window.document.drawing).pages
        // Sheets 1 and 2 are read beforehand by the shipping readers, so the short deadline below
        // can only ever catch the third sheet, however busy the machine is.
        var ready: [PageID: ProjectWindowController.AssistantSheetRead] = [:]
        for page in pages.prefix(2) {
            ready[page.id] = await previousReader(window.controller, window.document, page)
        }
        // The third sheet's reader never answers, as the live run's last sheet did not.
        ProjectWindowController.assistantSheetReader = { _, _, page in
            if let read = ready[page.id] { return read }
            await withCheckedContinuation { stuck.continuation = $0 }
            return ProjectWindowController.AssistantSheetRead(lines: [], extraction: nil)
        }
        ProjectWindowController.assistantSheetReadDeadline = .seconds(1)

        let filed = await Self.finishing(within: 60) {
            await window.controller.runTakeoffAssistant(for: window.document)
        }
        // Old output: no result within 60 s — the run awaited the third sheet for ever, the
        // note read "Preparing sheet 3 of 3…" and nothing after it ran.
        #expect(filed == 2, "\(String(describing: filed))")
        let note = window.core.status.snapshot.activeToolNote ?? ""
        #expect(note == "Prepared 2 of 3 sheets. 2 to review in the Takeoff Assistant Inbox. Not read in time, so passed over: 3. Run Prepare This Set again to retry.", "\(note)")
        let scales = window.document.automation.inbox.proposals.filter { $0.kind == .scale }
        #expect(Set(scales.map(\.pageID)) == [pages[0].id.rawValue, pages[1].id.rawValue])
        #expect(window.document.automation.isPreparingSet == false)
    }

    @Test("L-75: the result names unreadable linework, and one or many sheets in proper English")
    func resultWording() {
        #expect(ProjectWindowController.assistantResult(sheets: 3, filed: 0, open: 0, unreadLinework: 0, timedOut: [])
                == "Prepared 3 of 3 sheets. Nothing to review: the assistant found no names, scales, rooms or library symbols to propose.")
        #expect(ProjectWindowController.assistantResult(sheets: 3, filed: 2, open: 5, unreadLinework: 1, timedOut: [])
                == "Prepared 3 of 3 sheets. 5 to review in the Takeoff Assistant Inbox. The linework of 1 sheet could not be read, so its rooms and symbols were not searched.")
        #expect(ProjectWindowController.assistantResult(sheets: 4, filed: 1, open: 1, unreadLinework: 2, timedOut: ["A-102", "A-104"])
                == "Prepared 2 of 4 sheets. 1 to review in the Takeoff Assistant Inbox. The linework of 2 sheets could not be read, so their rooms and symbols were not searched. Not read in time, so passed over: A-102 and A-104. Run Prepare This Set again to retry.")
    }

    // MARK: - L-72

    @MainActor final class SymbolCapture {
        var model: SymbolCountReviewModel?
    }

    @Test("L-72: Create Symbol Schedule with a box round one TH symbol on the roof plan confirms it and its two copies")
    func symbolScheduleOnTheRoofPlan() async throws {
        let previousPrompt = ProjectWindowController.symbolSearchPrompt
        let previousPresenter = ProjectWindowController.symbolReviewPresenter
        defer {
            ProjectWindowController.symbolSearchPrompt = previousPrompt
            ProjectWindowController.symbolReviewPresenter = previousPresenter
        }
        let window = try await R2AutomationAppTests.open(try Self.scratchSheet(.syntheticRoofPlan), calibrate: false)
        defer { window.tearDown() }
        let capture = SymbolCapture()
        ProjectWindowController.symbolSearchPrompt = { _, _ in SymbolSearchRequest(designation: "TH", scope: .thisPage) }
        ProjectWindowController.symbolReviewPresenter = { model, _ in
            capture.model = model
            return {}
        }
        window.controller.beginSymbolSchedule(for: window.document)
        // Round the upper symbol's outer frame (x 1015…1065, y 1042.5…1077.5) with 5 pt to spare.
        window.canvas.onSnippetRegion?(PDFRectValue(x: 1010, y: 1037, width: 60, height: 46))
        #expect(await AppTestSupport.wait(upTo: 120) { capture.model != nil }, "the review never opened")
        let model = try #require(capture.model)
        #expect(await AppTestSupport.wait(upTo: 240) { !model.isSearching }, "the search never finished")
        // This box holds both frames (eight lines). Old output on the original sheet with the
        // matcher's second look switched off: 0 confirmed — the whole sheet welded into one
        // rejection at 13.67×. (The reported "0 confirmed, 7 near misses" came from the
        // inner-frame box below.)
        #expect(model.confirmedCount == 3, "\(model.summaryText)")
        // The three hits at the symbols' centres, the concentric frames' common centre
        // (`SyntheticRoofPlan.symbolCentres`; L8SymbolMatchRoofPlanTests).
        let hits = model.rows.filter { $0.status == .confirmed }.map(\.position).sorted { $0.y < $1.y }
        let expected = [PDFPoint(x: 1100, y: 640), PDFPoint(x: 1040, y: 990), PDFPoint(x: 1040, y: 1060)]
        #expect(hits.count == 3)
        for (hit, target) in zip(hits, expected) {
            #expect(abs(hit.x - target.x) < 0.05 && abs(hit.y - target.y) < 0.05, "\(hit)")
        }
        model.cancel()
    }

    @Test("L-72: the live box round one TH symbol's inner frame lists each of the three symbols once, and Add lands three counts")
    func symbolScheduleWithTheLiveBox() async throws {
        let previousPrompt = ProjectWindowController.symbolSearchPrompt
        let previousPresenter = ProjectWindowController.symbolReviewPresenter
        defer {
            ProjectWindowController.symbolSearchPrompt = previousPrompt
            ProjectWindowController.symbolReviewPresenter = previousPresenter
        }
        let window = try await R2AutomationAppTests.open(try Self.scratchSheet(.syntheticRoofPlan), calibrate: false)
        defer { window.tearDown() }
        let capture = SymbolCapture()
        ProjectWindowController.symbolSearchPrompt = { _, _ in SymbolSearchRequest(designation: "TH", scope: .thisPage) }
        ProjectWindowController.symbolReviewPresenter = { model, _ in
            capture.model = model
            return {}
        }
        window.controller.beginSymbolSchedule(for: window.document)
        // The live gesture: the inner frame only (x 1020…1060, y 1046…1074); the outer frame lies
        // outside the box.
        window.canvas.onSnippetRegion?(PDFRectValue(x: 1017, y: 1044, width: 46, height: 32))
        #expect(await AppTestSupport.wait(upTo: 120) { capture.model != nil }, "the review never opened")
        let model = try #require(capture.model)
        #expect(await AppTestSupport.wait(upTo: 240) { !model.isSearching }, "the search never finished")
        print("L-72 live box:", model.summaryText)
        // Old output on the original sheet: before L-72, "0 confirmed, 7 near misses"; after the
        // first L-72 fix, 6 confirmed — each symbol's inner frame at scale 1 and its outer frame as
        // a second symbol at the outer-to-inner scale (1.25 here) — so the review offered 6 counts
        // and landing, which merges places closer than half the symbol's radius, minted 3.
        #expect(model.confirmedCount == 3, "\(model.summaryText)")
        // What the review did not count, in place of the original sheet's own figures: the whole
        // page was searched, and the sheet's two distractors — the square-in-square at
        // (1100, 710) and the circle-in-square at (1115, 990) — are among the shapes not counted:
        // no confirmed row sits in either square, and at least those two are reported.
        #expect(model.pages.allSatisfy { !$0.isTruncated && $0.failure == nil }, "\(model.summaryText)")
        let distractors = [PDFRectValue(x: 1079, y: 689, width: 42, height: 42), PDFRectValue(x: 1092, y: 967, width: 46, height: 46)]
        #expect(!model.rows.contains { row in
            row.status == .confirmed && distractors.contains { $0.contains(row.position) }
        }, "\(model.summaryText)")
        #expect(model.nearMissCount + model.otherShapeCount >= distractors.count, "\(model.summaryText)")
        // The inner frames' centres (L8SymbolMatchRoofPlanTests.liveBoxConfirmsEachSymbolOnce):
        // the concentric frames share them.
        let hits = model.rows.filter { $0.status == .confirmed }.map(\.position).sorted { $0.y < $1.y }
        let expected = [PDFPoint(x: 1100, y: 640), PDFPoint(x: 1040, y: 990), PDFPoint(x: 1040, y: 1060)]
        #expect(hits.count == 3, "\(hits)")
        for (hit, target) in zip(hits, expected) {
            #expect(abs(hit.x - target.x) < 0.05 && abs(hit.y - target.y) < 0.05, "\(hit)")
        }
        // What the review offers is what lands.
        #expect(model.selectedRowIDs.count == 3)
        model.accept()
        var counts: [MarkupRecord] = []
        for _ in 0..<200 {
            counts = await window.core.session.orderedMarkups.filter { $0.tool == .count && $0.subject == "TH" }
            if !counts.isEmpty { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(counts.count == 1 && counts.first?.geometry?.countPoints.count == 3, "\(counts.map { $0.geometry?.countPoints.count ?? 0 })")
    }

    // MARK: - L-74

    /// The sheets' 1:50: 72 / (0.0254 × 50) page points per metre.
    static let roofPlanPointsPerMetre = 72 / (0.0254 * 50)

    @Test("L-74: Find Walls on an A1 wall and hatch module lists its classes with none ticked, and adds nothing until one is")
    func findWallsStartsUnticked() async throws {
        let window = try await R2AutomationAppTests.open(try Self.scratchSheet(.syntheticWallModule), pointsPerMetre: Self.roofPlanPointsPerMetre)
        defer { window.tearDown() }
        let previous = ProjectWindowController.wallReviewDecision
        defer { ProjectWindowController.wallReviewDecision = previous }
        var shown: [ProjectWindowController.WallProposal] = []
        // The decision a person makes by pressing Add Walls at once: the boxes as they start.
        ProjectWindowController.wallReviewDecision = { proposals, _ in
            shown = proposals
            let boxes = ProjectWindowController.wallReviewCheckboxes(for: proposals)
            return Set(boxes.indices.filter { boxes[$0].state == .on })
        }
        let added = await window.controller.runWallTakeoff(for: window.document)
        let total = shown.reduce(0) { $0 + $1.lengthMetres }
        print("L-74 classes:", shown.count, "total m:", total, shown.map { "\($0.thicknessMillimetres) \($0.repeatsLikeAPattern)" })
        // Old output on the original roof plan: every class ticked — Add Walls at once added all of
        // it to the ledger as walls. Hand-derived on the module (`FIXTURES.md`), at 1:50, where
        // 1 mm of building is 72 / 25.4 / 50 pt: the walls are 250 mm (faces 1800/127 pt apart) and
        // 120 mm (864/127 pt), and repeat nowhere; the hatch, 20 lines 90 mm (648/127 pt) apart,
        // pairs at k × 90 mm for every k with k × 90 inside the 50…600 mm band — 90, 180, 270, 360,
        // 450, 540 — each with (20 − k) × 300 pt of facing length, far over the 2 m a class needs,
        // and repeats over all of it. Walls first, thinnest first; then the patterns.
        #expect(shown.map(\.thicknessMillimetres) == [120, 250, 90, 180, 270, 360, 450, 540])
        #expect(shown.map(\.repeatsLikeAPattern) == [false, false, true, true, true, true, true, true])
        #expect(added == 0)
        #expect(await R2AutomationAppTests.markups(window.core, atLeast: 0).isEmpty)
        #expect(window.core.status.snapshot.activeToolNote == "No wall class was ticked, so nothing was added.")
        // The classes that repeat like a pattern come after the rest and say so.
        let firstPattern = shown.firstIndex { $0.repeatsLikeAPattern } ?? shown.count
        let tailIsPatterns = shown[firstPattern...].allSatisfy { $0.repeatsLikeAPattern }
        let anyPattern = shown.contains { $0.repeatsLikeAPattern }
        #expect(tailIsPatterns)
        #expect(anyPattern)
        for proposal in shown where proposal.repeatsLikeAPattern {
            #expect(ProjectWindowController.wallReviewRowTitle(proposal).contains("(repeats like hatching)"))
        }
    }

    @Test("L-74: walls come first and the hatch's classes last, labelled; one opening is singular")
    func wallsBeforePatterns() async throws {
        var hatch = R2AutomationAppTests.wallPlan
        for index in 0..<20 {
            let y = 50 + Double(index) * 10
            hatch += "\n1250 \(y) m 1550 \(y) l S"
        }
        let url = try AutomationFixtures.writeSinglePage(named: "Walls and hatch.pdf", mediaBox: "0 0 1700 700", content: hatch)
        let window = try await R2AutomationAppTests.open(url)
        defer { window.tearDown() }
        let previous = ProjectWindowController.wallReviewDecision
        defer { ProjectWindowController.wallReviewDecision = previous }
        var shown: [ProjectWindowController.WallProposal] = []
        ProjectWindowController.wallReviewDecision = { proposals, _ in
            shown = proposals
            return Set(proposals.indices.filter { proposals[$0].thicknessMillimetres == 150 })
        }
        let added = await window.controller.runWallTakeoff(for: window.document)
        // Hand-derived in L8WallPatternTests: the walls (150 mm, 250 mm) repeat nowhere; the hatch,
        // 20 lines 100 mm apart, repeats at 100 mm and every multiple up to 600 mm.
        // Old output: [100, 150, 200, 250, 300, 400, 500, 600], none marked, all ticked.
        #expect(shown.map(\.thicknessMillimetres) == [150, 250, 100, 200, 300, 400, 500, 600])
        #expect(shown.map(\.repeatsLikeAPattern) == [false, false, true, true, true, true, true, true])
        #expect(added == 2, "the ticked partition's two runs")
        let partition = try #require(shown.first)
        #expect(partition.openingWidthsMetres.count == 1)
        // Old output: "2 wall lengths added in 1 classes; 1 openings left out."
        #expect(window.core.status.snapshot.activeToolNote == "2 wall lengths added in 1 class; 1 opening left out.")
        #expect(ProjectWindowController.wallsAddedNote(lengths: 1, classes: 1, openings: 1) == "1 wall length added in 1 class; 1 opening left out.")
        #expect(ProjectWindowController.wallsAddedNote(lengths: 7, classes: 3, openings: 0) == "7 wall lengths added in 3 classes; 0 openings left out.")
        // Old output: "Wall 150 mm: 4.60 m (1 openings left out)".
        #expect(ProjectWindowController.wallReviewRowTitle(partition) == "Wall 150 mm: 4.60 m (1 opening left out)")
        #expect(ProjectWindowController.wallReviewRowTitle(shown[2]) == "Wall 100 mm: \(String(format: "%.2f", shown[2].lengthMetres)) m (repeats like hatching)")
        #expect(ProjectWindowController.wallReviewMessage(for: shown).contains("repeats like hatching"))
        #expect(ProjectWindowController.wallReviewCheckboxes(for: shown).allSatisfy { $0.state == .off })
    }
}
