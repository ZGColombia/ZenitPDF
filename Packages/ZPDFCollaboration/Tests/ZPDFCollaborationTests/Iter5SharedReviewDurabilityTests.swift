import Darwin
import Foundation
import Testing
import ZPDFContracts
import ZPDFCollaboration

/// The append that creates a participant's log makes the new name durable, or
/// publishes nothing (V-090).
@Suite("Iteration 5 — Shared Review log durability", .serialized)
struct Iter5SharedReviewDurabilityTests {

    /// `participants/` may be written and searched but not opened for reading, so a file can be
    /// created in it while the directory itself cannot be opened for the flush.
    ///
    /// Old output: the append succeeded and the log existed — the directory was never flushed,
    /// so nothing noticed that the new name could not be made durable, and the caller recorded
    /// the lines as published.
    @Test("V-090: a first append whose directory cannot be flushed throws and leaves no log behind")
    func firstAppendThatCannotFlushTheNameLeavesNoLog() throws {
        let (folder, url) = try Iter3SharedReviewLogTests.folder()
        let participants = url.appendingPathComponent("participants", isDirectory: true)
        defer {
            _ = chmod(participants.path, 0o755)
            try? FileManager.default.removeItem(at: url)
        }
        let log = Iter3SharedReviewLogTests.log(url, "ada-mac")
        let operation = Iter3SharedReviewLogTests.operation(.removeMarkup(MarkupID(UUID())), millis: 1_790_000_000_000, node: "ada-mac")
        try #require(chmod(participants.path, 0o300) == 0)

        #expect {
            try folder.append([operation], participant: "ada-mac")
        } throws: { error in
            guard case SharedReviewFolder.FolderError.unwritable = error else { return false }
            return true
        }
        var status = stat()
        #expect(lstat(log.path, &status) != 0 && errno == ENOENT, "a log nobody may rely on must not be left behind")

        // The fault clears: the same append publishes, and the lines read back.
        try #require(chmod(participants.path, 0o755) == 0)
        try folder.append([operation], participant: "ada-mac")
        #expect(folder.readAll(now: Iter3SharedReviewLogTests.t0.addingTimeInterval(86_400)).operations == [operation])
    }
}
