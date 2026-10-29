import AppKit
import ZPDFPersistence

/// The `Recover` / `Open Read-Only` / `Discard` choice for a package that did not close cleanly.
///
/// Modal rather than a sheet, because the window it would attach to does not exist yet: the choice
/// decides what the window will show. In every branch `documents/original.pdf` is untouched, which
/// is what makes `Discard` a safe thing to offer.
@MainActor
public enum RecoveryPrompt {

    /// The answer a test injects, so **no app-tier test can put this alert on screen**. `nil`
    /// in the shipping application, always.
    ///
    /// Modals must be injectable and tests never present them. A test whose process dies with a
    /// package open leaves the crash marker armed, so a reopen a few lines later would run
    /// `NSAlert.runModal()` with nobody there to answer it. The fixture is in the right place;
    /// the modal is the leak.
    ///
    /// A test sets this, asserts the branch it chose, and puts it back. A gate
    /// (`SearchAndOCRWiringTests.recoveryPromptOverrideIsTestOnly`) fails if any line under
    /// `Apps/ZenitPDF/Sources` ever assigns it, which is what keeps it a seam rather than a
    /// second code path.
    public static var decisionOverride: RecoveryDecision?

    /// Asks the user what to do about a package that did not close cleanly.
    public static func ask(assessment: RecoveryAssessment, packageName: String) async -> RecoveryDecision {
        if let decisionOverride { return decisionOverride }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            format: NSLocalizedString(
                "“%@” was not closed properly.",
                comment: "Recovery alert title"
            ),
            packageName
        )
        alert.informativeText = informativeText(for: assessment)
        alert.addButton(withTitle: NSLocalizedString("Recover", comment: "Recovery alert button"))
        alert.addButton(withTitle: NSLocalizedString("Open Read-Only", comment: "Recovery alert button"))
        let discard = alert.addButton(withTitle: NSLocalizedString("Discard", comment: "Recovery alert button"))
        // Discard throws the session's work away: marked as the destructive choice (IM-178).
        discard.hasDestructiveAction = true

        // Recover is what a process with no user gets: it is the only branch that neither
        // throws work away nor pretends the session was clean, and `documents/original.pdf`
        // is untouched in all three.
        switch ZenitModalPresenter.runAlert(
            alert,
            identifier: Self.modalIdentifier,
            answerWithoutAUser: .button(0)
        ) {
        case .button(0): return .recover
        case .button(1): return .openReadOnly
        case .button(2): return .discard
        default: return .recover
        }
    }

    /// The body, built from the assessment rather than the same words for every crash: when
    /// the last good save was, whether a save was cut off, and what each button keeps (IM-178).
    static func informativeText(for assessment: RecoveryAssessment, now: Date = Date()) -> String {
        var lines: [String] = []
        let saved = assessment.lastGoodManifest.flatMap { parseManifestDate($0.modifiedAt) }
        if let saved {
            let relative = RelativeDateTimeFormatter()
            relative.unitsStyle = .full
            lines.append(String(
                format: NSLocalizedString("Last saved %@.", comment: "Recovery alert: when the last good save was; a relative time"),
                relative.localizedString(for: saved, relativeTo: now)
            ))
        }
        if assessment.interruptedSave != nil {
            lines.append(NSLocalizedString(
                "A save was in progress when the app stopped.",
                comment: "Recovery alert: a save was interrupted"
            ))
        }
        lines.append(NSLocalizedString(
            "Recover keeps the edits made after that save.",
            comment: "Recovery alert: what Recover keeps"
        ))
        if let saved {
            lines.append(String(
                format: NSLocalizedString(
                    "Discard returns to the version saved %@.",
                    comment: "Recovery alert: what Discard returns to; the date and time"
                ),
                DateFormatter.localizedString(from: saved, dateStyle: .medium, timeStyle: .short)
            ))
        } else {
            lines.append(NSLocalizedString(
                "Discard returns to the last saved version.",
                comment: "Recovery alert: what Discard returns to, no date known"
            ))
        }
        lines.append(NSLocalizedString(
            "The original drawing inside the project has not been altered, whichever you choose.",
            comment: "Recovery alert: the original PDF is untouched"
        ))
        return lines.joined(separator: " ")
    }

    /// The manifest's `modifiedAt`, which is ISO 8601 with or without fractional seconds.
    static func parseManifestDate(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    /// The stable name of this dialogue, for `ZenitModalPresenter.didRequest(_:)`.
    public static let modalIdentifier = "recovery.notClosedProperly"
}
