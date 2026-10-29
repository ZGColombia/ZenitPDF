import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFPersistence

/// Save and reopen (R-046, R-047, R-050, R-066, K-06).
@Suite("Iteration 1 — archive")
struct Iter1AppCoreArchiveTests {

    static let stamp = Date(timeIntervalSince1970: 1_790_000_000)

    static func workspace(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-it1-appcore-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func line(on page: ZPDFContracts.PageDescriptor, from: Double, to: Double, y: Double = 0) -> ZPDFContracts.MarkupRecord {
        ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: page.documentID, pageID: page.id, kind: .measurement, tool: .length,
            subject: "Wall", author: "t",
            geometry: MeasurementGeometry(pageID: page.id, points: [PDFPoint(x: from, y: y), PDFPoint(x: to, y: y)]),
            createdAt: stamp, modifiedAt: stamp
        )
    }

    static func rectangle(on page: ZPDFContracts.PageDescriptor, subject: String, width: Double, height: Double) -> ZPDFContracts.MarkupRecord {
        ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: page.documentID, pageID: page.id, kind: .measurement, tool: .area,
            subject: subject, author: "t",
            geometry: MeasurementGeometry(pageID: page.id, polygons: [PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: 0, y: 0), PDFPoint(x: width, y: 0), PDFPoint(x: width, y: height), PDFPoint(x: 0, y: height)
            ], isClosed: true))]),
            createdAt: stamp, modifiedAt: stamp
        )
    }

    /// Writes `session` into a new package, closes it, reopens it and hydrates a fresh session the
    /// way the open path does: adopted page ids, columns, markups, then the arrangement.
    static func reopen(_ session: TakeoffSession, fixture: OpenedFixture, in directory: URL) async throws -> TakeoffSession {
        let url = directory.appendingPathComponent("Reopen.zpdfproj", isDirectory: true)
        let package = try await ProjectPackage.create(at: url, displayName: "Reopen", originalPDF: fixture.url)
        try await TakeoffArchive.write(await session.takeoffState(), into: package)
        _ = try await package.save()
        try await package.close()
        guard case .opened(let reopened) = try await ProjectPackage.open(at: url) else {
            throw ZPDFPersistenceError.packageMalformed(reason: "reopen required recovery")
        }
        let stored = try #require(try await TakeoffArchive.read(from: reopened))
        try await reopened.close()
        let fresh = fixture.pages.map { page -> ZPDFContracts.PageDescriptor in
            var copy = page; copy.id = PageID(UUID()); return copy
        }
        let pages = TakeoffArchive.adoptingStoredPageIDs(fresh, stored: stored)
        let restored = try TakeoffSession(documentID: fixture.documentID, pages: pages, units: .metric)
        _ = await restored.restoreCustomColumns(stored.customColumns)
        _ = try await restored.hydrate(
            markups: stored.markups, scales: stored.scales, pageScaleIDs: stored.pageScaleIDs,
            calibrationEvidence: stored.calibrationEvidence, scaleRegions: stored.scaleRegions,
            projectZones: stored.projectZones
        )
        await restored.restoreArrangement(excluded: stored.excludedPageIDs, views: stored.pageViews)
        return restored
    }

    // MARK: R-046

    /// 100 pt = 10 m (0.1 m/pt): the 50 pt line is 5 m. Recalibrated with Keep to 100 pt = 20 m it
    /// stays 5 m, at scale version 1, flagged stale. Old output after write/read/hydrate: 10 m
    /// (re-measured under version 2, 50 × 0.2) with no stale flag, because the archive read every
    /// markup back with `measurement: nil`.
    @Test("A value kept under an older scale survives save and reopen")
    func keptValueSurvivesTheArchive() async throws {
        let directory = try Self.workspace("kept")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try await OpenedFixture.open(.titleBlockSheet, in: directory)
        let page = fixture.firstPage
        let session = try TakeoffSession(documentID: fixture.documentID, pages: fixture.pages, units: .metric)
        _ = try await session.calibrate(page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
                                        knownLength: 10, knownLengthUnit: .metre)
        let line = Self.line(on: page, from: 0, to: 50)
        _ = try await session.apply(.addMarkup(line))
        #expect(await session.markup(line.id)?.measurement?[.planLength]?.value == 5)
        _ = try await session.calibrate(page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
                                        knownLength: 20, knownLengthUnit: .metre, keepExisting: true)
        // A second line drawn after the change measures at the new scale: 50 pt × 0.2 = 10 m.
        let fresh = Self.line(on: page, from: 0, to: 50, y: 20)
        _ = try await session.apply(.addMarkup(fresh))

        let restored = try await Self.reopen(session, fixture: fixture, in: directory)
        let kept = try #require(await restored.markup(line.id))
        #expect(kept.measurement?[.planLength]?.value == 5, "the kept 5 m, not 10 m")
        #expect(kept.scaleVersion == 1)
        #expect(kept.measurement?.hasWarning(.staleScaleVersion) == true)
        #expect(await restored.staleMeasurementIDs == [line.id])
        #expect(await restored.markup(fresh.id)?.measurement?[.planLength]?.value == 10)
        // Recalculate Stale still brings it current after the reopen: 10 m.
        _ = try await restored.apply(.recalculateMeasurements(pageID: nil))
        #expect(await restored.markup(line.id)?.measurement?[.planLength]?.value == 10)
    }

    /// An auto-traced capture kept under the old scale. Old output after the reopen: an empty
    /// values map (the capture stamp passed `keepsStoredValue`, recompute was skipped) and no
    /// stale flag.
    @Test("A kept detector capture reopens with its value and its capture method")
    func keptCaptureSurvivesTheArchive() async throws {
        let directory = try Self.workspace("kept-capture")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try await OpenedFixture.open(.titleBlockSheet, in: directory)
        let page = fixture.firstPage
        let session = try TakeoffSession(documentID: fixture.documentID, pages: fixture.pages, units: .metric)
        _ = try await session.calibrate(page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
                                        knownLength: 10, knownLengthUnit: .metre)
        // 40 × 30 pt at 0.1 m/pt = 4 m × 3 m = 12 m².
        let traced = CaptureStamp.stamped(Self.rectangle(on: page, subject: "Slab", width: 40, height: 30),
                                          method: .autoTraced(closureWidthsPoints: [25.4]))
        _ = try await session.apply(.addMarkup(traced))
        #expect(await session.markup(traced.id)?.measurement?[.planArea]?.value == 12)
        _ = try await session.calibrate(page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
                                        knownLength: 20, knownLengthUnit: .metre, keepExisting: true)

        let restored = try await Self.reopen(session, fixture: fixture, in: directory)
        let kept = try #require(await restored.markup(traced.id))
        #expect(kept.measurement?[.planArea]?.value == 12, "12 m² kept, not empty and not 48 m²")
        #expect(kept.measurement?.hasWarning(.staleScaleVersion) == true)
        #expect(kept.measurement?.provenance?.captureMethod?.kind == .autoTraced)
        #expect(await restored.staleMeasurementIDs == [traced.id])
    }

    @Test("A capture stamp alone never passes as a kept value")
    func captureStampIsNotKept() async throws {
        let page = ZPDFContracts.PageDescriptor(id: PageID(UUID()), documentID: DocumentID(UUID()), index: 0, label: "A",
                                                boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 1000, height: 1000)))
        let session = try TakeoffSession(documentID: page.documentID, pages: [page], units: .metric)
        _ = try await session.calibrate(page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
                                        knownLength: 10, knownLengthUnit: .metre)
        _ = try await session.calibrate(page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
                                        knownLength: 20, knownLengthUnit: .metre)
        let scale = try #require(await session.pageScale(page.id))
        #expect(scale.version == 2)
        var record = Self.line(on: page, from: 0, to: 50)
        record.scaleID = scale.id
        record.scaleVersion = 1
        let stub = CaptureStamp.stamped(record, method: .autoTraced(closureWidthsPoints: []))
        // Old output: true — empty values, current formula version, older scale version.
        #expect(await session.keepsStoredValue(stub) == false)
    }

    // MARK: R-047

    /// Sheet 1: Slab 40 × 30 pt at 0.1 m/pt = 12 m². Sheet 2: Slab 20 × 10 pt = 2 m², then removed
    /// from the set. The open ledger bills 12 m². Old output of the batch summary: 14 m².
    @Test("The summary across closed projects leaves out a sheet removed from the set")
    @MainActor
    func batchSummarySkipsRemovedSheets() async throws {
        let directory = try Self.workspace("batch-removed")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try await OpenedFixture.open(.set30SheetsTitleBlocks, in: directory)
        let url = directory.appendingPathComponent("Removed.zpdfproj", isDirectory: true)
        let package = try await ProjectPackage.create(at: url, displayName: "Removed", originalPDF: fixture.url)
        let session = try TakeoffSession(documentID: fixture.documentID, pages: fixture.pages, units: .metric)
        for (page, width, height) in [(fixture.pages[0], 40.0, 30.0), (fixture.pages[1], 20.0, 10.0)] {
            _ = try await session.calibrate(page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
                                            knownLength: 10, knownLengthUnit: .metre)
            _ = try await session.apply(.addMarkup(Self.rectangle(on: page, subject: "Slab", width: width, height: height)))
        }
        _ = try await session.apply(.setPagesExcluded([fixture.pages[1].id], excluded: true))
        let openTotals = try await session.subjectTotals()
        #expect(openTotals.map(\.quantity.value) == [12], "the open ledger bills the live sheet only")
        try await TakeoffArchive.write(await session.takeoffState(), into: package)
        try await package.close()

        let outcome = await ProjectBatchSummary.summarise([url], units: .metric, localeIdentifier: "en_US_POSIX")
        #expect(outcome.refused.isEmpty)
        #expect(outcome.drawings.first?.totals.map(\.quantity.value) == [12])
        #expect(outcome.combined.map(\.quantity.value) == [12])
    }

    // MARK: R-050 and R-066

    /// A two-drawing set; the second drawing's PDF lost its sheet 2 (index 1) before the reopen.
    /// The markup on that sheet is held, and the save must keep it. Old output: the second read
    /// of drawing B had no such markup — `writeSet` gave held IDs to the first drawing only, and
    /// B's `write` deleted the row.
    @Test("Saving a set keeps the held markups of every drawing, not only the first")
    func heldMarkupsOfEveryDrawingSurvive() async throws {
        let directory = try Self.workspace("held-set")
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = try await OpenedFixture.open(.titleBlockSheet, in: directory.appendingPathComponent("a"))
        let b = try await OpenedFixture.open(.mixedPageSizes, in: directory.appendingPathComponent("b"))
        #expect(b.pages.count >= 3)
        let url = directory.appendingPathComponent("Set.zpdfproj", isDirectory: true)
        let package = try await ProjectPackage.create(at: url, displayName: "Set", originalPDF: a.url)
        let rowA = try await TakeoffArchive.documentRows(of: package)[0]
        let rowB = try await package.addDocument(originalPDF: b.url, displayName: "B", pageCount: b.pages.count)
        let session = try TakeoffSession(documentID: a.documentID, pages: a.pages + b.pages, units: .metric)
        let onA = Self.line(on: a.pages[0], from: 0, to: 10)
        let onLostSheet = Self.line(on: b.pages[1], from: 0, to: 20)
        let onKeptSheet = Self.line(on: b.pages[0], from: 0, to: 30)
        for record in [onA, onLostSheet, onKeptSheet] { _ = try await session.apply(.addMarkup(record)) }
        let rows = [a.documentID: rowA, b.documentID: rowB]
        try await TakeoffArchive.writeSet(await session.takeoffState(), into: package, documentRows: rows)
        _ = try await package.save()
        try await package.close()

        guard case .opened(let reopened) = try await ProjectPackage.open(at: url) else {
            Issue.record("reopen required recovery"); return
        }
        let stored = try await TakeoffArchive.readSet(from: reopened)
        func fresh(_ pages: [ZPDFContracts.PageDescriptor]) -> [ZPDFContracts.PageDescriptor] {
            pages.map { var page = $0; page.id = PageID(UUID()); return page }
        }
        // B's PDF no longer has index 1.
        let bWithoutSheet2 = fresh(b.pages).filter { $0.index != 1 }
        let adopted = TakeoffArchive.adoptingStoredSet([(rowA, fresh(a.pages)), (rowB, bWithoutSheet2)], stored: stored)
        let takeoff = try #require(adopted.takeoff)
        let restored = try TakeoffSession(documentID: a.documentID, pages: adopted.pages, units: .metric)
        _ = try await restored.hydrate(markups: takeoff.markups, scales: takeoff.scales, pageScaleIDs: takeoff.pageScaleIDs)
        #expect(await restored.refusedMarkupIDs == [onLostSheet.id], "the markup on the lost sheet is held")

        try await TakeoffArchive.writeSet(await restored.takeoffState(), into: reopened, documentRows: rows)
        _ = try await reopened.save()
        try await reopened.close()
        guard case .opened(let again) = try await ProjectPackage.open(at: url) else {
            Issue.record("second reopen required recovery"); return
        }
        let second = try #require(try await TakeoffArchive.read(from: again, documentId: rowB))
        try await again.close()
        #expect(Set(second.markups.map(\.id)) == [onLostSheet.id, onKeptSheet.id], "the held markup survived the save")
    }

    /// Old output: the reason read "page \(page.id.rawValue) belongs …" literally.
    @Test("A set page from a drawing the project does not hold is refused by its id")
    func writeSetRefusalNamesThePage() async throws {
        let directory = try Self.workspace("refusal")
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = try await OpenedFixture.open(.titleBlockSheet, in: directory)
        let package = try await ProjectPackage.create(
            at: directory.appendingPathComponent("Refuse.zpdfproj", isDirectory: true), displayName: "Refuse", originalPDF: a.url
        )
        let session = try TakeoffSession(documentID: a.documentID, pages: a.pages, units: .metric)
        var refusal: String?
        do {
            try await TakeoffArchive.writeSet(await session.takeoffState(), into: package, documentRows: [:])
        } catch ZPDFPersistenceError.packageMalformed(let reason) {
            refusal = reason
        }
        try await package.close()
        let reason = try #require(refusal, "a page of an unknown drawing was written")
        #expect(reason.contains(a.pages[0].id.rawValue.uuidString), "names the page: \(reason)")
        #expect(!reason.contains("\\("), "no literal interpolation: \(reason)")
    }

    // MARK: K-06

    /// ROUND2_FOLLOWUPS platform: a sheet removed from the set must not drop the project's layer
    /// list, active layer or display units from the save (the fold used to build a fresh state
    /// without them).
    @Test("Removing a sheet keeps the layers, the active layer and the units through fold, save and reopen")
    func removedSheetKeepsProjectSettings() async throws {
        let directory = try Self.workspace("fold")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try await OpenedFixture.open(.set30SheetsTitleBlocks, in: directory)
        let session = try TakeoffSession(documentID: fixture.documentID, pages: fixture.pages, units: .metric)
        let walls = MarkupLayer(id: LayerID(UUID()), name: "Walls", order: 0)
        _ = try await session.apply(.setMarkupLayers(try await session.markupLayerList.adding(walls).layers, change: .add))
        await session.setActiveMarkupLayer(walls.id)
        try await session.setUnits(.imperial)
        _ = try await session.apply(.addMarkup(Self.line(on: fixture.pages[2], from: 0, to: 10)))
        _ = try await session.apply(.setPagesExcluded([fixture.pages[2].id], excluded: true))
        let layers = await session.markupLayers

        let state = await session.takeoffState()
        #expect(!state.excludedPages.isEmpty && !state.setAsideMarkups.isEmpty, "the fold has work to do")
        let folded = state.foldingArrangement()
        #expect(folded.markupLayers == layers)
        #expect(folded.activeMarkupLayerID == walls.id)
        #expect(folded.displayUnits == .imperial)
        #expect(folded.excludedPageIDs == [fixture.pages[2].id])

        let package = try await ProjectPackage.create(
            at: directory.appendingPathComponent("Fold.zpdfproj", isDirectory: true), displayName: "Fold", originalPDF: fixture.url
        )
        try await TakeoffArchive.write(state, into: package)
        let read = try #require(try await TakeoffArchive.read(from: package))
        try await package.close()
        #expect(read.markupLayers == layers)
        #expect(read.activeMarkupLayerID == walls.id)
        #expect(read.displayUnits == .imperial)
        #expect(read.excludedPageIDs == [fixture.pages[2].id])
        #expect(read.markups.count == 1, "the set-aside markup is written with its removed sheet")
    }
}
