import Foundation
import os
import Testing
@testable import ZPDFAppCore
import ZPDFCollaboration
import ZPDFContracts

/// Through the real session and command bus: a sync
/// that cannot read somebody's log refuses instead of removing that person's markups (T-079),
/// and the folder is read off the main actor (T-081, T-083).
@Suite("Iteration 3 — Shared Review sync reads the whole folder or refuses", .serialized)
struct Iter3SharedReviewSyncTests {

    /// Old output: the sync returned `removed == 2` and Bo's document no longer held Ada's two
    /// markups — the unreadable log merged as empty, and both were known from the last sync.
    @Test("T-079: a log that cannot be read refuses the sync, and nobody's markups are removed")
    @MainActor
    func unreadableLogRefusesTheSync() async throws {
        let folderURL = FileManager.default.temporaryDirectory.appendingPathComponent("zenit-it3-folder-\(UUID().uuidString)", isDirectory: true)
        let (a, dbA, dirA) = try await SharedReviewSyncTests.machine()
        let (b, dbB, dirB) = try await SharedReviewSyncTests.machine()
        defer { for url in [folderURL, dirA, dirB] { try? FileManager.default.removeItem(at: url) } }
        let syncA = SharedReviewSync(folderURL: folderURL, participantID: "ada-mac", base: nil)
        let syncB = SharedReviewSync(folderURL: folderURL, participantID: "bo-mac", base: nil)
        try syncA.prepare(projectID: "P1", projectName: "Tower")
        try syncB.prepare(projectID: "P1", projectName: "Tower")

        let slab = SharedReviewSyncTests.area()
        let cloud = SharedReviewSyncTests.cloud()
        try await a.commands.perform(.addMarkup(slab))
        try await a.commands.perform(.addMarkup(cloud))
        try await syncA.sync(core: a, authorName: "Ada")
        let received = try await syncB.sync(core: b, authorName: "Bo", now: Date().addingTimeInterval(1))
        #expect(received.added == 2)

        // Ada's log is evicted by the sync service and cannot be fetched while Bo is offline.
        syncB.readFile = { url in url.lastPathComponent == "ada-mac.zlog" ? nil : SharedReviewSync.readLog(url) }
        let baseBefore = syncB.base
        await #expect(throws: SharedReviewSync.SyncError.self) {
            try await syncB.sync(core: b, authorName: "Bo", now: Date().addingTimeInterval(2))
        }
        let slabKept = await b.session.markup(slab.id) != nil
        let cloudKept = await b.session.markup(cloud.id) != nil
        #expect(slabKept && cloudKept, "Bo keeps Ada's markups while her log cannot be read")
        #expect(syncB.base == baseBefore, "a refused sync leaves the base where it was")

        // The same refusal names the file, in words the status note can show.
        do {
            _ = try await syncB.sync(core: b, authorName: "Bo", now: Date().addingTimeInterval(3))
            Issue.record("the sync must refuse")
        } catch let SharedReviewSync.SyncError.refused(detail) {
            #expect(detail.contains("ada-mac.zlog"))
        }

