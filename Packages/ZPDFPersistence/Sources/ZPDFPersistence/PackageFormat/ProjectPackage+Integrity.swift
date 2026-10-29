import Foundation
import GRDB
import os

/// S17-07: `integrity.json` is checked on the open path, and a package that does not
/// match its own record is refused with an error the application can put in front of a
/// human.
///
/// ### Why this was not simply "hash everything and compare"
///
/// `integrity.json` records four hashes. Three of them are of files this package never
/// rewrites outside a save — `manifest.json`, `documents/original.pdf`,
/// `documents/working.pdf` — so comparing those is unambiguous: if they differ, someone
/// other than Zenit PDF wrote them.
///
/// `project.sqlite` is the awkward one, and it is the reason this finding sat open. The
/// database is edited **in place**: every committed edit, every WAL checkpoint and every
/// clean close moves its bytes away from the hash the last save recorded. Verifying it
/// naively would refuse every project on its second open, which is a worse outcome than
/// the vulnerability — a hardening pass that breaks normal use is not a hardening pass.
///
/// So the invariant was tightened instead of the check being weakened:
/// ``ProjectPackage/close()`` now re-records the database's hash after the final
/// checkpoint, so **a package at rest always describes itself truthfully**. A
/// `.zpdfproj` sitting in a shared folder, whoever last closed it, states its own
/// database's real digest. That makes the comparison meaningful on open, and it makes
/// `verifyIntegrity(at:)` meaningful on a project that was merely opened and closed.
///
/// ### Tampering versus damage
///
/// The two get different sentences in front of the user because they call for different
/// actions, and the evidence usually distinguishes them:
///
/// - A mismatched `manifest.json`, `original.pdf` or `working.pdf` is **tampering**.
///   Nothing in a crash rewrites those files; a save writes all four together.
/// - A mismatched `project.sqlite` in a package that is carrying **crash evidence** — a
///   crash marker, an interrupted save, an autosave snapshot — is **damage**. That is
///   precisely what a session that died between the last save and the close looks like,
///   and the recovery flow already exists to deal with it.
/// - A mismatched `project.sqlite` in a package that is **clean** — closed properly, no
///   crash evidence, nothing in flight — is tampering. The close that produced that
///   state is the close that recorded the hash.
extension ProjectPackage {

    /// What checking a package against its own `integrity.json` concluded.
    public struct IntegrityVerdict: Sendable, Hashable {

        public enum Outcome: String, Sendable, Hashable {
            /// Every hash in the record matches the bytes on disk.
            case verified
            /// The bytes differ, and the evidence says an editor other than this
            /// application produced them.
            case modifiedOutsideZenitPDF
            /// The bytes differ, and the evidence says an interrupted session or a bad
            /// disk produced them.
            case damaged
        }

        public let outcome: Outcome
        /// The package-relative paths whose hashes did not match, in layout order.
        public let mismatchedMembers: [String]
        /// A sentence naming what was found, carried into the typed error.
        public let detail: String

        public var isVerified: Bool { outcome == .verified }

        /// The refusal this verdict becomes on a read-write open, or `nil` if there is
        /// nothing to refuse.
        public var error: ZPDFPersistenceError? {
            switch outcome {
            case .verified:
                return nil
            case .modifiedOutsideZenitPDF:
                return .projectModifiedOutsideZenit(detail: detail)
            case .damaged:
                return .projectDamaged(detail: detail)
            }
        }

        public init(outcome: Outcome, mismatchedMembers: [String], detail: String) {
            self.outcome = outcome
            self.mismatchedMembers = mismatchedMembers
            self.detail = detail
        }

        /// The refusal a read-write open raises for this verdict, or `nil` (V-094).
        ///
        /// Every mismatch is refused but one: damage in a package that already carries crash
        /// evidence. That is the recovery flow's entire subject matter — the user has been
        /// shown the sheet and has chosen an outcome — and refusing it would turn a
        /// recoverable project into an unopenable one. Damage in a package that is otherwise
        /// clean has no such explanation and is refused. The one rule for the open path and
        /// for `zenit verify`, which used to keep a copy of its own.
        public func refusal(carriesCrashEvidence: Bool) -> ZPDFPersistenceError? {
            guard let error else { return nil }
            return outcome == .damaged && carriesCrashEvidence ? nil : error
        }

        /// Whether an open checks the database in full — `integrity_check` and, read-write,
        /// the foreign-key walk — rather than the structural `quick_check` (IM-074, IM-194).
        /// Only a package whose bytes were just proven to be the ones its last clean close
        /// recorded gets the quick walk. `zenit verify` counts foreign-key violations by the
        /// same rule (V-094).
        public func needsFullCheck(carriesCrashEvidence: Bool) -> Bool {
            !isVerified || carriesCrashEvidence
        }

