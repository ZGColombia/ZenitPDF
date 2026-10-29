import CryptoKit
import Foundation
import GRDB
import Testing
import ZPDFPersistence

/// The durability claim, demonstrated rather than asserted.
///
/// A separate process (`zpdf-save-harness`) opens a real package, adds rows, starts a
/// real save, and is `SIGKILL`ed at a named point in the pipeline. SIGKILL cannot be
/// caught, blocked or handled: no `defer` runs, no `deinit` runs, no error path runs,
/// nothing is flushed on the way out. Whatever is on disk afterwards is what the design
/// actually guarantees, as opposed to what it intends.
///
/// ### What "never a mixture" means precisely
///
/// `project.sqlite` is edited in place, so between saves it legitimately holds committed
/// rows that the last save did not record. The state that must never be a mixture is the
/// **saved** state, and after each kill this suite checks all of:
///
/// 1. `manifest.json` and the PDFs hash to what the package's own integrity record says —
///    the manifest and the record are written together into the temporary package and
///    arrive through one atomic swap, so a new manifest next to an old record is exactly
///    the mixture that must be impossible;
/// 2. the generation is either the old one or the new one, and when it is the new one the
///    database hashes to what the new record says, because nothing wrote to it after the
///    swap;
/// 3. the database is a sound SQLite file and its markup count is exactly the old value
///    or exactly the new one;
/// 4. `.versions/latest` — the clone of the last completed save, which is never
///    reopened — verifies completely, so a coherent saved state is always recoverable;
/// 5. reopening and discarding lands on exactly that saved state;
/// 6. `documents/original.pdf` has the SHA-256 it had before the harness ran.
struct KillDuringSaveTests {

    /// The four points before the swap, plus the two on the far side of it, where
    /// the save has already committed and only housekeeping is left.
    static let killPoints: [SaveCheckpoint] = [
        .willWriteTemporaryPackage,   // before the temporary package exists
        .midTemporaryPackageWrite,    // half way through streaming the database into it
        .didHash,                     // after the manifest, database and PDFs are hashed
        .willAtomicReplace,           // the instant before the swap
        .didAtomicReplace,            // the instant after it
        .didPreserveVersion           // after the version slots have rotated
    ]

    /// Enough rows that `project.sqlite` spans several 1 MiB copy chunks, so
    /// `midTemporaryPackageWrite` is a genuine partial write and not a formality.
    static let seedCount = 12_000
    static let insertCount = 500

    private func sha256(_ url: URL) throws -> String {
        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func databaseIsSound(_ packageURL: URL) throws -> Bool {
        let queue = try DatabaseQueue(path: packageURL.member(ProjectPackageLayout.database).path)
        defer { try? queue.close() }
        return try queue.read { db in try String.fetchAll(db, sql: "PRAGMA quick_check") } == ["ok"]
    }

    /// Row counts of every takeoff table hydration reads (ADR-0009).
    private struct TakeoffCounts {
        let measurementValues: Int
        let extras: Int
        let scales: Int
        let states: Int
    }

    private func takeoffCoherence(_ packageURL: URL) throws -> TakeoffCounts {
        let queue = try DatabaseQueue(path: packageURL.member(ProjectPackageLayout.database).path)
        defer { try? queue.close() }
        return try queue.read { db in
            TakeoffCounts(
                measurementValues: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM measurement_value") ?? -1,
                extras: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM markup_extra") ?? -1,
                scales: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM scale_definition") ?? -1,
                states: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM takeoff_state") ?? -1
            )
        }
    }

    @Test("A SIGKILL at any point in the save leaves one whole state, never a mixture",
          arguments: KillDuringSaveTests.killPoints)
    func killAtCheckpoint(_ checkpoint: SaveCheckpoint) async throws {
        let workspace = try TestSupport.makeWorkspace("Kill-\(checkpoint.rawValue)")
        defer { try? FileManager.default.removeItem(at: workspace.root) }

        // ── Build and seed the package in a child process ───────────────────────────
        let created = try TestSupport.runHarness([
            "create",
            "--package", workspace.packageURL.path,
            "--pdf", workspace.sourcePDF.path,
            "--seed", String(Self.seedCount)
        ])
        #expect(created.exitStatus == 0, "create failed: \(created.standardError)")

        let originalURL = workspace.packageURL.member(ProjectPackageLayout.originalPDF)
        let originalHashBefore = try sha256(originalURL)
        let countBefore = try TestSupport.markupCount(inPackageAt: workspace.packageURL)
        #expect(countBefore == Self.seedCount)
        let generationBefore = try IntegrityRecord.read(
            from: workspace.packageURL.member(ProjectPackageLayout.integrity)
        ).generation

        let databaseByteCount = FileDurabilityProbe.byteCount(
            workspace.packageURL.member(ProjectPackageLayout.database)
        )
        #expect(databaseByteCount > 4 << 20,
                "the database must span several copy chunks for a mid-write kill to mean anything")

        // ── Start a save in a child process and kill it ─────────────────────────────
        let killed = try TestSupport.runHarness([
            "save",
            "--package", workspace.packageURL.path,
            "--insert", String(Self.insertCount),
            "--kill-at", checkpoint.rawValue
        ])
        #expect(killed.wasKilled,
                "not killed by SIGKILL: status \(killed.exitStatus), stderr: \(killed.standardError)")
        #expect(killed.standardOutput.isEmpty, "the harness reported a completed save before dying")

