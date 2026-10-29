import AppKit
import UniformTypeIdentifiers
import ZPDFPersistence
import ZPDFUIPresentation

/// File ▸ Send Project… (NL-PLAT-10): the project as one `.zip` for a colleague, made from the last
/// saved state, without this Mac's recovery files, so it opens on the other side with no
/// "was not closed properly" prompt and the same totals. No server, no account.
@MainActor
enum SendProject {

    static let savePanelIdentifier = "project.sendArchivePanel"
    static let noteID = UUID(uuidString: "3F0A7C1E-8B2D-4E6F-9A1B-5C4D3E2F1A40")!

    static func note(_ title: String, _ message: String, severity: AppWarningSeverity) -> AppWarning {
        AppWarning(id: noteID, severity: severity, title: title, message: message,
                   source: NSLocalizedString("Send Project", comment: "Status note source for Send Project"),
                   isDismissible: true, timestamp: Date())
    }

    static func send(document: ZenitPDFProjectDocument, window: NSWindow?) {
        guard let package = document.projectPackage else {
            document.core?.document.post(note(
                NSLocalizedString("Only a project can be sent", comment: "Send Project refusal title for a Quick PDF"),
                // The menu row's own title, so the instruction cannot name a row that does not
                // exist (R-034: it named a Save As row the File menu does not have).
                String(format: NSLocalizedString("Save this drawing as a project first (File ▸ %@), then send it.", comment: "Send Project refusal detail for a Quick PDF; the Create Project menu command's title"),
                       ZenitAppCommandTable.spec(for: .createProject).title),
                severity: .warning))
            return
        }
        guard !document.isDocumentEdited else {
            document.core?.document.post(note(
                NSLocalizedString("Save the project before sending it", comment: "Send Project refusal title when there are unsaved changes"),
                NSLocalizedString("Send Project sends the last saved state, so unsaved changes would be left out. Press ⌘S, then send.", comment: "Send Project refusal detail when there are unsaved changes"),
                severity: .warning))
            return
        }
        let baseName = document.fileURL?.deletingPathExtension().lastPathComponent ?? document.displayName ?? "Project"
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = baseName + ".zip"
        panel.message = NSLocalizedString("The project as one file for a colleague: drawings, markups and ledger, without this Mac's recovery files.",
                                          comment: "Send Project save panel message")
        ZenitModalPresenter.runSavePanel(panel, identifier: savePanelIdentifier, sheetedOn: window) { answer in
            guard case let .urls(urls) = answer, let url = urls.first else { return }
            Task { @MainActor in
                _ = await write(package: package, name: baseName + ".zpdfproj", to: url, document: document)
            }
        }
    }

    /// Writes the archive and says what happened. Separated for tests.
    @discardableResult
    static func write(package: ProjectPackage, name: String, to url: URL, document: ZenitPDFProjectDocument) async -> Bool {
        do {
            let staging = FileManager.default.temporaryDirectory.appendingPathComponent("zpdf-send-\(UUID().uuidString).zip")
            defer { try? FileManager.default.removeItem(at: staging) }
            try await package.writeSendArchive(to: staging, packageName: name)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: staging)
            } else {
                try FileManager.default.moveItem(at: staging, to: url)
            }
            document.core?.document.post(note(
                String(format: NSLocalizedString("“%@” is ready to send", comment: "Send Project result title; the zip name"), url.lastPathComponent),
                NSLocalizedString("Unzip it and open the project inside. It opens as a clean copy of the last save.", comment: "Send Project result detail"),
                severity: .info))
            return true
        } catch {
            document.core?.document.post(note(
                NSLocalizedString("The project was not sent", comment: "Send Project failure title"),
                (error as? CustomStringConvertible)?.description ?? error.localizedDescription,
                severity: .warning))
            return false
        }
    }
}
