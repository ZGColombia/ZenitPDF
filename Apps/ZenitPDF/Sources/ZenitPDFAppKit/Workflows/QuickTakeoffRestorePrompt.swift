import AppKit
import Foundation

/// What to do with a quick takeoff's container autosave when its drawing is opened again.
public enum QuickTakeoffRestoreDecision: Sendable, Equatable {
    /// Continue the unsaved takeoff from the autosave.
    case restore
    /// Throw the autosave away and open the drawing clean.
    case discard
    /// Open the drawing clean and leave the autosave where it is — the answer of a process
    /// with no user (a test, a command-line tool): nothing restored, nothing destroyed.
    case ignore
}

/// The question a quick PDF asks when the container still holds a takeoff for it.
///
/// Quick PDF Mode autosaves the takeoff every second into the application container
/// as the crash-survival copy — and until CR-153 nothing
/// ever read it back: the copy was written for a session that died and forgotten by the next
/// one, and the packages (each with a copy of the drawing) accumulated forever. This prompt
/// is the reader. Presented through the one modal door, like the recovery prompt; a test
/// sets ``decisionOverride`` instead.
@MainActor
public enum QuickTakeoffRestorePrompt {

    /// The scripted answer, for tests. `nil` presents the alert.
    public static var decisionOverride: QuickTakeoffRestoreDecision?

    public static func ask(drawingName: String, autosavedAt: Date?) -> QuickTakeoffRestoreDecision {
        if let decisionOverride { return decisionOverride }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(
            format: NSLocalizedString(
                "“%@” has unsaved takeoff work from an earlier session.",
                comment: "Restore-autosave alert title; the drawing's file name"
            ),
            drawingName
        )
        var detail = NSLocalizedString(
            "The measurements were kept when that session ended without saving. Restore continues from them; Discard opens the drawing clean. The drawing itself has not been altered either way.",
            comment: "Restore-autosave alert message"
        )
        if let autosavedAt {
            let stamp = DateFormatter.localizedString(from: autosavedAt, dateStyle: .medium, timeStyle: .short)
            detail += "\n" + String(
                format: NSLocalizedString("Last autosaved %@.", comment: "Restore-autosave alert detail; a date and time"),
                stamp
            )
        }
        alert.informativeText = detail
        alert.addButton(withTitle: NSLocalizedString("Restore", comment: "Restore-autosave alert button"))
        alert.addButton(withTitle: NSLocalizedString("Discard", comment: "Restore-autosave alert button"))
        // A process with no user neither restores nor discards: restoring would hydrate
        // a session nobody asked for and mark it edited, discarding would destroy work.
        switch ZenitModalPresenter.runAlert(alert, identifier: modalIdentifier, answerWithoutAUser: .dismissed) {
        case .button(0): return .restore
        case .button(1): return .discard
        default: return .ignore
        }
    }

    public static let modalIdentifier = "quickPDF.restoreAutosave"
}
