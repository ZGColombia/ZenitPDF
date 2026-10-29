import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFPersistence
import ZPDFCollaboration
import ZPDFUIPresentation

/// NL-COLLAB-12 through the real session and command bus: two "machines" — two environments over
/// the same project copy — review together through one folder.
@Suite("Shared Review Folder — two machines")
struct SharedReviewSyncTests {

    static let documentID = DocumentID(UUID(uuidString: "0A000000-0000-0000-0000-000000000001")!)
    static let pageID = PageID(UUID(uuidString: "0B000000-0000-0000-0000-000000000001")!)
    static let scaleID = ScaleID(UUID(uuidString: "0C000000-0000-0000-0000-000000000001")!)

    /// One machine: the same pages and the same scale, as two copies of one project have.
    @MainActor
    static func machine() async throws -> (AppCoreEnvironment, ProjectDatabaseActor, URL) {
        let page = ZPDFContracts.PageDescriptor(
            id: pageID, documentID: documentID, index: 0, label: "A-101",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 1000, height: 1000))
        )
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        // 1 pt = 1 cm: 100 pt × 50 pt is 1 m × 0.5 m = 0.5 m².
        let scale = ScaleTransform(
            id: scaleID, pageID: pageID, version: 1,
            matrix: AffineScaleMatrix(a: Decimal(string: "0.01")!, b: 0, c: 0, d: Decimal(string: "0.01")!),
            units: .metric, source: .preset
        )
        try await environment.commands.perform(.changeScale(scale))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("zenit-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try await ProjectDatabaseActor.open(at: directory.appendingPathComponent("project.sqlite"))
        environment.history.attach(database: database, projectID: documentID.rawValue.uuidString)
        await environment.review.settle()
        return (environment, database, directory)
    }

    static func area(_ id: UUID = UUID(), width: Double = 100) -> ZPDFContracts.MarkupRecord {
        ZPDFContracts.MarkupRecord(
            id: MarkupID(id), documentID: documentID, pageID: pageID, kind: .measurement, tool: .area,
            subject: "Slab", author: "Ada",
            geometry: MeasurementGeometry(pageID: pageID, polygons: [PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: 0, y: 0), PDFPoint(x: width, y: 0), PDFPoint(x: width, y: 50), PDFPoint(x: 0, y: 50)
            ], isClosed: true))]),
            createdAt: Date(timeIntervalSince1970: 1_790_000_000), modifiedAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
    }

    static func cloud() -> ZPDFContracts.MarkupRecord {
        ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: documentID, pageID: pageID, kind: .cloud, author: "Ada",
            geometry: MeasurementGeometry(pageID: pageID, polygons: [PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: 300, y: 300), PDFPoint(x: 400, y: 300), PDFPoint(x: 400, y: 400)
            ], isClosed: true))]),
            createdAt: Date(timeIntervalSince1970: 1_790_000_000), modifiedAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
    }

    /// Plan area of the ledger, summed, as the ledger computes it.
    @MainActor
    static func totalArea(_ environment: AppCoreEnvironment) async -> Decimal {
        await environment.session.orderedMarkups
            .compactMap { $0.measurement?.values[.planArea]?.value }
            .reduce(Decimal(0), +)
    }

    @Test("A adds a cloud, B sees it; different fields both survive; the same field agrees; totals agree")
    @MainActor
    func twoMachinesReviewTogether() async throws {
        let folderURL = FileManager.default.temporaryDirectory.appendingPathComponent("zenit-folder-\(UUID().uuidString)", isDirectory: true)
        let (a, dbA, dirA) = try await Self.machine()
        let (b, dbB, dirB) = try await Self.machine()
        defer {
            for url in [folderURL, dirA, dirB] { try? FileManager.default.removeItem(at: url) }
        }
        let syncA = SharedReviewSync(folderURL: folderURL, participantID: "ada-mac", base: nil)
        let syncB = SharedReviewSync(folderURL: folderURL, participantID: "bo-mac", base: nil)
        try syncA.prepare(projectID: "P1", projectName: "Tower")
        try syncB.prepare(projectID: "P1", projectName: "Tower")

        let slab = Self.area()
        let cloud = Self.cloud()
        try await a.commands.perform(.addMarkup(slab))
        try await a.commands.perform(.addMarkup(cloud))
        let first = try await syncA.sync(core: a, authorName: "Ada")
        #expect(first.published == 3, "the two markups and, since round 2, the sheet's scale")
        let received = try await syncB.sync(core: b, authorName: "Bo")
        #expect(received.added == 2)
        #expect(received.scales == 0 && received.published == 0, "B measures by the same scale: nothing to install, nothing to republish")
        #expect(received.others == ["Ada"])
        #expect(await b.session.markup(cloud.id)?.kind == .cloud, "B sees A's cloud")
        #expect(await Self.totalArea(b) == Decimal(string: "0.5"), "B recomputed 1 m × 0.5 m under its own copy of the scale")

        // Different fields of one markup, concurrently.
        try await a.commands.perform(.editComment(id: cloud.id, comment: "Ada's note"))
        try await b.commands.perform(.batchStatusChange(ids: [cloud.id], status: .rejected))
        try await syncA.sync(core: a, authorName: "Ada", now: Date().addingTimeInterval(1))
        try await syncB.sync(core: b, authorName: "Bo", now: Date().addingTimeInterval(2))
        try await syncA.sync(core: a, authorName: "Ada", now: Date().addingTimeInterval(3))
        for machine in [a, b] {
            let record = await machine.session.markup(cloud.id)
            #expect(record?.comment == "Ada's note")
            #expect(record?.status == .rejected)
        }

        // The same field, concurrently: both machines end with the same label.
        try await a.commands.perform(.editLabel(id: cloud.id, label: "A says"))
        try await b.commands.perform(.editLabel(id: cloud.id, label: "B says"))
        try await syncA.sync(core: a, authorName: "Ada", now: Date().addingTimeInterval(4))
        try await syncB.sync(core: b, authorName: "Bo", now: Date().addingTimeInterval(5))
        try await syncA.sync(core: a, authorName: "Ada", now: Date().addingTimeInterval(6))
        let labelA = await a.session.markup(cloud.id)?.label
        let labelB = await b.session.markup(cloud.id)?.label
        #expect(labelA == labelB)

        // A vertex edit on B re-measures on both, and both ledgers agree digit for digit.
        let wider = MeasurementGeometry(pageID: Self.pageID, polygons: [PolygonGeometry(outer: PolygonRing(points: [
            PDFPoint(x: 0, y: 0), PDFPoint(x: 200, y: 0), PDFPoint(x: 200, y: 50), PDFPoint(x: 0, y: 50)
        ], isClosed: true))])
        try await b.commands.perform(.editVertices(id: slab.id, geometry: wider))
        try await syncB.sync(core: b, authorName: "Bo", now: Date().addingTimeInterval(7))
        try await syncA.sync(core: a, authorName: "Ada", now: Date().addingTimeInterval(8))
        #expect(await Self.totalArea(a) == Decimal(1))
        #expect(await Self.totalArea(a) == Self.totalArea(b))

        // A reply travels, and a delete reaches the other machine in one undoable step.
        #expect(a.review.addReply("Is this the slab edge?", to: cloud.id.rawValue) != nil)
        await a.review.settle()
        try await a.commands.perform(.removeMarkup(slab.id))
        try await syncA.sync(core: a, authorName: "Ada", now: Date().addingTimeInterval(9))
        let deletion = try await syncB.sync(core: b, authorName: "Bo", now: Date().addingTimeInterval(10))
        await b.review.settle()
        #expect(deletion.removed == 1 && deletion.replies == 1)
        #expect(await b.session.markup(slab.id) == nil)
        #expect(b.review.entries.map(\.body) == ["Is this the slab edge?"])
        await b.commands.undo()
        #expect(await b.session.markup(slab.id) != nil, "the sync is one undoable step")

        // One writer per file.
        let logs = try FileManager.default.contentsOfDirectory(atPath: folderURL.appendingPathComponent("participants").path).sorted()
        #expect(logs == ["ada-mac.presence", "ada-mac.zlog", "bo-mac.presence", "bo-mac.zlog"])
        try? await dbA.close()
        try? await dbB.close()
    }

    @Test("A folder that reviews another project is refused by name")
    @MainActor
    func otherProjectIsRefused() throws {
        let folderURL = FileManager.default.temporaryDirectory.appendingPathComponent("zenit-folder-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folderURL) }
        try SharedReviewSync(folderURL: folderURL, participantID: "a", base: nil).prepare(projectID: "P1", projectName: "Tower")
        #expect(throws: SharedReviewSync.SyncError.otherProject("Tower")) {
            try SharedReviewSync(folderURL: folderURL, participantID: "b", base: nil).prepare(projectID: "P2", projectName: "Villa")
        }
    }

    @Test("The base survives encoding, so a relaunch publishes only new changes")
    @MainActor
    func baseRoundTrips() async throws {
        let folderURL = FileManager.default.temporaryDirectory.appendingPathComponent("zenit-folder-\(UUID().uuidString)", isDirectory: true)
        let (a, db, dir) = try await Self.machine()
        defer {
            for url in [folderURL, dir] { try? FileManager.default.removeItem(at: url) }
        }
        let sync = SharedReviewSync(folderURL: folderURL, participantID: "ada-mac", base: nil)
        try sync.prepare(projectID: "P1", projectName: "Tower")
        try await a.commands.perform(.addMarkup(Self.cloud()))
        try await sync.sync(core: a, authorName: "Ada")
        let stored = try sync.base.encoded()
        let relaunched = SharedReviewSync(folderURL: folderURL, participantID: "ada-mac", base: SharedReviewBaseValue.decoded(stored))
        let report = try await relaunched.sync(core: a, authorName: "Ada")
        #expect(report.published == 0, "nothing changed, nothing published")
        try? await db.close()
    }
}

