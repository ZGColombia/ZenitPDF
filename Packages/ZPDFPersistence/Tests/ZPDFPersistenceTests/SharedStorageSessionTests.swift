import Foundation
import Testing
import ZPDFPersistence

/// NL-COLLAB-13: a project open on another Mac, seen through a shared or synced folder, is a
/// live session and never a crash.
///
/// Old output for every "open elsewhere" case below: `open(at:)` answered
/// `.recoveryRequired`, summary `"crash marker"`, because the marker held only a pid, a time
/// and an app version — and the second person was offered Recover or Discard over a session
/// that was still writing the package.
@Suite("Shared storage: foreign sessions are not crashes")
struct SharedStorageSessionTests {

    static let start = Date(timeIntervalSince1970: 1_800_000_000)
    static let localHost = SessionHost(machineID: "local-mac-id", displayName: "Local Mac", userName: "Ada")

    static func environment(ttl: TimeInterval = ForeignSessionPolicy.defaultTimeToLive) -> PersistenceEnvironment {
        PersistenceEnvironment(
            clock: SteppingClock(start: start),
            identifiers: SequentialIdentifierGenerator(prefix: "S"),
            appVersion: "1.0.0-test",
            minimumReaderVersion: "1.0.0",
            sessionHost: localHost,
            foreignSessionTimeToLive: ttl
        )
    }

    /// A cleanly closed package, then a marker planted as another machine's session would
    /// leave it.
    static func packageWithMarker(
        _ label: String,
        marker: ProjectPackage.CrashMarker?,
        autosave: Bool = false
    ) async throws -> TestSupport.Workspace {
        let workspace = try TestSupport.makeWorkspace(label)
        let package = try await TestSupport.createPackage(workspace, environment: environment())
        if autosave {
            _ = try await TestSupport.insertPage(into: package)
            _ = try await package.writeAutosave()
            // Let go without disarming, as the other machine's still-running process would.
            try await package.database.close()
        } else {
            try await package.close()
        }
        if let marker {
            let url = workspace.packageURL.member(ProjectPackageLayout.crashMarker)
            try? FileManager.default.removeItem(at: url)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(marker).write(to: url)
        }
        return workspace
    }

    static func foreignMarker(heartbeat: Date, host: String = "mac-b-id", pid: Int32 = 4242) -> ProjectPackage.CrashMarker {
        ProjectPackage.CrashMarker(
            processIdentifier: pid,
            openedAt: PersistenceTimestamp.string(from: heartbeat.addingTimeInterval(-3600)),
            appVersion: "1.0.0",
            hostID: host,
            hostName: "Mac-B",
            userName: "Bo",
            sessionID: "B-SESSION",
            heartbeatAt: PersistenceTimestamp.string(from: heartbeat)
        )
    }

    @Test("A fresh marker from another Mac opens as 'open elsewhere', never as a crash")
    func foreignFreshMarkerIsOpenElsewhere() async throws {
        let workspace = try await Self.packageWithMarker(
            "CollabForeignFresh", marker: Self.foreignMarker(heartbeat: Self.start.addingTimeInterval(-30))
        )
        defer { try? FileManager.default.removeItem(at: workspace.root) }

        switch try await ProjectPackage.open(at: workspace.packageURL, environment: Self.environment()) {
        case let .openElsewhere(session, assessment):
            #expect(session.host.displayName == "Mac-B")
            #expect(session.host.userName == "Bo")
            #expect(session.isSameMachine == false)
            #expect(session.openedAt == PersistenceTimestamp.string(from: Self.start.addingTimeInterval(-3630)))
            #expect(assessment.summary.hasPrefix("open on Mac-B"))
        case .recoveryRequired:
            Issue.record("a live session on another Mac was offered crash recovery")
        case let .opened(package):
            try await package.close()
            Issue.record("a live session on another Mac opened without asking")
        }
    }

    @Test("A foreign marker whose heartbeat is older than the TTL falls back to recovery")
    func staleForeignMarkerIsACrash() async throws {
        let stale = Self.start.addingTimeInterval(-(ForeignSessionPolicy.defaultTimeToLive + 60))
        let workspace = try await Self.packageWithMarker("CollabForeignStale", marker: Self.foreignMarker(heartbeat: stale))
        defer { try? FileManager.default.removeItem(at: workspace.root) }

        switch try await ProjectPackage.open(at: workspace.packageURL, environment: Self.environment()) {
        case let .recoveryRequired(assessment):
            #expect(assessment.foreignSession == nil)
            #expect(assessment.crashMarkerPresent)
        case .openElsewhere:
            Issue.record("a heartbeat past the TTL is a crash, not a live session")
        case let .opened(package):
            try await package.close()
            Issue.record("crash evidence opened without a decision")
        }
    }

