import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFPersistence
import ZPDFUIPresentation

/// Stamps and the scoped batch apply, driven through the shipping
/// environment, the shipping command bus and the shipping audit presenter. Nothing here
/// substitutes a double for any of the three: the claims are about exactly those.
///
/// | Rule | Test |
/// |---|---|
/// | Fields resolve at placement and freeze | ``resolvedFieldsAreFrozenForever()`` |
/// | Vector stays vector; raster is marked as such | ``rasterArtworkIsMarkedAndVectorIsNot()`` |
/// | The audit records template *and* resolved values | ``auditNoteCarriesTemplateAndResolvedValues()`` |
/// | Scope is previewed before anything happens | ``scopePreviewCountsBeforeAnythingHappens()`` |
/// | Anchored per page, not absolute | ``anchoringIsPerPageOnAMixedSizeSet()`` |
/// | **312 placed, one undo, zero remain, one audit group** | ``threeHundredAndTwelveStampsUndoAsOne()`` |
/// | Cancelling leaves all or none | ``cancellingLeavesNothingBehind()`` |
/// | Skip pages that already carry it, and report it | ``skipRuleReportsWhatItSkipped()`` |
/// | Range, size and search scopes | ``scopesSelectTheRightPages()`` |
/// | A stamp survives save and reopen saying the same thing | ``aStampSurvivesSaveAndReopen()`` |
@Suite("Stamps and scoped batch apply")
struct StampAndBatchApplyTests {

    // MARK: Fixtures

    /// 2026-08-25T09:00:00Z, fixed. Every date assertion below is against this instant, so
    /// no test in this file can pass or fail because of the day it ran on.
    static let placementInstant = Date(timeIntervalSince1970: 1_787_648_400)

    /// A stamp template with all seven dynamic field kinds, so the freezing rule is proved
    /// over the whole set rather than over the one field that happens to be easy.
    static func template(
        id: UUID,
        artwork: StampArtworkDescriptor? = nil,
        revision: Int = 1
    ) -> StampTemplate {
        StampTemplate(
            id: id,
            revision: revision,
            widthPoints: 160,
            heightPoints: 60,
            artwork: artwork,
            fields: StampFieldKind.allCases.enumerated().map { index, kind in
                StampFieldDefinition(
                    kind: kind,
                    prompt: kind == .freeText ? "Note" : "",
                    dateFormat: kind == .date ? "yyyy-MM-dd" : "",
                    normalizedFrame: PDFRectValue(
                        x: 0.05, y: 0.9 - Double(index) * 0.12, width: 0.9, height: 0.1
                    )
                )
            }
        )
    }

    static func preset(
        id: UUID = UUID(),
        name: String = "Reviewed",
        stamp: StampTemplate?
    ) -> ToolPresetSummary {
        ToolPresetSummary(
            id: id,
            name: name,
            category: "Review",
            panel: .myTools,
            markupKind: .stamp,
            colorRGBA: ColorRGBA(red: 0.8, green: 0.1, blue: 0.1),
            defaultSubject: "Review",
            stamp: stamp
        )
    }