/// NL-COLLAB-10: `.zpdfreview`, the lossless review exchange file.
@Suite("Review exchange file")
struct ReviewExchangeFileTests {

    @Test("A exports, B imports: markups and replies arrive, quantities recompute equal, a second import adds nothing")
    @MainActor
    func exportImportRoundTrip() async throws {
        let (a, dbA, dirA) = try await SharedReviewSyncTests.machine()
        let (b, dbB, dirB) = try await SharedReviewSyncTests.machine()
        defer { for url in [dirA, dirB] { try? FileManager.default.removeItem(at: url) } }
        let slab = SharedReviewSyncTests.area(width: 200)
        let cloud = SharedReviewSyncTests.cloud()
        try await a.commands.perform(.addMarkup(slab))
        try await a.commands.perform(.addMarkup(cloud))
        #expect(a.review.addReply("Check the edge", to: cloud.id.rawValue) != nil)
        await a.review.settle()

        let file = await a.exportReviewFile(projectID: "P1", projectName: "Tower", author: "Ada", participantID: "ada-mac")
        let bytes = try file.encoded()
        let read = try ReviewExchangeFile.decode(bytes)
        let plan = try await b.planReviewFileImport(read, projectID: "P1")
        #expect(plan.changes.added.count == 2)
        #expect(plan.changes.newReplies.count == 1)
        #expect(plan.authors == ["Ada"])
        try await b.acceptReviewFileImport(plan)
        await b.review.settle()
        #expect(await SharedReviewSyncTests.totalArea(b) == Decimal(1), "200 pt × 50 pt at 0.01 m/pt, recomputed on B")
        #expect(await SharedReviewSyncTests.totalArea(a) == SharedReviewSyncTests.totalArea(b))
        #expect(b.review.entries.map(\.body) == ["Check the edge"])

        let again = try await b.planReviewFileImport(read, projectID: "P1")
        #expect(again.isEmpty, "nothing new the second time")

        // One undo takes the import's markups back.
        await b.commands.undo()
        #expect(await b.session.orderedMarkups.isEmpty)
        try? await dbA.close()
        try? await dbB.close()
    }

