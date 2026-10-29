import Foundation

/// The named points a save passes through.
///
/// They are public because the durability tests kill a real process at four of them
/// (`willWriteTemporaryPackage`, `midTemporaryPackageWrite`, `didHash`,
/// `willAtomicReplace`) and because the recovery journal records the last one reached,
/// which is what tells the next launch how far a crashed save got.
public enum SaveCheckpoint: String, Sendable, Hashable, Codable, CaseIterable {
    case willValidate
    case didValidate
    case didCommit
    case didCheckpointWAL
    case willWriteTemporaryPackage
    case midTemporaryPackageWrite
    case didWriteTemporaryPackage
    case didHash
    case didFsync
    case willAtomicReplace
    case didAtomicReplace
    case didPreserveVersion
    case didComplete
}

/// A hook called at each ``SaveCheckpoint``.
///
/// In production this is empty. In the durability suite it is how a child process is
/// stopped at an exact point in the pipeline, which is the only way to find out what
/// the filesystem really holds at that point rather than what we believe it holds.
/// A hook that throws aborts the save. Before ``SaveCheckpoint/didAtomicReplace`` that
/// is a clean abort — the project on disk is untouched and the temporary sibling is
/// removed. After it the save has already committed, and throwing only skips
/// housekeeping.
public struct SaveHooks: Sendable {
    public var onCheckpoint: @Sendable (SaveCheckpoint) async throws -> Void

    public init(onCheckpoint: @escaping @Sendable (SaveCheckpoint) async throws -> Void) {
        self.onCheckpoint = onCheckpoint
    }

    public static let none = SaveHooks { _ in }
}

/// What kind of thing a journal line records.
public enum JournalEventKind: String, Sendable, Hashable, Codable, CaseIterable {
    case sessionOpened = "session-opened"
    case sessionClosed = "session-closed"
    case save
    case autosave
    case recovery
}

/// One line of the recovery journal.
public struct RecoveryJournalEntry: Sendable, Hashable, Codable {
    /// The operation this entry belongs to. Save entries share the save's token.
    public var token: String
    public var kind: JournalEventKind
    /// Set on `save` entries: how far the pipeline had got.
    public var checkpoint: SaveCheckpoint?
    /// Free text for `recovery` and `autosave` entries.
    public var detail: String?
    public var timestamp: String
    /// The document change count at the moment the entry was written.
    public var changeCount: Int

    public init(
        token: String,
        kind: JournalEventKind,
        checkpoint: SaveCheckpoint? = nil,
        detail: String? = nil,
        timestamp: String,
        changeCount: Int
    ) {
        self.token = token
        self.kind = kind
        self.checkpoint = checkpoint
        self.detail = detail
        self.timestamp = timestamp
        self.changeCount = changeCount
    }
}

/// `recovery/journal.json`.
///
/// Written into the **live** package, not the temporary one, and flushed with
/// `F_FULLFSYNC` before the pipeline moves on. That placement is the whole design: if
/// the process dies mid-save, the package the user still has on disk is the one holding
/// the note that says how far the save got. On success the swap replaces that package
/// with the temporary one, whose journal has a single `didComplete` line, so a clean
/// save leaves no crash evidence behind.
public struct RecoveryJournal: Sendable, Hashable, Codable {
    /// Newest last. Bounded, because a journal is a breadcrumb trail and not a log.
    public var entries: [RecoveryJournalEntry]

    public static let maximumEntryCount = 64
    public static let maximumByteCount = 1 << 20

    public init(entries: [RecoveryJournalEntry] = []) {
        self.entries = entries
    }

    public mutating func append(_ entry: RecoveryJournalEntry) {
        entries.append(entry)
        if entries.count > Self.maximumEntryCount {
            entries.removeFirst(entries.count - Self.maximumEntryCount)
        }
    }

