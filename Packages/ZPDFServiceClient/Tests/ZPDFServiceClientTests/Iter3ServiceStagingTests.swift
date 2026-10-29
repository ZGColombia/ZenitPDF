import Foundation
import Testing
import ZPDFServiceWire
@testable import ZPDFGeometryServiceCore

/// Iteration 3: a staged copy the geometry core reuses is kept fresh for the
/// startup sweep of a second service instance, and a lease on a copy that was replaced cannot
/// take a user off its replacement (T-085).
@Suite("Iteration 3 — geometry staging leases", .serialized)
struct Iter3ServiceStagingTests {

    /// Old output: the sweep removed the copy (1) — reuse never touched it, so it kept the
    /// modification time of its creation for as long as it was in use.
    @Test("T-085: a reused staged copy is touched at every lease, so a second instance's sweep leaves it")
    func reusedCopyIsTouched() async throws {
        let fixture = try ServiceTestSupport.makeFixture(.rectangle)
        defer { ServiceTestSupport.remove(fixture.directory) }
        let core = GeometryServiceCore(stagingIdleExpiry: .seconds(120))
        let handle = try FileHandle(forReadingFrom: fixture.url)
        defer { try? handle.close() }

        guard case .success(let first) = await core.acquireStagedDocument(fileDescriptor: handle.fileDescriptor) else {
            Issue.record("the document must stage"); return
        }
        await core.releaseStagedDocument(first)
        // The copy was made twenty minutes ago, as far as the file system can tell.
        let old = Date().addingTimeInterval(-20 * 60)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: first.url.path)

        guard case .success(let reused) = await core.acquireStagedDocument(fileDescriptor: handle.fileDescriptor) else {
            Issue.record("the document must be reused"); return
        }
        #expect(reused.url == first.url, "the same copy, reused")
        #expect(await core.stagingCopyCount == 1)
        // A second service instance starting now sweeps copies older than ten minutes. Only this
        // test's copy is considered: the prefix is its own file name.
        let removed = ServiceStaging.sweepStale(prefixes: [first.url.lastPathComponent], in: first.url.deletingLastPathComponent())
        #expect(removed == 0)
        #expect(FileManager.default.fileExists(atPath: first.url.path))
        await core.releaseStagedDocument(reused)
        await core.removeIdleStagedDocuments()
    }

    /// Old output: the fresh copy was deleted while its lease was still out — the stale release
    /// took its one user, and the idle clean-up then removed it.
    @Test("T-085: releasing a lease on a vanished copy leaves the replacement's lease count alone")
    func staleReleaseDoesNotCountAgainstTheReplacement() async throws {
        let fixture = try ServiceTestSupport.makeFixture(.rectangle)
        defer { ServiceTestSupport.remove(fixture.directory) }
        let core = GeometryServiceCore(stagingIdleExpiry: .seconds(120))
        let handle = try FileHandle(forReadingFrom: fixture.url)
        defer { try? handle.close() }

        guard case .success(let stale) = await core.acquireStagedDocument(fileDescriptor: handle.fileDescriptor) else {
            Issue.record("the document must stage"); return
        }
        // Another instance's sweep deletes the copy while its lease is out.
        try FileManager.default.removeItem(at: stale.url)
        guard case .success(let fresh) = await core.acquireStagedDocument(fileDescriptor: handle.fileDescriptor) else {
            Issue.record("the document must stage again"); return
        }
        #expect(fresh.url != stale.url)
        #expect(await core.stagingCopyCount == 2)

        await core.releaseStagedDocument(stale)
        await core.removeIdleStagedDocuments()
        #expect(FileManager.default.fileExists(atPath: fresh.url.path), "the replacement is still leased")
        #expect(await core.stagedDocumentCount == 1)

        await core.releaseStagedDocument(fresh)
        await core.removeIdleStagedDocuments()
        #expect(!FileManager.default.fileExists(atPath: fresh.url.path))
        #expect(await core.stagedDocumentCount == 0)
    }
}
