import AppKit
import UniformTypeIdentifiers
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation

/// File ▸ Import Review Annotations… (NL-COLLAB-08): a consultant's marked-up copy of the drawing
/// becomes Zenit markups, replies and status changes — shown first, applied only on Import, and
/// as one undoable step.
///
/// Every dialogue goes through ``ZenitModalPresenter``. A process with no user gets Cancel on the
/// preview, so no test can import behind anybody's back or put a sheet on the screen.
@MainActor
enum ReviewAnnotationImportFlow {

    static let panelIdentifier = "review.importAnnotations.panel"
    static let previewIdentifier = "review.importAnnotations.preview"
    static let refusalIdentifier = "review.importAnnotations.refused"

    /// Asks for the file, then runs ``importFile(_:into:)``.
    static func run(document: ZenitPDFProjectDocument, window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = NSLocalizedString(
            "Choose a marked-up copy of this drawing. Its comments become markups you can review.",
            comment: "Open panel message for importing a reviewer's PDF annotations"
        )
        ZenitModalPresenter.runOpenPanel(panel, identifier: panelIdentifier, sheetedOn: window) { answer in
            guard case let .urls(urls) = answer, let url = urls.first else { return }
            Task { @MainActor in _ = await importFile(url, into: document) }
        }
    }

    /// What happened, for the tests and the status note.
    enum Outcome: Equatable {
        case imported(markups: Int, replies: Int, statusChanges: Int)
        case cancelled
        case nothingToImport
        case refused(String)
    }

    /// Reads, previews and — on Import — applies one file.
    @discardableResult
    static func importFile(_ url: URL, into document: ZenitPDFProjectDocument) async -> Outcome {
        guard let core = document.core else { return .refused("no document") }
        let reading: ReviewAnnotationReader.Reading
        do {
            reading = try ReviewAnnotationReader.read(url: url)
        } catch {
            let reason = refusalReason(error)
            refuse(url, reason: reason)
            return .refused(reason)
        }
        // S-030: the drawing's own PDF page count, not the set's sheet count.
        if let mismatch = pageMismatch(reading: reading, pageCount: await core.reviewDrawingPageCount()) {
            refuse(url, reason: mismatch)
            return .refused(mismatch)
        }
        let plan = await core.planReviewImport(reading)
        guard !plan.isEmpty else {
            core.document.post(nothingNewNote(fileName: url.lastPathComponent, summary: plan.summary))
            return .nothingToImport
        }
        guard preview(plan, fileName: url.lastPathComponent) else { return .cancelled }
        do {
            try await core.acceptReviewImport(plan)
        } catch {
            refuse(url, reason: error.localizedDescription)
            return .refused(error.localizedDescription)
        }
        core.document.post(importedNote(fileName: url.lastPathComponent, summary: plan.summary))
        return .imported(markups: plan.newMarkups.count, replies: plan.replies.count, statusChanges: plan.statusChanges.count)
    }

    static let noteID = UUID(uuidString: "7E4C2B18-0D3A-4F59-9A61-5C2E8B7D1F03")!

    /// The note when a review file brought nothing new. One wording for every review import —
    /// annotations, XFDF and the review file (T-015): the other two used to end in silence.
    static func nothingNewNote(fileName: String, summary: String, id: UUID = noteID) -> AppWarning {
        note(
            title: String(
                format: NSLocalizedString(
                    "Nothing new in “%@”",
                    comment: "Review import note title when nothing is imported; the file name"
                ),
                fileName
            ),
            message: summary,
            id: id
        )
    }

    /// The note after a review import, for every review import (T-015).
    static func importedNote(fileName: String, summary: String, id: UUID = noteID) -> AppWarning {
        note(
            title: String(
                format: NSLocalizedString(
                    "Imported the review from “%@”",
                    comment: "Review import result note title; the file name"
                ),
                fileName
            ),
            message: summary,
            id: id
        )
    }

    private static func note(title: String, message: String, id: UUID) -> AppWarning {
        AppWarning(
            id: id,
            severity: .info,
            title: title,
            message: message,
            source: NSLocalizedString("Review", comment: "Status note source for review imports"),
            isDismissible: true,
            timestamp: Date()
        )
    }

    /// The preview: counts, per author, and what is left out. Answers whether to import.
    static func preview(_ plan: AnnotationImportPlan, fileName: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(
            format: NSLocalizedString("Import review from “%@”?", comment: "Review import preview title; the file name"),
            fileName
        )
        alert.informativeText = previewText(plan)
        alert.addButton(withTitle: NSLocalizedString("Import", comment: "Review import preview: confirm button"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button"))
        return ZenitModalPresenter.runAlert(alert, identifier: previewIdentifier, answerWithoutAUser: .button(1)) == .button(0)
    }

    static func previewText(_ plan: AnnotationImportPlan) -> String {
        var lines = [plan.summary]
        let authors = plan.countsByAuthor
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { name, count in
                String(
                    format: NSLocalizedString("%1$@: %2$lld", comment: "Review import preview: an author and how many items are theirs"),
                    name.isEmpty ? NSLocalizedString("Unnamed", comment: "Review import preview: items with no author") : name,
                    count
                )
            }
        if !authors.isEmpty {
            lines.append(String(
                format: NSLocalizedString("By author: %@.", comment: "Review import preview: counts per author"),
                authors.joined(separator: ", ")
            ))
        }
        if !plan.skipped.isEmpty {
            lines.append(String(
                format: NSLocalizedString("Not imported: %@.", comment: "Review import preview: what is left out and why"),
                plan.skipped.prefix(5).joined(separator: "; ")
            ))
        }
        lines.append(NSLocalizedString(
            "Imported shapes are markups, never quantities. One Undo takes the import back.",
            comment: "Review import preview: what the import does and does not do"
        ))
        return lines.joined(separator: "\n\n")
    }

    /// A file with another page count, or pages of another size, is another drawing.
    static func pageMismatch(reading: ReviewAnnotationReader.Reading, pageCount: Int) -> String? {
        guard reading.pageCount == pageCount else {
            return String(
                format: NSLocalizedString(
                    "It has %1$lld pages and this drawing has %2$lld, so it is not a copy of this drawing.",
                    comment: "Review import refusal: page counts differ"
                ),
                reading.pageCount, pageCount
            )
        }
        return nil
    }

    private static func refusalReason(_ error: any Error) -> String {
        switch error as? ReviewAnnotationReader.ReadError {
        case .encrypted?:
            return NSLocalizedString("The file is password-protected.", comment: "Review import refusal: encrypted")
        case .tooLarge?:
            return NSLocalizedString("The file is too large to be a review file.", comment: "Review import refusal: too large")
        default:
            return NSLocalizedString("The file could not be read as a PDF.", comment: "Review import refusal: unreadable")
        }
    }

    private static func refuse(_ url: URL, reason: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            format: NSLocalizedString("“%@” was not imported", comment: "Review import refusal title; the file name"),
            url.lastPathComponent
        )
        alert.informativeText = reason
        ZenitModalPresenter.runAlert(alert, identifier: refusalIdentifier, answerWithoutAUser: .button(0))
    }
}
