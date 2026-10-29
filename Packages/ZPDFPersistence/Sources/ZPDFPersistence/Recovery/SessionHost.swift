import CryptoKit
import Foundation
#if canImport(IOKit)
import IOKit
#endif
#if canImport(SystemConfiguration) && os(macOS)
import SystemConfiguration
#endif

/// Which machine, and which person on it, holds a project session (NL-COLLAB-13).
///
/// Written into the crash marker so that a project kept in a shared or synced folder can tell
/// "the session that armed this marker died" from "the session that armed this marker is alive
/// on another Mac". Before this, the marker carried only a process id, a time and an app
/// version, and a package open on Mac B looked exactly like a crash to Mac A: Mac A was offered
/// Recover or Discard over a live session, and the next atomic package replace on either side
/// could overwrite the other person's work.
///
/// `machineID` is pseudonymous on purpose. A package travels — it is emailed, zipped, put on a
/// share — and the hardware UUID it is derived from must not travel with it, so only a salted
/// SHA-256 prefix of it is stored. It is stable across launches and network changes, which a
/// host name is not (DHCP and Bonjour both rename machines).
public struct SessionHost: Sendable, Hashable, Codable {
    /// Stable, pseudonymous identifier of this machine.
    public var machineID: String
    /// The name the user gave the computer, for the sentence "Open on 'Mac-B'".
    public var displayName: String
    /// The person signed in, for "…by N". Optional: an old marker, or a machine that will not
    /// say, simply leaves it out of the sentence.
    public var userName: String?

    public init(machineID: String, displayName: String, userName: String? = nil) {
        self.machineID = machineID
        self.displayName = displayName
        self.userName = userName
    }

    /// This machine, computed once per process.
    public static var current: SessionHost { cachedCurrent }

    private static let cachedCurrent: SessionHost = {
        let display = computerName() ?? bsdHostName() ?? "Mac"
        let hardware = hardwareIdentifier() ?? bsdHostName() ?? display
        let digest = SHA256.hash(data: Data(("zenit-session-host:" + hardware).utf8))
        let machineID = digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        let fullName = NSFullUserName()
        return SessionHost(
            machineID: machineID,
            displayName: display,
            userName: fullName.isEmpty ? NSUserName() : fullName
        )
    }()

    private static func computerName() -> String? {
        #if canImport(SystemConfiguration) && os(macOS)
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String?,
           !name.trimmingCharacters(in: .whitespaces).isEmpty {
            return name
        }
        #endif
        return nil
    }

    private static func bsdHostName() -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        var name = String(decoding: bytes, as: UTF8.self)
        if name.hasSuffix(".local") { name.removeLast(".local".count) }
        return name.isEmpty ? nil : name
    }

    private static func hardwareIdentifier() -> String? {
        #if canImport(IOKit) && os(macOS)
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let property = IORegistryEntryCreateCFProperty(
            service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0
        )
        return property?.takeRetainedValue() as? String
        #else
        return nil
        #endif
    }
}

/// A live session on another machine, or in another process on this one (NL-COLLAB-13).
///
/// Reported instead of crash evidence when the marker's heartbeat is fresh. Never a recovery
/// prompt: the session it describes has not crashed, and "recovering" over it is the data loss
/// this type exists to prevent.
public struct ForeignSession: Sendable, Hashable, Codable {
    /// The machine that holds the session.
    public var host: SessionHost
    /// When that session opened the project, as the marker recorded it.
    public var openedAt: String
    /// The newest heartbeat the marker carries.
    public var heartbeatAt: String
    /// True when the other session is on this machine, in another live process.
    public var isSameMachine: Bool

    public init(host: SessionHost, openedAt: String, heartbeatAt: String, isSameMachine: Bool) {
        self.host = host
        self.openedAt = openedAt
        self.heartbeatAt = heartbeatAt
        self.isSameMachine = isSameMachine
    }

    /// `openedAt` as a date, when it parses.
    public var openedDate: Date? { PersistenceTimestamp.date(from: openedAt) }
}

/// What the user chose about a project that is open somewhere else (NL-COLLAB-13).
public enum ForeignSessionDecision: String, Sendable, Hashable, Codable, CaseIterable {
    /// Look without writing anything: not the marker, not the journal, not the database.
    case openReadOnly
    /// Open for editing anyway. The other session's marker is replaced by this one's and no
    /// recovery step runs — there is nothing to recover from a session that is alive.
    case openAnyway
    /// Do not open.
    case cancel
}

/// The rule that decides whether a crash marker describes a live session elsewhere.
public enum ForeignSessionPolicy {
    /// How often a live session refreshes its heartbeat. The app runs the timer.
    public static let heartbeatInterval: TimeInterval = 60
    /// How old a heartbeat may be and still count as alive. Generous on purpose: a sync
    /// service can sit on a small file for minutes, and the cost of a false "open elsewhere"
    /// is one extra click, while the cost of a false "crash" is somebody's afternoon.
    public static let defaultTimeToLive: TimeInterval = 15 * 60