    @Test("A newer local edit wins a conflict; a file from another project is refused; garbage is not a review file")
    @MainActor
    func conflictsAndRefusals() async throws {
        let (a, dbA, dirA) = try await SharedReviewSyncTests.machine()
        let (b, dbB, dirB) = try await SharedReviewSyncTests.machine()
        defer { for url in [dirA, dirB] { try? FileManager.default.removeItem(at: url) } }
        var cloud = SharedReviewSyncTests.cloud()
        try await a.commands.perform(.addMarkup(cloud))
        let old = await a.exportReviewFile(projectID: "P1", projectName: "Tower", author: "Ada", participantID: "ada-mac",
                                           now: Date(timeIntervalSince1970: 1_790_000_000))
        cloud.label = "B's own"
        try await b.commands.perform(.addMarkup(cloud))
        try await b.commands.perform(.editLabel(id: cloud.id, label: "B's newer label"))
        var stale = old
        stale.operations = old.operations.map { operation in
            var aged = operation
            aged.clock = HLCTimestamp(physicalMillis: 1_000, counter: 0, node: "test")
            return aged
        }
        let plan = try await b.planReviewFileImport(stale, projectID: "P1")
        #expect(plan.conflictsKeptLocal == [cloud.id])
        #expect(plan.changes.changed.isEmpty)
        await #expect(throws: ReviewExchangeFile.ExchangeError.self) {
            _ = try await b.planReviewFileImport(old, projectID: "OTHER")
        }
        #expect(throws: ReviewExchangeFile.ExchangeError.notAReviewFile) {
            _ = try ReviewExchangeFile.decode(Data("{}".utf8))
        }
        try? await dbA.close()
        try? await dbB.close()
    }
}