        /// This verdict with `members` found modified outside Zenit PDF as well (S-120).
        func addingModified(_ members: [String]) -> IntegrityVerdict {
            let fresh = members.filter { !mismatchedMembers.contains($0) }
            guard !fresh.isEmpty else { return self }
            let sentence = "\(fresh.joined(separator: ", ")) "
                + "\(fresh.count == 1 ? "does" : "do") not match the hash this project records"
            return IntegrityVerdict(
                outcome: .modifiedOutsideZenitPDF,
                mismatchedMembers: mismatchedMembers + fresh,
                detail: outcome == .modifiedOutsideZenitPDF ? "\(detail); \(sentence)" : sentence
            )
        }

        public static let verifiedVerdict = IntegrityVerdict(
            outcome: .verified,
            mismatchedMembers: [],
            detail: "every recorded hash matches the bytes on disk"
        )
    }

    /// A member's digest together with the identity of the bytes it was taken over, so
    /// the save pipeline can reuse it while those bytes are demonstrably unchanged.
    struct MemberDigest: Sendable, Hashable {
        let identity: FileDurability.FileIdentity
        let sha256: String
    }

    /// The verdict, plus every digest the check computed, keyed by package-relative path.
    ///
    /// The four members are hashed **concurrently** (IM-074): they are independent
    /// reads of independent files, and on the SSDs this ships on the two PDFs — the
    /// expensive half of the open — overlap rather than queue. The identity of each file
    /// is taken *before* it is read; a digest is only recorded when the identity is the
    /// same afterwards, so a member rewritten under the check is never cached.
    static func verifyAgainstIntegrityRecordCollectingDigests(
        at url: URL,
        integrity: IntegrityRecord,
        carriesCrashEvidence: Bool
    ) -> (verdict: IntegrityVerdict, digests: [String: MemberDigest]) {
        let members = [
            ProjectPackageLayout.manifest,
            ProjectPackageLayout.originalPDF,
            ProjectPackageLayout.workingPDF,
            ProjectPackageLayout.database
        ]
        let results = OSAllocatedUnfairLock(initialState: [String: MemberDigest?]())
        DispatchQueue.concurrentPerform(iterations: members.count) { index in
            let relativePath = members[index]
            let memberURL = url.member(relativePath)
            var digest: MemberDigest?
            if FileDurability.exists(memberURL),
               let before = FileDurability.identity(of: memberURL),
               let sha256 = try? FileDurability.sha256(ofFileAt: memberURL) {
                digest = MemberDigest(
                    identity: before,
                    sha256: sha256
                )
                if FileDurability.identity(of: memberURL) != before {
                    // Hashed, but over bytes that moved while being read: the digest is
                    // still compared, and it is not remembered.
                    digest = MemberDigest(identity: FileDurability.FileIdentity(
                        device: 0, inode: 0, byteCount: -1, modifiedAtNanoseconds: -1
                    ), sha256: sha256)
                }
            }
            let finished = digest
            results.withLock { $0[relativePath] = finished }
        }
        let computed = results.withLock { $0 }

        /// A member's hash, or `nil` if it could not be read at all.
        func hash(_ relativePath: String) -> String? {
            computed[relativePath]??.sha256
        }

        var tampered: [String] = []
        var damaged: [String] = []

        // The three files no session ever rewrites. `manifest.json` is a few hundred
        // bytes; the two PDFs are the expensive reads on this path, and they are still
        // cheaper than the `PRAGMA integrity_check` the same open performs, which walks
        // every page of the database.
        for (relativePath, expected) in [
            (ProjectPackageLayout.manifest, integrity.manifestSha256),
            (ProjectPackageLayout.originalPDF, integrity.originalPdfSha256),
            (ProjectPackageLayout.workingPDF, integrity.workingPdfSha256)
        ] {
            guard let actual = hash(relativePath) else {
                // `manifest.json` and `original.pdf` are required members, so a missing
                // one has already been refused by `validateStructure`. `working.pdf` is
                // not: a package without it is incomplete rather than hostile.
                damaged.append(relativePath)
                continue
            }
            if actual != expected { tampered.append(relativePath) }
        }

        var digests: [String: MemberDigest] = [:]
        for (relativePath, digest) in computed {
            if let digest, digest.identity.byteCount >= 0 { digests[relativePath] = digest }
        }

        // The database, whose honesty depends on the close that last touched it.
        if let actual = hash(ProjectPackageLayout.database) {
            if actual != integrity.databaseSha256 {
                if carriesCrashEvidence {
                    damaged.append(ProjectPackageLayout.database)
                } else {
                    tampered.append(ProjectPackageLayout.database)
                }
            }
        } else {
            damaged.append(ProjectPackageLayout.database)
        }

        if !tampered.isEmpty {
            return (IntegrityVerdict(
                outcome: .modifiedOutsideZenitPDF,
                mismatchedMembers: tampered + damaged,
                detail: "\(tampered.joined(separator: ", ")) "
                    + "\(tampered.count == 1 ? "does" : "do") not match the hash this project records"
            ), digests)
        }
        if !damaged.isEmpty {
            return (IntegrityVerdict(
                outcome: .damaged,
                mismatchedMembers: damaged,
                detail: "\(damaged.joined(separator: ", ")) "
                    + "\(damaged.count == 1 ? "does" : "do") not match the hash this project records, "
                    + "which is what a session that did not finish leaves behind"
            ), digests)
        }
        return (.verifiedVerdict, digests)
    }

