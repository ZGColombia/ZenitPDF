import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

/// One note on the Comments tab, for a multi-selection: whose note on which markup, when it was
/// written, and the text.
///
/// Who and when come from the review History (the row that last wrote the note), handed in as
/// `attribution`. They used to be the markup's author and last-modified time, which named A for
/// a note B wrote on A's markup and moved the date whenever the markup was dragged or restyled
/// (bug InspectorCommentsTab:31). A note the History never recorded — written by a build before
/// review history existed — says so rather than borrowing the markup's author.
public struct InspectorCommentCard: Identifiable, Hashable, Sendable {
    /// The markup's identity.
    public let id: UUID
    /// Who wrote the note; empty when the document never recorded it.
    public let author: String
    /// When the note was written; `nil` when the document never recorded it.
    public let written: Date?
    /// "Area Measurement · Floor Screed", so a card says which markup it belongs to.
    public let markupTitle: String
    public let text: String

    /// Who wrote a markup's note and when, or `nil` when that is not recorded.
    public typealias Attribution = (MarkupSummary) -> (author: String, date: Date?)?

    /// The cards for a selection: every selected markup whose note is not blank, the most
    /// recently written first; notes with no recorded time follow, in canvas order.
    public static func cards(
        for summary: InspectorSelectionSummary,
        attribution: Attribution? = nil
    ) -> [InspectorCommentCard] {
        summary.markups.enumerated()
            .compactMap { index, markup -> (Int, InspectorCommentCard)? in
                let text = markup.comment.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                var title = InspectorHeaderModel.typeName(for: markup)
                let subject = markup.subject.trimmingCharacters(in: .whitespacesAndNewlines)
                if !subject.isEmpty { title += " · " + subject }
                let who = attribution?(markup)
                return (index, InspectorCommentCard(
                    id: markup.id, author: who?.author ?? "", written: who?.date,
                    markupTitle: title, text: text
                ))
            }
            .sorted { lhs, rhs in
                switch (lhs.1.written, rhs.1.written) {
                case let (left?, right?) where left != right: return left > right
                case (.some, nil): return true
                case (nil, .some): return false
                default: return lhs.0 < rhs.0
                }
            }
            .map(\.1)
    }
}

/// The words a thread line is read out as, and shown as: shared by the view and the tests.
enum ReviewThreadText {

    static func unknownAuthor() -> String {
        NSLocalizedString("Author not recorded", comment: "Comments tab: a note written before review history existed")
    }

    /// "Ada set status Open → Accepted", "Ada undid a status change: Accepted → Open".
    static func statusLine(author: String, from: MarkupStatus?, to: MarkupStatus?, reverted: Bool) -> String {
        let who = author.isEmpty ? unknownAuthor() : author
        let before = (from ?? MarkupStatus.none).displayName
        let after = (to ?? MarkupStatus.none).displayName
        if reverted {
            return String(
                format: NSLocalizedString(
                    "%1$@ reverted a status change: %2$@ → %3$@",
                    comment: "Comments tab: an undone or redone status change; who, from, to"
                ),
                who, before, after
            )
        }
        return String(
            format: NSLocalizedString(
                "%1$@ set status %2$@ → %3$@",
                comment: "Comments tab: a status change; who, from, to"
            ),
            who, before, after
        )
    }

    /// "Ada assigned this to Bo, due 1 Oct 2026", "Ada cleared the assignment".
    static func assignmentLine(author: String, assignee: String, due: Date?) -> String {
        let who = author.isEmpty ? unknownAuthor() : author
        if assignee.isEmpty {
            return String(format: NSLocalizedString("%@ cleared the assignment", comment: "Comments tab: an assignment was cleared; who"), who)
        }
        if let due {
            return String(
                format: NSLocalizedString("%1$@ assigned this to %2$@, due %3$@", comment: "Comments tab: an assignment with a due date; who, to whom, the date"),
                who, assignee, DateFormatter.localizedString(from: due, dateStyle: .medium, timeStyle: .none)
            )
        }
        return String(format: NSLocalizedString("%1$@ assigned this to %2$@", comment: "Comments tab: an assignment; who, to whom"), who, assignee)
    }

    static func withdrawn() -> String {
        NSLocalizedString("Reply withdrawn", comment: "Comments tab: a reply its author withdrew")
    }

    @MainActor
    static func when(_ date: Date?) -> String {
        guard let date else {
            return NSLocalizedString("Time not recorded", comment: "Comments tab: a note with no recorded time")
        }
        let parts = InspectorMarkupFormatting.dateAndTime(date)
        return "\(parts.date)  \(parts.time)"
    }
}

