import Darwin
import Foundation
import Testing
import ZPDFPersistence

/// An open whose marker lands but whose `recovery/` flush
/// fails leaves the package exactly as it found it (W-094).
@Suite("Iteration 6 — persistence", .serialized)
struct Iter6PersistenceTests {

    // MARK: - W-094: the arm is undone when the flush after its rename throws

    /// Old output: the open threw (`open(dir)` on `recovery/`, EACCES), but this session's
    /// marker stayed renamed into place with this PID and a fresh heartbeat, so after the
    /// fault cleared `assessRecovery(...).isClean` was `false` and the next open answered
    /// `.recoveryRequired` for a project nothing had written to.
    @Test("W-094: a marker whose recovery/ flush fails is taken down, so the next open is clean")
    func failedFlushAfterTheRenameTakesTheMarkerDown() async throws {
        let workspace = try await Iter4PersistenceTests.closedPackage("Iter6FlushAbsent")
        let recoveryURL = workspace.packageURL.member(ProjectPackageLayout.recovery)
        defer {
            try? Iter4PersistenceTests.chmod(["-N", recoveryURL.path])
            try? FileManager.default.removeItem(at: workspace.root)
        }
        let databaseURL = workspace.packageURL.member(ProjectPackageLayout.database)
        let markerURL = workspace.packageURL.member(ProjectPackageLayout.crashMarker)
        let bytesBefore = try Data(contentsOf: databaseURL)
        #expect(!FileDurability.exists(markerURL))
        let entriesBefore = TestSupport.recoveryEntries(in: workspace.packageURL)

        // Files can still be created and renamed in `recovery/`, so the marker lands; the
        // directory cannot be opened for reading, so the flush after the rename throws.
        try Iter4PersistenceTests.chmod(["+a", "everyone deny list", recoveryURL.path])
        await #expect(throws: (any Error).self, "an open whose marker is not durable must not open") {
            _ = try await ProjectPackage.open(at: workspace.packageURL, environment: TestSupport.environment())
        }
        #expect(!FileDurability.exists(markerURL), "the refused open left its own marker armed")
        #expect(try Data(contentsOf: databaseURL) == bytesBefore, "the refused open wrote to project.sqlite")

        try Iter4PersistenceTests.chmod(["-N", recoveryURL.path])
        #expect(TestSupport.recoveryEntries(in: workspace.packageURL) == entriesBefore)
        let assessment = try await ProjectPackage.assessRecovery(
            at: workspace.packageURL, environment: TestSupport.environment()
        )
        #expect(assessment.isClean, "a refused open must not read as a crash")
        switch try await ProjectPackage.open(at: workspace.packageURL, environment: TestSupport.environment()) {
        case .opened(let package):
            #expect(await package.integrityVerdict.isVerified)
            try await package.close()
        case .recoveryRequired, .openElsewhere:
            Issue.record("a cleanly closed project whose open was refused must not carry crash evidence")
        }
    }

    /// Old output: the planted crashed-session marker was overwritten by this session's, which
    /// stayed in place after the open threw; the crashed session's evidence was gone.
    @Test("W-094: a crashed session's marker is put back byte for byte when the flush after the arm fails")
    func failedFlushAfterTheRenameRestoresThePriorMarker() async throws {
        let workspace = try await Iter4PersistenceTests.closedPackage("Iter6FlushPrior")
        let recoveryURL = workspace.packageURL.member(ProjectPackageLayout.recovery)
        defer {
            try? Iter4PersistenceTests.chmod(["-N", recoveryURL.path])
            try? FileManager.default.removeItem(at: workspace.root)
        }
        let markerURL = workspace.packageURL.member(ProjectPackageLayout.crashMarker)
        let planted = Data(#"{"appVersion":"0.9.0","openedAt":"2026-01-01T08:00:00.000Z","processIdentifier":999}"#.utf8)
        try planted.write(to: markerURL)

        try Iter4PersistenceTests.chmod(["+a", "everyone deny list", recoveryURL.path])
        await #expect(throws: (any Error).self) {
            _ = try await ProjectPackage.open(
                at: workspace.packageURL, environment: TestSupport.environment(), resolving: .discard
            )
        }
        #expect(try Data(contentsOf: markerURL) == planted, "the crashed session's marker was not put back")

        try Iter4PersistenceTests.chmod(["-N", recoveryURL.path])
        let leftovers = TestSupport.recoveryEntries(in: workspace.packageURL).filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty, "stranded temporaries: \(leftovers)")
    }
}
