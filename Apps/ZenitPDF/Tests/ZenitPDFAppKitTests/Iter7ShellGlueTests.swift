import AppKit
import CoreGraphics
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFExport
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// Loop iteration 7 (cycle 2), area app-shell-glue: X-011 … X-017. Every test states the old
/// output it fails with. Headless throughout: no window is ordered front, every modal is
/// answered by injection, and every store and fixture is a temporary one.
/// Hand-derived values: every sheet is calibrated 100 pt = 1 m.
@MainActor
@Suite("Iteration 7 — app shell glue", .appTierSerialised, .serialized)
struct Iter7ShellGlueTests {

    // MARK: - Helpers

    /// A saved project opened the way Finder opens it: no window, its own load.
    static func open(_ url: URL) async throws -> ZenitPDFProjectDocument {
        let document = ZenitPDFProjectDocument()
        try document.read(from: url, ofType: ZenitAppInfo.projectTypeIdentifier)
        document.startLoadingIfNeeded()
        #expect(await AppTestSupport.wait(upTo: 30) { document.core != nil && document.drawingSet != nil })
        return document
    }

    /// A calibrated length of `points` on `page` (100 pt = 1 m), through the command bus.
    static func measure(_ core: AppCoreEnvironment, on page: ZPDFContracts.PageDescriptor, points: Double, subject: String = "Wall") async throws -> MarkupRecord {
        try await Iter6ShellGlueTests.calibrate(core, page: page.id)
        let record = Iter6ShellGlueTests.length(on: page, points: points, subject: subject)
        _ = try await core.commands.perform(.addMarkup(record))
        await core.commands.settle()
        return record
    }

    /// Waits until the canvas of `core` shows `page`.
    static func show(_ core: AppCoreEnvironment, _ page: PageID) async -> Bool {
        core.document.goToPage(id: page.rawValue)
        return await AppTestSupport.wait { core.canvas.viewport.pageID == page.rawValue }
    }

    // MARK: - X-011

    @Test("X-011: after Save As, a drawing added to the project saves — ⌘S and every later save — and every drawing's markups reopen")
    func saveAsThenAddDrawingKeepsSaving() async throws {
        let harness = try await Fix2Harness.make("X011 A.pdf", calibrate: false)
        let directory = harness.directory
        defer { try? FileManager.default.removeItem(at: directory) }
        let b = try AppTestSupport.writeFixturePDF(named: "X011 B.pdf")
        let c = try AppTestSupport.writeFixturePDF(named: "X011 C.pdf")
        defer {
            try? FileManager.default.removeItem(at: b.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: c.deletingLastPathComponent())
        }
        let aPage = try #require(harness.document.drawing?.pages.first)
        _ = try await Self.measure(harness.core, on: aPage, points: 100)
        let first = try await Iter1ShellGlueTests.saveAsProject(harness, name: "X011 First.zpdfproj")
        harness.controller.window?.close()
        harness.document.close()

        // Opened from disk: every member's row is the first package's (the stale-row case;
        // a Quick PDF promoted in this session has no row yet, and was repaired before).
        let document = try await Self.open(first)
        let firstRow = try #require(document.drawingSet?.primary.row)

        // A project of one drawing, saved as, then extended.
        let second = directory.appendingPathComponent("X011 Second.zpdfproj")
        try await Iter1ShellGlueTests.save(document, to: second, .saveAsOperation)
        let secondPackage = try #require(document.projectPackage)
        let secondRow = try #require(try await TakeoffArchive.drawingRows(of: secondPackage).first(where: \.isPrimary)?.id)
        #expect(secondRow != firstRow, "Save As mints the new package's own document row")
        #expect(document.drawingSet?.primary.row == secondRow, "old: the first package's row, kept after the Save As")
        #expect(await document.addDrawingToSet(fileAt: b, at: 1))
        let core = try #require(document.core)
        let bPage = try #require(document.drawingSet?.members.last?.drawing.pages.first)
        _ = try await Self.measure(core, on: bPage, points: 200)
        // Old: throws — the set's rows named the first package's primary row, which the second
        // package does not hold, and the `document_set_entry` foreign key refused the write.
        try await Iter1ShellGlueTests.save(document, to: second, .saveOperation)
        try await Iter1ShellGlueTests.save(document, to: second, .saveOperation)

        // A project of two drawings, saved as, then extended again.
        let third = directory.appendingPathComponent("X011 Third.zpdfproj")
        try await Iter1ShellGlueTests.save(document, to: third, .saveAsOperation)
        #expect(await document.addDrawingToSet(fileAt: c, at: 2))
        let cPage = try #require(document.drawingSet?.members.last?.drawing.pages.first)
        _ = try await Self.measure(core, on: cPage, points: 300)
        // Old: throws — the map for the third package was rebuilt from the members' rows, the
        // second package's, so the primary and B rows were ones the third did not hold.
        try await Iter1ShellGlueTests.save(document, to: third, .saveOperation)
        let thirdPackage = try #require(document.projectPackage)
        let thirdRows = Set(try await TakeoffArchive.drawingRows(of: thirdPackage).map(\.id))
        #expect(Set(document.drawingSet?.members.compactMap(\.row) ?? []) == thirdRows, "every member's row is the package's being written")
        document.close()

        // Both projects reopen with every drawing and every markup: 1 + 2 = 3 m, then + 3 = 6 m.
        for (url, drawings, metres) in [(second, 2, Decimal(3)), (third, 3, Decimal(6))] {
            let reopened = try await Self.open(url)
            defer { reopened.close() }
            let reopenedCore = try #require(reopened.core)
            #expect(reopened.drawingSet?.members.count == drawings, "\(url.lastPathComponent)")
            await reopenedCore.refresh()
            #expect(reopenedCore.ledger.grandTotals.total("planLength")?.value == metres, "\(url.lastPathComponent)")
            #expect(await reopenedCore.session.orderedMarkups.count == drawings)
            #expect(await reopenedCore.session.refusedMarkupIDs.isEmpty)
        }
    }