extension InspectorPanel {

    /// The Comments tab: with one markup selected, its thread — note,
    /// replies and status changes in time order — a reply field, and the markup's History; with
    /// several, a card per note.
    func commentsTab(_ summary: InspectorSelectionSummary, onWriteNote: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.gutter) {
            if summary.count == 1, let markup = summary.markups.first, let review = environment.review {
                threadView(markup, review: review, summary: summary, onWriteNote: onWriteNote)
            } else {
                commentCards(summary, onWriteNote: onWriteNote)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(NSLocalizedString("Comments", comment: "Accessibility label of the Inspector's Comments tab body")))
    }

    // MARK: - One markup: the thread

    @ViewBuilder
    private func threadView(
        _ markup: MarkupSummary,
        review: any ReviewThreadPresenting,
        summary: InspectorSelectionSummary,
        onWriteNote: @escaping () -> Void
    ) -> some View {
        let thread = review.thread(for: markup)
        let colours = AuthorColors.assignments(
            for: review.reviewMarkups.map(\.author) + thread.items.map(\.author),
            aliases: review.myNames
        )
        if thread.items.isEmpty {
            emptyState(summary, onWriteNote: onWriteNote)
        } else {
            ForEach(thread.items) { item in
                threadItemView(item, review: review, canEdit: !markup.locked, colour: colours[item.author]?.color)
            }
        }
        ReviewComposer(isEnabled: !markup.locked) { body in
            review.addReply(body, to: markup.id) != nil
        }
        .id(markup.id)
        if !thread.history.isEmpty {
            historyCard(thread.history)
        }
    }

