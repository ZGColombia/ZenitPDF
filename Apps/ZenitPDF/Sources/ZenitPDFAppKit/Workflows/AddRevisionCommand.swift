import AppKit
import UniformTypeIdentifiers
import ZPDFUIPresentation

/// File ▸ Drawing Set ▸ Add Revision… and the Add Revision… buttons of Revision Compare and
/// Revision Overlay (L-57, L-93).
///
/// A revision could only be added by holding ⌥ while dropping a PDF from Finder on the canvas.
/// Nothing in a menu or a sheet said so or offered a file chooser, so the Set Compare Report,
/// Revision Compare and Revision Overlay were reachable and unusable: Compare opened an empty
/// sheet with two "Choose…" pop-ups. This is the chooser. It ends in the same
/// ``ZenitPDFProjectDocument/addRevision(fromDroppedFile:label:completion:)`` the ⌥ drop uses,
/// so a revision added either way is the same revision.
@MainActor
enum AddRevisionCommand {

    /// The open panel's identity in ``ZenitModalPresenter``'s record.
    static let panelIdentifier = "revision.addRevision"

    /// Asks for the revised PDF and adds it as a revision of `document`'s drawing.
    ///
    /// - Parameters:
    ///   - window: the window (or sheet) the panel hangs from.
    ///   - completion: whether a revision was added. A dismissed panel answers `false`.
    static func choose(
        document: ZenitPDFProjectDocument,
        sheetedOn window: NSWindow?,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        guard document.drawing != nil, document.comparePresenter != nil else {
            completion?(false)
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.pdf]
        panel.prompt = NSLocalizedString("Add Revision", comment: "Add Revision panel: confirm button")
        panel.message = NSLocalizedString(
            "Choose the revised PDF of this drawing. It is added as a revision for Revision Compare, Revision Overlay and the Set Compare Report; this drawing is not changed.",
            comment: "Add Revision panel message"
        )
        ZenitModalPresenter.runOpenPanel(panel, identifier: panelIdentifier, sheetedOn: window) { [weak document] answer in
            guard let document, let url = answer.firstURL else {
                completion?(false)
                return
            }
            // The bookmark is taken while the panel's grant is alive, as a drop takes its own,
            // so the revision reopens with the project next session.
            DroppedFileBookmarks.remember(url, defaults: ZenitProcessDefaults.bookmarks)
            document.addRevision(fromDroppedFile: url) { [weak document] added in
                if added {
                    document?.core?.status.setActiveToolNote(addedNote(fileName: url.lastPathComponent))
                }
                completion?(added)
            }
        }
    }

    /// "“Plan rev B.pdf” added as a revision. …" — said once the revision is in.
    static func addedNote(fileName: String) -> String {
        String(
            format: NSLocalizedString(
                "“%@” added as a revision. Revision Compare, Revision Overlay and the Set Compare Report can use it now.",
                comment: "Status note after Add Revision…; the file name"
            ),
            fileName
        )
    }
}
