import AppKit
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation

/// Set Status with Note… (NL-COLLAB-03): one status for the selection and the words that say why,
/// written as a status change on every markup and the note in every markup's thread.
@MainActor
enum ReviewStatusNotePrompt {

    static let modalIdentifier = "review.statusNote"

    /// The answer a test injects instead of the typed one. `nil` in the shipping application.
    static var answerOverride: (status: ZPDFUIPresentation.MarkupStatus, note: String)?

    /// Asks for the status and the note. `nil` when the person cancels, or nobody is there.
    static func ask(count: Int) -> (status: ZPDFUIPresentation.MarkupStatus, note: String)? {
        let statuses = ZPDFUIPresentation.MarkupStatus.allCases
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 32, width: 260, height: 26), pullsDown: false)
        popup.addItems(withTitles: statuses.map(\.displayName))
        popup.setAccessibilityLabel(NSLocalizedString("Review status", comment: "Accessibility label of the inspector's status popup"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = NSLocalizedString("Why — for example “see RFI 12”", comment: "Status note field placeholder")
        field.setAccessibilityLabel(NSLocalizedString("Status note", comment: "Accessibility label of the status note field"))
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 60))
        accessory.addSubview(popup)
        accessory.addSubview(field)

        let alert = NSAlert()
        alert.messageText = count == 1
            ? NSLocalizedString("Set the status and say why", comment: "Status note prompt title, one markup")
            : String(format: NSLocalizedString("Set the status of %lld markups and say why", comment: "Status note prompt title; count"), count)
        alert.informativeText = NSLocalizedString(
            "The note goes into each markup's thread beside the status change.",
            comment: "Status note prompt body"
        )
        alert.accessoryView = accessory
        alert.addButton(withTitle: NSLocalizedString("Set Status", comment: "Status note prompt: confirm"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button"))
        let answer = ZenitModalPresenter.runAlert(alert, identifier: modalIdentifier, answerWithoutAUser: .button(1))
        if let answerOverride { return answer == .button(0) ? answerOverride : nil }
        guard answer == .button(0), popup.indexOfSelectedItem >= 0 else { return nil }
        return (statuses[popup.indexOfSelectedItem], field.stringValue)
    }

    /// Applies a status and a note to markups: the status as one step, the note as one step.
    static func apply(status: ZPDFUIPresentation.MarkupStatus, note: String, to markupIDs: Set<UUID>, core: AppCoreEnvironment) async {
        guard !markupIDs.isEmpty else { return }
        do {
            try await core.commands.perform(.batchStatusChange(
                ids: markupIDs.sorted { $0.uuidString < $1.uuidString }.map(MarkupID.init),
                status: ZPDFContracts.MarkupStatus(shown: status)
            ))
        } catch {
            ZenitPDFProjectDocument.reportRefusedEdit(error, core: core)
            return
        }
        core.review.addReplies(note, to: markupIDs)
    }
}
