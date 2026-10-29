import Darwin
import Foundation
import Testing
import ZPDFPersistence

/// A package without a `recovery/` folder opens read-write
/// (X-053); a folder the scan cannot list is not reported as one without conflict copies (X-049).
@Suite("Iteration 7 — persistence", .serialized)
struct Iter7PersistenceTests {

    // MARK: - X-049: "could not look" is not "none found"

    /// Old output: `conflictCopyNames(besides:)` answered `[]` for a refused listing — the
    /// sandboxed application's EPERM on the package's parent folder — the same answer as a folder
    /// with no copies, so the open reported nothing.
    @Test("X-049: a refused or missing folder reads as not readable, an empty one as no copies")
    func refusedListingIsNotAnEmptyFolder() throws {
        let root = try TestSupport.makeTemporaryDirectory("Iter7SiblingScan")
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Takeoff.zpdfproj", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)

        let refused = SyncConflictScanner.conflictCopies(besides: package) { _ in
            throw CocoaError(.fileReadNoPermission)
        }
        #expect(refused == .folderNotReadable)
        let gone = root.appendingPathComponent("Gone", isDirectory: true).appendingPathComponent("Takeoff.zpdfproj")
        #expect(SyncConflictScanner.conflictCopies(besides: gone) == .folderNotReadable)
        #expect(SyncConflictScanner.conflictCopies(besides: package) == .copies([]))

        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Takeoff (Mac-B's conflicted copy).zpdfproj"), withIntermediateDirectories: true
        )
        #expect(SyncConflictScanner.conflictCopies(besides: package) == .copies(["Takeoff (Mac-B's conflicted copy).zpdfproj"]))
    }

    // MARK: - X-053: the open makes the recovery folder its marker goes into

    /// Old output: the read-write open threw "open(new) failed on …/Takeoff.zpdfproj/recovery/
    /// .crash-marker.<token>.tmp with errno 2" (ENOENT), because nothing on the open path created
    /// `recovery/`; the read-only open of the same package went through.
    @Test("X-053: a package whose recovery/ folder is gone opens read-write and arms its marker")
    func packageWithoutRecoveryFolderOpensReadWrite() async throws {
        let workspace = try await Iter4PersistenceTests.closedPackage("Iter7NoRecovery")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let recoveryURL = workspace.packageURL.member(ProjectPackageLayout.recovery)
        let markerURL = workspace.packageURL.member(ProjectPackageLayout.crashMarker)
        try FileManager.default.removeItem(at: recoveryURL)
        #expect(!FileDurability.exists(recoveryURL))

        let assessment = try await ProjectPackage.assessRecovery(
            at: workspace.packageURL, environment: TestSupport.environment()
        )
        #expect(assessment.isClean, "a package with no recovery folder carries no crash evidence")

        switch try await ProjectPackage.open(at: workspace.packageURL, environment: TestSupport.environment()) {
        case .opened(let package):
            #expect(package.accessMode == .readWrite)
            #expect(await package.integrityVerdict.isVerified)
            #expect(FileDurability.isDirectory(recoveryURL), "the open did not make recovery/")
            #expect(FileDurability.exists(markerURL), "the read-write session armed no marker")
            let leftovers = TestSupport.recoveryEntries(in: workspace.packageURL).filter { $0.hasSuffix(".tmp") }
            #expect(leftovers.isEmpty, "stranded temporaries: \(leftovers)")
            _ = try await TestSupport.insertPage(into: package, pageIndex: 1, identifier: "page-x053")
            _ = try await package.save()
            try await package.close()
        case .recoveryRequired, .openElsewhere:
            Issue.record("a cleanly closed project without recovery/ must open directly")
        }
        #expect(!FileDurability.exists(markerURL), "close did not take the marker down")

        // And it stays an ordinary project afterwards.
        switch try await ProjectPackage.open(at: workspace.packageURL, environment: TestSupport.environment()) {
        case .opened(let package):
            #expect(await package.integrityVerdict.isVerified)
            try await package.close()
        case .recoveryRequired, .openElsewhere:
            Issue.record("the reopened project must not carry crash evidence")
        }
    }

    /// The read-only open still works as before and still writes nothing: no recovery folder
    /// is made for a session that arms no marker.
    @Test("X-053: a read-only open of the same package makes nothing")
    func readOnlyOpenMakesNoRecoveryFolder() async throws {
        let workspace = try await Iter4PersistenceTests.closedPackage("Iter7NoRecoveryRO")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let recoveryURL = workspace.packageURL.member(ProjectPackageLayout.recovery)
        try FileManager.default.removeItem(at: recoveryURL)

        let package = try await ProjectPackage.open(
            at: workspace.packageURL, environment: TestSupport.environment(), resolving: .openReadOnly
        )
        #expect(package.accessMode == .readOnly)
        #expect(!FileDurability.exists(recoveryURL), "a read-only open must not write to the package")
        try await package.close()
    }
}