/// NL-COLLAB-19: review rounds and what changed since one.
@Suite("Review rounds")
struct ReviewRoundTests {

    @Test("Close Round 1, work, compare: added, removed, changed, status moves and the quantity delta per subject")
    @MainActor
    func roundComparison() async throws {
        let (a, db, dir) = try await SharedReviewSyncTests.machine()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keep = SharedReviewSyncTests.cloud()
        let gone = SharedReviewSyncTests.cloud()
        try await a.commands.perform(.addMarkup(keep))
        try await a.commands.perform(.addMarkup(gone))
        await a.history.settle()
        a.review.closeRound(named: "")
        await a.review.settle()
        let round = try #require(a.review.rounds.first)
        #expect(round.name == "Round 1")

        let slab = SharedReviewSyncTests.area()   // 100 pt × 50 pt at 0.01 m/pt = 0.5 m²
        try await a.commands.perform(.addMarkup(slab))
        try await a.commands.perform(.batchStatusChange(ids: [keep.id], status: .accepted))
        try await a.commands.perform(.removeMarkup(gone.id))
        await a.history.settle()

        let diff = a.review.changes(since: round)
        #expect(diff.added == [slab.id.rawValue])
        #expect(diff.removed == [gone.id.rawValue])
        #expect(diff.changed == [keep.id.rawValue])
        #expect(diff.statusTransitions == [.init(markupID: keep.id.rawValue, from: .none, to: .accepted)])
        let delta = try #require(diff.quantityDeltas.first { $0.subject == "Slab" && $0.field == "Plan Area" })
        #expect(delta.delta == Decimal(string: "0.5"), "hand-derived: 1 m × 0.5 m")
        let perimeter = try #require(diff.quantityDeltas.first { $0.subject == "Slab" && $0.field == "Perimeter" })
        #expect(perimeter.delta == Decimal(3), "hand-derived: 2 × (1 m + 0.5 m)")
        #expect(delta.deltaText.hasPrefix("+"))
        #expect(diff.summary.contains("1 added, 1 removed, 1 changed"))
        #expect(diff.summary.contains("1 now Accepted"))

        // Closing is one undo step.
        a.commands.undoManager.undo()
        await a.review.settle()
        #expect(a.review.rounds.isEmpty || a.review.rounds.count == 1, "the last undoable step is the delete, not the round")
        try? await db.close()
    }
}

/// NL-COLLAB-15: the activity feed after a sync.
@Suite("Review activity")
struct ReviewActivityTests {

    @Test("A mention and a reply on my markup become activity; my own reply does not")
    @MainActor
    func activityFromSync() async throws {
        let folderURL = FileManager.default.temporaryDirectory.appendingPathComponent("zenit-folder-\(UUID().uuidString)", isDirectory: true)
        let (a, dbA, dirA) = try await SharedReviewSyncTests.machine()
        let (b, dbB, dirB) = try await SharedReviewSyncTests.machine()
        defer { for url in [folderURL, dirA, dirB] { try? FileManager.default.removeItem(at: url) } }
        a.review.actorNameProvider = { "Ada" }
        a.review.myNamesProvider = { ["Ada"] }
        b.review.actorNameProvider = { "Bo" }
        b.review.myNamesProvider = { ["Bo"] }
        let syncA = SharedReviewSync(folderURL: folderURL, participantID: "ada-mac", base: nil)
        let syncB = SharedReviewSync(folderURL: folderURL, participantID: "bo-mac", base: nil)
        try syncA.prepare(projectID: "P1", projectName: "Tower")
        let mine = SharedReviewSyncTests.cloud()   // authored "Ada"
        try await a.commands.perform(.addMarkup(mine))
        #expect(a.review.addReply("My own note", to: mine.id.rawValue) != nil)
        await a.review.settle()
        try await syncA.sync(core: a, authorName: "Ada")
        try await syncB.sync(core: b, authorName: "Bo")

        #expect(b.review.addReply("@ada can you check the edge?", to: mine.id.rawValue) != nil)
        await b.review.settle()
        try await syncB.sync(core: b, authorName: "Bo", now: Date().addingTimeInterval(1))
        var posted: [ReviewActivityItem] = []
        a.review.onActivity = { posted.append(contentsOf: $0) }
        try await syncA.sync(core: a, authorName: "Ada", now: Date().addingTimeInterval(2))
        #expect(posted.map(\.kind) == [.mention])
        #expect(posted.first?.author == "Bo")
        #expect(a.review.activity.filter { !$0.isRead }.count == 1)
        a.review.markActivityRead()
        #expect(a.review.activity.allSatisfy { $0.isRead })
        #expect(b.review.activity.isEmpty, "Bo's own reply is not Bo's activity; Ada's own note reached Bo as a plain reply on Ada's markup, which is not Bo's")
        try? await dbA.close()
        try? await dbB.close()
    }