    /// `count` pages that are deliberately **not** all the same size: every third sheet is
    /// A3 landscape among A1 landscape sheets. That is the set per-page anchoring is
    /// about, and a fixture of identical pages would let an absolute-point implementation
    /// pass every test in this file.
    @MainActor
    static func makeEnvironment(pageCount: Int) async throws -> (AppCoreEnvironment, DocumentID, [ZPDFContracts.PageDescriptor]) {
        let documentID = DocumentID(UUID())
        let pages = (0..<pageCount).map { index -> ZPDFContracts.PageDescriptor in
            let isDetail = index % 3 == 2
            let width: Double = isDetail ? 1191 : 2384
            let height: Double = isDetail ? 842 : 1684
            return ZPDFContracts.PageDescriptor(
                id: PageID(UUID()),
                documentID: documentID,
                index: index,
                label: String(format: "A-%03d", index + 1),
                boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: width, height: height))
            )
        }
        let session = try TakeoffSession(documentID: documentID, pages: pages)
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        environment.documentDisplayName = "Block C"
        environment.documentRevisionName = "Rev C"
        environment.projectDisplayName = "Harbour Works"
        return (environment, documentID, pages)
    }

    static func makeDatabase() async throws -> (ProjectDatabaseActor, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-stamp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try await ProjectDatabaseActor.open(
            at: directory.appendingPathComponent("stamps.sqlite")
        )
        return (database, directory)
    }

    // MARK: Stamps

    @Test("Dynamic fields resolve once, at placement, and never again")
    func resolvedFieldsAreFrozenForever() throws {
        let template = Self.template(id: UUID())
        let context = StampResolutionContext(
            now: Self.placementInstant,
            author: "Estimator",
            pageLabel: "A-207",
            documentName: "Block C",
            revision: "Rev C",
            projectName: "Harbour Works",
            promptedText: "Checked on site",
            localeIdentifier: "en_US_POSIX",
            timeZoneIdentifier: "UTC"
        )
        let stamp = StampBridge.instance(of: template, named: "Reviewed", in: context)

        #expect(stamp.text(for: .date) == "2026-08-25")
        #expect(stamp.text(for: .author) == "Estimator")
        #expect(stamp.text(for: .pageLabel) == "A-207")
        #expect(stamp.text(for: .documentName) == "Block C")
        #expect(stamp.text(for: .revision) == "Rev C")
        #expect(stamp.text(for: .projectName) == "Harbour Works")
        #expect(stamp.text(for: .freeText) == "Checked on site")
        #expect(stamp.fields.count == ZPDFUIPresentation.StampFieldKind.allCases.count)

        // The whole point of freezing. Encode the stamp, decode it a year later, and the date is
        // still the date it was placed on — because the stored value is text, and there is
        // no code path anywhere that re-resolves it.
        let data = try JSONEncoder().encode(stamp)
        let reopened = try JSONDecoder().decode(StampInstance.self, from: data)
        #expect(reopened.text(for: .date) == "2026-08-25")
        #expect(reopened.resolvedValues == stamp.resolvedValues)
    }

    @Test("Raster artwork is marked as raster; vector artwork carries no warning")
    func rasterArtworkIsMarkedAndVectorIsNot() {
        let vector = Self.template(id: UUID(), artwork: StampArtworkDescriptor(
            kind: .vector, digest: String(repeating: "a", count: 64),
            byteCount: 4096, sourceName: "seal.pdf", sourcePageIndex: 0
        ))
        #expect(vector.artworkIsRaster == false)
        #expect(vector.rasterSharpnessWarning == nil)
        #expect(vector.artworkKind.staysSharpWhenMagnified)

        let raster = Self.template(id: UUID(), artwork: StampArtworkDescriptor(
            kind: .raster, digest: String(repeating: "b", count: 64),
            byteCount: 90_000, sourceName: "seal.png", pixelWidth: 320, pixelHeight: 120
        ))
        #expect(raster.artworkIsRaster)
        #expect(raster.artworkKind.staysSharpWhenMagnified == false)
        // Hand-derived (BH-166 / BH-794): raster artwork is stored as a mosaic
        // capped at 96 cells on its longer side, so 320 x 120 px keeps round(320 * 96 / 320) = 96
        // columns. The 320:120 aspect equals the 160:60 pt box, so the letterboxed width is the
        // full 160 pt, and 96 / 160 = 0.60, i.e. sharp to about 60 %. The old expectation of
        // "200" (320 / 160) counted source pixels the stored mosaic no longer keeps.
        let warning = try? #require(raster.rasterSharpnessWarning)
        #expect(warning?.contains("60") == true)
        #expect(warning?.contains("200") == false)
        #expect(Self.preset(stamp: raster).placesRasterStamp)
        #expect(Self.preset(stamp: vector).placesRasterStamp == false)
    }

    @Test("The audit note carries the template and every resolved value")
    func auditNoteCarriesTemplateAndResolvedValues() throws {
        let templateID = UUID()
        let stamp = StampBridge.instance(
            of: Self.template(id: templateID, revision: 4),
            named: "Reviewed",
            in: StampResolutionContext(
                now: Self.placementInstant,
                author: "Estimator",
                pageLabel: "A-207",
                promptedText: "Checked on site",
                localeIdentifier: "en_US_POSIX",
                timeZoneIdentifier: "UTC"
            )
        )
        let note = try #require(StampBridge.auditNote(for: stamp))
        let decoded = try JSONDecoder().decode([String: String].self, from: Data(note.utf8))
        #expect(decoded["stampTemplateID"] == templateID.uuidString)
        #expect(decoded["stampTemplate"] == "Reviewed")
        #expect(decoded["stampTemplateRevision"] == "4")
        #expect(decoded["field.date"] == "2026-08-25")
        #expect(decoded["field.freeText"] == "Checked on site")
    }

    // MARK: Scope, preview and anchoring

    @Test("The scope is previewed, and previewing changes nothing")
    @MainActor
    func scopePreviewCountsBeforeAnythingHappens() async throws {
        let (environment, _, _) = try await Self.makeEnvironment(pageCount: 312)
        let preset = Self.preset(stamp: Self.template(id: UUID()))
        let producer = try #require(environment.stampBatchProducer(
            for: preset, promptedText: "", now: Self.placementInstant
        ))
        let plan = environment.planBatchApply(
            producer,
            request: BatchApplyRequest(scope: .allPages, anchor: .corner(.bottomRight, insetX: 36, insetY: 36))
        )

        #expect(plan.placementCount == 312)
        #expect(plan.totalPageCount == 312)
        #expect(plan.previewSentence.contains("312"))
        // The preview is a read. Nothing exists yet.
        #expect(environment.snapshot.markups.isEmpty)
    }

    @Test("Anchoring resolves against each page's own box, not against one absolute point")
    func anchoringIsPerPageOnAMixedSizeSet() {
        let a1 = PDFRectValue(x: 0, y: 0, width: 2384, height: 1684)
        let a3 = PDFRectValue(x: 0, y: 0, width: 1191, height: 842)
        let size = PDFSizeValue(width: 160, height: 60)
        let anchor = BatchAnchor.corner(.bottomRight, insetX: 36, insetY: 36)

        let onA1 = BatchPlacementGeometry.anchorPoint(in: a1, anchor: anchor, size: size)
        let onA3 = BatchPlacementGeometry.anchorPoint(in: a3, anchor: anchor, size: size)

        // Both are 36 pt from their own right edge and 36 pt from their own bottom edge —
        // which is the whole claim, and is exactly what an absolute point cannot do.
        #expect(abs((a1.maxX - onA1.x) - (36 + 80)) < 1e-9)
        #expect(abs((a3.maxX - onA3.x) - (36 + 80)) < 1e-9)
        #expect(abs((onA1.y - a1.minY) - (36 + 30)) < 1e-9)
        #expect(abs((onA3.y - a3.minY) - (36 + 30)) < 1e-9)
        // And they are genuinely different points, so a test that accidentally compared a
        // page against itself would not pass.
        #expect(onA1 != onA3)

        // Centred is the page centre on both, and the stamp's own extent does not shift it.
        #expect(BatchPlacementGeometry.anchorPoint(in: a3, anchor: .centered, size: size) == a3.center)
    }

    @Test("A rotated page anchors at the corner the estimator sees")
    func anchoringFollowsPageRotation() {
        let box = PDFRectValue(x: 0, y: 0, width: 1000, height: 500)
        let size = PDFSizeValue(width: 100, height: 40)
        let anchor = BatchAnchor.corner(.topRight, insetX: 20, insetY: 10)

        let upright = BatchPlacementGeometry.anchorPoint(
            in: box, rotation: .degrees0, anchor: anchor, size: size
        )
        #expect(abs((box.maxX - upright.x) - (20 + 50)) < 1e-9)
        #expect(abs((box.maxY - upright.y) - (10 + 20)) < 1e-9)

        // Turned 90° clockwise for display, the corner the estimator calls "top right" is
        // the page-space **top-left** corner, and the inset axes swap with it — the screen
        // right edge being page-space `maxY` and the screen top edge page-space `minX`. The
        // stamp turns with the page, so its page-space extent is *not* swapped (BH-051):
        // the centre sits insetX + half the stamp's page-space height (20) from `maxY`
        // and insetY + half its page-space width (50) from `minX`. The old expectation, 20 + 50
        // and 10 + 20, pinned the swapped extent that put a rotated stamp off the sheet.
        let turned = BatchPlacementGeometry.anchorPoint(
            in: box, rotation: .degrees90, anchor: anchor, size: size
        )
        #expect(abs((box.maxY - turned.y) - (20 + 20)) < 1e-9)
        #expect(abs((turned.x - box.minX) - (10 + 50)) < 1e-9)
    }

    @Test("Range, size and search scopes select the pages they name")
    @MainActor
    func scopesSelectTheRightPages() async throws {
        let (_, _, domainPages) = try await Self.makeEnvironment(pageCount: 12)
        let pages = domainPages.map { ZPDFUIPresentation.PageDescriptor(domain: $0) }

        let range = AppCoreEnvironment.pageIDsInScope(
            request: BatchApplyRequest(scope: .pageRange(from: 3, through: 5), anchor: .centered),
            pages: pages
        )
        #expect(range == Set(pages[2...4].map(\.id)))

        // Clamped, not refused: "1 to 9999" on a twelve-page set is the twelve pages.
        let clamped = AppCoreEnvironment.pageIDsInScope(
            request: BatchApplyRequest(scope: .pageRange(from: 1, through: 9999), anchor: .centered),
            pages: pages
        )
        #expect(clamped.count == 12)

        // Every third sheet is the A3 detail, so four of twelve.
        let bySize = AppCoreEnvironment.pageIDsInScope(
            request: BatchApplyRequest(
                scope: .matchingSize(widthPoints: 1191, heightPoints: 842, tolerancePoints: 1),
                anchor: .centered
            ),
            pages: pages
        )
        #expect(bySize.count == 4)

        // A search scope with no search run matches nothing, loudly.
        let unrun = AppCoreEnvironment.pageIDsInScope(
            request: BatchApplyRequest(scope: .matchingSearchTerm("FOUNDATION"), anchor: .centered),
            pages: pages
        )
        #expect(unrun.isEmpty)

        let matched = Set(pages[0...1].map(\.id))
        let searched = AppCoreEnvironment.pageIDsInScope(
            request: BatchApplyRequest(
                scope: .matchingSearchTerm("FOUNDATION"),
                anchor: .centered,
                searchMatchedPageIDs: matched
            ),
            pages: pages
        )
        #expect(searched == matched)

        let selected = Set([pages[7].id, pages[9].id])
        let navigator = AppCoreEnvironment.pageIDsInScope(
            request: BatchApplyRequest(scope: .navigatorSelection(Array(selected)), anchor: .centered),
            pages: pages
        )
        #expect(navigator == selected)
    }

    // MARK: The headline safety claim

    @Test("312 stamps, one Undo, zero remain, and one audit group")
    @MainActor
    func threeHundredAndTwelveStampsUndoAsOne() async throws {
        let (environment, _, pages) = try await Self.makeEnvironment(pageCount: 312)
        let (database, directory) = try await Self.makeDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectID = UUID().uuidString
        environment.history.attach(database: database, projectID: projectID)

        let templateID = UUID()
        let preset = Self.preset(stamp: Self.template(id: templateID))
        let producer = try #require(environment.stampBatchProducer(
            for: preset, promptedText: "Checked", now: Self.placementInstant
        ))
        let request = BatchApplyRequest(
            scope: .allPages,
            anchor: .corner(.bottomRight, insetX: 36, insetY: 36)
        )
        let plan = environment.planBatchApply(producer, request: request)
        #expect(plan.placementCount == 312)

        let receipt = await environment.runBatchApply(producer, plan: plan)
        #expect(receipt.wasCancelled == false)
        #expect(receipt.failureMessage == nil)
        #expect(receipt.placementCount == 312)
        #expect(environment.snapshot.markups.count == 312)

        // Every one of the 312 is on its own page, anchored against that page's own box —
        // so the A3 details did not get the A1 sheets' point.
        #expect(Set(environment.snapshot.markups.map(\.pageID)).count == 312)
        let a3PageIDs = Set(pages.filter { $0.boxes.media.width < 1500 }.map(\.id.rawValue))
        let onA3 = environment.snapshot.markups.filter { a3PageIDs.contains($0.pageID) }
        #expect(onA3.isEmpty == false)
        for markup in onA3 {
            #expect(markup.boundsInPageSpace.maxX < 1191)
        }

        // One undo step on the stack, not 312.
        #expect(environment.commands.undoManager.canUndo)
        await environment.commands.undo()
        await environment.refresh()
        #expect(environment.snapshot.markups.isEmpty, "one Undo must remove all 312")
        #expect(environment.commands.undoManager.canUndo == false, "there was only ever one step")

        // Redo puts all 312 back, still as one step.
        await environment.commands.redo()
        await environment.refresh()
        #expect(environment.snapshot.markups.count == 312)

        await environment.history.settle()
        let group = try #require(receipt.auditGroup)
        let rows = try await database.read { db in
            try MeasurementAuditStore.auditTrail(
                project: projectID,
                filter: MeasurementAuditStore.AuditFilter(undoGroup: group),
                in: db
            )
        }
        #expect(rows.count == 312, "one audit group, expandable to 312 rows")
        #expect(Set(rows.compactMap(\.undoGroup)).count == 1, "312 entries, one group")
        #expect(rows.allSatisfy { $0.action == MeasurementAuditAction.markupCreated.rawValue })
        // The trail records both the template and the resolved values.
        let note = try #require(rows.first?.note)
        #expect(note.contains(templateID.uuidString))
        #expect(note.contains("2026-08-25"))
        #expect(note.contains("Checked"))

        try await database.close()
    }

    @Test("Cancelling a batch leaves nothing behind")
    @MainActor
    func cancellingLeavesNothingBehind() async throws {
        let (environment, _, _) = try await Self.makeEnvironment(pageCount: 200)
        let preset = Self.preset(stamp: Self.template(id: UUID()))
        let producer = try #require(environment.stampBatchProducer(
            for: preset, now: Self.placementInstant
        ))
        let plan = environment.planBatchApply(
            producer, request: BatchApplyRequest(scope: .allPages, anchor: .centered)
        )
        #expect(plan.placementCount == 200)

        // Cancelled before the run begins: the loop's first `Task.isCancelled` check fires
        // and the single atomic commit is never reached.
        let task = Task { @MainActor in
            await environment.runBatchApply(producer, plan: plan)
        }
        task.cancel()
        let receipt = await task.value

        #expect(receipt.wasCancelled)
        #expect(receipt.placementCount == 0)
        await environment.refresh()
        #expect(environment.snapshot.markups.isEmpty, "cancelling leaves all or none — here, none")
        #expect(environment.commands.undoManager.canUndo == false)
    }

    @Test("Pages that already carry the same stamp are skipped, and the skip is reported")
    @MainActor
    func skipRuleReportsWhatItSkipped() async throws {
        let (environment, _, _) = try await Self.makeEnvironment(pageCount: 20)
        let templateID = UUID()
        let preset = Self.preset(stamp: Self.template(id: templateID))
        let producer = try #require(environment.stampBatchProducer(
            for: preset, now: Self.placementInstant
        ))

        // First pass over pages 1–5.
        let firstPlan = environment.planBatchApply(
            producer,
            request: BatchApplyRequest(scope: .pageRange(from: 1, through: 5), anchor: .centered)
        )
        #expect(firstPlan.placementCount == 5)
        _ = await environment.runBatchApply(producer, plan: firstPlan)
        #expect(environment.snapshot.markups.count == 5)

        // Second pass over the whole set, with the skip rule on.
        let secondPlan = environment.planBatchApply(
            producer,
            request: BatchApplyRequest(
                scope: .allPages, anchor: .centered, skipPagesAlreadyCarrying: true
            )
        )
        #expect(secondPlan.placementCount == 15)
        #expect(secondPlan.skippedCount == 5)
        let skipSentence = try #require(secondPlan.skipSentence)
        #expect(skipSentence.contains("5"))
        #expect(skipSentence.contains("Reviewed"))

        let receipt = await environment.runBatchApply(producer, plan: secondPlan)
        #expect(receipt.placementCount == 15)
        #expect(receipt.skippedPageIDs.count == 5)
        #expect(environment.snapshot.markups.count == 20, "no page got a second copy")
        #expect(receipt.completionSentence.contains("15"))

        // With the rule off, the same second pass would duplicate — which is what makes the
        // rule a rule rather than an accident of the fixture.
        let unskipped = environment.planBatchApply(
            producer,
            request: BatchApplyRequest(
                scope: .allPages, anchor: .centered, skipPagesAlreadyCarrying: false
            )
        )
        #expect(unskipped.placementCount == 20)
        #expect(unskipped.skippedCount == 0)
    }

    @Test("A batch reports progress and finishes")
    @MainActor
    func batchReportsProgress() async throws {
        let (environment, _, _) = try await Self.makeEnvironment(pageCount: 60)
        let preset = Self.preset(stamp: Self.template(id: UUID()))
        let producer = try #require(environment.stampBatchProducer(for: preset, now: Self.placementInstant))
        let plan = environment.planBatchApply(
            producer, request: BatchApplyRequest(scope: .allPages, anchor: .centered)
        )

        let reports = Reports()
        _ = await environment.runBatchApply(
            producer,
            plan: plan,
            progress: ProgressSink { reports.append($0) }
        )
        let seen = reports.all()
        #expect(seen.contains { $0.stage == .working })
        #expect(seen.last?.stage == .completed)
        #expect(seen.contains { ($0.totalUnits ?? 0) == 60 })
    }

    /// A thread-safe collector, because `ProgressSink` reports from wherever the work is.
    final class Reports: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [OperationProgress] = []
        func append(_ progress: OperationProgress) {
            lock.lock(); defer { lock.unlock() }
            storage.append(progress)
        }
        func all() -> [OperationProgress] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
    }

    @Test("A single Place-mode click resolves the stamp too")
    @MainActor
    func singleClickPlacementResolvesTheStamp() async throws {
        let (environment, _, pages) = try await Self.makeEnvironment(pageCount: 1)
        let preset = Self.preset(stamp: Self.template(id: UUID()))
        let receipt = await environment.placeStamp(
            preset,
            at: PDFPointValue(x: 400, y: 400),
            pageID: pages[0].id.rawValue,
            promptedText: "Site copy",
            now: Self.placementInstant
        )
        #expect(receipt.failureMessage == nil)
        #expect(receipt.markupID != nil)
        let placed = try #require(environment.snapshot.markups.first)
        #expect(placed.stampTemplateID == preset.stamp?.id)
    }
}

