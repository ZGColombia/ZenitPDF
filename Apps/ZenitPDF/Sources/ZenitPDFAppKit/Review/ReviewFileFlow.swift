import AppKit
import UniformTypeIdentifiers
import ZPDFAppCore
import ZPDFUIPresentation

/// File ▸ Export Review File… / Import Review File… (NL-COLLAB-10): the whole review of a project —
/// every markup and reply, signed — as one small `.zpdfreview` another copy of the project can
/// merge. Quantities are recomputed on import, never trusted from the file.
@MainActor
enum ReviewFileFlow {

    static let exportPanelIdentifier = "reviewFile.export.panel"
    static let importPanelIdentifier = "reviewFile.import.panel"
    static let previewIdentifier = "reviewFile.import.preview"
    static let refusalIdentifier = "reviewFile.refused"
    static let noteID = UUID(uuidString: "9D2E4F10-6A3B-4C8D-B1E7-2F5A0C9E8B61")!

    static var contentType: UTType {
        UTType(filenameExtension: ReviewExchangeFile.fileExtension) ?? .json
    }

    // MARK: - Export

    static func export(document: ZenitPDFProjectDocument, window: NSWindow?) {
        guard document.projectPackage != nil else {
            refuse(NSLocalizedString(
                "A review file belongs to a project. Save this drawing as a project first.",
                comment: "Review file refusal: a Quick PDF has no project"
            ))
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [contentType]
        panel.nameFieldStringValue = "\(document.displayName ?? "Review").\(ReviewExchangeFile.fileExtension)"
        panel.message = NSLocalizedString(
            "Every markup and reply, for another copy of this project. The drawing is not included.",
            comment: "Review file export panel message"
        )
        ZenitModalPresenter.runSavePanel(panel, identifier: exportPanelIdentifier, sheetedOn: window) { answer in
            guard let url = answer.firstURL else { return }
            Task { @MainActor in _ = await write(document: document, to: url) }
        }
    }

    /// Writes the review file. `remembers` records it for Share Last Export… (R-028); Share
    /// Review File… passes `false`, because its file is a temporary copy handed straight to the
    /// share picker, not an export the person keeps.
    @discardableResult
    static func write(document: ZenitPDFProjectDocument, to url: URL, remembers: Bool = true) async -> Bool {
        guard let package = document.projectPackage, let core = document.core else {
            // Share Review File… reached this silently on a Quick PDF (R-029).
            refuse(NSLocalizedString(
                "A review file belongs to a project. Save this drawing as a project first.",
                comment: "Review file refusal: a Quick PDF has no project"
            ))
            return false
        }
        let manifest = await package.manifest
        let file = await core.exportReviewFile(
            projectID: manifest.projectId,
            projectName: document.displayName ?? manifest.displayName,
            author: AuthorIdentity.current(),
            participantID: SharedReviewCommands.participantID
        )
        do {
            try file.encoded().write(to: url, options: .atomic)
            if remembers { ExportCompletion.remember(url, document: document) }
            return true
        } catch {
            refuse(error.localizedDescription)
            return false
        }
    }

    // MARK: - Share

    /// Where a shared review file is handed to the system's sharing picker. A test injects its own;
    /// outside the assembled application nothing is shown.
    static var sharingPresenter: (@MainActor (URL, NSWindow?) -> Void)?

    /// Share Review File…: the review as a small `.zpdfreview` through AirDrop, Mail or Messages —
    /// always the person's own action, never automatic, and the drawing never goes with it.
    static func share(document: ZenitPDFProjectDocument, window: NSWindow?) {
        Task { @MainActor in
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("zenit-share-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("\(document.displayName ?? "Review").\(ReviewExchangeFile.fileExtension)")
            guard await write(document: document, to: url, remembers: false) else { return }
            if let sharingPresenter { sharingPresenter(url, window); return }
            guard ZenitModalPresenter.canPresentModally, let view = window?.contentView else { return }
            let picker = NSSharingServicePicker(items: [url])
            picker.show(relativeTo: NSRect(x: view.bounds.midX, y: view.bounds.maxY - 1, width: 1, height: 1), of: view, preferredEdge: .minY)
        }
    }

    // MARK: - Import

    static func importFile(document: ZenitPDFProjectDocument, window: NSWindow?) {
        // Before the panel, as Export checks (S-016): an open panel that can only end in this
        // refusal wastes the person's choice.
        guard document.projectPackage != nil else {
            refuse(NSLocalizedString(
                "A review file belongs to a project. Save this drawing as a project first.",
                comment: "Review file refusal: a Quick PDF has no project"
            ))
            return
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [contentType]
        panel.allowsMultipleSelection = false
        panel.message = NSLocalizedString(
            "Choose a review file exported from another copy of this project.",
            comment: "Review file import panel message"
        )
        ZenitModalPresenter.runOpenPanel(panel, identifier: importPanelIdentifier, sheetedOn: window) { answer in
            guard case let .urls(urls) = answer, let url = urls.first else { return }
            Task { @MainActor in _ = await importFile(url, into: document) }
        }
    }

    enum Outcome: Equatable {
        case imported(added: Int, changed: Int, replies: Int)
        case cancelled
        case nothingToImport
        case refused(String)
    }

    @discardableResult
    static func importFile(_ url: URL, into document: ZenitPDFProjectDocument) async -> Outcome {
        guard let package = document.projectPackage, let core = document.core else {
            let reason = NSLocalizedString(
                "A review file belongs to a project. Save this drawing as a project first.",
                comment: "Review file refusal: a Quick PDF has no project"
            )
            refuse(reason)
            return .refused(reason)
        }
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let file = try ReviewExchangeFile.decode(data)
            let plan = try await core.planReviewFileImport(file, projectID: await package.manifest.projectId)
            // A file that brings nothing new says so (T-015), in the words every review import uses.
            guard !plan.isEmpty else {
                core.document.post(ReviewAnnotationImportFlow.nothingNewNote(fileName: url.lastPathComponent, summary: plan.summary, id: noteID))
                return .nothingToImport
            }
            guard preview(plan, fileName: url.lastPathComponent) else { return .cancelled }
            try await core.acceptReviewFileImport(plan)
            core.document.post(ReviewAnnotationImportFlow.importedNote(fileName: url.lastPathComponent, summary: plan.summary, id: noteID))
            return .imported(added: plan.changes.added.count, changed: plan.changes.changed.count, replies: plan.changes.newReplies.count)
        } catch {
            let reason = message(for: error)
            refuse(reason)
            return .refused(reason)
        }
    }

    static func preview(_ plan: ReviewExchangePlan, fileName: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(
            format: NSLocalizedString("Import review from “%@”?", comment: "Review import preview title; the file name"),
            fileName
        )
        var lines = [plan.summary]
        if !plan.authors.isEmpty {
            lines.append(String(
                format: NSLocalizedString("From %@.", comment: "Review file import preview: who wrote it"),
                plan.authors.joined(separator: ", ")
            ))
        }
        lines.append(NSLocalizedString(
            "Quantities are measured again here. Nothing of yours is deleted. One Undo takes the import back.",
            comment: "Review file import preview: what the import does and does not do"
        ))
        alert.informativeText = lines.joined(separator: "\n\n")
        alert.addButton(withTitle: NSLocalizedString("Import", comment: "Review import preview: confirm button"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button"))
        return ZenitModalPresenter.runAlert(alert, identifier: previewIdentifier, answerWithoutAUser: .button(1)) == .button(0)
    }

    static func message(for error: any Error) -> String {
        switch error as? ReviewExchangeFile.ExchangeError {
        case .otherProject(let fileProject, _)?:
            return String(
                format: NSLocalizedString(
                    "It is the review of “%@”, another project. A review file only merges into a copy of the project it came from.",
                    comment: "Review file refusal: another project; the file's project name"
                ),
                fileProject
            )
        case .newerFormat?:
            return NSLocalizedString("A newer version of Zenit PDF wrote this file. Update to import it.", comment: "Review file refusal: newer format")
        case .notAReviewFile?:
            return NSLocalizedString("This is not a Zenit review file.", comment: "Review file refusal: not a review file")
        case .tooLarge?:
            return NSLocalizedString("The file is too large to be a review file.", comment: "Review import refusal: too large")
        case nil:
            return error.localizedDescription
        }
    }

    private static func refuse(_ reason: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = NSLocalizedString("Review file", comment: "Review file refusal title")
        alert.informativeText = reason
        ZenitModalPresenter.runAlert(alert, identifier: refusalIdentifier, answerWithoutAUser: .button(0))
    }
}