        // ── 1 & 2. The saved state is coherent ──────────────────────────────────────
        let verification = try ProjectPackage.verifyIntegrity(at: workspace.packageURL)
        #expect(verification.manifestHashMatches, "manifest does not match its integrity record")
        #expect(verification.originalPDFHashMatches, "original PDF does not match its integrity record")
        #expect(verification.workingPDFHashMatches, "working PDF does not match its integrity record")

        let generationAfter = verification.integrity.generation
        #expect(generationAfter == generationBefore || generationAfter == generationBefore + 1,
                "generation jumped from \(generationBefore) to \(generationAfter)")
        let sawTheSwap = generationAfter == generationBefore + 1
        if sawTheSwap {
            #expect(verification.databaseHashMatches,
                    "the swap committed a database that does not match the record written with it")
        }

        // ── 3. The database is sound, and holds one of the two counts ───────────────
        #expect(try databaseIsSound(workspace.packageURL), "the database did not survive the kill")
        let countAfter = try TestSupport.markupCount(inPackageAt: workspace.packageURL)
        let expectedNew = countBefore + Self.insertCount
        #expect(countAfter == countBefore || countAfter == expectedNew,
                "markup count is \(countAfter), neither the old \(countBefore) nor the new \(expectedNew)")
        if sawTheSwap {
            #expect(countAfter == expectedNew, "the swap committed the old row set")
        }

        // The mixture rule covers the whole takeoff (ADR-0009): whatever state survived,
        // every markup has its measurement values and its extras, and the scale plus the
        // takeoff_state row are there — never a ledger without its scale.
        let takeoff = try takeoffCoherence(workspace.packageURL)
        #expect(takeoff.measurementValues == countAfter,
                "\(countAfter) markup(s) but \(takeoff.measurementValues) measurement_value row(s)")
        #expect(takeoff.extras == countAfter,
                "\(countAfter) markup(s) but \(takeoff.extras) markup_extra row(s)")
        #expect(takeoff.scales == 1, "expected exactly one scale, found \(takeoff.scales)")
        #expect(takeoff.states == 1, "expected exactly one takeoff_state row, found \(takeoff.states)")

        // ── 4. A coherent saved state is always still on disk ───────────────────────
        let latestVersion = ProjectPackage
            .versionsRootURL(forPackageAt: workspace.packageURL)
            .appendingPathComponent(ProjectPackageLayout.latestVersion, isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: latestVersion.path),
                "no saved version survived the kill")
        let versionVerification = try ProjectPackage.verifyIntegrity(at: latestVersion)
        #expect(versionVerification.isFullyConsistent, "the saved version is not self-consistent")
        let savedCount = try TestSupport.markupCount(inPackageAt: latestVersion)
        #expect(savedCount == countBefore || savedCount == expectedNew)

        // ── 5. The crash is accounted for, and discarding lands on the saved state ──
        let assessment = try await ProjectPackage.assessRecovery(at: workspace.packageURL)
        #expect(assessment.crashMarkerPresent, "a killed session left no crash marker")
        #expect(assessment.interruptedSave != nil, "the journal has no record of the interrupted save")

        let reopened = try await ProjectPackage.open(
            at: workspace.packageURL, environment: TestSupport.environment(), resolving: .discard
        )
        let liveCount = try await reopened.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM markup") ?? -1
        }
        #expect(liveCount == savedCount,
                "discarding should land on the last saved state (\(savedCount)), got \(liveCount)")
        try await reopened.close()

        // ── 6. The original PDF is untouched, whatever happened ─────────────────────
        #expect(try sha256(originalURL) == originalHashBefore)

        // And no leftover sibling survives the reopen.
        let siblings = try FileManager.default.contentsOfDirectory(atPath: workspace.root.path)
        #expect(!siblings.contains { $0.contains(".save-") || $0.contains(".discard-") },
                "leftovers after recovery: \(siblings)")
    }

    @Test("A save that is not interrupted completes and advances the generation")
    func uninterruptedSaveInTheSameHarness() async throws {
        let workspace = try TestSupport.makeWorkspace("KillControl")
        defer { try? FileManager.default.removeItem(at: workspace.root) }

        let created = try TestSupport.runHarness([
            "create", "--package", workspace.packageURL.path,
            "--pdf", workspace.sourcePDF.path, "--seed", "200"
        ])
        #expect(created.exitStatus == 0, "\(created.standardError)")

        let saved = try TestSupport.runHarness([
            "save", "--package", workspace.packageURL.path,
            "--insert", "50", "--kill-at", "none"
        ])
        #expect(saved.exitStatus == 0, "\(saved.standardError)")
        #expect(saved.terminatingSignal == nil)
        #expect(saved.standardOutput.contains("saved generation 3"))
        #expect(try TestSupport.markupCount(inPackageAt: workspace.packageURL) == 250)

        // The live database has moved on (a clean close checkpoints a pool-open artefact
        // into it), so the artefact to verify is the clone of the save itself.
        let latestVersion = ProjectPackage
            .versionsRootURL(forPackageAt: workspace.packageURL)
            .appendingPathComponent(ProjectPackageLayout.latestVersion, isDirectory: true)
        #expect(try ProjectPackage.verifyIntegrity(at: latestVersion).isFullyConsistent)
        #expect(try TestSupport.markupCount(inPackageAt: latestVersion) == 250)
        #expect(try await ProjectPackage.assessRecovery(at: workspace.packageURL).isClean)
    }
}
