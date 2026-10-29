import AppKit
import ZPDFPersistence

/// The question asked when a project is open in a live session on another Mac, or in another
/// process on this one (NL-COLLAB-13).
///
/// It replaces the crash-recovery prompt for that case, never sits beside it: before this, the
/// second person was told the project "was not closed properly" and offered Recover or Discard
/// over a session that was still writing it — and the next atomic package replace on either
/// machine could overwrite the other person's work.
///
/// Through ``ZenitModalPresenter`` like every other alert, so no test can put it on screen. A
/// process with no user gets ``ForeignSessionDecision/openReadOnly``: it writes nothing, which
/// is the one answer that cannot harm the live session.
@MainActor
public enum SharedStoragePrompt {

    /// The stable name of the dialogue, for `ZenitModalPresenter` assertions.
    public static let modalIdentifier = "sharedStorage.openElsewhere"
    /// The stable name of the sync-conflict notice.
    public static let conflictModalIdentifier = "sharedStorage.syncConflicts"

    /// Asks what to do about a project that is open elsewhere.
    public static func ask(session: ForeignSession, packageName: String, now: Date = Date()) -> ForeignSessionDecision {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title(for: session, packageName: packageName)
        alert.informativeText = informativeText(for: session, now: now)
        alert.addButton(withTitle: NSLocalizedString("Open Read-Only", comment: "Recovery alert button"))
        let anyway = alert.addButton(withTitle: NSLocalizedString(
            "Open Anyway", comment: "Shared storage alert button: open a project that is open on another Mac for editing"
        ))
        anyway.hasDestructiveAction = true
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button"))
        switch ZenitModalPresenter.runAlert(
            alert, identifier: modalIdentifier, answerWithoutAUser: .button(0)
        ) {
        case .button(0): return .openReadOnly
        case .button(1): return .openAnyway
        case .button(2): return .cancel
        default: return .openReadOnly
        }
    }

    static func title(for session: ForeignSession, packageName: String) -> String {
        if session.isSameMachine {
            return String(
                format: NSLocalizedString(
                    "“%@” is already open in another Zenit PDF window on this Mac.",
                    comment: "Shared storage alert title: the project is open in another process on this Mac; the project name"
                ),
                packageName
            )
        }
        return String(
            format: NSLocalizedString(
                "“%1$@” is open on “%2$@”.",
                comment: "Shared storage alert title: the project name, then the other Mac's name"
            ),
            packageName, session.host.displayName
        )
    }

    /// "Open on 'Mac-B' by N since 10:42", then what each button does.
    static func informativeText(for session: ForeignSession, now: Date = Date()) -> String {
        var lines: [String] = []
        let since = session.openedDate.map {
            DateFormatter.localizedString(
                from: $0,
                dateStyle: Calendar.current.isDate($0, inSameDayAs: now) ? .none : .medium,
                timeStyle: .short
            )
        }
        switch (session.host.userName, since) {
        case let (name?, since?):
            lines.append(String(
                format: NSLocalizedString(
                    "%1$@ has had it open since %2$@.",
                    comment: "Shared storage alert: who has the project open and since when"
                ),
                name, since
            ))
        case let (name?, nil):
            lines.append(String(
                format: NSLocalizedString("%@ has it open.", comment: "Shared storage alert: who has the project open"),
                name
            ))
        case let (nil, since?):
            lines.append(String(
                format: NSLocalizedString("It has been open since %@.", comment: "Shared storage alert: since when"),
                since
            ))
        case (nil, nil):
            break
        }
        lines.append(NSLocalizedString(
            "This is not a crash: that session is still running.",
            comment: "Shared storage alert: why no recovery is offered"
        ))
        lines.append(NSLocalizedString(
            "Open Read-Only lets you look without changing anything. Open Anyway lets you edit, and whichever of you saves last replaces the other’s changes.",
            comment: "Shared storage alert: what the two open buttons do"
        ))
        return lines.joined(separator: " ")
    }

    /// Tells the user about copies a sync service made of this project. Informational: which
    /// copy holds the work is for the user to decide, and nothing is merged or deleted.
    /// The package the next conflict report is about, set by the open for the actions of
    /// NL-PLAT-16 (open the other copy, keep this one). `nil`: the report is a notice only.
    static var conflictPackageURL: URL?
    /// Whether the open could look in the project's folder for sibling copies (X-049), set by
    /// the open beside ``conflictPackageURL``. `false`: the notice says the folder was not checked.
    static var conflictFolderChecked = true

