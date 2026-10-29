import Foundation
import GRDB
import Testing
import ZPDFPersistence

/// Adversarial verification of the ADR-0007 same-transaction guarantee.
///
/// The claim: a mutation and its audit entry are written inside one transaction, so it is
/// impossible for one to exist on disk without the other. The existing suite proves the
/// rollback case in-process; this suite proves the crash case with a real process and a
/// real SIGKILL, because in-process simulation cannot show what the filesystem holds when
/// no error path gets to run.
///
/// `zpdf-save-harness audit-crash` opens a real package and, inside ONE `write` closure,
/// inserts a markup, appends its audit entry, and SIGKILLs itself at a named point:
///
/// - `after-mutation`  — the markup INSERT has executed, the audit append has not.
/// - `after-audit`     — both statements have executed, the commit has not.
/// - `none`            — no kill; the transaction commits.
///
/// If the guarantee is real, both kill points leave NEITHER row, and only the committed
/// run leaves BOTH. A surviving markup without its audit row (or the reverse) fails.
struct KillDuringAuditTests {

    private func counts(_ packageURL: URL) throws -> (markups: Int, audits: Int) {
        let queue = try DatabaseQueue(path: packageURL.member(ProjectPackageLayout.database).path)
        defer { try? queue.close() }
        return try queue.read { db in
            (markups: try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM markup WHERE id = 'crash-markup'") ?? -1,
             audits: try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM measurement_audit WHERE id = 'crash-audit'") ?? -1)
        }
    }

    @Test("SIGKILL between mutation and audit append leaves neither row",
          arguments: ["after-mutation", "after-audit"])
    func killLeavesNeither(_ killPoint: String) async throws {
        let workspace = try TestSupport.makeWorkspace("AuditKill-\(killPoint)")
        defer { try? FileManager.default.removeItem(at: workspace.root) }

        let created = try TestSupport.runHarness([
            "create",
            "--package", workspace.packageURL.path,
            "--pdf", workspace.sourcePDF.path,
            "--seed", "1"
        ])
        #expect(created.exitStatus == 0, "create failed: \(created.standardError)")

        let killed = try TestSupport.runHarness([
            "audit-crash",
            "--package", workspace.packageURL.path,
            "--kill", killPoint
        ])
        // The harness must actually have died of SIGKILL, not exited cleanly — otherwise
        // this test proves nothing.
        #expect(killed.terminatingSignal == SIGKILL,
                "harness was not SIGKILLed: exit \(killed.exitStatus), err \(killed.standardError)")
        #expect(killed.standardError.contains("killing at"),
                "kill point was never reached: \(killed.standardError)")

        let after = try counts(workspace.packageURL)
        #expect(after.markups == 0, "\(killPoint): mutation survived the crash without its audit row")
        #expect(after.audits == 0, "\(killPoint): audit row survived the crash without a commit")
    }

    @Test("The same transaction, committed, leaves exactly both rows (non-vacuity)")
    func commitLeavesBoth() async throws {
        let workspace = try TestSupport.makeWorkspace("AuditKill-none")
        defer { try? FileManager.default.removeItem(at: workspace.root) }

        let created = try TestSupport.runHarness([
            "create",
            "--package", workspace.packageURL.path,
            "--pdf", workspace.sourcePDF.path,
            "--seed", "1"
        ])
        #expect(created.exitStatus == 0, "create failed: \(created.standardError)")

        let committed = try TestSupport.runHarness([
            "audit-crash",
            "--package", workspace.packageURL.path,
            "--kill", "none"
        ])
        #expect(committed.exitStatus == 0, "commit run failed: \(committed.standardError)")
        #expect(committed.standardOutput.contains("committed both"))

        let after = try counts(workspace.packageURL)
        #expect(after.markups == 1)
        #expect(after.audits == 1)
    }
}
