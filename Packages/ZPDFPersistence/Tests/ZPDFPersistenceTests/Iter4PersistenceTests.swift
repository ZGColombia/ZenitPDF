import Darwin
import Foundation
import Testing
import ZPDFPersistence

/// The heartbeat survives a failed write (U-097), and the
/// recovery files of a received package are read as regular files only (U-098).
@Suite("Iteration 4 — persistence", .serialized)
struct Iter4PersistenceTests {

    // MARK: - Support

    /// Runs `/bin/chmod` with an ACL argument. An ACL is the one way to let a test *delete* a
    /// file in a directory while refusing to *create* one there — exactly the failure the old
    /// remove-then-create marker write could not survive.
    static func chmod(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "chmod \(arguments) failed")
    }

    /// A project saved and closed cleanly: no marker, a journal, no autosave.
    static func closedPackage(_ label: String) async throws -> TestSupport.Workspace {
        let workspace = try TestSupport.makeWorkspace(label)
        let package = try await TestSupport.createPackage(workspace)
        _ = try await TestSupport.insertPage(into: package)
        _ = try await package.save()
        try await package.close()
        return workspace
    }

    static func isSymbolicLink(_ url: URL) -> Bool {
        var status = stat()
        return lstat(url.path, &status) == 0 && (status.st_mode & S_IFMT) == S_IFLNK
    }

    // MARK: - U-097: a failed heartbeat

    /// Old output: `refreshSessionHeartbeat()` answered `false` — the caller's loop ended for
    /// the rest of the session — and `CrashMarker.read` answered `nil`, because the marker had
    /// been removed before the create that the directory refused. Another Mac then opened the
    /// package read-write with no "open elsewhere" warning.
    @Test("U-097: a heartbeat that cannot write keeps the previous marker and the timer running")
    func failedHeartbeatKeepsMarkerAndTimer() async throws {
        let workspace = try TestSupport.makeWorkspace("Iter4Heartbeat")
        let recoveryURL = workspace.packageURL.member(ProjectPackageLayout.recovery)
        defer {
            try? Self.chmod(["-N", recoveryURL.path])
            try? FileManager.default.removeItem(at: workspace.root)
        }
        let package = try await TestSupport.createPackage(workspace, environment: SharedStorageSessionTests.environment())
        let markerURL = workspace.packageURL.member(ProjectPackageLayout.crashMarker)
        let before = try #require(ProjectPackage.CrashMarker.read(from: markerURL))
        let entriesBefore = Set(try FileManager.default.contentsOfDirectory(atPath: recoveryURL.path))

        // Deleting in `recovery/` stays allowed; creating a file there is refused.
        try Self.chmod(["+a", "everyone deny add_file", recoveryURL.path])
        #expect(await package.refreshSessionHeartbeat(), "a failed write must not stop the caller's timer")
        let during = ProjectPackage.CrashMarker.read(from: markerURL)
        #expect(during == before, "the previous marker must survive a failed rewrite")
        let entriesDuring = Set(try FileManager.default.contentsOfDirectory(atPath: recoveryURL.path))
        #expect(entriesDuring == entriesBefore, "no temporary sibling may be stranded: \(entriesDuring.subtracting(entriesBefore))")

        // The fault clears; the very next tick restores a fresh heartbeat for the same session.
        try Self.chmod(["-N", recoveryURL.path])
        #expect(await package.refreshSessionHeartbeat())
        let after = try #require(ProjectPackage.CrashMarker.read(from: markerURL))
        #expect(after.sessionID == before.sessionID)
        let beatBefore = try #require(before.heartbeatAt.flatMap(PersistenceTimestamp.date(from:)))
        let beatAfter = try #require(after.heartbeatAt.flatMap(PersistenceTimestamp.date(from:)))
        #expect(beatAfter > beatBefore)

        try await package.close()
        #expect(await package.refreshSessionHeartbeat() == false, "a closed handle still stops the timer")
    }

    // MARK: - U-098: recovery files that are not regular files

    /// Old output: `assessRecovery` never returned — `Data(contentsOf:)` opened the FIFO without
    /// `O_NONBLOCK` and blocked in `open(2)` waiting for a writer.
    @Test("U-098: a FIFO at the crash marker's path is crash evidence, never a hang", .timeLimit(.minutes(1)))
    func fifoMarkerDoesNotHang() async throws {
        let workspace = try await Self.closedPackage("Iter4MarkerFIFO")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let markerURL = workspace.packageURL.member(ProjectPackageLayout.crashMarker)
        try #require(mkfifo(markerURL.path, 0o644) == 0)

        #expect(ProjectPackage.CrashMarker.read(from: markerURL) == nil)
        let assessment = try await ProjectPackage.assessRecovery(at: workspace.packageURL, environment: TestSupport.environment())
        #expect(assessment.crashMarkerPresent, "its presence still counts as crash evidence")
        #expect(assessment.foreignSession == nil)
        switch try await ProjectPackage.open(at: workspace.packageURL, environment: TestSupport.environment()) {
        case .recoveryRequired: break
        case .opened(let package):
            Issue.record("a package with crash evidence opened without a recovery decision")
            try? await package.close()
        case .openElsewhere:
            Issue.record("an unreadable marker is not a live session")
        }
    }

    /// Old output: the read never returned — the size cap was measured on the link's own bytes,
    /// then `Data(contentsOf:)` followed it into `/dev/zero` and read until memory ran out.
    @Test("U-098: a crash marker linked to /dev/zero is refused, not read", .timeLimit(.minutes(1)))
    func deviceLinkedMarkerIsRefused() async throws {
        let workspace = try await Self.closedPackage("Iter4MarkerDevice")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let markerURL = workspace.packageURL.member(ProjectPackageLayout.crashMarker)
        try FileManager.default.createSymbolicLink(at: markerURL, withDestinationURL: URL(fileURLWithPath: "/dev/zero"))

        #expect(ProjectPackage.CrashMarker.read(from: markerURL) == nil)
        let assessment = try await ProjectPackage.assessRecovery(at: workspace.packageURL, environment: TestSupport.environment())
        #expect(assessment.crashMarkerPresent)
    }

    /// Old output: the open never returned — the same unbounded read, on `journal.json`, which
    /// `assessRecovery` reads before the package's structure is validated.
    @Test("U-098: a journal linked to /dev/zero reads as empty, and the open replaces the link", .timeLimit(.minutes(1)))
    func deviceLinkedJournalIsEmpty() async throws {
        let workspace = try await Self.closedPackage("Iter4JournalDevice")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let journalURL = workspace.packageURL.member(ProjectPackageLayout.recoveryJournal)
        try FileManager.default.removeItem(at: journalURL)
        try FileManager.default.createSymbolicLink(at: journalURL, withDestinationURL: URL(fileURLWithPath: "/dev/zero"))

        #expect(RecoveryJournal.read(from: journalURL).entries.isEmpty)
        let assessment = try await ProjectPackage.assessRecovery(at: workspace.packageURL, environment: TestSupport.environment())
        #expect(assessment.interruptedSave == nil)
        #expect(!assessment.crashMarkerPresent)

        guard case let .opened(package) = try await ProjectPackage.open(
            at: workspace.packageURL, environment: TestSupport.environment()
        ) else {
            Issue.record("a cleanly closed package with an unreadable journal should open")
            return
        }
        // The session's first journal line is written atomically over the link, never through it.
        #expect(!Self.isSymbolicLink(journalURL))
        #expect(RecoveryJournal.read(from: journalURL).entries.last?.kind == .sessionOpened)
        try await package.close()
    }

    /// Old output: `assessRecovery` never returned — the journal FIFO blocked in `open(2)`.
    @Test("U-098: a FIFO at the journal's path reads as an empty journal", .timeLimit(.minutes(1)))
    func fifoJournalDoesNotHang() async throws {
        let workspace = try await Self.closedPackage("Iter4JournalFIFO")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let journalURL = workspace.packageURL.member(ProjectPackageLayout.recoveryJournal)
        try FileManager.default.removeItem(at: journalURL)
        try #require(mkfifo(journalURL.path, 0o644) == 0)

        #expect(RecoveryJournal.read(from: journalURL).entries.isEmpty)
        let assessment = try await ProjectPackage.assessRecovery(at: workspace.packageURL, environment: TestSupport.environment())
        #expect(assessment.interruptedSave == nil)
    }

    /// Old output: `passesIntegrityCheck == true` — the health probe's clone followed the link
    /// and checked a database that is not part of this package, which was then offered as the
    /// project's recovery point.
    @Test("U-098: an autosave that is a symbolic link is never a sound snapshot")
    func symlinkedAutosaveIsNotSound() async throws {
        let workspace = try await Self.closedPackage("Iter4AutosaveLink")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        // A sound database outside the package: a copy of the project's own.
        let elsewhere = workspace.root.appendingPathComponent("elsewhere.sqlite")
        try FileManager.default.copyItem(at: workspace.packageURL.member(ProjectPackageLayout.database), to: elsewhere)
        try #require(ProjectPackage.databaseIsHealthyForTesting(at: elsewhere), "precondition: the target is sound")
        let autosaveURL = workspace.packageURL.member(ProjectPackageLayout.autosaveDatabase)
        try FileManager.default.createSymbolicLink(at: autosaveURL, withDestinationURL: elsewhere)

        let assessment = try await ProjectPackage.assessRecovery(at: workspace.packageURL, environment: TestSupport.environment())
        let autosave = try #require(assessment.autosave)
        #expect(autosave.passesIntegrityCheck == false)
    }
}