    public static func reportConflicts(copyNames: [String], unresolvedVersions: Int, packageName: String) {
        guard !copyNames.isEmpty || unresolvedVersions > 0 else { return }
        let folderChecked = conflictFolderChecked
        conflictFolderChecked = true
        if let url = conflictPackageURL {
            conflictPackageURL = nil
            offerConflictChoice(url: url, copyNames: copyNames, unresolvedVersions: unresolvedVersions, packageName: packageName,
                                folderChecked: folderChecked)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(
            format: NSLocalizedString(
                "“%@” has sync conflict copies.",
                comment: "Sync conflict notice title; the project name"
            ),
            packageName
        )
        alert.informativeText = conflictText(copyNames: copyNames, unresolvedVersions: unresolvedVersions, folderChecked: folderChecked)
        alert.addButton(withTitle: NSLocalizedString("OK", comment: "OK button"))
        _ = ZenitModalPresenter.runAlert(alert, identifier: conflictModalIdentifier, answerWithoutAUser: .dismissed)
    }

    /// NL-PLAT-16 (r2-platform): the conflict with its two ways forward — open the other version
    /// as a separate copy to compare, or keep this one. Never a merge, never a deletion.
    @discardableResult
    static func offerConflictChoice(url: URL, copyNames: [String], unresolvedVersions: Int, packageName: String,
                                    folderChecked: Bool = true) -> SyncedFolderSafety.ConflictChoice {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(format: NSLocalizedString("“%@” has sync conflict copies.", comment: "Sync conflict notice title; the project name"), packageName)
        alert.informativeText = conflictText(copyNames: copyNames, unresolvedVersions: unresolvedVersions, folderChecked: folderChecked)
        alert.addButton(withTitle: NSLocalizedString("Open the Other Copy", comment: "Sync conflict: open the other version as a separate copy"))
        alert.addButton(withTitle: NSLocalizedString("Keep This One", comment: "Sync conflict: keep the version that was opened"))
        alert.addButton(withTitle: NSLocalizedString("Later", comment: "Sync conflict: decide later"))
        let choice: SyncedFolderSafety.ConflictChoice
        switch ZenitModalPresenter.runAlert(alert, identifier: SyncedFolderSafety.conflictChoiceIdentifier, answerWithoutAUser: .button(2)) {
        case .button(0): choice = .openOtherCopy
        case .button(1): choice = .keepThisOne
        default: choice = .later
        }
        switch choice {
        case .openOtherCopy:
            if let copy = SyncedFolderSafety.copyOfOtherVersion(of: url, siblingNames: copyNames) {
                SyncedFolderSafety.opener(copy)
            }
        case .keepThisOne:
            SyncedFolderSafety.keepThisOne(url)
        case .later:
            break
        }
        return choice
    }

    static func conflictText(copyNames: [String], unresolvedVersions: Int, folderChecked: Bool = true) -> String {
        var lines: [String] = [NSLocalizedString(
            "A sync service saved two versions of this project at the same time. The one you opened may not hold everybody’s latest work.",
            comment: "Sync conflict notice: what happened"
        )]
        if !copyNames.isEmpty {
            lines.append(String(
                format: NSLocalizedString(
                    "Copies in the same folder: %@.",
                    comment: "Sync conflict notice: the names of the conflict copies"
                ),
                copyNames.joined(separator: ", ")
            ))
        }
        if unresolvedVersions > 0 {
            lines.append(String(
                format: NSLocalizedString(
                    "Other versions waiting to be resolved: %lld.",
                    comment: "Sync conflict notice: number of unresolved file versions"
                ),
                unresolvedVersions
            ))
        }
        if !folderChecked {
            // X-049: until the folder is granted, a look that could not happen is said, never
            // passed off as "no copies there".
            lines.append(NSLocalizedString(
                "The project’s folder was not checked for copies: Zenit PDF has no access to it.",
                comment: "Sync conflict notice: the folder beside the project could not be listed"
            ))
        }
        lines.append(NSLocalizedString(
            "Open each copy and compare before deleting any of them.",
            comment: "Sync conflict notice: what to do"
        ))
        return lines.joined(separator: " ")
    }
}

/// Keeps a live session's crash-marker heartbeat fresh, so another Mac reading the project
/// through a shared folder sees "open here" rather than a crash (NL-COLLAB-13).
///
/// Holds the package weakly and stops on its own once the package is closed or gone
/// (`refreshSessionHeartbeat()` answers `false`), so nobody has to remember to stop it.
enum ProjectSessionHeartbeat {
    @discardableResult
    static func start(
        for package: ProjectPackage,
        interval: TimeInterval = ForeignSessionPolicy.heartbeatInterval
    ) -> Task<Void, Never> {
        Task.detached(priority: .utility) { [weak package] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(max(interval, 0.01) * 1_000_000_000))
                guard let package, await package.refreshSessionHeartbeat() else { return }
            }
        }
    }
}