/// The v7 companion, proved through the real `.zpdfproj` save pipeline: a stamp saved in
/// 2026 reopens saying what it said in 2026.
///
/// Separate from the suite above because it needs a real fixture PDF and a real package,
/// and the claim it makes is a persistence claim rather than a batch one.
@Suite("Stamp persistence")
struct StampPersistenceTests {

    @Test("A stamp survives save and reopen saying exactly what it said")
    @MainActor
    func aStampSurvivesSaveAndReopen() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-stamp-roundtrip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let fixture = try await OpenedFixture.open(.titleBlockSheet, in: workspace)
        let session = try TakeoffSession(
            documentID: fixture.documentID, pages: fixture.pages, units: .metric
        )
        let templateID = UUID()
        let placedAt = StampAndBatchApplyTests.placementInstant
        let stamp = StampBridge.instance(
            of: StampAndBatchApplyTests.template(
                id: templateID,
                artwork: StampArtworkDescriptor(
                    kind: .raster,
                    digest: String(repeating: "c", count: 64),
                    byteCount: 2048,
                    sourceName: "seal.png",
                    pixelWidth: 320,
                    pixelHeight: 120
                ),
                revision: 7
            ),
            named: "Reviewed",
            in: StampResolutionContext(
                now: placedAt,
                author: "Estimator",
                pageLabel: "A-101",
                documentName: "Block C",
                revision: "Rev C",
                projectName: "Harbour Works",
                promptedText: "Checked on site",
                localeIdentifier: "en_US_POSIX",
                timeZoneIdentifier: "UTC"
            )
        )
        let markupID = MarkupID(UUID())
        _ = try await session.apply(.addMarkup(MarkupRecord(
            id: markupID,
            documentID: fixture.documentID,
            pageID: fixture.firstPage.id,
            kind: .stamp,
            subject: "Review",
            author: "Estimator",
            geometry: MeasurementGeometry(
                pageID: fixture.firstPage.id, points: [PDFPoint(x: 400, y: 300)]
            ),
            stamp: stamp,
            createdAt: placedAt,
            modifiedAt: placedAt
        )))

