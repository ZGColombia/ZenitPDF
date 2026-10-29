import Foundation
import Testing
import ZPDFPersistence

/// A save's journal line costs the two device flushes its atomic
/// write already makes, not four (T-084).
@Suite("Iteration 3 — persistence", .serialized)
struct Iter3PersistenceTests {

    /// Old output: 4 — `writeFileAtomically` flushed the temporary file and `recovery/`, then
    /// the `durable` branch flushed the renamed file (the same inode) and `recovery/` again.
    @Test("T-084: a save's journal line issues two F_FULLFSYNC, not four")
    func saveJournalLineFlushesTwice() async throws {
        let workspace = try TestSupport.makeWorkspace("Iter3JournalFlush")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let package = try await TestSupport.createPackage(workspace)
        let (_, counts) = await FileDurability.Statistics.measure {
            await package.appendSaveJournal(token: "iter3-journal", checkpoint: .didCommit)
        }
        #expect(counts.fullSyncCount == 2, "\(counts.fullSyncCount) full syncs for one journal line")

        // Still durable where it matters: the line is in the journal on disk.
        let journal = RecoveryJournal.read(from: workspace.packageURL.member(ProjectPackageLayout.recoveryJournal))
        #expect(journal.entries.last?.token == "iter3-journal")
        #expect(journal.entries.last?.checkpoint == .didCommit)
        try? await package.close()
    }
}