    // MARK: - X-012

    @Test("X-012: Revision Compare Accept clouds the compared sheet by identity in a rearranged set, and refuses in words")
    func acceptCloudsTheComparedSheet() async throws {
        let harness = try await Fix2Harness.make("X012.pdf", pageCount: 3, calibrate: false)
        defer { harness.tearDown() }
        let core = harness.core
        let pdf = try #require(harness.document.drawing?.pages)
        // A3 moved first: the set reads A3 A1 A2, every sheet keeping its PDF index.
        _ = try await core.commands.perform(.reorderPage(from: 2, to: 0))
        await core.commands.settle()
        await core.refresh()
        #expect(core.snapshot.pages.map(\.id) == [pdf[2], pdf[0], pdf[1]].map(\.id.rawValue))

        #expect(try await harness.document.registerCurrentDrawingAsBaseline())
        let baselineID = try #require(harness.document.comparePresenter?.baselineRevisionID)
        var reference = try #require(harness.document.revisionPages[baselineID])
        let diff = CompareDiffSummary(
            id: UUID(), changeKind: .added, pageLabel: "Rev B",
            baselineBounds: PDFRectValue(x: 120, y: 200, width: 80, height: 40),
            comparisonBounds: PDFRectValue(x: 120, y: 200, width: 80, height: 40),
            areaInSquarePoints: 3200, confidence: 0.9, isAccepted: false
        )
        func promoted(after count: Int) async -> MarkupSummary? {
            guard await AppTestSupport.wait(upTo: 5, for: { core.snapshot.markups.count == count + 1 }) else { return nil }
            return core.snapshot.markups.last
        }

        // The baseline compared on A3 (PDF index 2).
        reference.pageIndex = 2
        harness.document.revisionPages[baselineID] = reference
        var before = core.snapshot.markups.count
        harness.document.promoteCompareDifference(diff)
        let onA3 = try #require(await promoted(after: before))
        // Old: snapshot.pages[2] — A2, at A3's coordinates.
        #expect(onA3.pageID == pdf[2].id.rawValue)
        #expect(onA3.kind == .revisionCloud)

        // No baseline reference: the sheet on screen, A2 (PDF index 1, set position 2).
        harness.document.revisionPages[baselineID] = nil
        #expect(await Self.show(core, pdf[1].id))
        before = core.snapshot.markups.count
        harness.document.promoteCompareDifference(diff)
        let onA2 = try #require(await promoted(after: before))
        // Old: snapshot.pages[1] — A1.
        #expect(onA2.pageID == pdf[1].id.rawValue)

        // A baseline index no sheet of the drawing has: refused in words, nothing added.
        reference.pageIndex = 7
        harness.document.revisionPages[baselineID] = reference
        before = core.snapshot.markups.count
        harness.document.promoteCompareDifference(diff)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(core.snapshot.markups.count == before)
        #expect(core.status.snapshot.activeToolNote == "The difference was not marked: its sheet is not in this project's set.")
    }

