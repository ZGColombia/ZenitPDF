import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
import ZPDFUIShell
import ZPDFSnapEngine
@testable import ZenitPDFAppKit

/// nl-automation: auto-trace honours hidden layers and the measure lock, runs off the main actor
/// on a prepared page, and proposes closing lines across door openings that a person accepts.
@MainActor
@Suite(.appTierSerialised)
struct AutoTraceAutomationTests {

    private struct Window {
        let document: ZenitPDFProjectDocument
        let controller: ProjectWindowController
        let canvas: PDFCanvasViewController
        let core: AppCoreEnvironment
        let shell: ProjectShellEnvironment

        @MainActor
        func tearDown() {
            document.close()
            try? FileManager.default.removeItem(at: document.fileURL?.deletingLastPathComponent() ?? URL(fileURLWithPath: "/nonexistent"))
        }
    }

    /// The document inside a real window controller, so the canvas carries the automation
    /// context the application gives it. Calibrated so `pointsPerMetre` page points are 1 m.
    private func openInWindow(_ url: URL, pointsPerMetre: Double = 100) async throws -> Window {
        let document = try AppTestSupport.makeDocument(opening: url)
        #expect(await AppTestSupport.wait { document.core != nil && document.drawing != nil && document.shell != nil })
        let core = try #require(document.core)
        let shell = try #require(document.shell)
        let controller = ProjectWindowController(document: document)
        document.addWindowController(controller)
        #expect(await AppTestSupport.wait { controller.canvasController(for: document) != nil })
        let canvas = try #require(controller.canvasController(for: document))
        _ = try await core.commands.calibrate(
            page: try #require(await core.session.firstPageID),
            first: PDFPoint(x: 0, y: 0),
            second: PDFPoint(x: pointsPerMetre, y: 0),
            knownLength: 1,
            knownLengthUnit: .metre
        )
        await core.refresh()
        return Window(document: document, controller: controller, canvas: canvas, core: core, shell: shell)
    }

    /// The session's markups once at least `count` have landed: a committed measurement reaches
    /// the session through the command bus a moment after the trace answers.
    private func markups(_ core: AppCoreEnvironment, atLeast count: Int) async -> [MarkupRecord] {
        var records = await core.session.orderedMarkups
        for _ in 0..<150 where records.count < count {
            try? await Task.sleep(for: .milliseconds(20))
            records = await core.session.orderedMarkups
        }
        return records
    }

    private func areaSquareMetres(_ record: MarkupRecord?) -> Double? {
        guard let value = record?.measurement?.values[.planArea]?.value else { return nil }
        return NSDecimalNumber(decimal: value).doubleValue
    }

    // MARK: - BUG PDFCanvasViewController.swift:2441 — hidden layers and the measure lock

    @Test("A line on a layer the person hid no longer splits the traced room")
    func hiddenLayerDoesNotSplitTheRoom() async throws {
        let window = try await openInWindow(try AutomationFixtures.writeLayeredRoom())
        defer { window.tearDown() }
        let layers = window.document.layerVisibility
        #expect(await AppTestSupport.wait { layers.items.count == 2 }, "the two layers were never read")
        let furniture = try #require(layers.items.first { $0.name == "Furniture" })
        layers.setVisible(false, layerID: furniture.id)

        window.shell.perform(.measureArea)
        window.canvas.handleClick(at: PDFPointValue(x: 150, y: 150), additive: false, optionHeld: true)
        await window.canvas.settleAutoTrace()

        let records = await markups(window.core, atLeast: 1)
        #expect(records.count == 1, "\(records.count) records")
        // Old output: 1.5 m × 2 m = 3 m² — the hidden Furniture line at x = 222 split the room.
        // The whole room: 300 × 200 pt at 100 pt/m = 3 m × 2 m = 6 m².
        let area = try #require(areaSquareMetres(records.first))
        #expect(abs(area - 6) < 1e-6, "traced \(area) m²")
        let note = window.core.status.snapshot.activeToolNote ?? ""
        #expect(note.contains("1 hidden layer"), "the trace must say what it ignored: \(note)")
    }

