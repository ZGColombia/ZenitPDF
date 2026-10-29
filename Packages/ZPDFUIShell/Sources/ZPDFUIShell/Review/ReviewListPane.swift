import Combine
import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

/// The Review List (NL-COLLAB-04): every markup of the document in one filterable list — clouds,
/// callouts and text boxes as well as measurements — with status, author, replies and last
/// activity. Double-click (or Reveal) selects the markup and pages the canvas to it.
///
/// A sibling of the Quantity Ledger rather than ledger rows, which keeps quantities clean. Rows are
/// rebuilt from the review presenter on every change, so counts follow the canvas through add,
/// undo and redo.
public struct ReviewListPane: View {

    let environment: ProjectShellEnvironment
    @State private var filter = ReviewListFilter()
    @State private var sort: ReviewListSort = .page
    @State private var selection: UUID?
    @State private var assigning = false
    /// The Assign form's fields, read from the selected markup's stored assignment when the form
    /// opens (U-041).
    @State private var draft = ReviewAssignDraft(current: nil)
    @State private var comparison: (round: ReviewRound, diff: ReviewRoundDiff)?
    @State private var showsActivity = false
    @State private var notifyTick = 0
    /// Bumped when the calendar day changes, so a pane left open past midnight redraws against
    /// the new day (T-061).
    @State private var dayTick = 0

    public init(environment: ProjectShellEnvironment) {
        self.environment = environment
    }