    // MARK: - The drawings of a set (S-120)

    /// A stored file and the digest its row records.
    struct RecordedFile: Sendable, Hashable {
        let relativePath: String
        let sha256: String
    }

    /// The drawings added after creation and the stored revisions whose bytes do not match the
    /// SHA-256 their rows record, in row order (documents, then revisions).
    ///
    /// S-120. `addDocument` and `addRevision` record a digest for every `documents/added-*.pdf`
    /// and `documents/revisions/*.pdf`, but only the primary pair was ever compared, so a drawing
    /// swapped outside Zenit PDF in a multi-drawing project opened as if nothing had happened
    /// and the takeoff landed on other geometry. Like `original.pdf` these files are read-only
    /// and never rewritten by any session, so a difference is always an editor other than this
    /// application: a special file or symbolic link in their place, or a path outside
    /// `documents/` (which no save writes), counts the same. A file that is missing is not
    /// compared — the load path already skips a drawing it cannot find, and says so.
    ///
    /// Hashed concurrently, like the primary pair. The rows are read through a read-only
    /// probe connection, which writes nothing; when they cannot be read, nothing is compared.
    /// A crash between an add's copy and its row leaves a file with no row, never a row whose
    /// file differs, so crash evidence changes nothing here.
    static func drawingSetMismatches(at url: URL, databaseAt databaseURL: URL) -> [String] {
        let primary = ProjectPackageLayout.originalPDF
        let configuration = DatabaseTuning.probeConfiguration(readOnly: true)
        guard let queue = try? DatabaseQueue(path: databaseURL.path, configuration: configuration) else { return [] }
        defer { try? queue.close() }
        let recorded: [RecordedFile]
        do {
            recorded = try queue.read { db -> [RecordedFile] in
                var files = try Row.fetchAll(
                    db, sql: "SELECT relative_path, sha256 FROM document WHERE relative_path <> ? ORDER BY rowid",
                    arguments: [primary]
                ).map { RecordedFile(relativePath: $0["relative_path"], sha256: $0["sha256"]) }
                if try db.tableExists("revision_entry") {
                    files += try Row.fetchAll(db, sql: "SELECT relative_path, sha256 FROM revision_entry ORDER BY rowid")
                        .map { RecordedFile(relativePath: $0["relative_path"], sha256: $0["sha256"]) }
                }
                return files
            }
        } catch {
            return []
        }
        guard !recorded.isEmpty else { return [] }

        enum Found: Sendable { case missing, unreadable, digest(String) }
        let paths = Array(Set(recorded.map(\.relativePath)))
        let found = OSAllocatedUnfairLock(initialState: [String: Found]())
        DispatchQueue.concurrentPerform(iterations: paths.count) { index in
            let relativePath = paths[index]
            let result: Found
            if !relativePath.hasPrefix("\(ProjectPackageLayout.documents)/") || relativePath.contains("..") {
                result = .unreadable
            } else {
                let memberURL = url.member(relativePath)
                var status = stat()
                if lstat(memberURL.path, &status) != 0, errno == ENOENT {
                    result = .missing
                } else if let digest = try? FileDurability.sha256(ofFileAt: memberURL) {
                    result = .digest(digest)
                } else {
                    result = .unreadable
                }
            }
            found.withLock { $0[relativePath] = result }
        }
        let results = found.withLock { $0 }
        var mismatched: [String] = []
        for file in recorded where !mismatched.contains(file.relativePath) {
            switch results[file.relativePath] {
            case .missing, nil: continue
            case .unreadable: mismatched.append(file.relativePath)
            case .digest(let actual): if actual != file.sha256 { mismatched.append(file.relativePath) }
            }
        }
        return mismatched
    }

    /// Re-records the database's hash so the package at rest describes itself truthfully.
    ///
    /// Called from ``ProjectPackage/close()`` after the final `TRUNCATE` checkpoint, when
    /// `project.sqlite` has reached the shape the next reader will find. Returns whether
    /// the record on disk is now correct; ``ProjectPackage/close()`` keeps the crash
    /// marker armed when it is not, so a package whose record could not be refreshed
    /// arrives at the recovery sheet rather than at an accusation of tampering.
    @discardableResult
    func refreshIntegrityRecordAtRest() -> Bool {
        guard var record = currentIntegrity else { return false }
        guard let actual = try? FileDurability.sha256(
            ofFileAt: url.member(ProjectPackageLayout.database)
        ) else { return false }
        guard actual != record.databaseSha256 else { return true }

        record.databaseSha256 = actual
        guard let data = try? record.encoded() else { return false }
        do {
            try FileDurability.writeFileAtomically(
                data,
                to: url.member(ProjectPackageLayout.integrity),
                token: record.saveToken
            )
            currentIntegrity = record
            return true
        } catch {
            return false
        }
    }
}