    // MARK: - X-013

    @Test("X-013: the ledger CSV guards text starting with '-', whatever follows, and leaves a rendered negative number alone")
    func ledgerCSVGuardsByCellKind() async throws {
        let harness = try await Fix2Harness.make("X013.pdf")
        defer { harness.tearDown() }
        let core = harness.core
        let column = ZPDFContracts.LedgerColumnDefinition(
            id: ColumnID(UUID()), key: "custom.x013-adjust", title: "Adjust", kind: .number,
            dimension: .count, precision: .decimalPlaces(0), order: 100
        )
        try await core.session.addCustomColumns([column])
        let page = try #require(harness.document.drawing?.pages.first)
        let payload = "-2+3+cmd|' /C calc'!A0"
        let record = Iter6ShellGlueTests.length(on: page, points: 100, subject: payload)
        _ = try await core.commands.perform(.addMarkup(record))
        _ = try await core.commands.perform(.editCustomValue(
            id: record.id, column: column.id, value: .number(ZPDFContracts.DecimalQuantity(value: -3, dimension: .count))
        ))
        await core.commands.settle()
        await core.refresh()

        // Split on `;`, which no cell here holds, so a decimal comma needs no quoting.
        let csv = LedgerCSVExport.render(presenter: core.ledger, delimiter: ";")
        let lines = csv.components(separatedBy: "\r\n")
        let header = lines[0].components(separatedBy: ";")
        let row = try #require(lines.first { $0.contains("cmd|") })
        // Old: written bare — "-2+3+cmd|' /C calc'!A0" — and evaluated by a spreadsheet.
        #expect(row.contains("'" + payload), "\(row)")
        #expect(!row.contains(";" + payload) && !row.hasPrefix(payload), "\(row)")
        // The rendered number is written as the ledger shows it, with no apostrophe.
        let adjust = try #require(header.firstIndex(of: "Adjust"))
        let shown = try #require(core.ledger.row(at: 0)?.displayValue(LedgerColumnID(column.key)))
        #expect(shown.hasPrefix("-") || shown.hasPrefix("\u{2212}"), "precondition: a negative display, \(shown)")
        #expect(row.components(separatedBy: ";")[adjust] == shown, "\(row)")

        // The rule itself, which the audit trail, review report, set compare and batch report
        // share. Old: "-2+3…" and "-0+HYPERLINK(…)" passed because a digit followed the minus.
        #expect(LedgerCSVExport.field(payload) == "'" + payload)
        #expect(LedgerCSVExport.field("-0+HYPERLINK(\"x\")").hasPrefix("\"'-0+HYPERLINK"))
        #expect(LedgerCSVExport.field("\r\n=1+1").hasPrefix("\"'\r\n"), "a CRLF first character is guarded too")
        #expect(LedgerCSVExport.field("-3,2 m", delimiter: ";", isNumber: true) == "-3,2 m")
        #expect(LedgerCSVExport.isNumber(.quantity(ZPDFUIPresentation.DecimalQuantity(value: -1, dimension: .length))))
        #expect(!LedgerCSVExport.isNumber(.text("-1")))
    }

    // MARK: - X-014