    @Test("Under a measure lock on Walls, the visible Furniture line is not traced either")
    func measureLockExcludesOtherLayers() async throws {
        let window = try await openInWindow(try AutomationFixtures.writeLayeredRoom())
        defer { window.tearDown() }
        let layers = window.document.layerVisibility
        #expect(await AppTestSupport.wait { layers.items.count == 2 })
        let walls = try #require(layers.items.first { $0.name == "Walls" })
        layers.setMeasureLock(walls.id)

        window.shell.perform(.measureArea)
        window.canvas.handleClick(at: PDFPointValue(x: 150, y: 150), additive: false, optionHeld: true)
        await window.canvas.settleAutoTrace()

        let records = await markups(window.core, atLeast: 1)
        // Old output: 3 m² — the trace ignored the lock and walked the Furniture line.
        let area = try #require(areaSquareMetres(records.first))
        #expect(abs(area - 6) < 1e-6, "traced \(area) m²")
    }

    @Test("With both layers visible and no lock the split still counts: nothing is hidden that the person can see")
    func visibleLayersStillSplit() async throws {
        let window = try await openInWindow(try AutomationFixtures.writeLayeredRoom())
        defer { window.tearDown() }
        #expect(await AppTestSupport.wait { window.document.layerVisibility.items.count == 2 })
        window.shell.perform(.measureArea)
        window.canvas.handleClick(at: PDFPointValue(x: 150, y: 150), additive: false, optionHeld: true)
        await window.canvas.settleAutoTrace()
        let area = try #require(areaSquareMetres(await markups(window.core, atLeast: 1).first))
        // Left half: 150 × 200 pt = 1.5 m × 2 m = 3 m².
        #expect(abs(area - 3) < 1e-6, "traced \(area) m²")
    }

    // MARK: - BUG PDFCanvasViewController.swift:2441 — unprepared, on the main actor

    @Test("The click returns before the walk, and a second click does not prepare the page again")
    func preparedOnceAndOffTheMainActor() async throws {
        let window = try await openInWindow(try AppTestSupport.writeFixturePDF(named: "prepared.pdf"))
        defer { window.tearDown() }
        window.shell.perform(.measureArea)

        let started = ContinuousClock.now
        window.canvas.handleClick(at: PDFPointValue(x: 200, y: 150), additive: false, optionHeld: true)
        let clickDuration = ContinuousClock.now - started
        // Old behaviour: the whole trace ran inside handleClick and the record existed on return.
        let immediately = await window.core.session.orderedMarkups
        #expect(immediately.isEmpty, "the trace ran synchronously inside the click")
        #expect(clickDuration < .milliseconds(16), "the click held the main actor for \(clickDuration)")

        await window.canvas.settleAutoTrace()
        #expect(await markups(window.core, atLeast: 1).count == 1)
        #expect(window.canvas.autoTraceService.prepareCount == 1)

        // Second click on the same page: the prepared page is reused.
        window.shell.perform(.measureArea)
        window.canvas.handleClick(at: PDFPointValue(x: 200, y: 150), additive: false, optionHeld: true)
        await window.canvas.settleAutoTrace()
        #expect(await markups(window.core, atLeast: 2).count == 2)
        // Old behaviour: every click re-flattened and re-collected the page (count would be 2).
        #expect(window.canvas.autoTraceService.prepareCount == 1)
    }

    // MARK: - NL-AUTO-07: openings a person closes

    /// 1:50 — one page point is 25.4 / 72 mm of paper, 50 × that of building.
    private static let pointsPerRealMillimetre = 72.0 / 25.4 / 50.0
    private static func pt(_ millimetres: Double) -> Double { 100 + millimetres * pointsPerRealMillimetre }

    /// Room 4000 × 3000 mm with a 900 mm door (x 1000…1900 mm) in its bottom wall, a corridor
    /// 1500 mm deep below, all offset by 100 pt.
    private func writeDoorRoom() throws -> URL {
        func f(_ value: Double) -> String { String(format: "%.4f", value) }
        let y0 = Self.pt(0), yTop = Self.pt(3000), yCorridor = 100 - 1500 * Self.pointsPerRealMillimetre
        let content = """
        1 w 0 0 0 RG
        \(f(Self.pt(0))) \(f(y0)) m \(f(Self.pt(1000))) \(f(y0)) l S
        \(f(Self.pt(1900))) \(f(y0)) m \(f(Self.pt(4000))) \(f(y0)) l S
        \(f(Self.pt(4000))) \(f(y0)) m \(f(Self.pt(4000))) \(f(yTop)) l S
        \(f(Self.pt(4000))) \(f(yTop)) m \(f(Self.pt(0))) \(f(yTop)) l S
        \(f(Self.pt(0))) \(f(yTop)) m \(f(Self.pt(0))) \(f(y0)) l S
        \(f(Self.pt(0))) \(f(yCorridor)) m \(f(Self.pt(4000))) \(f(yCorridor)) l S
        \(f(Self.pt(0))) \(f(yCorridor)) m \(f(Self.pt(0))) \(f(y0)) l S
        \(f(Self.pt(4000))) \(f(yCorridor)) m \(f(Self.pt(4000))) \(f(y0)) l S
        """
        return try AutomationFixtures.writeSinglePage(named: "Door Room.pdf", content: content)
    }

