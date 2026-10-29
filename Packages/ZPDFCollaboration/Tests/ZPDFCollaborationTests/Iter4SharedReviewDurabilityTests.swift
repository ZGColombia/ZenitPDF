import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFCollaboration

/// The Shared Review log is on the platter before anybody relies on it (U-102).
///
/// A power loss cannot be staged in a test, so these assert the flushes themselves, in the order
/// that makes the log durable — through ``SharedReviewFolder/flushRecord``, which records only
/// while a test has switched it on.
@Suite("Iteration 4 — Shared Review log durability", .serialized)
struct Iter4SharedReviewDurabilityTests {

    /// The paths under `root` flushed while `body` ran.
    static func flushes(under root: URL, _ body: () throws -> Void) rethrows -> [String] {
        SharedReviewFolder.flushRecord.withLock { $0 = [] }
        defer { SharedReviewFolder.flushRecord.withLock { $0 = nil } }
        try body()
        return SharedReviewFolder.flushRecord.withLock { $0 ?? [] }.filter { $0.hasPrefix(root.path + "/") }
    }

    /// Old output: `[]` — the compacted log was written with `Data.write(to:options:)` and renamed
    /// over the log with nothing flushed, so after a power loss the rename could persist without
    /// the data: an empty or zero-filled log, read as no operations, and every machine that knew
    /// this participant's markups deleted them on its next sync.
    @Test("U-102: a compaction flushes the new log before the rename and the directory after it")
    func compactionIsFlushedAroundTheRename() throws {
        let (folder, url) = try Iter3SharedReviewLogTests.folder()
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Iter3SharedReviewLogTests.t0.addingTimeInterval(86_400)
        let markup = MarkupID(UUID())
        // Four removals of one markup: compaction keeps the newest, so the log shrinks.
        let removals = (0..<4).map {
            Iter3SharedReviewLogTests.operation(.removeMarkup(markup), millis: 1_790_000_000_000 + Int64($0), node: "ada-mac")
        }
        try folder.append(removals, participant: "ada-mac")
        let log = Iter3SharedReviewLogTests.log(url, "ada-mac")
        let size = try Data(contentsOf: log).count

        var compacted = false
        let flushed = try Self.flushes(under: url) {
            compacted = try folder.compactOwnLogIfOverLimit(participant: "ada-mac", now: now, limit: size - 1)
        }
        #expect(compacted)
        #expect(flushed.count == 2, "\(flushed)")
        let temporaryName = flushed.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        #expect(temporaryName.hasPrefix(".ada-mac.zlog.") && temporaryName.hasSuffix(".tmp"),
                "the new log is flushed under its temporary name — before the rename that retires that name")
        #expect(flushed.last == folder.participantsURL.path, "then the directory that records the rename")
        #expect(!FileManager.default.fileExists(atPath: flushed.first ?? "/"), "the temporary name is gone: it was renamed")

        let read = folder.readAll(now: now)
        #expect(read.isComplete)
        #expect(read.operations == [removals[3]])
    }

    /// Old output: `[]` — the lines were written and the append returned, and the caller recorded
    /// them as published while they could still be only in the drive's cache.
    ///
    /// V-090, the first append: old output `[log]` — the append that created the log flushed the
    /// file but never `participants/`, so after a power loss the new name could be gone while
    /// the base recorded its lines as published. A later append to the same log adds no name and
    /// flushes the file alone.
    @Test("U-102/V-090: an append flushes its lines before it returns, and the first one the new name too")
    func appendIsFlushedBeforeItReturns() throws {
        let (folder, url) = try Iter3SharedReviewLogTests.folder()
        defer { try? FileManager.default.removeItem(at: url) }
        let log = Iter3SharedReviewLogTests.log(url, "ada-mac")
        let operation = Iter3SharedReviewLogTests.operation(.removeMarkup(MarkupID(UUID())), millis: 1_790_000_000_000, node: "ada-mac")
        let second = Iter3SharedReviewLogTests.operation(.removeMarkup(MarkupID(UUID())), millis: 1_790_000_000_001, node: "ada-mac")

        let flushed = try Self.flushes(under: url) {
            try folder.append([operation], participant: "ada-mac")
        }
        #expect(flushed == [log.path, folder.participantsURL.path], "the file, then the directory that names it")
        let flushedAgain = try Self.flushes(under: url) {
            try folder.append([second], participant: "ada-mac")
        }
        #expect(flushedAgain == [log.path])
        #expect(folder.readAll(now: Iter3SharedReviewLogTests.t0.addingTimeInterval(86_400)).operations == [operation, second])
    }

    @Test("U-102: with recording off — the application's state — nothing is kept")
    func recordingIsOffByDefault() throws {
        let (folder, url) = try Iter3SharedReviewLogTests.folder()
        defer { try? FileManager.default.removeItem(at: url) }
        let operation = Iter3SharedReviewLogTests.operation(.removeMarkup(MarkupID(UUID())), millis: 1_790_000_000_000, node: "ada-mac")
        try folder.append([operation], participant: "ada-mac")
        #expect(SharedReviewFolder.flushRecord.withLock { $0 } == nil)
    }
}
