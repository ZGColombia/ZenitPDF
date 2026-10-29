import AppKit
import Foundation

/// Asks for the password of an encrypted drawing (LT-38).
///
/// PDFKit "opens" a protected drawing without its password: the page count is right, the
/// geometry is right, and every page renders blank white — which an estimator reads as an
/// empty drawing, the same silent-wrongness class as a quantity computed without a scale.
/// So the open pauses on this one question. Cancel refuses the open in words; it never
/// proceeds to a blank sheet.
///
/// Presented through ``ZenitModalPresenter`` like every other dialogue, so a process with
/// no user answers Cancel without drawing anything, and a test injects the outcome through
/// ``ZenitPDFProjectDocument/passwordPrompt`` — the password itself is a value no
/// `ZenitModalAnswer` can carry, which is why the document seam sits above this panel.
@MainActor
public enum DrawingPasswordPrompt {

    /// The stable name of this dialogue, for `ZenitModalPresenter.didRequest(_:)`.
    public static let modalIdentifier = "document.password"

    /// Runs the prompt and returns the entered password, or `nil` when the person
    /// cancelled — or when nobody was there to answer.
    public static func ask(fileName: String) -> String? {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(
            format: NSLocalizedString(
                "“%@” is protected by a password.",
                comment: "Password prompt title; the drawing's file name"
            ),
            fileName
        )
        alert.informativeText = NSLocalizedString(
            "Enter the password to open the drawing. Zenit PDF never stores it, so you will be asked again the next time this drawing is opened.",
            comment: "Password prompt detail"
        )
        alert.addButton(withTitle: NSLocalizedString("Unlock", comment: "Password prompt button"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Password prompt button"))

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = NSLocalizedString("Password", comment: "Password field placeholder")
        // Return in the field presses Unlock directly rather than only committing the
        // field editor — the double-press defect of LT-5, not repeated here.
        if let unlock = alert.buttons.first {
            field.target = unlock
            field.action = #selector(NSButton.performClick(_:))
        }
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        // A process with no user cannot know a password. The only honest answer is
        // Cancel, and the caller then refuses the open in words.
        guard ZenitModalPresenter.runAlert(
            alert,
            identifier: modalIdentifier,
            answerWithoutAUser: .dismissed
        ) == .button(0) else { return nil }

        // The field editor's live text, not the cell: `stringValue` lags while editing
        // is still open (the other half of LT-5).
        let text = field.currentEditor()?.string ?? field.stringValue
        return text.isEmpty ? nil : text
    }
}