    @Test("X-014: Find Repeated Sheets names the measurements already on the other sheets, defaults to Not Now, and multiplies a repetition already set")
    func repeatedSheetsRespectsExistingWork() async throws {
        let plan = "0.5 w 0 0 0 RG 100 100 m 900 100 l 900 600 l 100 600 l h S 500 100 m 500 600 l S"
        let other = "0.5 w 0 0 0 RG 100 100 m 900 100 l 900 600 l 100 600 l h S 300 100 m 300 600 l S 100 350 m 300 350 l S"
        let url = try AutomationFixtures.writePages(named: "X014 Storeys.pdf", mediaBox: "0 0 1000 700", contents: [plan, other, plan])
        let harness = try await Fix2Harness.make("X014 Storeys.pdf", fixture: url)
        defer { harness.tearDown() }
        let core = harness.core
        let pages = try #require(harness.document.drawing?.pages)
        // A floor on sheet 1, already ×2 (a mirrored unit), and a wall already measured on sheet 3.
        let floor = MarkupRecord(
            id: MarkupID(UUID()), documentID: pages[0].documentID, pageID: pages[0].id, kind: .measurement, tool: .area,
            subject: "Floor", geometry: MeasurementGeometry(pageID: pages[0].id, polygons: [PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: 100, y: 100), PDFPoint(x: 500, y: 100), PDFPoint(x: 500, y: 600), PDFPoint(x: 100, y: 600)], isClosed: true))]),
            createdAt: Date(timeIntervalSince1970: 1_790_000_000), modifiedAt: Date(timeIntervalSince1970: 1_790_000_000))
        _ = try await core.commands.perform(.addMarkup(floor))
        _ = try await core.commands.perform(RepetitionColumn.edit(markupID: floor.id, count: 2))
        _ = try await Self.measure(core, on: pages[2], points: 400)

        let previous = ProjectWindowController.repeatedSheetsDecision
        defer { ProjectWindowController.repeatedSheetsDecision = previous }
        var asked: [ProjectWindowController.RepeatedSheetsPrompt] = []
        ProjectWindowController.repeatedSheetsDecision = { prompt, _ in asked.append(prompt); return true }
        let groups = await harness.controller.runRepeatedSheets(for: harness.document)
        #expect(groups.map(\.pageIDs) == [[pages[0].id, pages[2].id]])
        let prompt = try #require(asked.first)
        // Old: the decision was told the first sheet's count only.
        #expect(prompt.measurementCount == 1)
        #expect(prompt.measuredElsewhere == 1)
        #expect(prompt.alreadyRepeated == 1)
        #expect(prompt.needsCare)

        // ×2 on a floor that repeats on two sheets counts ×4. Old: ×2 — the ×2 replaced by ×N.
        let applied = try #require(await core.session.orderedMarkups.first { $0.id == floor.id })
        #expect(RepetitionColumn.count(of: applied) == 4)
        #expect(ProjectWindowController.repeatedCount(3, times: 5_000) == RepetitionColumn.maximumCount)
        #expect(ProjectWindowController.repeatedCount(Int.max, times: 2) == RepetitionColumn.maximumCount)

        // The prompt says both, and Return is Not Now. Old: neither sentence; Return applied.
        let alert = ProjectWindowController.repeatedSheetsAlert(prompt)
        #expect(alert.informativeText.contains("Already measured on the other sheets: 1. Applying ×2 would count those sheets twice."), "\(alert.informativeText)")
        #expect(alert.informativeText.contains(": 1. Applying multiplies their Repeat × by 2."), "\(alert.informativeText)")
        #expect(alert.buttons.map(\.keyEquivalent) == ["", "\r"])
        // Nothing measured elsewhere and nothing repeating: Return applies, as before.
        let plain = ProjectWindowController.repeatedSheetsAlert(.init(group: prompt.group, measurementCount: 1))
        #expect(plain.buttons.first?.keyEquivalent == "\r")
        #expect(!plain.informativeText.contains("Already"))
    }

    // MARK: - X-016

    @Test("X-016: Revision Overlay stacks nothing on a sheet of an added drawing, says so once, and pairs the primary's sheets by identity")
    func overlayFollowsThePrimaryDrawingOnly() async throws {
        let harness = try await Fix2Harness.make("X016 A.pdf", pageCount: 2, calibrate: false)
        defer { harness.tearDown() }
        let addedPDF = try AppTestSupport.writeFixturePDF(named: "X016 B.pdf", pageCount: 2)
        defer { try? FileManager.default.removeItem(at: addedPDF.deletingLastPathComponent()) }
        let (_, added) = try await Iter6ShellGlueTests.twoDrawings(harness, added: addedPDF, project: "X016.zpdfproj")
        let primary = try #require(harness.document.drawing)
        #expect(try await harness.document.registerCurrentDrawingAsBaseline())
        let baselineID = try #require(harness.document.comparePresenter?.baselineRevisionID)
        let warningID = ZenitPDFProjectDocument.revisionPairingWarningID("primary-drawing-only")

        // Sheet 2 of the added drawing (PDF index 1).
        #expect(await Self.show(harness.core, added.pages[1].id))
        // Old: [baseline: page 1] — the primary's sheet 2 stacked over the added sheet.
        #expect(harness.document.labelPairedOverlayPages(for: harness.core, postsWarnings: false).isEmpty)
        #expect(!harness.core.document.warnings.contains { $0.id == warningID }, "a count posts nothing")
        #expect(harness.document.labelPairedOverlayPages(for: harness.core).isEmpty)
        #expect(harness.core.document.warnings.filter { $0.id == warningID }.count == 1)
        _ = harness.document.labelPairedOverlayPages(for: harness.core)
        #expect(harness.core.document.warnings.filter { $0.id == warningID }.count == 1, "said once")

        // The primary's sheet 2: the baseline follows it.
        #expect(await Self.show(harness.core, primary.pages[1].id))
        #expect(harness.document.labelPairedOverlayPages(for: harness.core)[baselineID]?.pageIndex == 1)
    }

    // MARK: - X-017

    @Test("X-017 (BH-381 on the shipping path): a straight horizontal length's exported annotation has a /Rect padded beyond its stroke")
    func exportedLineRectIsPadded() async throws {
        let harness = try await Fix2Harness.make("X017.pdf")
        defer { harness.tearDown() }
        let page = try #require(harness.document.drawing?.pages.first)
        let record = try await Self.measure(harness.core, on: page, points: 300)   // y = 100, x 100 → 400
        await harness.core.refresh()
        let job = try await StandardAnnotationExport.job(for: harness.document)
        let output = harness.directory.appendingPathComponent("X017 annotated.pdf")
        _ = try await StandardAnnotationExport.write(job, to: output)
        let rect = try #require(Self.annotationRect(in: try Data(contentsOf: output), named: record.id.rawValue.uuidString))
        // The helper this replaced was test-only; the writer pads by 2 pt plus the stroke width.
        #expect(rect.minY < 98 && rect.maxY > 102, "\(rect)")
        #expect(rect.minX < 98 && rect.maxX > 402, "\(rect)")
    }

    /// The `/Rect` of the annotation on page 1 whose `/NM` is `name`.
    static func annotationRect(in data: Data, named name: String) -> CGRect? {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              let dictionary = document.page(at: 1)?.dictionary else { return nil }
        var annotations: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, "Annots", &annotations), let annotations else { return nil }
        for position in 0..<CGPDFArrayGetCount(annotations) {
            var annotation: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(annotations, position, &annotation), let annotation else { continue }
            var nm: CGPDFStringRef?
            guard CGPDFDictionaryGetString(annotation, "NM", &nm), let nm,
                  (CGPDFStringCopyTextString(nm) as String?) == name else { continue }
            var array: CGPDFArrayRef?
            guard CGPDFDictionaryGetArray(annotation, "Rect", &array), let array, CGPDFArrayGetCount(array) == 4 else { return nil }
            var values: [CGFloat] = []
            for index in 0..<4 {
                var value: CGPDFReal = 0
                guard CGPDFArrayGetNumber(array, index, &value) else { return nil }
                values.append(value)
            }
            return CGRect(x: min(values[0], values[2]), y: min(values[1], values[3]),
                          width: abs(values[2] - values[0]), height: abs(values[3] - values[1]))
        }
        return nil
    }
}
