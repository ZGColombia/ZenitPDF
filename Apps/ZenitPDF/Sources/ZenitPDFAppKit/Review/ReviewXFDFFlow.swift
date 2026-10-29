import AppKit
import UniformTypeIdentifiers
import ZPDFAppCore

/// File ▸ Export Review as XFDF… / Import XFDF… (NL-COLLAB-09): the review as the standard small
/// XML markup file, so it travels without the drawing. Imports go through the same preview and the
/// same planner as a marked-up PDF.
@MainActor
enum ReviewXFDFFlow {

    static let exportPanelIdentifier = "xfdf.export.panel"
    static let importPanelIdentifier = "xfdf.import.panel"

    static var contentType: UTType { UTType(filenameExtension: XFDF.fileExtension) ?? .xml }

    static func export(document: ZenitPDFProjectDocument, window: NSWindow?) {
        guard let drawing = document.drawing else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [contentType]
        panel.nameFieldStringValue = drawing.url.deletingPathExtension().lastPathComponent + ".xfdf"
        panel.message = NSLocalizedString(
            "The markups, notes, statuses and replies as XFDF, for any reader that opens the same drawing.",
            comment: "XFDF export panel message"
        )
        ZenitModalPresenter.runSavePanel(panel, identifier: exportPanelIdentifier, sheetedOn: window) { answer in
            guard let url = answer.firstURL else { return }
            Task { @MainActor in _ = await write(document: document, to: url) }
        }
    }

    @discardableResult
    static func write(document: ZenitPDFProjectDocument, to url: URL) async -> Bool {
        guard let core = document.core, let drawing = document.drawing else { return false }
        let data = await core.exportXFDF(drawingName: drawing.url.lastPathComponent, drawingDigest: drawing.digest.sha256)
        do {
            try data.write(to: url, options: .atomic)
            ExportCompletion.remember(url, document: document)   // R-028
            return true
        } catch {
            ZenitErrorPresenter.present(error, in: document.windowForSheet)
            return false
        }
    }

    static func importFile(document: ZenitPDFProjectDocument, window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [contentType, .xml]
        panel.allowsMultipleSelection = false
        panel.message = NSLocalizedString(
            "Choose an XFDF made on this drawing.",
            comment: "XFDF import panel message"
        )
        ZenitModalPresenter.runOpenPanel(panel, identifier: importPanelIdentifier, sheetedOn: window) { answer in
            guard case let .urls(urls) = answer, let url = urls.first else { return }
            Task { @MainActor in _ = await importFile(url, into: document) }
        }
    }

    @discardableResult
    static func importFile(_ url: URL, into document: ZenitPDFProjectDocument) async -> ReviewAnnotationImportFlow.Outcome {
        guard let core = document.core, let drawing = document.drawing else { return .refused("no document") }
        let reading: XFDF.Reading
        do {
            reading = try XFDF.read(try Data(contentsOf: url))
            try XFDF.check(reading, drawingDigest: drawing.digest.sha256)
        } catch let XFDF.XFDFError.otherDrawing(fileDrawing) {
            let reason = String(
                format: NSLocalizedString(
                    "It was made on “%1$@”, and this drawing is “%2$@”. An XFDF only fits the drawing it was made on.",
                    comment: "XFDF import refusal: another drawing; its name, this drawing's name"
                ),
                fileDrawing, drawing.url.lastPathComponent
            )
            refuse(url, reason)
            return .refused(reason)
        } catch {
            let reason = NSLocalizedString("The file could not be read as XFDF.", comment: "XFDF import refusal: unreadable")
            refuse(url, reason)
            return .refused(reason)
        }
        let plan = await core.planXFDFImport(reading)
        // Said either way (T-015): a file that brought nothing, and a finished import, both
        // used to end with nothing visibly happening.
        guard !plan.isEmpty else {
            core.document.post(ReviewAnnotationImportFlow.nothingNewNote(fileName: url.lastPathComponent, summary: plan.summary))
            return .nothingToImport
        }
        guard ReviewAnnotationImportFlow.preview(plan, fileName: url.lastPathComponent) else { return .cancelled }
        do {
            try await core.acceptReviewImport(plan)
        } catch {
            refuse(url, error.localizedDescription)
            return .refused(error.localizedDescription)
        }
        core.document.post(ReviewAnnotationImportFlow.importedNote(fileName: url.lastPathComponent, summary: plan.summary))
        return .imported(markups: plan.newMarkups.count, replies: plan.replies.count, statusChanges: plan.statusChanges.count)
    }

    private static func refuse(_ url: URL, _ reason: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            format: NSLocalizedString("“%@” was not imported", comment: "Review import refusal title; the file name"),
            url.lastPathComponent
        )
        alert.informativeText = reason
        ZenitModalPresenter.runAlert(alert, identifier: ReviewAnnotationImportFlow.refusalIdentifier, answerWithoutAUser: .button(0))
    }
}