        let packageURL = workspace.appendingPathComponent("Stamps.zpdfproj", isDirectory: true)
        let package = try await ProjectPackage.create(
            at: packageURL, displayName: "Stamps", originalPDF: fixture.url
        )
        try await TakeoffArchive.write(await session.takeoffState(), into: package)
        _ = try await package.save()
        try await package.close()

        guard case .opened(let reopened) = try await ProjectPackage.open(at: packageURL) else {
            Issue.record("reopen required recovery")
            return
        }
        let stored = try #require(try await TakeoffArchive.read(from: reopened))
        let record = try #require(stored.markups.first { $0.id == markupID })
        let restored = try #require(record.stamp)

        #expect(restored.templateID == templateID)
        #expect(restored.templateName == "Reviewed")
        #expect(restored.templateRevision == 7)
        #expect(restored.artworkKind == .raster)
        #expect(restored.artworkKind.staysSharpWhenMagnified == false)
        #expect(restored.widthPoints == 160)
        #expect(restored.heightPoints == 60)
        // The whole reason the table stores text and not a recipe.
        #expect(restored.text(for: .date) == "2026-08-25")
        #expect(restored.text(for: .author) == "Estimator")
        #expect(restored.text(for: .pageLabel) == "A-101")
        #expect(restored.text(for: .freeText) == "Checked on site")
        #expect(restored.resolvedValues == stamp.resolvedValues)
        // The batch skip rule — the one stamp-identity rule, `StampBatchProducer.matchesExisting`
        // (V-087) — reads the reopened record as the same stamp.
        let skipRule = StampBatchProducer(
            preset: StampAndBatchApplyTests.preset(stamp: StampAndBatchApplyTests.template(id: templateID)),
            template: StampAndBatchApplyTests.template(id: templateID),
            now: placedAt,
            author: "A. Berg"
        )
        #expect(skipRule.matchesExisting(MarkupBridge.summary(of: record, names: ProjectNameTable(), formatter: QuantityFormatter())))

        // The bytes are content-addressed and shared, so the stamp row names a digest and
        // does not carry a copy of the artwork.
        let digests = try await reopened.read { db in
            try String.fetchAll(db, sql: "SELECT artwork_digest FROM markup_stamp")
        }
        #expect(digests == [String(repeating: "c", count: 64)])
        try await reopened.close()
    }
}
