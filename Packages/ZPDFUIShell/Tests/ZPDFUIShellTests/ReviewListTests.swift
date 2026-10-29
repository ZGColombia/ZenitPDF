import AppKit
import SwiftUI
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIShell

/// NL-COLLAB-04: the Review List lists every markup and filters by status, author, text and replies.
@MainActor
@Suite(.shellTierSerialised)
struct ReviewListTests {

    private static func markup(_ kind: MarkupKind, status: MarkupStatus = .none, author: String = "Ada",
                               measurement: MeasurementKind? = nil, page: Int = 0, comment: String = "") -> MarkupSummary {
        MarkupSummary(
            id: UUID(), kind: kind, measurementKind: measurement, subject: kind == .measurement ? "Slab" : "",
            label: "", comment: comment, pageLabel: "A-10\(page)", pageID: UUID(), pageIndex: page,
            status: status, author: author, colorRGBA: ColorRGBA(red: 1, green: 0, blue: 0, alpha: 1),
            created: Date(timeIntervalSince1970: 100), modified: Date(timeIntervalSince1970: 100),
            boundsInPageSpace: PDFRectValue(x: 0, y: 0, width: 1, height: 1)
        )
    }

    /// The report's acceptance: 10 measurements, 5 clouds and 3 text boxes list as 18 rows, and
    /// "status = Open AND author = X" returns exactly that subset. Old output: the only list, the
    /// ledger, showed the 10 measurements and none of the 8 review markups.
    @Test("Every markup is a row; status AND author narrows to exactly the right ones")
    func listsEverythingAndFilters() {
        var markups: [MarkupSummary] = []
        for index in 0..<10 { markups.append(Self.markup(.measurement, status: index < 3 ? .open : .accepted, author: index.isMultiple(of: 2) ? "Bo" : "Ada", measurement: .area)) }
        for index in 0..<5 { markups.append(Self.markup(.cloud, status: .open, author: index < 2 ? "Bo" : "Cy", comment: "Check \(index)")) }
        for _ in 0..<3 { markups.append(Self.markup(.text, status: .none, author: "Ada")) }
        let presenter = MockReviewThreadPresenter()
        presenter.reviewMarkups = markups
        let rows = ReviewList.rows(markups: presenter.reviewMarkups, threads: presenter)
        #expect(rows.count == 18)
        let openByBo = ReviewList.visible(rows, filter: ReviewListFilter(statuses: [.open], authors: ["Bo"]), sort: .page)
        let expected = markups.filter { $0.status == .open && $0.author == "Bo" }.map(\.id)
        #expect(Set(openByBo.map(\.id)) == Set(expected))
        #expect(openByBo.count == 4, "2 measurements (0, 2) and 2 clouds")
        #expect(ReviewList.visible(rows, filter: ReviewListFilter(text: "check 3"), sort: .page).count == 1)
        #expect(ReviewList.authors(in: rows) == ["Ada", "Bo", "Cy"])
    }

    @Test("Replies count, and the with-replies filter and last-activity sort follow them")
    func repliesAndSort() {
        let quiet = Self.markup(.cloud)
        let busy = Self.markup(.cloud)
        let presenter = MockReviewThreadPresenter(author: "Bo", now: { Date(timeIntervalSince1970: 5_000) })
        presenter.reviewMarkups = [quiet, busy]
        presenter.addReply("First", to: busy.id)
        presenter.addReply("Second", to: busy.id)
        let rows = ReviewList.rows(markups: presenter.reviewMarkups, threads: presenter)
        #expect(rows.first { $0.id == busy.id }?.replyCount == 2)
        #expect(ReviewList.visible(rows, filter: ReviewListFilter(onlyWithReplies: true), sort: .page).map(\.id) == [busy.id])
        #expect(ReviewList.visible(rows, filter: ReviewListFilter(), sort: .lastActivity).first?.id == busy.id)
    }

    /// NL-COLLAB-17: "Assigned to me" and "Overdue" filters.
    @Test("Assigned-to-me and overdue filters narrow to the right rows")
    func assignmentFilters() {
        let mine = Self.markup(.cloud)
        let theirs = Self.markup(.cloud)
        let unassigned = Self.markup(.cloud)
        let presenter = MockReviewThreadPresenter(author: "Bo")
        presenter.reviewMarkups = [mine, theirs, unassigned]
        let yesterday = Date(timeIntervalSince1970: 1_790_000_000)
        let today = yesterday.addingTimeInterval(86_400)
        presenter.assign([mine.id], to: "Bo", due: yesterday)
        presenter.assign([theirs.id], to: "Cy", due: today)
        let rows = ReviewList.rows(markups: presenter.reviewMarkups, threads: presenter)
        var filter = ReviewListFilter()
        filter.assignedTo = presenter.myNames
        #expect(ReviewList.visible(rows, filter: filter, sort: .page).map(\.id) == [mine.id])
        var overdue = ReviewListFilter()
        overdue.onlyOverdue = true
        overdue.today = today
        #expect(ReviewList.visible(rows, filter: overdue, sort: .page).map(\.id) == [mine.id], "due today is not overdue")
        #expect(rows.first { $0.id == theirs.id }?.assignee == "Cy")
    }

    /// NL-COLLAB-19: a round comparison narrows the list to what changed since the round.
    @Test("A round comparison's touched set narrows the list")
    func roundFilter() {
        let changed = Self.markup(.cloud)
        let quiet = Self.markup(.cloud)
        let presenter = MockReviewThreadPresenter()
        presenter.reviewMarkups = [changed, quiet]
        presenter.closeRound(named: "Round 1")
        let round = presenter.rounds[0]
        var diff = ReviewRoundDiff()
        diff.changed = [changed.id]
        presenter.diffs[round.id] = diff
        let rows = ReviewList.rows(markups: presenter.reviewMarkups, threads: presenter)
        var filter = ReviewListFilter()
        filter.onlyIDs = presenter.changes(since: round).touched
        #expect(ReviewList.visible(rows, filter: filter, sort: .page).map(\.id) == [changed.id])
        #expect(!filter.isEmpty)
        #expect(presenter.changes(since: round).summary.hasPrefix("0 added, 0 removed, 1 changed"))
    }

    @Test("The pane renders off screen; Reveal selects and zooms to the markup")
    func rendersAndReveals() throws {
        let environment = ProjectShellEnvironment.mock()
        let presenter = MockReviewThreadPresenter()
        let target = try #require(environment.canvas.visibleMarkups.first)
        presenter.reviewMarkups = environment.canvas.visibleMarkups
        environment.review = presenter
        let pane = ReviewListPane(environment: environment)
        let view = NSHostingView(rootView: pane)
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
        view.layoutSubtreeIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        pane.reveal(target.id)
        #expect(environment.canvas.selectedMarkupIDs == [target.id])
        #expect(ReviewListPane.statusMenuTitle([]) == "All Statuses")
        #expect(ReviewListPane.statusMenuTitle([.open]) == "Open")
        #expect(ReviewListPane.authorMenuTitle(["Bo", "Cy"]) == "2 Authors")
    }
}