    /// The last save recorded, and how far it got.
    public var lastSave: (token: String, checkpoint: SaveCheckpoint, timestamp: String)? {
        for entry in entries.reversed() where entry.kind == .save {
            guard let checkpoint = entry.checkpoint else { continue }
            return (entry.token, checkpoint, entry.timestamp)
        }
        return nil
    }

    /// The save that was still in flight when the process last wrote to this journal,
    /// or `nil` if the process is known to have outlived it.
    ///
    /// The rule is positional, and it is the whole of the crash story: only this process
    /// writes the journal, and a process that died mid-save wrote nothing after the
    /// checkpoint line it reached. So a save is in flight exactly when its checkpoint
    /// line, short of `didComplete`, is the **last** line. Any line after it — a
    /// recovery note, a session opened or closed, an autosave, the aborted marker the
    /// pipeline writes when it throws before the swap — is proof the process went on.
    ///
    /// ``lastSave`` alone is not that rule, and treating it as one produced two false
    /// crashes: a recovery that had already been *applied* still saw the pre-crash line
    /// and re-prompted on every later open, with `Discard` on that spurious sheet
    /// throwing away every edit since (BH-030); and a save refused before the swap —
    /// validation, a full disk, a changed original PDF — left its last checkpoint line
    /// in place, so a clean close was reported as a session that died mid-save (BH-190).
    public var saveInFlight: (token: String, checkpoint: SaveCheckpoint, timestamp: String)? {
        guard let last = entries.last, last.kind == .save,
              let checkpoint = last.checkpoint, checkpoint != .didComplete
        else { return nil }
        return (last.token, checkpoint, last.timestamp)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(self)
        } catch {
            throw ZPDFPersistenceError.recoveryFailed(reason: "journal encode: \(error.localizedDescription)")
        }
    }

    /// Reads the journal. A missing or unreadable journal is an *empty* journal, never
    /// an error: the journal is evidence about a crash, and refusing to open a project
    /// because the crash evidence is itself damaged would be exactly backwards.
    ///
    /// Only a regular file is read, capped on the open descriptor (U-098, the BH-598/BH-600
    /// rule the manifest already follows). The cap used to be measured on the path, which
    /// for a symbolic link is the link's own few bytes, and `Data(contentsOf:)` then followed
    /// it: a journal linked to `/dev/zero` read until memory ran out, and a FIFO blocked the
    /// open for good — both before the package's structure was ever validated.
    public static func read(from url: URL) -> RecoveryJournal {
        guard FileDurability.exists(url),
              let data = try? FileDurability.readRegularFile(
                  at: url, limit: maximumByteCount, what: "recovery/journal.json"
              ),
              let journal = try? JSONDecoder().decode(RecoveryJournal.self, from: data)
        else { return RecoveryJournal() }
        return journal
    }
}

/// What an interrupted save left behind.
public struct InterruptedSave: Sendable, Hashable, Codable {
    public var token: String
    /// The last checkpoint that made it to disk before the process died.
    public var lastCheckpoint: SaveCheckpoint
    public var timestamp: String

    public init(token: String, lastCheckpoint: SaveCheckpoint, timestamp: String) {
        self.token = token
        self.lastCheckpoint = lastCheckpoint
        self.timestamp = timestamp
    }
}

/// What an autosave snapshot holds.
public struct AutosaveInfo: Sendable, Hashable, Codable {
    public var timestamp: String
    public var byteCount: Int
    /// Whether `PRAGMA integrity_check` came back clean on the snapshot.
    public var passesIntegrityCheck: Bool

    public init(timestamp: String, byteCount: Int, passesIntegrityCheck: Bool) {
        self.timestamp = timestamp
        self.byteCount = byteCount
        self.passesIntegrityCheck = passesIntegrityCheck
    }
}

/// The three outcomes spec 6.5 offers the user.
public enum RecoveryDecision: String, Sendable, Hashable, Codable, CaseIterable {
    /// Adopt the autosave snapshot, if there is a usable one, and open for editing.
    case recover
    /// Open the last committed state without writing anything at all — not even the
    /// crash marker. The choice for a user who wants to look before they leap.
    case openReadOnly
    /// Throw the autosave away and open the last committed state for editing.
    case discard
}

