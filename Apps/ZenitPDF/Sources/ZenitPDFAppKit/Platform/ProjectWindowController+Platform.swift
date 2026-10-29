import AppKit
import ZPDFAppCore
import ZPDFUIShell

/// The round-2 platform unit's window hooks.
extension ProjectWindowController {

    func wireR2Platform(document: ZenitPDFProjectDocument, canvas: PDFCanvasViewController) {
        guard let core = document.core else { return }
        // NL-COLLAB-05: this person's id, company and colour go into the project's author
        // directory when they sign a reply. Only in the assembled application: the id is made
        // once and kept in the person's preferences, which a test process must never write.
        if ZenitProcessDefaults.isAssembledApplication {
            core.review.localAuthorProvider = {
                AppReviewPresenter.LocalAuthor(id: AuthorIdentity.authorID(), company: AuthorIdentity.company(), colorRGBA: AuthorIdentity.colorHex())
            }
            core.review.recordLocalAuthor()
        }
        // NL-PLAT-20: VoiceOver reads each markup's subject, label, quantity and sheet, and a
        // press selects it. The canvas is handed in: this runs inside `install`, before the
        // document's content is registered, so `canvasController(for:)` still answered nil
        // here and the labels were never installed (R-016).
        canvas.installMarkupAccessibility()
        // The rest is once per document, not again for a second window on it (NL-UX-20).
        guard windowViews[document.documentIdentity] == nil else { return }
        // NL-PLAT-15: the office tool library, read now and whenever the application comes back.
        SubscribedToolLibrary.shared.install()
        // Read off the main thread, and not at all when the folder is unchanged (R-035).
        Task { @MainActor in await SubscribedToolLibrary.shared.refreshInBackground([document]) }
        // NL-COLLAB-12: a project connected to a shared review folder is watched again.
        Task { @MainActor in await SharedReviewAutoSync.resume(document: document) }
    }
}
