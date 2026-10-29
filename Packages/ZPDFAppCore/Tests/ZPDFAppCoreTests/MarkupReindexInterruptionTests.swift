import Foundation
import GRDB
import os
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFPersistence
import ZPDFSearch

/// R-152 re-fix: a markup re-index interrupted between its markup-table commit and its
/// full-text rebuild must not leave the incremental cache claiming rows that were never indexed.
///
/// The interruption is the real one: the document cancels its re-index task on every new edit,
/// and a cancellation that lands after the markup commit makes `TextIndexer.indexAnnotations`
/// throw at its first cancellation check.
@Suite("R-152: an interrupted markup re-index heals")
struct MarkupReindexInterruptionTests {

    /// Cancels the task it was armed with on the commit of the next transaction that changed
    /// the `markup` table, then disarms. Runs on GRDB's writer queue.
    private final class CancelOnMarkupCommit: TransactionObserver, Sendable {
        private struct State: Sendable {
            var task: Task<AnnotationIndexReport, any Error>?
            var sawMarkupChange = false
            var fired = false
        }
        private let state = OSAllocatedUnfairLock(initialState: State())

        func arm(cancelling task: Task<AnnotationIndexReport, any Error>) {
            state.withLock { $0.task = task }
        }

        var fired: Bool { state.withLock { $0.fired } }

        func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
            eventKind.tableName == "markup"
        }

        func databaseDidChange(with event: DatabaseEvent) {
            state.withLock { if $0.task != nil { $0.sawMarkupChange = true } }
        }

        func databaseDidCommit(_ db: Database) {
            let task: Task<AnnotationIndexReport, any Error>? = state.withLock { state in
                guard state.sawMarkupChange, let task = state.task else { return nil }
                state.task = nil
                state.sawMarkupChange = false
                state.fired = true
                return task
            }
            task?.cancel()
        }

        func databaseDidRollback(_ db: Database) {
            state.withLock { $0.sawMarkupChange = false }
        }
    }

    private static func markup(subject: String, page: ZPDFContracts.PageDescriptor, x: Double) -> ZPDFContracts.MarkupRecord {
        ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: page.documentID, pageID: page.id, kind: .measurement, tool: .area,
            subject: subject, author: "t",
            geometry: MeasurementGeometry(pageID: page.id, polygons: [PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: x, y: 100), PDFPoint(x: x + 20, y: 100), PDFPoint(x: x + 20, y: 110), PDFPoint(x: x, y: 110)
            ], isClosed: true))]),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private static func markupHits(_ text: String, in index: DocumentSearchIndex) async throws -> [SearchHit] {
        try await index.service.search(SearchRequest(
            text: text, scope: .project(projectId: index.projectKey), resolvesBounds: false
        )).hits.filter { $0.sourceType == .markupSubject }
    }

    @Test("R-152: a cancel after the markup commit leaves the next re-index rebuilding that markup")
    func cancelledRebuildIsHealedByTheNextReindex() async throws {
        let index = try await DocumentSearchIndexTests.makeIndex()
        defer { Task { await index.shutDown() } }
        let pages = DocumentSearchIndexTests.pages(count: 1, documentID: DocumentID(UUID()))
        var markups = [
            Self.markup(subject: "Slab", page: pages[0], x: 50),
            Self.markup(subject: "Wall", page: pages[0], x: 150)
        ]
        let xID = markups[0].id.rawValue.uuidString

        let first = try await index.indexMarkups(markups, pages: pages)
        #expect(first.markupRowsInserted == 2)
        let before = try await Self.markupHits("slab", in: index).map(\.sourceId)
        #expect(before == [xID])

        // X's subject changes, and the re-index is cancelled the moment its markup row commits —
        // what a second edit arriving mid-rebuild does in the app.
        let observer = CancelOnMarkupCommit()
        try await index.database.addTransactionObserver(observer)
        markups[0].subject = "Terrazzo"
        let edited = markups
        let (gate, open) = AsyncStream<Void>.makeStream()
        let interrupted = Task { () async throws -> AnnotationIndexReport in
            for await _ in gate { break }
            return try await index.indexMarkups(edited, pages: pages)
        }
        observer.arm(cancelling: interrupted)
        open.yield()
        open.finish()
        let outcome = await interrupted.result
        #expect(observer.fired, "the markup commit was never observed")
        guard case .failure = outcome else {
            Issue.record("the interrupted re-index returned instead of throwing: \(outcome)")
            return
        }
        // The failure came after the markup table was written, not before it.
        let stored = try await index.database.read { db in
            try String.fetchOne(db, sql: "SELECT subject FROM markup WHERE id = ?", arguments: [xID])
        }
        #expect(stored == "Terrazzo")

        // An unrelated edit to Y. Old output: incremental against the cache that already held
        // X's new row, so only Y was rebuilt — "terrazzo" found nothing and "slab" still found X
        // for the rest of the session.
        markups[1].subject = "Wall north"
        let healed = try await index.indexMarkups(markups, pages: pages)
        #expect(healed.markupRowsInserted == 2, "an interrupted write is followed by a full rebuild")
        let newSubject = try await Self.markupHits("terrazzo", in: index).map(\.sourceId)
        let oldSubject = try await Self.markupHits("slab", in: index).map(\.sourceId)
        let unrelated = try await Self.markupHits("north", in: index).map(\.sourceId)
        #expect(newSubject == [xID])
        #expect(oldSubject.isEmpty)
        #expect(unrelated == [markups[1].id.rawValue.uuidString])

        // And the cache is trustworthy again: the next edit is incremental.
        markups[1].subject = "Wall south"
        let next = try await index.indexMarkups(markups, pages: pages)
        #expect(next.markupRowsInserted == 1)
        #expect(next.rowsDeleted == 1)
    }
}
