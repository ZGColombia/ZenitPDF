import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFCollaboration
import ZPDFContracts
import ZPDFMeasurementEngine
import ZPDFUIPresentation

/// Through the shipping session: X-042 (an Arc
/// Length is three points — a fourth is refused on commit, and one saved before the fix opens as
/// the three it was measured on) and X-044 (an Ellipse Cutout flush with its parent's edge raises
/// no `cutoutOutsideParent` on the parent). Cycle 2: a four-point Arc Length saved by an older
/// build opens as three through every door — a Shared Review sync (added or moved), a review file,
/// a paste — while a live four-point commit is still refused; a doubled click is stored as the
/// three points measured; a partial-overlap cutout warning informs without blocking.
@Suite("Iteration 7 — quantities core, session")
struct Iter7QuantitiesCoreAppCoreTests {

    static let stamp = Date(timeIntervalSince1970: 1_790_000_000)
    static let documentID = DocumentID(UUID(uuidString: "0A070000-0000-4000-8000-000000000001")!)
    static let page = ZPDFContracts.PageDescriptor(
        id: PageID(UUID(uuidString: "0A070000-0000-4000-8000-000000000002")!), documentID: documentID, index: 0, label: "A-1",
        boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 1_000, height: 1_000))
    )

    /// A session on the one page, calibrated 100 pt = 10 m (0.1 m/pt).
    static func calibratedSession() async throws -> TakeoffSession {
        let session = try TakeoffSession(documentID: documentID, pages: [page], units: .metric)
        _ = try await session.calibrate(
            page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 10, knownLengthUnit: .metre
        )
        return session
    }

    static func record(_ tool: ZPDFContracts.MeasurementTool, kind: ZPDFContracts.MarkupKind = .measurement,
                       geometry: MeasurementGeometry, id: String) -> ZPDFContracts.MarkupRecord {
        ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID(uuidString: id)!), documentID: documentID, pageID: page.id, kind: kind, tool: tool,
            subject: "Run", author: "A. Berg", geometry: geometry, createdAt: stamp, modifiedAt: stamp
        )
    }

    static func double(_ value: Decimal?) -> Double? {
        value.map { NSDecimalNumber(decimal: $0).doubleValue }
    }

    // MARK: - X-042

    /// (100, 100), (150, 150), (200, 100) and a fourth point (250, 150).
    static let fourPoints = [PDFPoint(x: 100, y: 100), PDFPoint(x: 150, y: 150), PDFPoint(x: 200, y: 100), PDFPoint(x: 250, y: 150)]

    /// Old output: accepted and measured as the semicircle through the first three — 50π pt at
    /// 0.1 m/pt, 5π = 15.708 m — with the fourth point kept, drawn and ignored.
    @Test("X-042: a four-point Arc Length is refused on commit")
    func fourPointsRefusedOnCommit() async throws {
        let session = try await Self.calibratedSession()
        let record = Self.record(.arcLength, geometry: MeasurementGeometry(pageID: Self.page.id, points: Self.fourPoints),
                                 id: "0A070000-0000-4000-8000-0000000000a1")
        await #expect(throws: (any Error).self) { try await session.apply(.addMarkup(record)) }
        #expect(await session.markup(record.id) == nil)
    }

    /// A project saved before X-042 with that four-point Arc Length opens as its first three
    /// points, with the value it was saved with: the semicircle of r = 50 pt about (150, 100),
    /// 5π m at 0.1 m/pt.
    /// Old output (without the open repair, engine refusing the fourth point): `hydrate` threw
    /// `measurementFailed`, the damaged-file error, and the project did not open.
    @Test("X-042: a saved four-point Arc Length opens as the three it was measured on")
    func storedFourPointsOpen() async throws {
        let live = try await Self.calibratedSession()
        let state = await live.takeoffState()
        let stored = Self.record(.arcLength, geometry: MeasurementGeometry(pageID: Self.page.id, points: Self.fourPoints),
                                 id: "0A070000-0000-4000-8000-0000000000a2")
        let restored = try TakeoffSession(documentID: Self.documentID, pages: [Self.page], units: .metric)
        _ = try await restored.hydrate(markups: [stored], scales: state.scales, pageScaleIDs: state.pageScaleIDs)
        let opened = try #require(await restored.markup(stored.id))
        #expect(opened.geometry?.points == Array(Self.fourPoints.prefix(3)))
        let value = try #require(Self.double(opened.measurement?[.arcLength]?.value))
        #expect(Swift.abs(value - 5 * Double.pi) <= 5 * Double.pi * 1e-12, "\(value)")
        // Drawn and snapped as that arc: the record's chain is the arc from the first point to the
        // third, bending through the second (MarkupRecord.drawnPointChain).
        let chain = try #require(opened.drawnPointChain)
        #expect(chain.points == [Self.fourPoints[0], Self.fourPoints[2]])
        #expect(chain.hasArcs)
    }

    // MARK: - X-044

    /// A 400 × 300 pt area (100, 100)–(500, 400) with an Ellipse Cutout dragged in the box
    /// (100, 200)–(300, 300), flush with the area's left edge: a = 100 pt, b = 50 pt. At 0.1 m/pt
    /// the gross is 40 × 30 = 1200 m², the hole π·10·5 = 50π m², the net 1200 − 50π = 1042.92036732 m².
    /// Old output: the parent carried `cutoutOutsideParent` (the hole ring reached 2.5e-3 pt past
    /// x = 100), shown with the blocking "A cutout must overlap the area it is subtracted from."
    @Test("X-044: an ellipse cutout flush with its parent's edge leaves no cutoutOutsideParent on it")
    func flushEllipseCutout() async throws {
        let session = try await Self.calibratedSession()
        let parent = Self.record(.area, geometry: MeasurementGeometry(pageID: Self.page.id, polygons: [PolygonGeometry(outer: PolygonRing(points: [
            PDFPoint(x: 100, y: 100), PDFPoint(x: 500, y: 100), PDFPoint(x: 500, y: 400), PDFPoint(x: 100, y: 400)
        ]))]), id: "0A070000-0000-4000-8000-0000000000b1")
        _ = try await session.apply(.addMarkup(parent))
        let cutout = Self.record(.ellipseCutout, geometry: MeasurementGeometry(pageID: Self.page.id, points: [
            PDFPoint(x: 100, y: 200), PDFPoint(x: 300, y: 300)
        ]), id: "0A070000-0000-4000-8000-0000000000b2")
        _ = try await session.apply(.addCutout(parent: parent.id, cutout: cutout))
        let measured = try #require(await session.markup(parent.id)?.measurement)
        #expect(!measured.warnings.contains { $0.code == .cutoutOutsideParent }, "\(measured.warnings)")
        let net = try #require(Self.double(measured[.netArea]?.value))
        #expect(Swift.abs(net - (1200 - 50 * Double.pi)) <= 1200 * 1e-12, "\(net)")
        // The parent carries the engine's ring, 360 facets inside the dragged box.
        let hole = try #require(await session.markup(parent.id)?.geometry?.polygons.first?.holes.first)
        #expect(hole.points.count == EllipseCutoutRing.facets)
        #expect(hole.points.allSatisfy { $0.x >= 100 && $0.x <= 300 && $0.y >= 200 && $0.y <= 300 })
    }

    // MARK: - X-042, cycle 2: every door for a saved record opens it

    /// An Arc Length an older build saved with four points, on the Shared Review machine's sheet
    /// (1 pt = 1 cm): the semicircle of r = 50 pt through its first three is 50π cm = 0.5π m.
    static func olderBuildArc(_ id: MarkupID, points: [PDFPoint]) -> ZPDFContracts.MarkupRecord {
        ZPDFContracts.MarkupRecord(
            id: id, documentID: SharedReviewSyncTests.documentID, pageID: SharedReviewSyncTests.pageID,
            kind: .measurement, tool: .arcLength, subject: "Kerb", author: "Old",
            geometry: MeasurementGeometry(pageID: SharedReviewSyncTests.pageID, points: points),
            createdAt: stamp, modifiedAt: stamp
        )
    }

    /// An operation in the older build's own log, `secondsAgo` before now (a clock the reader
    /// accepts: not in the future).
    static func olderBuildOperation(_ payload: ReviewOperation.Payload, secondsAgo: Int64) -> ReviewOperation {
        let millis = Int64(Date().timeIntervalSince1970 * 1000) - secondsAgo * 1000
        return ReviewOperation(
            clock: HLCTimestamp(physicalMillis: millis, counter: 0, node: "old-mac"),
            participantID: "old-mac", authorName: "Old", payload: payload
        )
    }

    static func temporaryFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("zenit-c2r-\(UUID().uuidString)", isDirectory: true)
    }

    /// A colleague on a build from before X-042 adds a four-point Arc Length to the folder.
    /// Old output: `SharedReviewSync.commands` sent `.addMarkup` with the four points, the engine
    /// refused the fourth, and the one batch threw — `SyncError.refused`, on every sync for as
    /// long as the colleague's record stood.
    @Test("X-042 c2: a Shared Review sync carrying a four-point Arc Length an older build added lands as its first three points")
    @MainActor
    func sharedReviewAddFromOlderBuild() async throws {
        let folderURL = Self.temporaryFolder()
        let (machine, database, directory) = try await SharedReviewSyncTests.machine()
        defer { for url in [folderURL, directory] { try? FileManager.default.removeItem(at: url) } }
        let sync = SharedReviewSync(folderURL: folderURL, participantID: "new-mac", base: nil)
        try sync.prepare(projectID: "P1", projectName: "Tower")
        let saved = Self.olderBuildArc(MarkupID(UUID()), points: Self.fourPoints)
        try SharedReviewFolder(url: folderURL).append(
            [Self.olderBuildOperation(.putMarkup(MarkupRegisters(record: saved)), secondsAgo: 60)], participant: "old-mac")

        let report = try await sync.sync(core: machine, authorName: "New")
        #expect(report.added == 1 && report.notApplied == 0)
        let landed = try #require(await machine.session.markup(saved.id))
        #expect(landed.geometry?.points == Array(Self.fourPoints.prefix(3)))
        let value = try #require(Self.double(landed.measurement?[.arcLength]?.value))
        #expect(Swift.abs(value - 0.5 * Double.pi) <= 0.5 * Double.pi * 1e-12, "\(value)")
        #expect(landed.drawnPointChain?.hasArcs == true, "drawn and snapped as the arc it measures")
        // Nothing is left over: the merged record opens as the document holds it, so the next
        // sync neither re-applies it nor publishes the repair.
        let again = try await sync.sync(core: machine, authorName: "New")
        #expect(again.isQuiet && again.published == 0, "\(again)")
        try? await database.close()
    }

    /// This machine opened a project saved before X-042 — its four-point Arc Length opens as
    /// three — and its base, agreed before the update, still holds the four points. The colleague
    /// on the older build then moves the record by (100, 200) pt.
    /// Old output: the move arrived as `.editVertices` with the colleague's four points and the
    /// batch threw `SyncError.refused` on every attempt. Opening only the merged state would not
    /// do either: against the four-point base this machine published its three points as its own
    /// edit, with a clock newer than the move, and the move was lost on every machine.
    @Test("X-042 c2: a four-point Arc Length an older build moved is applied as its first three moved points, and the move stands")
    @MainActor
    func sharedReviewMoveFromOlderBuild() async throws {
        let folderURL = Self.temporaryFolder()
        let (machine, database, directory) = try await SharedReviewSyncTests.machine()
        defer { for url in [folderURL, directory] { try? FileManager.default.removeItem(at: url) } }
        let id = MarkupID(UUID())
        let saved = Self.olderBuildArc(id, points: Self.fourPoints)
        let state = await machine.session.takeoffState()
        _ = try await machine.session.hydrate(markups: [saved], scales: state.scales, pageScaleIDs: state.pageScaleIDs)
        await machine.refresh()
        #expect(await machine.session.markup(id)?.geometry?.points == Array(Self.fourPoints.prefix(3)))

        var agreed = SharedReviewBase(participantID: "new-mac")
        agreed.markups[id] = MarkupRegisters(record: saved)
        let sync = SharedReviewSync(folderURL: folderURL, participantID: "new-mac", base: SharedReviewBaseValue(value: agreed))
        try sync.prepare(projectID: "P1", projectName: "Tower")
        let movedPoints = Self.fourPoints.map { PDFPoint(x: $0.x + 100, y: $0.y + 200) }
        let moved = Self.olderBuildArc(id, points: movedPoints)
        let shape = try #require(MarkupRegisters(record: moved).values[.shape])
        try SharedReviewFolder(url: folderURL).append([
            Self.olderBuildOperation(.putMarkup(MarkupRegisters(record: saved)), secondsAgo: 120),
            Self.olderBuildOperation(.setRegisters(id, [.shape: shape]), secondsAgo: 60)
        ], participant: "old-mac")

        let report = try await sync.sync(core: machine, authorName: "New")
        #expect(report.changed == 1 && report.notApplied == 0, "\(report)")
        let landed = try #require(await machine.session.markup(id))
        #expect(landed.geometry?.points == Array(movedPoints.prefix(3)))
        let value = try #require(Self.double(landed.measurement?[.arcLength]?.value))
        #expect(Swift.abs(value - 0.5 * Double.pi) <= 0.5 * Double.pi * 1e-12, "\(value)")
        // The colleague's move still stands in the folder: this machine did not publish the
        // repair over it.
        let folder = SharedReviewFolder(url: folderURL).readAll()
        let inFolder = MergedReview.merge(folder.operations).markups[id]?.record(modifiedAt: Self.stamp)
        #expect(inFolder?.geometry?.points == movedPoints)
        let again = try await sync.sync(core: machine, authorName: "New")
        #expect(again.isQuiet && again.published == 0, "\(again)")
        try? await database.close()
    }

    /// A `.zpdfreview` exported by an older build with a four-point Arc Length.
    /// Old output: `acceptReviewFileImport` threw — the same `.addMarkup` refusal, the whole file.
    @Test("X-042 c2: a review file carrying a four-point Arc Length imports it as its first three points")
    @MainActor
    func reviewFileFromOlderBuild() async throws {
        let (machine, database, directory) = try await SharedReviewSyncTests.machine()
        defer { try? FileManager.default.removeItem(at: directory) }
        let saved = Self.olderBuildArc(MarkupID(UUID()), points: Self.fourPoints)
        let file = ReviewExchangeFile(
            format: ReviewExchangeFile.formatName, formatVersion: ReviewExchangeFile.formatVersion,
            projectID: "P1", projectName: "Tower", exportedBy: "Old", exportedAt: Date(),
            operations: [Self.olderBuildOperation(.putMarkup(MarkupRegisters(record: saved)), secondsAgo: 60)]
        )
        let plan = try await machine.planReviewFileImport(file, projectID: "P1")
        #expect(plan.changes.added.map(\.id) == [saved.id])
        _ = try await machine.acceptReviewFileImport(plan)
        #expect(await machine.session.markup(saved.id)?.geometry?.points == Array(Self.fourPoints.prefix(3)))
        try? await database.close()
    }

    /// A four-point Arc Length on the pasteboard, copied by an older build before an update.
    /// Old output: the paste's one batch was refused — `failureDescription` set, nothing pasted.
    @Test("X-042 c2: a pasted four-point Arc Length lands as its first three points")
    @MainActor
    func pasteFromOlderBuild() async throws {
        let session = try await Self.calibratedSession()
        let environment = try await AppCoreEnvironment.make(session: session, documentID: Self.documentID)
        let copied = Self.record(.arcLength, geometry: MeasurementGeometry(pageID: Self.page.id, points: Self.fourPoints),
                                 id: "0A070000-0000-4000-8000-0000000000a3")
        let payload = MarkupClipboardPayload(sourceDocumentID: Self.documentID.rawValue, sourcePageID: Self.page.id.rawValue, records: [copied])
        let receipt = await environment.pasteMarkups(payload, onto: [Self.page.id.rawValue], placement: .inPlace)
        #expect(receipt.failureDescription == nil)
        let pastedID = try #require(receipt.pastedIDs.first)
        let pasted = try #require(await session.markup(MarkupID(pastedID)))
        #expect(pasted.geometry?.points == Array(Self.fourPoints.prefix(3)))
        let value = try #require(Self.double(pasted.measurement?[.arcLength]?.value))
        #expect(Swift.abs(value - 5 * Double.pi) <= 5 * Double.pi * 1e-12, "\(value)")
    }

    /// The live four-point refusal stands: only saved records are opened.
    @Test("X-042 c2: a live four-point commit is still refused after the import repairs")
    func liveFourPointCommitStillRefused() async throws {
        let session = try await Self.calibratedSession()
        let record = Self.record(.arcLength, geometry: MeasurementGeometry(pageID: Self.page.id, points: Self.fourPoints),
                                 id: "0A070000-0000-4000-8000-0000000000a4")
        await #expect(throws: (any Error).self) { try await session.apply(.addMarkup(record)) }
        // A vertex edit that adds a fourth point is refused too, and leaves the three.
        let three = Self.record(.arcLength, geometry: MeasurementGeometry(pageID: Self.page.id, points: Array(Self.fourPoints.prefix(3))),
                                id: "0A070000-0000-4000-8000-0000000000a5")
        _ = try await session.apply(.addMarkup(three))
        await #expect(throws: (any Error).self) {
            try await session.apply(.editVertices(id: three.id, geometry: MeasurementGeometry(pageID: Self.page.id, points: Self.fourPoints)))
        }
        #expect(await session.markup(three.id)?.geometry?.points == Array(Self.fourPoints.prefix(3)))
    }

    /// A doubled start click, (100, 100) twice, then (150, 150) and (200, 100): the engine
    /// collapses the duplicate and measures the semicircle, 5π m at 0.1 m/pt.
    /// Old output: stored with all four points — measured as the arc, drawn and snapped as three
    /// chords (`drawnPointChain` draws an arc only for exactly three stored points), until the
    /// project was reopened.
    @Test("X-042 c2: a doubled click is stored as the three points measured, and drawn as the arc")
    func doubledClickStoredAsMeasured() async throws {
        let session = try await Self.calibratedSession()
        let doubled = [Self.fourPoints[0], Self.fourPoints[0], Self.fourPoints[1], Self.fourPoints[2]]
        let record = Self.record(.arcLength, geometry: MeasurementGeometry(pageID: Self.page.id, points: doubled),
                                 id: "0A070000-0000-4000-8000-0000000000a6")
        _ = try await session.apply(.addMarkup(record))
        let stored = try #require(await session.markup(record.id))
        #expect(stored.geometry?.points == Array(Self.fourPoints.prefix(3)))
        let value = try #require(Self.double(stored.measurement?[.arcLength]?.value))
        #expect(Swift.abs(value - 5 * Double.pi) <= 5 * Double.pi * 1e-12, "\(value)")
        let chain = try #require(stored.drawnPointChain)
        #expect(chain.hasArcs && chain.points == [Self.fourPoints[0], Self.fourPoints[2]])
    }

    // MARK: - X-044, cycle 2: a partial overlap informs, it does not block

    /// The 400 × 300 pt area (100, 100)–(500, 400) and a 100 × 100 pt Polygon Cutout
    /// (50, 200)–(150, 300) half outside its left edge. The engine accepts it and subtracts the
    /// half inside: 50 × 100 pt = 50 m² at 0.1 m/pt, net 1200 − 50 = 1150 m², warning
    /// `cutoutOutsideParent`.
    /// Old output: the same number, shown with the blocking octagon and "A cutout must overlap
    /// the area it is subtracted from." — copy for the refusal, on a value already accepted.
    @Test("X-044 c2: a cutout partly outside its parent is accepted, and its warning informs without blocking")
    func partialOverlapInforms() async throws {
        let session = try await Self.calibratedSession()
        let parent = Self.record(.area, geometry: MeasurementGeometry(pageID: Self.page.id, polygons: [PolygonGeometry(outer: PolygonRing(points: [
            PDFPoint(x: 100, y: 100), PDFPoint(x: 500, y: 100), PDFPoint(x: 500, y: 400), PDFPoint(x: 100, y: 400)
        ]))]), id: "0A070000-0000-4000-8000-0000000000c1")
        _ = try await session.apply(.addMarkup(parent))
        let cutout = Self.record(.polygonCutout, geometry: MeasurementGeometry(pageID: Self.page.id, points: [
            PDFPoint(x: 50, y: 200), PDFPoint(x: 150, y: 200), PDFPoint(x: 150, y: 300), PDFPoint(x: 50, y: 300)
        ]), id: "0A070000-0000-4000-8000-0000000000c2")
        _ = try await session.apply(.addCutout(parent: parent.id, cutout: cutout))
        let measured = try #require(await session.markup(parent.id)?.measurement)
        let net = try #require(Self.double(measured[.netArea]?.value))
        #expect(Swift.abs(net - 1150) <= 1150 * 1e-12, "\(net)")
        let shown = MarkupBridge.warnings(of: measured)
        #expect(shown.contains(.cutoutOutsideParent), "\(shown)")
        let blocking = shown.filter { $0.isBlocking }
        #expect(blocking.isEmpty, "\(shown)")
        #expect(MeasurementWarningSummary.cutoutOutsideParent.message
            == "Part of a cutout lies outside this area. Only the part inside is subtracted.")
    }
}