/// What the last launch left behind, and what this package recommends doing about it.
///
/// In every branch, `documents/original.pdf` is untouched. Recovery only ever replaces
/// `project.sqlite`, and only ever from a snapshot that passed an integrity check.
public struct RecoveryAssessment: Sendable, Hashable, Codable {
    /// A crash marker was present at open: the previous session did not close cleanly.
    public var crashMarkerPresent: Bool
    /// A save was in flight when the process died.
    public var interruptedSave: InterruptedSave?
    /// An autosave snapshot is available.
    public var autosave: AutosaveInfo?
    /// The manifest of the last save known to have completed.
    public var lastGoodManifest: ProjectManifest?
    /// Leftover sibling directories from a crashed save, ready to be reclaimed.
    public var reclaimableLeftovers: [String]
    /// The marker describes a session that is alive on another machine, or in another
    /// process on this one (NL-COLLAB-13). When set, the package is **not** offered recovery:
    /// ``ProjectPackage/open(at:environment:)`` answers ``OpenOutcome/openElsewhere(_:_:)``.
    public var foreignSession: ForeignSession?

    public init(
        crashMarkerPresent: Bool,
        interruptedSave: InterruptedSave? = nil,
        autosave: AutosaveInfo? = nil,
        lastGoodManifest: ProjectManifest? = nil,
        reclaimableLeftovers: [String] = [],
        foreignSession: ForeignSession? = nil
    ) {
        self.crashMarkerPresent = crashMarkerPresent
        self.interruptedSave = interruptedSave
        self.autosave = autosave
        self.lastGoodManifest = lastGoodManifest
        self.reclaimableLeftovers = reclaimableLeftovers
        self.foreignSession = foreignSession
    }

    /// Nothing to decide: the last session closed cleanly.
    public var isClean: Bool {
        !crashMarkerPresent && interruptedSave == nil && autosave == nil
    }

    /// What to preselect in the recovery sheet: always ``RecoveryDecision/recover``.
    ///
    /// Not a hedge. `recover` keeps every edit the previous session committed, which the
    /// write-ahead log has usually already made durable, and falls back to the autosave
    /// and then to the last saved version only if the database ahead of it is damaged.
    /// It is the outcome that loses nothing, so it is the one that should be one Return
    /// keypress away. `discard` throws a user's work away and should always be a
    /// deliberate act.
    public var recommended: RecoveryDecision { .recover }

    public var summary: String {
        var parts: [String] = []
        if let foreignSession {
            parts.append("open on \(foreignSession.host.displayName) since \(foreignSession.openedAt)")
        } else if crashMarkerPresent {
            parts.append("crash marker")
        }
        if let interruptedSave {
            parts.append("save \(interruptedSave.token) stopped at \(interruptedSave.lastCheckpoint.rawValue)")
        }
        if let autosave {
            parts.append("autosave \(autosave.timestamp), integrity \(autosave.passesIntegrityCheck ? "ok" : "failed")")
        }
        if !reclaimableLeftovers.isEmpty {
            parts.append("\(reclaimableLeftovers.count) leftover item(s)")
        }
        return parts.isEmpty ? "clean" : parts.joined(separator: ", ")
    }
}

/// The result of opening a package.
public enum OpenOutcome: Sendable {
    /// The package opened. There was nothing to recover.
    case opened(ProjectPackage)
    /// The package carries crash evidence. Show the user the assessment, get a
    /// ``RecoveryDecision``, then call `ProjectPackage.open(at:environment:resolving:)`.
    case recoveryRequired(RecoveryAssessment)
    /// The package is open in a live session elsewhere (NL-COLLAB-13). Never a recovery
    /// prompt. Ask for a ``ForeignSessionDecision``, then call
    /// `ProjectPackage.open(at:environment:foreignSession:)`.
    case openElsewhere(ForeignSession, RecoveryAssessment)
}
