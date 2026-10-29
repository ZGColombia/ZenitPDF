import Foundation
import ZPDFAppCore
import ZPDFContracts
import ZPDFExport
import ZPDFPersistence
import ZPDFUIShell

/// The collaboration wiring of a document's shell to its core: the drawn text of text
/// boxes (NL-COLLAB-18) and the review threads (NL-COLLAB-01/02).
///
/// Kept out of `ZenitPDFProjectDocument.swift` so the big file carries one call.
extension ZenitPDFProjectDocument {

    /// - Parameter restoringLook: whether this is the document's first window, which restores
    ///   "changed since you last looked" once per open. A second window (NL-UX-20) shares the
    ///   review presenter and must not reset what the first window restored.
    func wireReview(shell: ProjectShellEnvironment, core: AppCoreEnvironment, restoringLook: Bool = true) {
        // The Comments tab's thread and reply field (NL-COLLAB-01/02). The presenter follows
        // the History into the project database, so replies land beside the audit trail.
        shell.review = core.review
        if restoringLook { restoreReviewLook(core: core) }
        // NL-COLLAB-15: local notifications, only when the person turned them on.
        core.review.onActivity = { items in ReviewNotifications.post(items) }
        shell.reviewNotificationsEnabled = { ReviewNotifications.isEnabled }
        shell.setReviewNotificationsEnabled = { ReviewNotifications.setEnabled($0) }
        // NL-COLLAB-16: the Review List's "Export Report…".
        shell.onExportReviewReport = { [weak self] markupIDs in
            guard let self else { return }
            ReviewReportExport.present(document: self, markupIDs: markupIDs, window: self.windowForSheet)
        }
        shell.inspectorEditing.onRequestStatusNote = { [weak core] markupIDs in
            guard let core, let answer = ReviewStatusNotePrompt.ask(count: markupIDs.count) else { return }
            Task { @MainActor in
                await ReviewStatusNotePrompt.apply(status: answer.status, note: answer.note, to: markupIDs, core: core)
            }
        }
        shell.inspectorEditing.onEditText = { [weak core] markupIDs, text in
            guard let core else { return }
            Task { @MainActor in
                await Self.applyDrawnTextEdit(markupIDs: markupIDs, text: text, core: core)
            }
        }
    }

    /// NL-COLLAB-14: what changed since this person last opened the project. The newest History
    /// sequence at the previous open, and the markups syncs and imports brought in, are kept per
    /// project in this person's preferences — local, never in the project.
    private func restoreReviewLook(core: AppCoreEnvironment) {
        guard let package = projectPackage else { return }
        Task { @MainActor [weak core] in
            let projectID = await package.manifest.projectId
            guard let core else { return }
            await core.history.settle()
            let store = ReviewPreferences.store
            let seenKey = "zenit.review.lastSeenSequence.\(projectID)"
            let unseenKey = "zenit.review.changedElsewhere.\(projectID)"
            if store.object(forKey: seenKey) != nil {
                core.review.lastSeenSequence = store.integer(forKey: seenKey)
            }
            let unseen = (store.stringArray(forKey: unseenKey) ?? []).compactMap(UUID.init(uuidString:))
            core.review.restoreChangedElsewhere(Set(unseen))
            store.set(core.history.auditRecords.map(\.sequence).max() ?? 0, forKey: seenKey)
            core.review.onChangedElsewhere = { ids in
                store.set(ids.map(\.uuidString).sorted(), forKey: unseenKey)
            }
        }
    }

    /// Every markup's thread, as the annotated export writes it (NL-COLLAB-07): each reply that has
    /// not been withdrawn, oldest first, as a hidden `/Text` reply with `/IRT` to its markup.
    func reviewRepliesForExport() -> [MarkupID: [StandardAnnotation.Reply]] {
        guard let core else { return [:] }
        var replies: [MarkupID: [StandardAnnotation.Reply]] = [:]
        for entry in core.review.entries where !entry.retracted && entry.kind == ReviewEntryRecord.Kind.reply.rawValue {
            guard let id = UUID(uuidString: entry.id), let markup = UUID(uuidString: entry.markupId) else { continue }
            replies[MarkupID(markup), default: []].append(StandardAnnotation.Reply(
                id: id,
                author: entry.authorName,
                body: entry.body,
                createdAt: PersistenceTimestamp.date(from: entry.createdAt) ?? Date(),
                modifiedAt: entry.editedAt.flatMap(PersistenceTimestamp.date(from:))
            ))
        }
        return replies
    }

    /// Rewrites the words the given text boxes draw, as one undoable step.
    static func applyDrawnTextEdit(markupIDs: Set<UUID>, text: String, core: AppCoreEnvironment) async {
        guard !markupIDs.isEmpty else { return }
        do {
            try await core.commands.performBatch(
                markupIDs.sorted { $0.uuidString < $1.uuidString }
                    .map { .editText(id: MarkupID($0), text: text) },
                actionName: NSLocalizedString(
                    "Edit Text",
                    comment: "Undo action name for rewriting the text a text box or callout draws"
                )
            )
        } catch {
            reportRefusedEdit(error, core: core)
        }
    }
}
