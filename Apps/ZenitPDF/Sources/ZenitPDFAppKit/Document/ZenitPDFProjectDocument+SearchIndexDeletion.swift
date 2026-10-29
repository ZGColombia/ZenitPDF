import AppKit
import Foundation
import ZPDFAppCore
import ZPDFUIPresentation

/// Search options ▸ Delete Search Index and Recognised Text… (V-079).
///
/// The privacy promise says the index can be deleted and rebuilt, and nothing in
/// the product deleted it: `TextIndexer.removeProjectIndexReportingTokens` was reached only by
/// tests. The index lives beside the document in the application container, and it holds every
/// word read off the project's drawings — their own text layers, and whatever text recognition
/// read off scanned sheets that may be confidential. This is the control: it asks, deletes
/// every index the project holds (the primary drawing's and every added drawing's), purges the
/// words from the files, and indexes the drawings' own text and the markups again so search
/// keeps working. Recognised text stays gone until recognition is run again.
extension ZenitPDFProjectDocument {

    static let deleteSearchIndexIdentifier = "search.deleteIndex"
    static let searchIndexDeletedNoteID = UUID(uuidString: "8DDA7D39-F5E7-4ADA-AFFA-F8FCFD833A12")!

    /// Asks before deleting. Without a person to answer, nothing is deleted.
    func confirmSearchIndexDeletion() {
        guard searchIndex != nil else { return }
        let alert = NSAlert()
        alert.messageText = NSLocalizedString(
            "Delete the search index and recognised text?",
            comment: "Delete search index confirmation title"
        )
        alert.informativeText = String(
            format: NSLocalizedString(
                "Every word read from this project's drawings is removed from this Mac: the drawings' own text and the text recognised on scanned sheets. The drawings' own text and the markups are indexed again so search keeps working. Scanned sheets are searchable again only after you choose %@.",
                comment: "Delete search index confirmation detail; the menu path of the text recognition command"
            ),
            ZenitAppCommandTable.menuPath(for: .readScannedText)
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("Delete", comment: "Delete search index confirmation: delete"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Button: cancel"))
        ZenitModalPresenter.runAlert(
            alert,
            identifier: Self.deleteSearchIndexIdentifier,
            sheetedOn: windowForSheet,
            answerWithoutAUser: .button(1)
        ) { [weak self] answer in
            guard answer.buttonIndex == 0, let self else { return }
            Task { @MainActor in await self.deleteSearchIndex() }
        }
    }

    /// Deletes every search index this project holds and the text recognised into them, then
    /// indexes the drawings' own text and the markups again, and says what it did.
    ///
    /// A recognition run in flight is stopped first and its last page waited for, and the
    /// open's own read of the text layer is let finish, so neither can write a word back after
    /// the deletion.
    ///
    /// - Returns: the recognised words removed, or `nil` when an index could not be deleted.
    @discardableResult
    func deleteSearchIndex() async -> Int? {
        guard let primary = searchIndex else { return nil }
        await stopTextRecognition()
        await settleTextIndexing()
        let members = drawingSet.map { Array($0.searchIndexes.values) } ?? []
        var recognisedWords = 0
        var failure: (any Error)?
        for index in [primary] + members {
            do {
                recognisedWords += try await index.deleteIndexAndRecognisedText().recognisedWords
            } catch {
                failure = failure ?? error
            }
        }
        // And the copies an earlier open left behind under the retired per-open key (W-019):
        // the alert promises every word read from this project's drawings, not this open's.
        if let set = drawingSet {
            let digests = Set(set.members.map(\.drawing.digest.sha256))
            let root = Self.searchIndexRoot
            _ = await Task.detached(priority: .utility) {
                Self.removeRetiredSetSearchIndexes(in: root, digests: digests)
            }.value
        }
        // Results on screen may be words that no longer exist anywhere: searched again at once,
        // and again once the drawings' own text is back.
        let presenter = searchPresenter as? AppSearchPresenter
        if let presenter, !presenter.query.isEmpty { presenter.runSearch() }
        reindexDrawingText()
        for index in members { _ = try? await index.indexDrawingText() }
        await settleTextIndexing()
        if let presenter, !presenter.query.isEmpty { presenter.runSearch() }
        postSearchIndexDeleted(recognisedWords: recognisedWords, failure: failure)
        return failure == nil ? recognisedWords : nil
    }

    private func postSearchIndexDeleted(recognisedWords: Int, failure: (any Error)?) {
        let recognise = ZenitAppCommandTable.menuPath(for: .readScannedText)
        let note: AppWarning
        if let failure {
            let reason = (failure as? CustomStringConvertible)?.description ?? failure.localizedDescription
            note = AppWarning(
                id: Self.searchIndexDeletedNoteID,
                severity: .warning,
                title: NSLocalizedString("The search index could not be deleted in full.", comment: "Delete search index failed title"),
                message: String(
                    format: NSLocalizedString(
                        "Some of it may still be on this Mac: %@. Try again after closing and reopening the project.",
                        comment: "Delete search index failed detail; the reason"
                    ),
                    reason
                ),
                source: NSLocalizedString("Search", comment: "Status note source for search"),
                isDismissible: true,
                timestamp: Date()
            )
        } else {
            note = AppWarning(
                id: Self.searchIndexDeletedNoteID,
                severity: .info,
                title: NSLocalizedString("Search index deleted.", comment: "Delete search index done title"),
                message: String(
                    format: NSLocalizedString(
                        "%1$lld recognised words and the drawings' text index were removed from this Mac. The drawings' own text and the markups were indexed again; choose %2$@ to make scanned sheets searchable again.",
                        comment: "Delete search index done detail; recognised words removed, the menu path of the text recognition command"
                    ),
                    Int64(recognisedWords),
                    recognise
                ),
                source: NSLocalizedString("Search", comment: "Status note source for search"),
                isDismissible: true,
                timestamp: Date()
            )
        }
        core?.document.post(note)
    }
}
