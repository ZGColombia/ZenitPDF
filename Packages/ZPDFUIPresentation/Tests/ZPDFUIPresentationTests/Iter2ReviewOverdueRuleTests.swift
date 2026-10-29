import Foundation
import Testing
@testable import ZPDFUIPresentation

/// Quality-loop iteration 2, area "ui-presentation-measure", S-096: one overdue rule.
///
/// Before, `ReviewAssignment.isOverdue` (called only by tests) and `ReviewListFilter.matches`
/// (the Review List's Overdue filter) each wrote the calendar-day comparison, so the two could
/// drift. Both now read `ReviewAssignment.isOverdue(due:today:calendar:)`.
@Suite("Iteration 2 ui-presentation-measure (review overdue rule)")
struct Iter2ReviewOverdueRuleTests {

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    static func day(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.date(from: text)!
    }

    static func row(due: Date?) -> ReviewListRow {
        ReviewListRow(
            id: UUID(), pageLabel: "A-101", pageIndex: 0, kind: .text, kindName: "Text", subject: "S",
            note: "", author: "a", status: .open, replyCount: 0,
            lastActivity: day("2026-09-01T00:00:00Z"), searchText: "S", due: due
        )
    }

    @Test("Due today is not overdue; any earlier calendar day is; no due date never is")
    func theRule() {
        let today = Self.day("2026-09-27T15:00:00Z")
        #expect(!ReviewAssignment.isOverdue(due: Self.day("2026-09-27T01:00:00Z"), today: today, calendar: Self.calendar))
        #expect(ReviewAssignment.isOverdue(due: Self.day("2026-09-26T23:59:00Z"), today: today, calendar: Self.calendar))
        #expect(!ReviewAssignment.isOverdue(due: Self.day("2026-09-28T00:00:00Z"), today: today, calendar: Self.calendar))
        #expect(!ReviewAssignment.isOverdue(due: nil, today: today, calendar: Self.calendar))
        let assignment = ReviewAssignment(
            assignee: "b", due: Self.day("2026-09-26T12:00:00Z"), assignedBy: "a", assignedAt: Self.day("2026-09-20T00:00:00Z")
        )
        #expect(assignment.isOverdue(today: today, calendar: Self.calendar))
    }

    @Test("The Review List's Overdue filter agrees with the assignment's rule, row for row")
    func filterAgreesWithTheRule() {
        // Noon, so the calendar-day answer is the same in every time zone within ±11 h.
        let today = Self.day("2026-09-27T12:00:00Z")
        var filter = ReviewListFilter()
        filter.onlyOverdue = true
        filter.today = today
        let dues: [Date?] = [nil, Self.day("2026-09-20T12:00:00Z"), Self.day("2026-09-27T12:00:00Z"), Self.day("2026-10-01T12:00:00Z")]
        for due in dues {
            let expected = ReviewAssignment.isOverdue(due: due, today: today)
            #expect(filter.matches(Self.row(due: due)) == expected, "\(String(describing: due))")
        }
        #expect(filter.matches(Self.row(due: Self.day("2026-09-20T12:00:00Z"))))
        #expect(!filter.matches(Self.row(due: Self.day("2026-09-27T12:00:00Z"))))
    }
}