    public var body: some View {
        let _ = dayTick
        // The day "overdue" is counted against, read once per render for the filter and the
        // cells alike; it used to be fixed when the pane opened (T-061).
        let today = Date()
        let review = environment.review
        let all = review.map { ReviewList.rows(markups: $0.reviewMarkups, threads: $0) } ?? []
        let rows = ReviewList.visible(all, filter: filter, sort: sort, now: today)
        VStack(alignment: .leading, spacing: 0) {
            filterBar(all: all, shown: rows.count)
            if let comparison {
                HStack(spacing: ZPDFSpacing.m) {
                    Image(systemName: "clock.arrow.circlepath").accessibilityHidden(true)
                    Text(String(
                        format: NSLocalizedString("Since %1$@: %2$@", comment: "Review List round comparison banner; round name, summary"),
                        comparison.round.name, comparison.diff.summary
                    ))
                    .zpdfText(.caption, .textPrimary)
                    .lineLimit(3)
                    Spacer(minLength: 0)
                    Button(NSLocalizedString("Done", comment: "Review List: close the round comparison")) {
                        self.comparison = nil
                        filter.onlyIDs = nil
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, ZPDFSpacing.m)
                .padding(.vertical, ZPDFSpacing.xs)
                .accessibilityElement(children: .combine)
            }
            Divider()
            if rows.isEmpty {
                emptyState(hasAny: !all.isEmpty)
            } else {
                list(rows, today: today)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: RunLoop.main)) { _ in
            dayTick &+= 1
        }
        // L-83: the list always has room under its bar; the panel opened 45 pt tall.
        .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)
        .background(ZPDFColor.color(.surface))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(NSLocalizedString("Review List", comment: "Accessibility label of the Review List")))
    }

    // MARK: - Filter bar

    /// The smallest the pane is laid out at: the filter bar's two rows and room for rows of
    /// the list under them. L-83: the panel opened about 520 × 45 pt, showing only the bar, its
    /// checkboxes squeezed to blank squares and the count wrapped one letter per line.
    public static let minimumSize = CGSize(width: 760, height: 320)

    /// The filter bar, in two rows of controls that keep their own width: what is shown (search,
    /// status, author, rounds, sort and the count), then the narrowing switches and the actions.
    private func filterBar(all: [ReviewListRow], shown: Int) -> some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.xs) {
            HStack(spacing: ZPDFSpacing.m) {
                TextField(NSLocalizedString("Search markups", comment: "Review List search field placeholder"), text: $filter.text)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 140, maxWidth: 220)
                    .accessibilityLabel(Text(NSLocalizedString("Search markups", comment: "Review List search field placeholder")))
                statusMenu
                authorMenu(all: all)
                roundsMenu
                Picker(NSLocalizedString("Sort", comment: "Review List sort picker"), selection: $sort) {
                    ForEach(ReviewListSort.allCases) { Text($0.title).tag($0) }
                }
                .fixedSize()
                Spacer(minLength: 0)
                Text(String(
                    format: NSLocalizedString("%1$lld of %2$lld markups", comment: "Review List count: shown of total"),
                    shown, all.count
                ))
                .zpdfText(.caption, .textSecondary)
                .lineLimit(1)
                .fixedSize()
            }
            HStack(spacing: ZPDFSpacing.m) {
                Toggle(NSLocalizedString("With replies", comment: "Review List filter: only markups that have replies"), isOn: $filter.onlyWithReplies)
                    .toggleStyle(.checkbox)
                    .fixedSize()
                Toggle(NSLocalizedString("Assigned to me", comment: "Review List filter: markups assigned to the person using the app"), isOn: Binding(
                    get: { filter.assignedTo != nil },
                    set: { on in filter.assignedTo = on ? (environment.review?.myNames ?? []) : nil }
                ))
                .toggleStyle(.checkbox)
                .fixedSize()
                Toggle(NSLocalizedString("Overdue", comment: "Review List filter: markups past their due date"), isOn: $filter.onlyOverdue)
                    .toggleStyle(.checkbox)
                    .fixedSize()
                let newCount = all.filter(\.isNew).count
                Toggle(String(
                    format: NSLocalizedString("New since I looked (%lld)", comment: "Review List filter: markups others changed since this person last looked; count"),
                    newCount
                ), isOn: $filter.onlyNew)
                .toggleStyle(.checkbox)
                .fixedSize()
                if newCount > 0 {
                    Button(NSLocalizedString("Mark All Seen", comment: "Review List: clear the new-since-last-look marks")) {
                        environment.review?.markAllSeen()
                        filter.onlyNew = false
                    }
                    .controlSize(.small)
                    .fixedSize()
                }
                Spacer(minLength: 0)
                Button(NSLocalizedString("Assign…", comment: "Review List: assign the selected markup to a person")) {
                    draft = Self.openingDraft(for: selection, review: environment.review)
                    assigning = true
                }
                .controlSize(.small)
                .fixedSize()
                .disabled(selection == nil)
                .popover(isPresented: $assigning) { assignForm(all: all) }
                let unread = environment.review?.activity.filter { !$0.isRead }.count ?? 0
                Button(unread > 0
                       ? String(format: NSLocalizedString("Activity (%lld)", comment: "Review List: the activity feed button with an unread count"), unread)
                       : NSLocalizedString("Activity", comment: "Review List: the activity feed button")) {
                    showsActivity = true
                }
                .controlSize(.small)
                .fixedSize()
                .accessibilityLabel(Text(String(
                    format: NSLocalizedString("Activity, %lld unread", comment: "Accessibility label of the activity button; unread count"), unread
                )))
                .popover(isPresented: $showsActivity) { activityFeed() }
                if let export = environment.onExportReviewReport {
                    Button(NSLocalizedString("Export Report…", comment: "Review List: export the listed markups as a review report")) {
                        export(ReviewList.visible(all, filter: filter, sort: sort).map(\.id))
                    }
                    .controlSize(.small)
                    .fixedSize()
                    .help(NSLocalizedString("Every markup in the list, with status, author and thread, as PDF or CSV.", comment: "Review List export report help"))
                }
                if !filter.isEmpty {
                    Button(NSLocalizedString("Clear Filter", comment: "Review List: reset every filter")) {
                        filter = ReviewListFilter()
                    }
                    .controlSize(.small)
                    .fixedSize()
                }
            }
        }
        .padding(.horizontal, ZPDFSpacing.m)
        .padding(.vertical, ZPDFSpacing.s)
    }

    private var statusMenu: some View {
        Menu {
            ForEach(MarkupStatus.allCases) { status in
                Toggle(isOn: Binding(
                    get: { filter.statuses.contains(status) },
                    set: { on in if on { filter.statuses.insert(status) } else { filter.statuses.remove(status) } }
                )) {
                    Label(status.displayName, systemImage: status.symbolName)
                }
            }
        } label: {
            Text(Self.statusMenuTitle(filter.statuses))
        }
        .fixedSize()
        .accessibilityLabel(Text(NSLocalizedString("Filter by status", comment: "Review List status filter")))
    }

    private func authorMenu(all: [ReviewListRow]) -> some View {
        Menu {
            // NL-COLLAB-05: every name this person has signed with, as one person.
            if let mine = environment.review?.myNames, !mine.isEmpty {
                Toggle(NSLocalizedString("Me", comment: "Review List author filter: every name the person using the app has signed with"), isOn: Binding(
                    get: { !mine.isEmpty && mine.isSubset(of: filter.authors) },
                    set: { on in if on { filter.authors.formUnion(mine) } else { filter.authors.subtract(mine) } }
                ))
                Divider()
            }
            ForEach(ReviewList.authors(in: all), id: \.self) { author in
                Toggle(author.isEmpty ? NSLocalizedString("Unnamed", comment: "Review import preview: items with no author") : author, isOn: Binding(
                    get: { filter.authors.contains(author) },
                    set: { on in if on { filter.authors.insert(author) } else { filter.authors.remove(author) } }
                ))
            }
        } label: {
            Text(Self.authorMenuTitle(filter.authors))
        }
        .fixedSize()
        .accessibilityLabel(Text(NSLocalizedString("Filter by author", comment: "Review List author filter")))
    }

    private var roundsMenu: some View {
        Menu {
            Button(NSLocalizedString("Close Round", comment: "Undo action name for closing a review round")) {
                environment.review?.closeRound(named: "")
            }
            if let rounds = environment.review?.rounds, !rounds.isEmpty {
                Divider()
                ForEach(rounds) { round in
                    Button(String(format: NSLocalizedString("Compare with %@", comment: "Review List: compare the review with a closed round; its name"), round.name)) {
                        guard let review = environment.review else { return }
                        let diff = review.changes(since: round)
                        comparison = (round, diff)
                        filter.onlyIDs = diff.touched
                    }
                }
            }
        } label: {
            Text(NSLocalizedString("Rounds", comment: "Review List: the review rounds menu"))
        }
        .fixedSize()
        .accessibilityLabel(Text(NSLocalizedString("Review rounds", comment: "Accessibility label of the Review List rounds menu")))
    }

    /// What VoiceOver reads for an Assignee cell: the name, the due day and, once it has passed,
    /// "overdue" in words (T-061).
    static func assigneeAccessibilityLabel(assignee: String, due: Date?, today: Date) -> String {
        guard let due else { return assignee }
        let day = due.formatted(.dateTime.day().month())
        let format = ReviewAssignment.isOverdue(due: due, today: today)
            ? NSLocalizedString("%1$@, due %2$@, overdue", comment: "Review List Assignee cell for VoiceOver: name, due day, past due")
            : NSLocalizedString("%1$@, due %2$@", comment: "Review List Assignee cell for VoiceOver: name, due day")
        return String(format: format, assignee, day)
    }

    static func statusMenuTitle(_ statuses: Set<MarkupStatus>) -> String {
        switch statuses.count {
        case 0: return NSLocalizedString("All Statuses", comment: "Review List status filter: nothing chosen")
        case 1: return statuses.first?.displayName ?? ""
        default:
            return String(format: NSLocalizedString("%lld Statuses", comment: "Review List status filter: several chosen"), statuses.count)
        }
    }

    static func authorMenuTitle(_ authors: Set<String>) -> String {
        switch authors.count {
        case 0: return NSLocalizedString("All Authors", comment: "Review List author filter: nothing chosen")
        case 1: return authors.first ?? ""
        default:
            return String(format: NSLocalizedString("%lld Authors", comment: "Review List author filter: several chosen"), authors.count)
        }
    }

    // MARK: - The list

    private func list(_ rows: [ReviewListRow], today: Date) -> some View {
        Table(rows, selection: $selection) {
            TableColumn(NSLocalizedString("Page", comment: "Review List column")) { row in
                HStack(spacing: 4) {
                    if row.isNew {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 6))
                            .foregroundStyle(ZPDFColor.color(.accentBlue))
                            .accessibilityLabel(Text(NSLocalizedString("New", comment: "Review List: a markup changed since this person last looked")))
                    }
                    Text(row.pageLabel).zpdfText(.control, .textPrimary)
                }
            }
            .width(min: 44, ideal: 60)
            TableColumn(NSLocalizedString("Kind", comment: "Review List column")) { row in
                Text(row.kindName).zpdfText(.control, .textPrimary)
            }
            .width(min: 60, ideal: 90)
            TableColumn(NSLocalizedString("Subject", comment: "Review List column")) { row in
                Text(row.subject).zpdfText(.control, .textPrimary)
            }
            TableColumn(NSLocalizedString("Note", comment: "Review List column: the markup's note, first line")) { row in
                Text(row.note).zpdfText(.control, .textSecondary).lineLimit(1)
            }
            TableColumn(NSLocalizedString("Author", comment: "Review List column")) { row in
                Text(row.author).zpdfText(.control, .textPrimary).lineLimit(1)
            }
            .width(min: 60, ideal: 100)
            TableColumn(NSLocalizedString("Status", comment: "Review List column")) { row in
                Label(row.status.displayName, systemImage: row.status.symbolName)
                    .zpdfText(.control, .textPrimary)
                    .accessibilityLabel(Text(row.status.displayName))
            }
            .width(min: 80, ideal: 110)
            TableColumn(NSLocalizedString("Assignee", comment: "Review List column")) { row in
                // The one overdue rule (S-096), with a glyph and words beside the red date:
                // colour was the only overdue cue in the column (T-061).
                let overdue = ReviewAssignment.isOverdue(due: row.due, today: today)
                HStack(spacing: 4) {
                    Text(row.assignee).zpdfText(.control, .textPrimary).lineLimit(1)
                    if let due = row.due {
                        if overdue {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(ZPDFColor.color(.danger))
                                .accessibilityHidden(true)
                        }
                        Text(due, format: .dateTime.day().month())
                            .zpdfText(.caption, overdue ? .danger : .textSecondary)
                    }
                }
                .help(overdue ? NSLocalizedString("Overdue", comment: "Review List: help tag of a due date that has passed") : "")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(Self.assigneeAccessibilityLabel(assignee: row.assignee, due: row.due, today: today)))
            }
            .width(min: 70, ideal: 120)
            TableColumn(NSLocalizedString("Replies", comment: "Review List column")) { row in
                Text(row.replyCount == 0 ? "" : "\(row.replyCount)").zpdfText(.monoNumeric, .textPrimary)
            }
            .width(min: 40, ideal: 56)
            TableColumn(NSLocalizedString("Last Activity", comment: "Review List column")) { row in
                Text(row.lastActivity, format: .dateTime.day().month().hour().minute())
                    .zpdfText(.monoNumeric.withSize(11), .textSecondary)
            }
            .width(min: 90, ideal: 120)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let id = ids.first {
                Button(NSLocalizedString("Reveal Markup", comment: "History row action: select and zoom to the markup")) {
                    reveal(id)
                }
            }
        } primaryAction: { ids in
            if let id = ids.first { reveal(id) }
        }
    }

    private func activityFeed() -> some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.s) {
            Text(NSLocalizedString("Activity", comment: "Review List: the activity feed button"))
                .zpdfText(.body.withWeight(.semibold), .textPrimary)
            let items = environment.review?.activity ?? []
            if items.isEmpty {
                Text(NSLocalizedString("Nothing from anyone else yet.", comment: "Activity feed: empty"))
                    .zpdfText(.caption, .textSecondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: ZPDFSpacing.s) {
                        ForEach(items.prefix(100)) { item in
                            HStack(alignment: .firstTextBaseline, spacing: ZPDFSpacing.s) {
                                Image(systemName: item.isRead ? "circle" : "circle.fill")
                                    .font(.system(size: 6))
                                    .accessibilityLabel(Text(item.isRead
                                        ? NSLocalizedString("Read", comment: "Activity item: already read")
                                        : NSLocalizedString("Unread", comment: "Activity item: not read yet")))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.sentence).zpdfText(.control, .textPrimary).lineLimit(3)
                                    Text(item.date, format: .dateTime.day().month().hour().minute())
                                        .zpdfText(.caption, .textSecondary)
                                }
                            }
                            .onTapGesture(count: 2) { reveal(item.markupID) }
                        }
                    }
                }
                .frame(maxHeight: 280)
                Button(NSLocalizedString("Mark All Read", comment: "Activity feed: mark every item read")) {
                    environment.review?.markActivityRead()
                }
                .controlSize(.small)
            }
            if let isOn = environment.reviewNotificationsEnabled, let set = environment.setReviewNotificationsEnabled {
                Divider()
                Toggle(NSLocalizedString("Notify me about replies and mentions", comment: "Activity feed: turn on local notifications"), isOn: Binding(
                    get: { _ = notifyTick; return isOn() },
                    set: { set($0); notifyTick += 1 }
                ))
                .toggleStyle(.checkbox)
            }
        }
        .padding(ZPDFSpacing.l)
        .frame(width: 320)
    }

    private func assignForm(all: [ReviewListRow]) -> some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.m) {
            Text(NSLocalizedString("Assign to", comment: "Review List assign form title"))
                .zpdfText(.body.withWeight(.semibold), .textPrimary)
            TextField(NSLocalizedString("Name", comment: "Review List assign form: the person's name"), text: $draft.assignee)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .accessibilityLabel(Text(NSLocalizedString("Assignee name", comment: "Review List assign form accessibility label")))
            let suggestions = ReviewList.authors(in: all).filter { !$0.isEmpty }
            if !suggestions.isEmpty {
                Picker(NSLocalizedString("People on this project", comment: "Review List assign form: pick a known author"), selection: $draft.assignee) {
                    ForEach(suggestions, id: \.self) { Text($0).tag($0) }
                }
                .frame(width: 220)
            }
            Toggle(NSLocalizedString("Due date", comment: "Review List assign form: set a due date"), isOn: $draft.hasDue)
            if draft.hasDue {
                DatePicker(NSLocalizedString("Due", comment: "Review List assign form: the due date"), selection: $draft.due, displayedComponents: .date)
            }
            HStack {
                Button(NSLocalizedString("Clear", comment: "Review List assign form: remove the assignment")) {
                    commitAssignment(assignee: "", due: nil)
                }
                // Nothing to clear on a markup that was never assigned: pressing it used to write
                // an empty assignment the Comments tab reads as "cleared the assignment" (U-041).
                .disabled(!draft.canClear)
                Spacer()
                Button(NSLocalizedString("Assign", comment: "Undo action name for assigning markups to a person")) {
                    commitAssignment(assignee: draft.assignee, due: draft.committedDue)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.canAssign)
            }
        }
        .padding(ZPDFSpacing.l)
    }

    /// The Assign form as it opens on `selection`: the whole stored assignment — assignee and due
    /// date — so confirming the form unchanged stores the same assignment again (U-041).
    static func openingDraft(for selection: UUID?, review: (any ReviewThreadPresenting)?) -> ReviewAssignDraft {
        ReviewAssignDraft(current: selection.flatMap { review?.assignment(for: $0) })
    }

    func commitAssignment(assignee: String, due: Date?) {
        guard let selection else { return }
        environment.review?.assign([selection], to: assignee, due: due)
        assigning = false
    }

    /// Selects the markup and pages the canvas to it — the ledger's own reveal path.
    func reveal(_ id: UUID) {
        environment.reveal(markupID: id)
    }

    private func emptyState(hasAny: Bool) -> some View {
        VStack(spacing: ZPDFSpacing.s) {
            Text(hasAny
                 ? NSLocalizedString("No markup matches the filter.", comment: "Review List empty state with a filter")
                 : NSLocalizedString("No markups yet.", comment: "Review List empty state"))
                .zpdfText(.body, .textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}


/// The Review List's Assign form, as values (U-041).
///
/// The form used to fill in only the assignee and always start with the due date off, so pressing
/// Assign — even with nothing changed — stored the assignment again with no due date and the old
/// one was gone. It now opens on the whole stored assignment.
struct ReviewAssignDraft: Equatable {
    var assignee: String
    var hasDue: Bool
    var due: Date
    /// Whether the markup has an assignment to clear.
    let canClear: Bool

    init(current: ReviewAssignment?, today: Date = Date()) {
        assignee = current?.assignee ?? ""
        hasDue = current?.due != nil
        due = current?.due ?? today
        canClear = current != nil
    }

    /// The due date Assign stores: the picked day when Due date is on, otherwise none.
    var committedDue: Date? { hasDue ? due : nil }

    /// Assign needs a name; a blank one is what Clear is for.
    var canAssign: Bool { !assignee.trimmingCharacters(in: .whitespaces).isEmpty }
}
