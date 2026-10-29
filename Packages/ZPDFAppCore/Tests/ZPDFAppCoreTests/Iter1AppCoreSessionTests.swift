import Foundation
import os
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFQuantityLedger
import ZPDFUIPresentation

/// Session and command bus (R-051, R-057, R-058, R-059, R-060, R-064).
@Suite("Iteration 1 — session")
@MainActor
struct Iter1AppCoreSessionTests {

    nonisolated static let start = Date(timeIntervalSince1970: 1_790_416_810)   // 2026-09-26 10:00:10 UTC

    static func page(_ documentID: DocumentID, index: Int = 0) -> ZPDFContracts.PageDescriptor {
        ZPDFContracts.PageDescriptor(id: PageID(UUID()), documentID: documentID, index: index, label: "A-\(101 + index)",
                                     boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 612, height: 792)))
    }

    static func rectangle(on page: ZPDFContracts.PageDescriptor, subject: String, width: Double, height: Double) -> ZPDFContracts.MarkupRecord {
        Iter1AppCoreArchiveTests.rectangle(on: page, subject: subject, width: width, height: height)
    }

    /// One sheet at 100 pt = 10 m (0.1 m/pt) with Slab 40 × 30 pt = 12 m², a clock the test moves,
    /// and a live quantity table.
    func summaryFixture() async throws -> (AppCoreEnvironment, TakeoffSession, OSAllocatedUnfairLock<Date>, MarkupID, MarkupID) {
        let documentID = DocumentID(UUID())
        let page = Self.page(documentID)
        let clock = OSAllocatedUnfairLock(initialState: Self.start)
        let session = try TakeoffSession(documentID: documentID, pages: [page], clock: { clock.withLock { $0 } })
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        try await environment.commands.calibrate(page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
                                                 knownLength: 10, knownLengthUnit: .metre)
        let slab = Self.rectangle(on: page, subject: "Slab", width: 40, height: 30)
        try await environment.commands.perform(.addMarkup(slab))
        let summary = try await environment.placeLiveSummary(LiveSummarySpec(kind: .quantities), onPage: page.id, at: PDFPoint(x: 300, y: 700))
        return (environment, session, clock, slab.id, summary)
    }

    // MARK: R-051

    /// Old output, once the minute had turned: the colour change rewrote the summary (its "As of"
    /// line differed), put it into the step's inverse and changed set, and a command that changed
    /// nothing registered an undo step through the summary's rewrite.
    @Test("A new minute alone never rewrites a live summary; a new total does, restamped")
    func summaryIgnoresTheClock() async throws {
        let (environment, session, clock, slab, summary) = try await summaryFixture()
        let placed = try #require(await session.markup(summary)?.caption)
        #expect(placed.contains("Slab — 12 m²") || placed.contains("Slab"), "\(placed)")
        clock.withLock { $0 = Self.start.addingTimeInterval(110) }   // 10:02:00

        // A ledger row changes, the quantities do not.
        var style = try #require(await session.markup(slab)).style
        style.color = RGBAColor(red: 1, green: 0, blue: 0, alpha: 1)
        let outcome = try await session.apply(.changeStyle(id: slab, style: style))
        #expect(!outcome.changedMarkupIDs.contains(summary))
        #expect(outcome.inverse.markups.index(forKey: summary) == nil)
        #expect(await session.markup(summary)?.caption == placed)

        // A command that changes nothing is not a step.
        environment.commands.undoManager.removeAllActions()
        try await environment.commands.perform(.editSubject(id: slab, subject: "Slab"))
        #expect(!environment.commands.undoManager.canUndo, "a no-op registered an undo step")
        #expect(await session.markup(summary)?.caption == placed)

        // A new total rewrites the summary and restamps it: 12 + 2 = 14 m².
        let page = try #require(await session.pageDescriptors.first)
        try await environment.commands.perform(.addMarkup(Self.rectangle(on: page, subject: "Slab", width: 20, height: 10)))
        let rewritten = try #require(await session.markup(summary)?.caption)
        #expect(rewritten != placed)
        #expect(LiveSummaryBodies.body(rewritten) != LiveSummaryBodies.body(placed))
        #expect(rewritten.hasSuffix(LiveSummaryBodies.stamp(clock.withLock { $0 })), "restamped at the new time")
    }

    @Test("A step that touches no ledger row skips the summaries")
    func nonLedgerStepSkips() async throws {
        let (_, session, clock, _, summary) = try await summaryFixture()
        clock.withLock { $0 = Self.start.addingTimeInterval(600) }
        let page = try #require(await session.pageDescriptors.first)
        let cloud = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: page.documentID, pageID: page.id, kind: .cloud,
            geometry: MeasurementGeometry(pageID: page.id, polygons: [PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: 400, y: 400), PDFPoint(x: 450, y: 400), PDFPoint(x: 450, y: 450)
            ], isClosed: true))]),
            createdAt: Self.start, modifiedAt: Self.start
        )
        #expect(await session.stepLeavesSummariesAlone([.addMarkup(cloud)], touched: [cloud.id], before: [:]))
        let outcome = try await session.apply(.addMarkup(cloud))
        #expect(!outcome.changedMarkupIDs.contains(summary))
        // A scale change is never skipped.
        #expect(await session.stepLeavesSummariesAlone([.recalculateMeasurements(pageID: nil)], touched: [], before: [:]) == false)
        // A step touching a summary is never skipped: the summary is no ledger row, but its own
        // text is what the step moved (R-059, iteration 1 re-fix).
        let placed = try #require(await session.markup(summary))
        #expect(await session.stepLeavesSummariesAlone([.editText(id: summary, text: "x")], touched: [summary], before: [summary: placed]) == false)
    }

    // MARK: R-059 (iteration 1 re-fix)

    /// Two sheets at 0.1 m/pt: Slab 40 × 30 pt = 12 m² on sheet 1, Slab 20 × 10 pt = 2 m² on
    /// sheet 2, and a "this sheet only" quantity table on sheet 1.
    func twoSheetFixture() async throws -> (AppCoreEnvironment, TakeoffSession, [ZPDFContracts.PageDescriptor], MarkupID, OSAllocatedUnfairLock<Date>) {
        let documentID = DocumentID(UUID())
        let pages = [Self.page(documentID, index: 0), Self.page(documentID, index: 1)]
        let clock = OSAllocatedUnfairLock(initialState: Self.start)
        let session = try TakeoffSession(documentID: documentID, pages: pages, clock: { clock.withLock { $0 } })
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        for page in pages {
            try await environment.commands.calibrate(page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
                                                     knownLength: 10, knownLengthUnit: .metre)
        }
        try await environment.commands.perform(.addMarkup(Self.rectangle(on: pages[0], subject: "Slab", width: 40, height: 30)))
        try await environment.commands.perform(.addMarkup(Self.rectangle(on: pages[1], subject: "Slab", width: 20, height: 10)))
        let summary = try await environment.placeLiveSummary(LiveSummarySpec(kind: .quantities, pageOnly: true), onPage: pages[0].id,
                                                             at: PDFPoint(x: 300, y: 700))
        return (environment, session, pages, summary, clock)
    }

    /// Old output (the R-059 skip): the pasted copy's caption was sheet 1's, word for word —
    /// "Slab — 12.00 (1)" and "Total: 12.00 (1 rows)" on sheet 2, whose only row is 2 m² —
    /// because an `.addMarkup` of a text markup with no subject was taken for a step that moves
    /// no summary.
    @Test("A 'this sheet only' summary pasted onto another sheet shows that sheet's totals in the same step")
    func pastedSummaryFollowsItsSheet() async throws {
        let (environment, session, pages, summary, _) = try await twoSheetFixture()
        let source = try #require(await session.markup(summary)?.caption)
        #expect(source.contains("Slab — 12.00 (1)"), "\(source)")
        #expect(source.contains("Total: 12.00 (1 rows)"), "\(source)")

        let payload = try #require(await environment.markupClipboardPayload(for: [summary.rawValue]))
        environment.commands.undoManager.removeAllActions()
        let receipt = await environment.pasteMarkups(payload, onto: [pages[1].id.rawValue], placement: .inPlace)
        #expect(receipt.failureDescription == nil)
        let pastedID = try #require(receipt.pastedIDs.first)
        let pasted = try #require(await session.markup(MarkupID(pastedID)))
        #expect(pasted.pageID == pages[1].id)
        let caption = try #require(pasted.caption)
        // Sheet 2 holds one row: 20 × 10 pt at 0.1 m/pt = 2 × 1 m = 2 m².
        #expect(caption.contains("Slab — 2.00 (1)"), "\(caption)")
        #expect(caption.contains("Total: 2.00 (1 rows)"), "\(caption)")
        #expect(!caption.contains("12.00"), "\(caption)")
        // The source keeps its own sheet's numbers, and one undo takes the paste back whole.
        #expect(await session.markup(summary)?.caption == source)
        await environment.commands.undo()
        #expect(await session.markup(MarkupID(pastedID)) == nil)

        // The same through a bare `.addMarkup` of a summary carrying another sheet's words.
        var copy = pasted
        copy.id = MarkupID(UUID())
        copy.caption = source
        let outcome = try await session.apply(.addMarkup(copy))
        #expect(outcome.changedMarkupIDs.contains(copy.id))
        #expect(await session.markup(copy.id)?.caption?.contains("Total: 2.00 (1 rows)") == true)
    }

    /// Old output (the R-059 skip): "Total: 999 m²" stayed on the sheet as the summary's text —
    /// `.editText` of a text markup with no subject was taken for a step that moves no summary.
    @Test("Text typed over a live summary does not stay: its numbers come back in the same step")
    func editTextOnASummaryDoesNotStick() async throws {
        let (environment, session, clock, slab, summary) = try await summaryFixture()
        let placed = try #require(await session.markup(summary)?.caption)
        // Same totals: the summary's own caption comes back exactly, "As of" line and all,
        // even a minute later (a new minute alone never restamps, R-051).
        clock.withLock { $0 = Self.start.addingTimeInterval(110) }
        try await environment.commands.perform(.editText(id: summary, text: "Total: 999 m²"))
        let after = try #require(await session.markup(summary)?.caption)
        #expect(!after.contains("999"), "\(after)")
        #expect(after == placed)

        // Typed over while the totals move in the same step: the new totals, restamped.
        let page = try #require(await session.pageDescriptors.first)
        let wall = Self.rectangle(on: page, subject: "Slab", width: 20, height: 10)
        _ = try await environment.commands.performBatch(
            [.editText(id: summary, text: "Total: 999 m²\nAs of Jan 1, 2020 at 9:00 AM"), .addMarkup(wall)],
            actionName: "Edit"
        )
        let moved = try #require(await session.markup(summary)?.caption)
        // 12 m² + 2 m² = 14 m².
        #expect(moved.contains("Total: 14.00 (2 rows)"), "\(moved)")
        #expect(!moved.contains("999") && !moved.contains("2020"), "\(moved)")
        #expect(moved.hasSuffix(LiveSummaryBodies.stamp(clock.withLock { $0 })))
        _ = slab
    }

    /// The pane's filter and grouping are installed on the live coordinator; the summary asks
    /// for every row grouped by Subject. Old output (before the separate view): the summary's
    /// refresh set its own spec on the pane's coordinator, so after a ledger-touching command
    /// `currentLedgerSpec` was the summary's — a full regroup for the summary, and another
    /// when the pane set its own back on the next snapshot.
    @Test("A summary with its own spec leaves the pane's spec on the live coordinator and totals under its own")
    func summaryLeavesThePaneSpec() async throws {
        let (environment, session, _, _, _) = try await summaryFixture()
        let page = try #require(await session.pageDescriptors.first)
        try await environment.commands.perform(.addMarkup(Self.rectangle(on: page, subject: "Wall", width: 20, height: 10)))
        // The pane: only Wall rows, grouped by Status.
        environment.ledger.setFilter(LedgerFilterGroup(id: UUID(), rules: [
            LedgerFilterRule(id: UUID(), column: .subject, comparison: .equals, operand: .text("Wall"))
        ]))
        environment.ledger.setGrouping([.status])
        await environment.ledger.refresh()
        let pane = try #require(await session.currentLedgerSpec)
        #expect(pane.filter != .all && !pane.grouping.isEmpty, "the pane's spec is installed")

        // A ledger-touching command straight on the session (no pane refresh after it).
        let outcome = try await session.apply(.addMarkup(Self.rectangle(on: page, subject: "Slab", width: 10, height: 10)))
        #expect(await session.currentLedgerSpec == pane, "the pane's spec is still the live one")
        let summary = try #require(await session.orderedMarkups.first { $0.customValues[LiveSummaryColumn.columnID] != nil })
        #expect(outcome.changedMarkupIDs.contains(summary.id))
        let caption = try #require(summary.caption)
        // Under the summary's own spec (every row, by Subject): Slab 12 + 1 = 13 m² in 2 rows,
        // Wall 2 m² in 1 row, total 15 m² in 3 rows — not the pane's Wall-only 2 m².
        #expect(caption.contains("All rows"), "\(caption)")
        #expect(caption.contains("Slab — 13.00 (2)"), "\(caption)")
        #expect(caption.contains("Wall — 2.00 (1)"), "\(caption)")
        #expect(caption.contains("Total: 15.00 (3 rows)"), "\(caption)")

        // The pane still shows its own view: one Wall row of 2 m².
        await environment.ledger.refresh()
        #expect(environment.ledger.rowCount == 1)
        #expect(environment.ledger.grandTotals.total("planArea")?.value == 2)
        #expect(await session.currentLedgerSpec == pane)
    }

    // MARK: R-057

    /// Old output: the batch returned an outcome, registered "Edit" on the undo stack and bumped
    /// `modifiedAt`, although every value was already what it was set to.
    @Test("A batch that changes nothing is not a step")
    func noOpBatchIsNotAStep() async throws {
        let (environment, session, _, slab, _) = try await summaryFixture()
        let before = try #require(await session.markup(slab))
        environment.commands.undoManager.removeAllActions()
        let outcome = try await environment.commands.performBatch(
            [.editSubject(id: slab, subject: before.subject), .changeStyle(id: slab, style: before.style)],
            actionName: "Edit"
        )
        #expect(outcome == nil)
        #expect(!environment.commands.undoManager.canUndo)
        #expect(await session.markup(slab)?.modifiedAt == before.modifiedAt, "the modifiedAt bump is taken back")
        // A batch that changes something is still a step.
        let changed = try await environment.commands.performBatch([.editSubject(id: slab, subject: "Slab A")], actionName: "Edit")
        #expect(changed != nil)
        #expect(environment.commands.undoManager.canUndo)
    }

    // MARK: R-058

    /// Old output after calibrate and undo: `uncalibratedCapture(of:)` was nil and the save wrote
    /// no capture method — measuring had removed the set-aside entry, and no undo patch held it.
    @Test("A capture method set aside on an uncalibrated sheet survives calibrate and undo")
    func setAsideCaptureSurvivesUndo() async throws {
        let documentID = DocumentID(UUID())
        let page = Self.page(documentID)
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        let traced = CaptureStamp.stamped(Self.rectangle(on: page, subject: "Room", width: 40, height: 30),
                                          method: .autoTraced(closureWidthsPoints: [25.4]))
        _ = try await session.apply(.addMarkup(traced))
        #expect(await session.markup(traced.id)?.measurement == nil, "no scale yet")
        #expect(await session.uncalibratedCapture(of: traced.id)?.kind == .autoTraced)

        let calibration = try await session.calibrate(page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
                                                      knownLength: 10, knownLengthUnit: .metre)
        // 40 × 30 pt at 0.1 m/pt = 12 m², captured by the tracer.
        #expect(await session.markup(traced.id)?.measurement?[.planArea]?.value == 12)
        #expect(await session.markup(traced.id)?.measurement?.provenance?.captureMethod?.kind == .autoTraced)
        #expect(await session.uncalibratedCapture(of: traced.id) == nil, "measured: the method rides on the provenance")
        #expect(await session.takeoffState().uncalibratedCaptures[traced.id] == nil)

        _ = try await session.revert(calibration.inverse)
        #expect(await session.markup(traced.id)?.measurement == nil)
        #expect(await session.uncalibratedCapture(of: traced.id)?.kind == .autoTraced)
        #expect(await session.takeoffState().uncalibratedCaptures[traced.id]?.kind == .autoTraced, "the save writes it")

        // Calibrating again carries it onto the measurement once more.
        _ = try await session.calibrate(page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
                                        knownLength: 10, knownLengthUnit: .metre)
        #expect(await session.markup(traced.id)?.measurement?.provenance?.captureMethod?.kind == .autoTraced)

        // A markup reshaped by hand while waiting reads as drawn by hand.
        _ = try await session.revert(calibration.inverse)
        _ = try await session.apply(.moveMarkup(id: traced.id, dx: 5, dy: 0))
        #expect(await session.uncalibratedCapture(of: traced.id) == nil)
    }

    // MARK: R-060

    /// 20 000 sheets. Old: `pageOrder.compactMap { pages.first … }`, about 2 × 10⁸ identity
    /// comparisons per call, several calls per snapshot. Now one dictionary lookup per page.
    @Test("Page descriptors are one lookup per page, in set order")
    func pageDescriptorsAreLinear() async throws {
        let documentID = DocumentID(UUID())
        let pages = (0..<20_000).map { Self.page(documentID, index: $0) }
        let session = try TakeoffSession(documentID: documentID, pages: pages)
        let clock = ContinuousClock()
        let started = clock.now
        let described = await session.pageDescriptors
        let elapsed = clock.now - started
        #expect(described.map(\.id) == pages.map(\.id))
        #expect(elapsed < .seconds(1), "20 000 sheets took \(elapsed)")
        // The order is the set order after a reorder, and a removed sheet leaves it.
        _ = try await session.apply(.reorderPage(from: 0, to: 2))
        #expect(await session.pageDescriptors.prefix(3).map(\.id) == [pages[1].id, pages[2].id, pages[0].id])
        _ = try await session.apply(.setPagesExcluded([pages[1].id], excluded: true))
        #expect(await session.pageDescriptors.prefix(2).map(\.id) == [pages[2].id, pages[0].id])
        #expect(await session.userUnit(onPage: pages[1].id) == 1)
    }

    // MARK: R-064

    @Test("A prebuilt ledger is the store the first snapshot uses, with the same totals")
    func prebuiltLedgerIsUsed() async throws {
        let documentID = DocumentID(UUID())
        let page = Self.page(documentID)
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        _ = try await session.calibrate(page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
                                        knownLength: 10, knownLengthUnit: .metre)
        for (width, height) in [(40.0, 30.0), (20.0, 10.0)] {
            _ = try await session.apply(.addMarkup(Self.rectangle(on: page, subject: "Slab", width: width, height: height)))
        }
        #expect(await session.currentLedgerSpec == nil, "nothing built yet")
        try await session.prebuildLedger()
        #expect(await session.currentLedgerSpec != nil, "the prebuilt store is installed")
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        // 12 m² + 2 m² = 14 m².
        #expect(environment.ledger.grandTotals.total("planArea")?.value == 14)
    }
}

/// The stamp and body of a live summary caption, as the session writes them.
enum LiveSummaryBodies {
    static func body(_ caption: String) -> String? { TakeoffSession.body(ofCaption: caption) }
    static func stamp(_ date: Date) -> String {
        TakeoffSession.stamping("", at: date, localeIdentifier: "en_US_POSIX").trimmingCharacters(in: .newlines)
    }
}
