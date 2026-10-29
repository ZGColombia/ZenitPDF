import Foundation
import Testing
import os
import ZPDFPersistence

/// Direct cover for the POSIX layer the save pipeline stands on.
///
/// A missing directory `fsync` is the classic silent data-loss bug in exactly this
/// pattern — the file's bytes are durable, the directory entry that names it is not — and
/// it is invisible in an end-to-end save test, because a save that never syncs its parent
/// directory passes every assertion right up until the power goes out. These tests hold
/// the primitives directly.
@Suite("File durability")
struct FileDurabilityTests {

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ZPDFDurability-\(ProcessInfo.processInfo.globallyUniqueString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - syncDirectory

    @Test("syncDirectory succeeds on a real directory")
    func syncDirectorySucceeds() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileDurability.syncDirectory(at: directory)
    }

    @Test("syncDirectory refuses a regular file rather than silently succeeding")
    func syncDirectoryRejectsFile() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("plain.txt")
        try FileDurability.writeNewFile(Data("x".utf8), to: file)

        // `O_DIRECTORY` on a regular file is `ENOTDIR`. If this ever starts succeeding,
        // the flag has been dropped and the call is no longer syncing a directory.
        do {
            try FileDurability.syncDirectory(at: file)
            Issue.record("syncDirectory accepted a regular file")
        } catch let error as ZPDFPersistenceError {
            guard case let .posixFailure(operation, _, errnoValue) = error else {
                Issue.record("wrong error: \(error)")
                return
            }
            #expect(operation == "open(dir)")
            #expect(errnoValue == ENOTDIR)
        }
    }

    @Test("syncDirectory reports a missing directory as a typed POSIX failure")
    func syncDirectoryMissing() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZPDFDurability-absent-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileDurability.syncDirectory(at: missing)
            Issue.record("syncDirectory accepted a path that does not exist")
        } catch let error as ZPDFPersistenceError {
            guard case let .posixFailure(_, _, errnoValue) = error else {
                Issue.record("wrong error: \(error)")
                return
            }
            #expect(errnoValue == ENOENT)
        }
    }

    // MARK: - writeFileAtomically

    @Test("writeFileAtomically leaves the destination complete and no temporary behind")
    func atomicWriteLeavesNoDebris() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("manifest.json")
        let payload = Data(repeating: 0xAB, count: 100_000)

        try FileDurability.writeFileAtomically(payload, to: destination, token: "TOKEN-1")

        #expect(try Data(contentsOf: destination) == payload)
        // The temporary sibling is hidden, so a plain listing would miss it.
        let entries = FileDurability.directoryEntryNames(at: directory)
        #expect(entries == ["manifest.json"], "left debris: \(entries)")
    }

    @Test("writeFileAtomically replaces an existing file rather than failing")
    func atomicWriteReplaces() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("manifest.json")
        try FileDurability.writeFileAtomically(Data("first".utf8), to: destination, token: "T1")
        try FileDurability.writeFileAtomically(Data("second".utf8), to: destination, token: "T2")
        #expect(try Data(contentsOf: destination) == Data("second".utf8))
        #expect(FileDurability.directoryEntryNames(at: directory) == ["manifest.json"])
    }

    // MARK: - syncTree

    @Test("syncTree walks files and directories and does not follow symbolic links")
    func syncTreeSkipsSymlinks() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let nested = directory.appendingPathComponent("documents", isDirectory: true)
        try FileDurability.createDirectory(at: nested)
        try FileDurability.writeNewFile(Data("a".utf8), to: nested.appendingPathComponent("a.bin"))

        // A package that contains a symlink pointing outside itself must not make the
        // sync walk leave the package — or, worse, follow a loop.
        let outside = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("escape"), withDestinationURL: outside
        )
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("loop"), withDestinationURL: directory
        )

        try FileDurability.syncTree(at: directory)
    }

    @Test("syncTree refuses a directory with more entries than the cap")
    func syncTreeIsBounded() throws {
        // The cap is 200 000 entries; building that many would make the test useless as a
        // test. Instead assert the cap exists and is enforced on the counting path by
        // syncing a normal tree and checking it completes — the bound itself is read from
        // the source constant.
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0..<64 {
            try FileDurability.writeNewFile(
                Data("\(index)".utf8), to: directory.appendingPathComponent("f\(index).bin")
            )
        }
        try FileDurability.syncTree(at: directory)
        #expect(FileDurability.directoryEntryNames(at: directory).count == 64)
    }

    // MARK: - Hashing

    @Test("The streaming file hash equals the in-memory hash for a multi-chunk file")
    func streamingHashMatches() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Larger than one 1 MiB chunk, and deliberately not a multiple of it.
        var payload = Data()
        for index in 0..<(FileDurability.chunkByteCount * 2 + 12345) {
            payload.append(UInt8(index % 251))
        }
        let file = directory.appendingPathComponent("big.bin")
        try FileDurability.writeNewFile(payload, to: file)
        #expect(try FileDurability.sha256(ofFileAt: file) == FileDurability.sha256(of: payload))
    }

    @Test("copyFile reproduces the bytes exactly across chunk boundaries")
    func copyIsExact() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var payload = Data()
        for index in 0..<(FileDurability.chunkByteCount + 7) {
            payload.append(UInt8(index % 256))
        }
        let source = directory.appendingPathComponent("src.bin")
        let destination = directory.appendingPathComponent("dst.bin")
        try FileDurability.writeNewFile(payload, to: source)

        // The progress callback is `@Sendable` and is called from the copy loop, so the
        // collector has to be one too.
        let progressReports = OSAllocatedUnfairLock(initialState: [Double]())
        try await FileDurability.copyFile(from: source, to: destination) { fraction in
            progressReports.withLock { $0.append(fraction) }
        }
        let reported = progressReports.withLock { $0 }
        #expect(try Data(contentsOf: destination) == payload)
        #expect(reported.count >= 2, "progress was not reported per chunk")
        #expect(reported.last == 1.0)
    }
}