    @ViewBuilder
    private func threadItemView(_ item: ReviewThreadItem, review: any ReviewThreadPresenting, canEdit: Bool, colour: ColorRGBA?) -> some View {
        switch item.kind {
        case let .statusChange(from, to, reverted):
            HStack(alignment: .firstTextBaseline, spacing: ZPDFSpacing.s) {
                Image(systemName: (to ?? MarkupStatus.none).symbolName)
                    .foregroundStyle(ZPDFColor.color(InspectorMarkupFormatting.severity(for: to ?? .none).tint))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(ReviewThreadText.statusLine(author: item.author, from: from, to: to, reverted: reverted))
                        .zpdfText(.control, .textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !item.text.isEmpty {
                        Text(item.text).zpdfText(.caption, .textSecondary)
                    }
                    Text(ReviewThreadText.when(item.date)).zpdfText(.caption, .textSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, ZPDFSpacing.m)
            .accessibilityElement(children: .combine)
        case let .assignment(assignee, due):
            HStack(alignment: .firstTextBaseline, spacing: ZPDFSpacing.s) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .foregroundStyle(ZPDFColor.textSecondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(ReviewThreadText.assignmentLine(author: item.author, assignee: assignee, due: due))
                        .zpdfText(.control, .textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(ReviewThreadText.when(item.date)).zpdfText(.caption, .textSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, ZPDFSpacing.m)
            .accessibilityElement(children: .combine)
        case .note, .reply:
            InspectorCard {
                HStack(spacing: ZPDFSpacing.m) {
                    InspectorAvatar(author: item.author, color: colour)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.author.isEmpty ? ReviewThreadText.unknownAuthor() : item.author)
                            .zpdfText(.control.withWeight(.semibold), .textPrimary)
                            .lineLimit(1)
                        Text(ReviewThreadText.when(item.date))
                            .zpdfText(.caption, .textSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if item.kind == .reply, let replyID = item.replyID, !item.isRetracted, canEdit {
                        Button {
                            review.retractReply(replyID)
                        } label: {
                            ZPDFGlyphView(.symbol(.close), size: ZPDFSpacing.Control.iconSmall)
                        }
                        .buttonStyle(.plain)
                        .help(NSLocalizedString("Withdraw this reply. It stays in the thread, marked withdrawn.", comment: "Comments tab: withdraw-reply button help"))
                        .accessibilityLabel(Text(NSLocalizedString("Withdraw Reply", comment: "Comments tab: withdraw-reply button")))
                    }
                }
                if item.isRetracted {
                    Text(ReviewThreadText.withdrawn())
                        .zpdfText(.caption, .textSecondary)
                        .italic()
                } else {
                    Text(item.text)
                        .zpdfText(.body, .textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .padding(.leading, item.kind == .reply ? ZPDFSpacing.l : 0)
            .accessibilityElement(children: .combine)
        }
    }

    private func historyCard(_ history: [LedgerAuditEvent]) -> some View {
        InspectorCard {
            Text(NSLocalizedString("History", comment: "Comments tab: the markup's History entries"))
                .zpdfText(.sectionHeader, .textSecondary)
                .textCase(.uppercase)
            ForEach(history) { event in
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.actionDisplayName).zpdfText(.control, .textPrimary)
                    if let change = InspectorDerivationSection.changeSummary(event) {
                        Text(change)
                            .zpdfText(.monoNumeric.withSize(10), .textSecondary)
                            .lineLimit(3)
                    }
                    Text(verbatim: "\(event.actor) · \(ReviewThreadText.when(event.occurredAt))")
                        .zpdfText(.caption, .textSecondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: - Several markups: a card per note

    @ViewBuilder
    private func commentCards(_ summary: InspectorSelectionSummary, onWriteNote: @escaping () -> Void) -> some View {
        let review = environment.review
        let cards = InspectorCommentCard.cards(for: summary, attribution: review.map { presenter in
            { markup in
                guard let note = presenter.thread(for: markup).items.first(where: { $0.kind == .note }),
                      !note.author.isEmpty || note.date != nil
                else { return nil }
                return (note.author, note.date)
            }
        })
        if cards.isEmpty {
            emptyState(summary, onWriteNote: onWriteNote)
        } else {
            ForEach(cards) { card in
                InspectorCard {
                    HStack(spacing: ZPDFSpacing.m) {
                        InspectorAvatar(author: card.author)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(card.author.isEmpty ? ReviewThreadText.unknownAuthor() : card.author)
                                .zpdfText(.control.withWeight(.semibold), .textPrimary)
                                .lineLimit(1)
                            Text(ReviewThreadText.when(card.written))
                                .zpdfText(.caption, .textSecondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    if summary.isMultiple {
                        Text(card.markupTitle)
                            .zpdfText(.caption, .textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Text(card.text)
                        .zpdfText(.body, .textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func emptyState(_ summary: InspectorSelectionSummary, onWriteNote: @escaping () -> Void) -> some View {
        InspectorCard {
            VStack(spacing: ZPDFSpacing.m) {
                ZPDFGlyphView(.symbol(.callout), size: ZPDFSpacing.Control.iconLarge)
                    .foregroundStyle(ZPDFColor.textSecondary)
                    .accessibilityHidden(true)
                Text(NSLocalizedString("No comments", comment: "Inspector Comments tab empty state title"))
                    .zpdfText(.body.withWeight(.semibold), .textPrimary)
                Text(NSLocalizedString(
                    "Notes written on the selected markups appear here.",
                    comment: "Inspector Comments tab empty state message"
                ))
                .zpdfText(.caption, .textSecondary)
                .multilineTextAlignment(.center)
                Button(NSLocalizedString("Write a Note", comment: "Inspector Comments tab: opens the Markup tab's Notes field")) {
                    onWriteNote()
                }
                .controlSize(.small)
                .disabled(!canEditText(summary))
                .help(NSLocalizedString(
                    "Opens the Markup tab, where the Notes field edits the markup's comment.",
                    comment: "Inspector Comments tab write-a-note help"
                ))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, ZPDFSpacing.m)
            .accessibilityElement(children: .contain)
        }
    }
}

/// The reply field under a thread: multi-line, sent with ⌘↩ or the Reply button, and off for a
/// locked markup.
struct ReviewComposer: View {
    let isEnabled: Bool
    /// Sends the reply; answers whether it was kept, so the field clears only then.
    let onSend: (String) -> Bool

    @State private var draft = ""

    var body: some View {
        InspectorCard {
            TextField(
                NSLocalizedString("Reply…", comment: "Comments tab: reply field placeholder"),
                text: $draft,
                axis: .vertical
            )
            .lineLimit(2...6)
            .textFieldStyle(.roundedBorder)
            .disabled(!isEnabled)
            .accessibilityLabel(Text(NSLocalizedString("Reply", comment: "Comments tab: reply field accessibility label")))
            HStack {
                Spacer(minLength: 0)
                Button(NSLocalizedString("Reply", comment: "Comments tab: send-reply button")) { send() }
                    .controlSize(.small)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!isEnabled || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help(isEnabled
                        ? NSLocalizedString("Send the reply (⌘↩).", comment: "Comments tab: send-reply help")
                        : NSLocalizedString("The markup is locked. Unlock it to reply.", comment: "Comments tab: send-reply help when locked"))
            }
        }
    }

    private func send() {
        guard isEnabled, onSend(draft) else { return }
        draft = ""
    }
}