    /// Whether a process with this id is running on this machine.
    public static func processIsAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        // EPERM: it exists and belongs to someone we may not signal.
        return errno == EPERM
    }

    /// Classifies a marker. `nil` means "treat as crash evidence, exactly as before".
    ///
    /// - A marker with no host (written by a build before NL-COLLAB-13) is crash evidence.
    /// - A marker whose heartbeat is older than `timeToLive` is crash evidence: whoever armed
    ///   it stopped refreshing it, which is what a crash looks like from outside.
    /// - A marker from another machine with a fresh heartbeat is a foreign session.
    /// - A marker from this machine is a foreign session only when its process is another,
    ///   living one. Our own pid, or a dead one, is a crash on this machine.
    public static func foreignSession(
        in marker: ProjectPackage.CrashMarker,
        localHost: SessionHost,
        localProcessIdentifier: Int32,
        now: Date,
        timeToLive: TimeInterval = defaultTimeToLive,
        isProcessAlive: (Int32) -> Bool = processIsAlive
    ) -> ForeignSession? {
        guard let hostID = marker.hostID, !hostID.isEmpty else { return nil }
        let heartbeatText = marker.heartbeatAt ?? marker.openedAt
        guard let heartbeat = PersistenceTimestamp.date(from: heartbeatText) else { return nil }
        let age = now.timeIntervalSince(heartbeat)
        // A heartbeat from the future (clock skew between two Macs) counts as fresh; one older
        // than the time to live does not.
        guard age <= timeToLive else { return nil }

        let sameMachine = hostID == localHost.machineID
        if sameMachine {
            guard marker.processIdentifier != localProcessIdentifier,
                  isProcessAlive(marker.processIdentifier)
            else { return nil }
        }
        return ForeignSession(
            host: SessionHost(
                machineID: hostID,
                displayName: marker.hostName ?? hostID,
                userName: marker.userName
            ),
            openedAt: marker.openedAt,
            heartbeatAt: heartbeatText,
            isSameMachine: sameMachine
        )
    }
}

/// Copies of a project that a sync service made when two machines wrote it at once
/// (NL-COLLAB-13). Reported, never merged or deleted: which copy holds the work is for the user.
public enum SyncConflictScanner {

    /// What a look beside a package found (X-049).
    public enum SiblingScan: Sendable, Equatable {
        /// The folder was listed; these are the conflict copies in it, possibly none.
        case copies([String])
        /// The folder could not be listed, so nobody knows whether copies are there: a
        /// sandboxed process holding a grant for the package and nothing beside it, a folder
        /// that refuses listing, or one that has gone.
        case folderNotReadable
    }

    /// The folder's entries, as the scan reads them by default.
    public static func listFolder(_ folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path)
    }

    /// The conflict copies beside `url`, or that the folder could not be looked at.
    ///
    /// X-049: a refused listing used to read as an empty one, so the sandboxed application —
    /// which may read the package it opened and nothing beside it — reported "no conflict
    /// copies" for every project, and a colleague's work in a sibling copy went unmentioned.
    ///
    /// - Parameter listing: how the folder is listed; a test refuses it as the sandbox does.
    public static func conflictCopies(
        besides url: URL, listing: (URL) throws -> [String] = listFolder
    ) -> SiblingScan {
        guard let names = try? listing(url.deletingLastPathComponent()) else { return .folderNotReadable }
        return .copies(conflictCopyNames(names, besides: url))
    }

    /// Which of a folder's `names` say a sync client made them from the package at `url`.
    ///
    /// The shapes recognised are the ones sync clients actually produce: a "conflicted copy"
    /// or "conflict" note after the package's own stem, or a `.sync-conflict-` infix. Only names that start with this package's stem
    /// and keep its extension are considered, so an unrelated project in the same folder is
    /// never reported.
    public static func conflictCopyNames(_ names: [String], besides url: URL) -> [String] {
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        return names.filter { name in
            guard name != url.lastPathComponent else { return false }
            let candidate = URL(fileURLWithPath: name)
            guard candidate.pathExtension == ext else { return false }
            let otherStem = candidate.deletingPathExtension().lastPathComponent
            return isConflictStem(otherStem, of: stem)
        }.sorted()
    }

    static func isConflictStem(_ other: String, of stem: String) -> Bool {
        guard other.hasPrefix(stem), other.count > stem.count else { return false }
        let rest = other.dropFirst(stem.count)
        // "(Mac-B's conflicted copy 2026-09-23)", ".sync-conflict-20260923-…", "-conflict-1".
        // A plain numbered sibling ("Project 2") is deliberately not matched: it is as likely
        // to be a second project the user named that way, and a false alarm teaches people to
        // ignore the real one.
        return rest.lowercased().contains("conflict")
    }

    /// Unresolved conflict versions the file coordinator knows about (iCloud Drive and other
    /// file providers that use `NSFileVersion`).
    public static func unresolvedVersionCount(at url: URL) -> Int {
        #if os(macOS)
        return NSFileVersion.unresolvedConflictVersionsOfItem(at: url)?.count ?? 0
        #else
        return 0
        #endif
    }
}