        // Back online: nothing was lost, and nothing is removed.
        syncB.readFile = SharedReviewSync.readLog
        let online = try await syncB.sync(core: b, authorName: "Bo", now: Date().addingTimeInterval(4))
        #expect(online.removed == 0)
        #expect(await b.session.orderedMarkups.count == 2)
        try? await dbA.close()
        try? await dbB.close()
    }

    /// Old output: Ada's own sync threw "the shared review file “ada-mac.zlog” could not be read
    /// in full…" and the log stayed at 268 439 552 bytes: the sync's first read refused her own
    /// over-cap log before the append — the only place compaction ran — was reached, so nothing
    /// in the product could ever shrink it and every participant's sync refused for good.
    @Test("T-079: an own log already over the cap is compacted by its owner's next sync, and everybody syncs again")
    @MainActor
    func ownLogOverTheCapIsCompactedByTheOwnersSync() async throws {
        let folderURL = FileManager.default.temporaryDirectory.appendingPathComponent("zenit-it3-folder-\(UUID().uuidString)", isDirectory: true)
        let (a, dbA, dirA) = try await SharedReviewSyncTests.machine()
        let (b, dbB, dirB) = try await SharedReviewSyncTests.machine()
        defer { for url in [folderURL, dirA, dirB] { try? FileManager.default.removeItem(at: url) } }
        let syncA = SharedReviewSync(folderURL: folderURL, participantID: "ada-mac", base: nil)
        let syncB = SharedReviewSync(folderURL: folderURL, participantID: "bo-mac", base: nil)
        try syncA.prepare(projectID: "P1", projectName: "Tower")
        try syncB.prepare(projectID: "P1", projectName: "Tower")

        let slab = SharedReviewSyncTests.area()
        let cloud = SharedReviewSyncTests.cloud()
        try await a.commands.perform(.addMarkup(slab))
        try await a.commands.perform(.addMarkup(cloud))
        try await syncA.sync(core: a, authorName: "Ada")
        #expect(try await syncB.sync(core: b, authorName: "Bo", now: Date().addingTimeInterval(1)).added == 2)

        // Ada's log, grown past the cap by a build from before the append kept it under (a sparse
        // file past the end of her lines, as the checker planted it).
        let log = folderURL.appendingPathComponent("participants/ada-mac.zlog")
        let oversized = UInt64(OperationLogCodec.maximumLogBytes + 4096)
        let handle = try FileHandle(forWritingTo: log)
        try handle.truncate(atOffset: oversized)
        try handle.close()
        func size() throws -> UInt64 { try #require(try FileManager.default.attributesOfItem(atPath: log.path)[.size] as? UInt64) }

        // Bo may not rewrite Ada's log: his sync refuses, naming it, and leaves it alone.
        do {
            _ = try await syncB.sync(core: b, authorName: "Bo", now: Date().addingTimeInterval(2))
            Issue.record("Bo's sync must refuse while Ada's log is over the cap")
        } catch let SharedReviewSync.SyncError.refused(detail) {
            #expect(detail.contains("ada-mac.zlog"))
        }
        #expect(try size() == oversized, "only its owner rewrites a log")

        // Ada's next sync compacts her own log first, then publishes and merges as usual — here
        // with a new markup, so the append after the compaction is proven too.
        let third = SharedReviewSyncTests.area(width: 200)
        try await a.commands.perform(.addMarkup(third))
        let ada = try await syncA.sync(core: a, authorName: "Ada", now: Date().addingTimeInterval(3))
        #expect(ada.published == 1)
        #expect(ada.removed == 0)
        #expect(try size() < 64 * 1024, "back to the size of her lines")
        #expect(await a.session.orderedMarkups.count == 3)

        // Bo syncs again: every log reads, nothing of Ada's is removed, her new markup arrives.
        let bo = try await syncB.sync(core: b, authorName: "Bo", now: Date().addingTimeInterval(4))
        #expect(bo.removed == 0)
        #expect(bo.added == 1)
        let slabKept = await b.session.markup(slab.id) != nil
        let cloudKept = await b.session.markup(cloud.id) != nil
        let thirdArrived = await b.session.markup(third.id) != nil
        #expect(slabKept && cloudKept && thirdArrived)
        try? await dbA.close()
        try? await dbB.close()
    }

    /// Old output: every call was on the main thread — the folder was read and decoded
    /// synchronously on the main actor, where a coordinated read of an evicted file (or a FIFO)
    /// held the whole interface.
    @Test("T-081/T-083: the folder is read off the main actor")
    @MainActor
    func folderIsReadOffTheMainActor() async throws {
        let folderURL = FileManager.default.temporaryDirectory.appendingPathComponent("zenit-it3-folder-\(UUID().uuidString)", isDirectory: true)
        let (a, db, dir) = try await SharedReviewSyncTests.machine()
        defer { for url in [folderURL, dir] { try? FileManager.default.removeItem(at: url) } }
        let sync = SharedReviewSync(folderURL: folderURL, participantID: "ada-mac", base: nil)
        try sync.prepare(projectID: "P1", projectName: "Tower")
        try await a.commands.perform(.addMarkup(SharedReviewSyncTests.cloud()))
        let threads = ThreadLog()
        sync.readFile = { url in
            threads.record(Thread.isMainThread)
            return SharedReviewSync.readLog(url)
        }
        try await sync.sync(core: a, authorName: "Ada")
        let calls = threads.calls
        #expect(!calls.isEmpty, "the reader was used")
        #expect(!calls.contains(true), "no read ran on the main thread")
        try? await db.close()
    }
}

/// Which threads a reader ran on (`OSAllocatedUnfairLock`: Sendable, and available on macOS 14).
private final class ThreadLog: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: [Bool]())
    func record(_ onMain: Bool) { state.withLock { $0.append(onMain) } }
    var calls: [Bool] { state.withLock { $0 } }
}