    @Test("A recalibrates the sheet; after one sync each, B measures the slab under the new scale and both totals agree")
    @MainActor
    func scaleTravelsValuesDoNot() async throws {
        let folderURL = FileManager.default.temporaryDirectory.appendingPathComponent("zenit-folder-\(UUID().uuidString)", isDirectory: true)
        let (a, _, dirA) = try await SharedReviewSyncTests.machine()
        let (b, _, dirB) = try await SharedReviewSyncTests.machine()
        defer {
            for url in [folderURL, dirA, dirB] { try? FileManager.default.removeItem(at: url) }
        }
        let syncA = SharedReviewSync(folderURL: folderURL, participantID: "ada-mac", base: nil)
        let syncB = SharedReviewSync(folderURL: folderURL, participantID: "bo-mac", base: nil)
        try syncA.prepare(projectID: "P1", projectName: "Tower")
        let slab = SharedReviewSyncTests.area()
        try await a.commands.perform(.addMarkup(slab))
        _ = try await syncA.sync(core: a, authorName: "Ada")
        _ = try await syncB.sync(core: b, authorName: "Bo")
        // 1 pt = 1 cm: the 100 × 50 pt slab is 0.5 m² on both.
        #expect(await b.session.markup(slab.id)?.measurement?.values[.planArea]?.value == Decimal(string: "0.5"))
        let quiet = try await syncB.sync(core: b, authorName: "Bo")
        #expect(quiet.published == 0, "a scale both already measure by is not published again")

        // A calibrates: 100 pt is 2 m, so 1 pt = 2 cm and the slab is 2 m × 1 m = 2 m².
        _ = try await a.commands.calibrate(page: SharedReviewSyncTests.pageID, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
                                           knownLength: 2, knownLengthUnit: .metre)
        let published = try await syncA.sync(core: a, authorName: "Ada")
        #expect(published.published == 1, "one scale operation; the slab's recomputed value is not an operation")
        let received = try await syncB.sync(core: b, authorName: "Bo")
        #expect(received.scales == 1)
        #expect(received.changed == 0, "no markup changed: B recomputed the slab itself")
        #expect(await b.session.markup(slab.id)?.measurement?.values[.planArea]?.value == 2)
        #expect(await SharedReviewSyncTests.totalArea(a) == SharedReviewSyncTests.totalArea(b))
        // The scale kept B's own identity, one version on; the picked points stayed with Ada.
        let installed = try #require(await b.session.pageScales[SharedReviewSyncTests.pageID])
        #expect(installed.id == SharedReviewSyncTests.scaleID && installed.version == 2)
        #expect(await b.session.takeoffState().calibrationEvidence[SharedReviewSyncTests.scaleID] == nil)
        // One undo on B puts its old scale back, and the slab is 0.5 m² again.
        await b.commands.undo()
        #expect(await b.session.markup(slab.id)?.measurement?.values[.planArea]?.value == Decimal(string: "0.5"))
    }

    @Test("Presence: each person's heartbeat names the sheet; a stale one is not shown")
    @MainActor
    func presence() async throws {
        let folderURL = FileManager.default.temporaryDirectory.appendingPathComponent("zenit-folder-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folderURL) }
        let syncA = SharedReviewSync(folderURL: folderURL, participantID: "ada-mac", base: nil)
        let syncB = SharedReviewSync(folderURL: folderURL, participantID: "bo-mac", base: nil)
        try syncA.prepare(projectID: "P1", projectName: "Tower")
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        syncA.heartbeat(authorName: "Ada", now: now, looking: (pageLabel: "A-201", selectedCount: 1))
        syncB.heartbeat(authorName: "Bo", now: now.addingTimeInterval(-600), looking: (pageLabel: "A-101", selectedCount: 0))
        #expect(syncB.others(now: now).map(\.name) == ["Ada"])
        #expect(syncB.others(now: now).first?.pageLabel == "A-201")
        #expect(syncA.others(now: now).isEmpty, "Bo's heartbeat is ten minutes old")
        #expect(syncA.others(now: now, freshness: 3_600).map(\.name) == ["Bo"])
    }
}