    @Test("A room with a 900 mm door: the proposal shows one closing line, Return commits the room")
    func doorProposalAcceptedWithReturn() async throws {
        // 1 m at 1:50 is 1000 × pointsPerRealMillimetre page points.
        let window = try await openInWindow(try writeDoorRoom(), pointsPerMetre: 1000 * Self.pointsPerRealMillimetre)
        defer { window.tearDown() }
        window.shell.perform(.measureArea)
        window.canvas.handleClick(at: PDFPointValue(x: Self.pt(2000), y: Self.pt(1500)), additive: false, optionHeld: true)
        await window.canvas.settleAutoTrace()

        // Proposed, not committed.
        #expect(await window.core.session.orderedMarkups.isEmpty, "a closure was committed without the person")
        let proposal = try #require(window.canvas.pendingOpeningProposal)
        #expect(proposal.closures.count == 1)
        #expect(window.core.measurement.placedPoints.count == proposal.region.ring.count)
        let note = window.core.status.snapshot.activeToolNote ?? ""
        #expect(note.contains("Closes 1 opening (0.90 m)"), "note: \(note)")

        // Return accepts through the ordinary Finish.
        _ = window.canvas.handle(key: .finish)
        var committed: MarkupRecord?
        for _ in 0..<100 {
            committed = await window.core.session.orderedMarkups.first
            if committed != nil { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        // The hand polygon closed at the wall line: 4 m × 3 m = 12 m², within QUALITY_BAR's 0.10 %.
        let area = try #require(areaSquareMetres(committed))
        #expect(abs(area - 12) / 12 <= 0.001, "committed \(area) m²")
        #expect(window.canvas.pendingOpeningProposal == nil)
    }

    @Test("Escape withdraws the proposal and commits nothing")
    func doorProposalCancelledWithEscape() async throws {
        let window = try await openInWindow(try writeDoorRoom(), pointsPerMetre: 1000 * Self.pointsPerRealMillimetre)
        defer { window.tearDown() }
        window.shell.perform(.measureArea)
        window.canvas.handleClick(at: PDFPointValue(x: Self.pt(2000), y: Self.pt(1500)), additive: false, optionHeld: true)
        await window.canvas.settleAutoTrace()
        #expect(window.canvas.pendingOpeningProposal != nil)

        _ = window.canvas.handle(key: .escape)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await window.core.session.orderedMarkups.isEmpty)
        #expect(window.canvas.pendingOpeningProposal == nil)
        #expect(window.core.measurement.placedPoints.isEmpty)
    }

    // MARK: - NL-AUTO-11: the person's trace options

    @Test("Auto-Trace Options ▸ Ignore fills and hatch: a filled band no longer splits the room, and the note says so")
    func traceOptionsIgnoreFills() async throws {
        // The standard room 72…372 × 72…272, and a filled band 210…230 across it.
        let content = "1 w 0 0 0 RG 72 72 m 372 72 l 372 272 l 72 272 l h S 0 g 210 72 20 200 re f"
        let window = try await openInWindow(try AutomationFixtures.writeSinglePage(named: "Hatch.pdf", content: content))
        defer { window.tearDown() }
        let previous = ProjectWindowController.autoTraceOptionsPrompt
        defer { ProjectWindowController.autoTraceOptionsPrompt = previous }

        window.shell.perform(.measureArea)
        window.canvas.handleClick(at: PDFPointValue(x: 100, y: 150), additive: false, optionHeld: true)
        await window.canvas.settleAutoTrace()
        // Without the option the band is a boundary: 138 × 200 pt = 1.38 m × 2 m = 2.76 m².
        let first = try #require(areaSquareMetres(await markups(window.core, atLeast: 1).first))
        #expect(abs(first - 2.76) < 1e-6, "traced \(first) m²")

        ProjectWindowController.autoTraceOptionsPrompt = { _, _ in TraceFilter(excludesFillOnly: true) }
        window.controller.showAutoTraceOptions(for: window.document)
        #expect(await AppTestSupport.wait { window.document.automation.traceChoices.excludesFillOnly })
        #expect((window.core.status.snapshot.activeToolNote ?? "").contains("fills and hatch"))

        window.shell.perform(.measureArea)
        window.canvas.handleClick(at: PDFPointValue(x: 100, y: 150), additive: false, optionHeld: true)
        await window.canvas.settleAutoTrace()
        let records = await markups(window.core, atLeast: 2)
        #expect(records.count == 2)
        // The whole room: 3 m × 2 m = 6 m².
        let second = try #require(areaSquareMetres(records.last))
        #expect(abs(second - 6) < 1e-6, "traced \(second) m²")
        #expect((window.core.status.snapshot.activeToolNote ?? "").contains("Tracing ignores: fills and hatch"))
    }

    // MARK: - NL-AUTO-10: islands offered as cutouts

    @Test("A column inside the traced room is offered as a cutout; accepting deducts it")
    func islandOfferedAndDeducted() async throws {
        // Room 72…372 × 72…272 (6 m² at 100 pt/m) with a column 200…240 × 150…190 (0.16 m²).
        let content = "1 w 0 0 0 RG 72 72 m 372 72 l 372 272 l 72 272 l h S 200 150 m 240 150 l 240 190 l 200 190 l h S"
        let window = try await openInWindow(try AutomationFixtures.writeSinglePage(named: "Column.pdf", content: content))
        defer { window.tearDown() }
        window.shell.perform(.measureArea)
        window.canvas.handleClick(at: PDFPointValue(x: 100, y: 100), additive: false, optionHeld: true)
        await window.canvas.settleAutoTrace()
        // Not deducted unasked: the traced area is the whole room.
        let traced = try #require(areaSquareMetres(await markups(window.core, atLeast: 1).first))
        #expect(abs(traced - 6) < 1e-6)

        #expect(await AppTestSupport.wait { window.core.document.warnings.contains { $0.actionTitle == "Deduct as Cutouts" } })
        let offer = try #require(window.core.document.warnings.first { $0.actionTitle == "Deduct as Cutouts" })
        #expect(offer.title.contains("1 closed outline(s)") && offer.title.contains("0.16 m²"), "\(offer.title)")
        #expect(window.document.handleAutomationWarningAction(offer.id))
        var net: Double?
        var cutout: Double?
        for _ in 0..<100 {
            let parent = await window.core.session.orderedMarkups.first { $0.tool == .area }
            net = parent?.measurement?[.netArea].map { NSDecimalNumber(decimal: $0.value).doubleValue }
            cutout = parent?.measurement?[.cutoutArea].map { NSDecimalNumber(decimal: $0.value).doubleValue }
            if let net, abs(net - 5.84) < 1e-6 { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        // The column 0.4 m × 0.4 m = 0.16 m² comes off: net 6 − 0.16 = 5.84 m², gross stays 6.
        #expect(abs((net ?? 0) - 5.84) < 1e-6, "net \(net ?? -1) m²")
        #expect(abs((cutout ?? 0) - 0.16) < 1e-6)
    }

    // MARK: - NL-AUTO-21: the room name printed inside, offered as the subject

    @Test("A traced room labelled WC 3 offers “WC 3” as its subject, and only sets it when used")
    func subjectSuggestedFromLabel() async throws {
        let content = "1 w 0 0 0 RG 72 72 m 372 72 l 372 272 l 72 272 l h S BT /F1 10 Tf 200 170 Td (WC 3) Tj ET"
        let window = try await openInWindow(try AutomationFixtures.writeSinglePage(named: "WC.pdf", content: content))
        defer { window.tearDown() }
        window.shell.perform(.measureArea)
        window.canvas.handleClick(at: PDFPointValue(x: 100, y: 100), additive: false, optionHeld: true)
        await window.canvas.settleAutoTrace()
        let record = try #require(await markups(window.core, atLeast: 1).first)
        #expect(record.subject != "WC 3", "the suggestion must never be applied unasked")
        #expect(await AppTestSupport.wait { window.core.document.warnings.contains { $0.actionTitle == "Use as Subject" } })
        let offer = try #require(window.core.document.warnings.first { $0.actionTitle == "Use as Subject" })
        #expect(offer.title == "Name this area “WC 3”?")
        #expect(window.document.handleAutomationWarningAction(offer.id))
        var subject = record.subject
        for _ in 0..<100 {
            subject = await window.core.session.orderedMarkups.first?.subject ?? ""
            if subject == "WC 3" { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(subject == "WC 3")
    }
}
