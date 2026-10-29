import Foundation
import Testing
@testable import ZPDFCollaboration

/// S-126: presence files were read whole before the 64 KiB check, and nothing asked whether an
/// entry was a regular file. The folder is writable by anybody who can reach it and this read
/// runs on every presence refresh.
@Suite("Shared Review Folder — presence files are bounded before they are read (S-126)")
struct Iter2PresenceBoundsTests {

    static let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    static func folder() throws -> (SharedReviewFolder, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zpdf-presence-bounds-\(UUID().uuidString)", isDirectory: true)
        let shared = SharedReviewFolder(url: url)
        try shared.prepare(projectID: "P1", projectName: "Tower", now: t0)
        try shared.writePresence(.init(participantID: "ada", name: "Ada", lastSync: t0))
        return (shared, url)
    }

    @Test("A presence entry that is a symbolic link is not followed")
    func symlinkSkipped() throws {
        let (shared, url) = try Self.folder()
        defer { try? FileManager.default.removeItem(at: url) }
        let target = url.appendingPathComponent("elsewhere.json")
        try JSONEncoder().encode(SharedReviewFolder.Presence(participantID: "eve", name: "Eve", lastSync: Self.t0)).write(to: target)
        try FileManager.default.createSymbolicLink(at: url.appendingPathComponent("participants/eve.presence"), withDestinationURL: target)
        // Old output: ["Ada", "Eve"] — the link was read through to whatever it named.
        #expect(shared.presences().map(\.name) == ["Ada"])
    }

    @Test("An oversized presence file is refused on its size, before it is read")
    func oversizedSkipped() throws {
        let (shared, url) = try Self.folder()
        defer { try? FileManager.default.removeItem(at: url) }
        // A 1 GiB sparse file costs no disk; the old code allocated and filled 1 GiB to refuse it.
        let huge = url.appendingPathComponent("participants/eve.presence")
        #expect(FileManager.default.createFile(atPath: huge.path, contents: Data("{".utf8)))
        let handle = try FileHandle(forWritingTo: huge)
        try handle.truncate(atOffset: 1 << 30)
        try handle.close()
        #expect(shared.presences().map(\.name) == ["Ada"])
        #expect(SharedReviewFolder.readSmallRegularFile(huge, limit: SharedReviewFolder.maximumPresenceBytes) == nil)

        // The bound is inclusive: exactly the limit is read, one byte more is not.
        let atLimit = url.appendingPathComponent("at-limit")
        try Data(repeating: 0x20, count: SharedReviewFolder.maximumPresenceBytes).write(to: atLimit)
        #expect(SharedReviewFolder.readSmallRegularFile(atLimit, limit: SharedReviewFolder.maximumPresenceBytes)?.count == SharedReviewFolder.maximumPresenceBytes)
        try Data(repeating: 0x20, count: SharedReviewFolder.maximumPresenceBytes + 1).write(to: atLimit)
        #expect(SharedReviewFolder.readSmallRegularFile(atLimit, limit: SharedReviewFolder.maximumPresenceBytes) == nil)
    }

    @Test("A FIFO planted as a presence file does not block the refresh")
    func fifoSkipped() async throws {
        let (shared, url) = try Self.folder()
        defer { try? FileManager.default.removeItem(at: url) }
        let fifo = url.appendingPathComponent("participants/eve.presence").path
        #expect(mkfifo(fifo, 0o644) == 0)
        let refresh = Task.detached { shared.presences().map(\.name) }
        // Old output: presences() blocked in open(2) until some writer opened the FIFO. Give it
        // five seconds, then release it ourselves so a regression fails instead of hanging.
        let deadline = Date().addingTimeInterval(5)
        let finished = Flag()
        Task.detached { _ = await refresh.value; await finished.set() }
        while !(await finished.value), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        if !(await finished.value) {
            Issue.record("presences() blocked on a FIFO")
            let writer = open(fifo, O_WRONLY | O_NONBLOCK)
            if writer >= 0 { close(writer) }
        }
        #expect(await refresh.value == ["Ada"])
    }
}

/// A flag two tasks share, for the FIFO test's watchdog.
private actor Flag {
    private(set) var value = false
    func set() { value = true }
}