    @Test("A marker written before NL-COLLAB-13 (no host) decodes and is read as a crash, as before")
    func legacyMarkerIsACrash() async throws {
        let workspace = try await Self.packageWithMarker("CollabLegacyMarker", marker: nil)
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let legacy = #"{"appVersion":"1.0.0","openedAt":"2027-01-15T08:00:00.000Z","processIdentifier":999}"#
        try Data(legacy.utf8).write(to: workspace.packageURL.member(ProjectPackageLayout.crashMarker))

        let decoded = ProjectPackage.CrashMarker.read(from: workspace.packageURL.member(ProjectPackageLayout.crashMarker))
        #expect(decoded?.processIdentifier == 999)
        #expect(decoded?.hostID == nil)
        switch try await ProjectPackage.open(at: workspace.packageURL, environment: Self.environment()) {
        case .recoveryRequired: break
        case .openElsewhere: Issue.record("a legacy marker carries no host and cannot name one")
        case let .opened(package):
            try await package.close()
            Issue.record("crash evidence opened without a decision")
        }
    }

    @Test("Same machine: a dead pid is a crash here; another living process is a session elsewhere")
    func sameMachineRules() {
        let marker = ProjectPackage.CrashMarker(
            processIdentifier: 777, openedAt: PersistenceTimestamp.string(from: Self.start),
            appVersion: "1", hostID: Self.localHost.machineID, hostName: "Local Mac",
            heartbeatAt: PersistenceTimestamp.string(from: Self.start)
        )
        let dead = ForeignSessionPolicy.foreignSession(
            in: marker, localHost: Self.localHost, localProcessIdentifier: 100,
            now: Self.start, isProcessAlive: { _ in false }
        )
        #expect(dead == nil)
        let alive = ForeignSessionPolicy.foreignSession(
            in: marker, localHost: Self.localHost, localProcessIdentifier: 100,
            now: Self.start, isProcessAlive: { $0 == 777 }
        )
        #expect(alive?.isSameMachine == true)
        // Our own pid is our own earlier session in this process: crash evidence, as before.
        let own = ForeignSessionPolicy.foreignSession(
            in: marker, localHost: Self.localHost, localProcessIdentifier: 777,
            now: Self.start, isProcessAlive: { _ in true }
        )
        #expect(own == nil)
        // A heartbeat from the future (another Mac's clock runs ahead) is fresh, not stale.
        let skewed = Self.foreignMarker(heartbeat: Self.start.addingTimeInterval(120))
        #expect(ForeignSessionPolicy.foreignSession(
            in: skewed, localHost: Self.localHost, localProcessIdentifier: 1, now: Self.start
        ) != nil)
    }

    @Test("Open Anyway opens read-write, runs no recovery step, and leaves the other session's files alone")
    func openAnywayLeavesForeignStateAlone() async throws {
        let workspace = try await Self.packageWithMarker(
            "CollabOpenAnyway", marker: Self.foreignMarker(heartbeat: Self.start), autosave: true
        )
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        // A temporary sibling, as the other machine's save in flight would have.
        let sibling = workspace.root.appendingPathComponent(".Takeoff.zpdfproj.save-OTHER.tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let autosaveURL = workspace.packageURL.member(ProjectPackageLayout.autosaveDatabase)
        #expect(FileManager.default.fileExists(atPath: autosaveURL.path))

        let package = try await ProjectPackage.open(
            at: workspace.packageURL, environment: Self.environment(), foreignSession: .openAnyway
        )
        #expect(package.accessMode == .readWrite)
        #expect(FileManager.default.fileExists(atPath: autosaveURL.path), "Recover would have deleted the live session's autosave")
        #expect(FileManager.default.fileExists(atPath: sibling.path), "a live session's save sibling is not a leftover")
        let marker = ProjectPackage.CrashMarker.read(from: workspace.packageURL.member(ProjectPackageLayout.crashMarker))
        #expect(marker?.hostID == Self.localHost.machineID)
        #expect(marker?.hostName == "Local Mac")
        #expect(marker?.userName == "Ada")
        #expect(marker?.sessionID != nil && marker?.sessionID != "B-SESSION")
        try await package.close()
    }

    @Test("Open Read-Only writes nothing, not even the marker")
    func openReadOnlyWritesNothing() async throws {
        let workspace = try await Self.packageWithMarker(
            "CollabReadOnly", marker: Self.foreignMarker(heartbeat: Self.start)
        )
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let markerURL = workspace.packageURL.member(ProjectPackageLayout.crashMarker)
        let before = try Data(contentsOf: markerURL)
        let package = try await ProjectPackage.open(
            at: workspace.packageURL, environment: Self.environment(), foreignSession: .openReadOnly
        )
        #expect(package.accessMode == .readOnly)
        try await package.close()
        #expect(try Data(contentsOf: markerURL) == before)
    }

    @Test("Cancel throws and opens nothing")
    func cancelThrows() async throws {
        let workspace = try await Self.packageWithMarker("CollabCancel", marker: Self.foreignMarker(heartbeat: Self.start))
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        await #expect(throws: CancellationError.self) {
            _ = try await ProjectPackage.open(
                at: workspace.packageURL, environment: Self.environment(), foreignSession: .cancel
            )
        }
    }

    @Test("Open Anyway on a marker that went stale meanwhile asks for the recovery decision instead")
    func openAnywayOnStaleMarkerDefersToRecovery() async throws {
        let stale = Self.start.addingTimeInterval(-(ForeignSessionPolicy.defaultTimeToLive + 60))
        let workspace = try await Self.packageWithMarker("CollabAnywayStale", marker: Self.foreignMarker(heartbeat: stale))
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        await #expect(throws: ZPDFPersistenceError.self) {
            _ = try await ProjectPackage.open(
                at: workspace.packageURL, environment: Self.environment(), foreignSession: .openAnyway
            )
        }
    }

    @Test("A session's marker names its host and refreshes its heartbeat without changing its identity")
    func heartbeatRefreshes() async throws {
        let workspace = try TestSupport.makeWorkspace("CollabHeartbeat")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let package = try await TestSupport.createPackage(workspace, environment: Self.environment())
        let markerURL = workspace.packageURL.member(ProjectPackageLayout.crashMarker)
        let first = try #require(ProjectPackage.CrashMarker.read(from: markerURL))
        #expect(first.hostID == Self.localHost.machineID)
        #expect(first.processIdentifier == ProcessInfo.processInfo.processIdentifier)

        #expect(await package.refreshSessionHeartbeat())
        let second = try #require(ProjectPackage.CrashMarker.read(from: markerURL))
        #expect(second.sessionID == first.sessionID)
        #expect(second.openedAt == first.openedAt)
        let firstBeat = try #require(first.heartbeatAt.flatMap(PersistenceTimestamp.date(from:)))
        let secondBeat = try #require(second.heartbeatAt.flatMap(PersistenceTimestamp.date(from:)))
        #expect(secondBeat > firstBeat)

        // A save carries the same session into the swapped-in package.
        _ = try await package.save()
        let afterSave = try #require(ProjectPackage.CrashMarker.read(from: markerURL))
        #expect(afterSave.sessionID == first.sessionID)

        try await package.close()
        #expect(await package.refreshSessionHeartbeat() == false, "a closed handle stops the timer")
        #expect(!FileManager.default.fileExists(atPath: markerURL.path), "the heartbeat must not re-arm a closed package")
    }

    @Test("Sync-conflict copies beside the package are reported; unrelated projects are not")
    func conflictCopiesAreReported() throws {
        let root = try TestSupport.makeTemporaryDirectory("CollabConflicts")
        defer { try? FileManager.default.removeItem(at: root) }
        let names = [
            "Takeoff.zpdfproj",
            "Takeoff (Mac-B's conflicted copy 2026-09-23).zpdfproj",
            "Takeoff.sync-conflict-20260923-104200-ABCDEFG.zpdfproj",
            "Takeoff 2.zpdfproj",
            "Other (conflicted copy).zpdfproj",
            "Takeoff (conflicted copy).pdf"
        ]
        for name in names {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let found = SyncConflictScanner.conflictCopies(besides: root.appendingPathComponent("Takeoff.zpdfproj"))
        #expect(found == .copies([
            "Takeoff (Mac-B's conflicted copy 2026-09-23).zpdfproj",
            "Takeoff.sync-conflict-20260923-104200-ABCDEFG.zpdfproj"
        ]))
    }

    @Test("The current host has a pseudonymous machine id, never the raw hardware UUID")
    func currentHostIsPseudonymous() {
        let host = SessionHost.current
        #expect(host.machineID.count == 24)
        #expect(host.machineID.allSatisfy { $0.isHexDigit })
        #expect(!host.displayName.isEmpty)
    }
}
