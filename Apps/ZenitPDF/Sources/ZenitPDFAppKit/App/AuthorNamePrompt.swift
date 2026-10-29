import AppKit
import ZPDFAppCore

/// The first-run author-name question: asked once, ever.
///
/// One pre-filled text field carrying the machine's answer (`NSFullUserName()`), one
/// keystroke to keep it — Return is the default button — and skippable, which keeps the
/// default silently. The question never blocks a second launch: accepted, edited or
/// skipped all count as answered.
@MainActor
public enum AuthorNamePrompt {

    /// Applies the outcome of the prompt. Separated from the panel so the decision logic
    /// is testable without a window: `skipped` keeps the default silently; a kept or
    /// edited name goes through ``AuthorIdentity/set(_:)``, whose trimming and
    /// machine-default folding rules apply. Either way the question is marked answered.
    public static func commit(enteredName: String?, skipped: Bool) {
        if !skipped, let enteredName {
            AuthorIdentity.set(enteredName)
        }
        AuthorIdentity.markPrompted()
    }

    /// The stable name of this dialogue, for `ZenitModalPresenter.didRequest(_:)`.
    public static let modalIdentifier = "author.firstRunName"

    /// The name the prompt offers to keep: whatever signs today.
    static var prefilledName: String { AuthorIdentity.current() }

    /// Presents the question when it is still owed, and never twice.
    ///
    /// Asked as a sheet on the first project window once its drawing is on screen, not as an
    /// app-modal alert inside launch: a first launch from a double-clicked PDF waited on the
    /// answer before the drawing opened, and the alert had no window to belong to (IM-160).
    public static func presentIfNeeded(on window: NSWindow?) {
        // A process with no user never reads or writes the author preference from here: the
        // test host's defaults are the user's.
        guard ZenitModalPresenter.canPresentModally || presentsWithoutABundleForTesting else { return }
        guard AuthorIdentity.needsFirstRunPrompt, !isPresenting else { return }
        isPresenting = true
        let (alert, field) = makeAlert()
        // No user skips: the machine default is already the answer, and silently accepting a
        // name nobody typed would be a signature nobody gave.
        ZenitModalPresenter.runAlert(
            alert,
            identifier: modalIdentifier,
            sheetedOn: window,
            answerWithoutAUser: .button(1)
        ) { answer in
            isPresenting = false
            commit(enteredName: field.stringValue, skipped: answer != .button(0))
        }
    }

    /// Whether the question is up right now, so a second window cannot ask it twice.
    private(set) static var isPresenting = false

    /// Lets a test drive the prompt in a process without the app bundle. Tests only.
    static var presentsWithoutABundleForTesting = false

    static func makeAlert() -> (NSAlert, NSTextField) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = NSLocalizedString(
            "Who signs your measurements?",
            comment: "First-run author name prompt title"
        )
        alert.informativeText = String(
            format: NSLocalizedString(
                "Measurements and history entries will be signed “%@”. Use this name, or type another. You can change it any time in Settings. The name never leaves this Mac except inside project files and exports you share.",
                comment: "First-run author name prompt detail; the name in force"
            ),
            Self.prefilledName
        )

        // The name already in force, not the account name: an install that had a name set in
        // Settings but no prompt flag pre-filled the account name, and Keep then erased the
        // chosen one (BH-873).
        let field = NSTextField(string: Self.prefilledName)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        field.placeholderString = AuthorIdentity.machineDefault
        field.setAccessibilityLabel(NSLocalizedString("Author name", comment: "Accessibility label of the first-run author name field"))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        // "Keep" was wrong once the person had typed a different name (IM-160).
        alert.addButton(withTitle: NSLocalizedString("Use This Name", comment: "First-run author prompt: accept the field"))
        // "Not Now" promised a second asking that never comes: every answer, this one included,
        // marks the question answered, as "asked once" requires (R-044).
        alert.addButton(withTitle: NSLocalizedString("Skip", comment: "First-run author prompt: keep the name in force and never ask again"))
        return (alert, field)
    }
}
