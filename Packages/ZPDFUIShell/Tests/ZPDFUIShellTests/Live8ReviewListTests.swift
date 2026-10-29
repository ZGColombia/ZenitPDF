import AppKit
import SwiftUI
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIShell

/// Live test 8, L-83: the Review List showed nothing for a text box or callout — no subject, no
/// note — so the list never said what a note says; and the pane had no minimum size, so its
/// panel opened as a strip with only the filter bar.
@MainActor
@Suite("Live test 8 — Review List (L-83)", .shellTierSerialised)
struct Live8ReviewListTests {

    private static func markup(_ kind: MarkupKind, subject: String = "", label: String = "", comment: String = "", drawnText: String? = nil) -> MarkupSummary {
        var summary = MarkupSummary(
            id: UUID(), kind: kind, measurementKind: nil, subject: subject,
            label: label, comment: comment, pageLabel: "A-101", pageID: UUID(), pageIndex: 0,
            status: .open, author: "A. Berg", colorRGBA: ColorRGBA(red: 1, green: 0, blue: 0, alpha: 1),
            created: Date(timeIntervalSince1970: 100), modified: Date(timeIntervalSince1970: 100),
            boundsInPageSpace: PDFRectValue(x: 0, y: 0, width: 1, height: 1)
        )
        summary.drawnText = drawnText
        return summary
    }

    @Test("L-83: a text box and a callout show what they say, and a markup with no subject is named by its label")
    func textAndCalloutRowsSayWhatTheySay() {
        let text = Self.markup(.text, drawnText: "\n  Check the fire door rating\nwith the consultant")
        let callout = Self.markup(.callout, label: "Door D-12", drawnText: "Swap to EI30")
        let noted = Self.markup(.cloud, subject: "Revision", comment: "Moved wall\nsecond line", drawnText: "ignored")
        let rows = ReviewList.rows(markups: [text, callout, noted], threads: nil)
        // Old: "" and "" — the Note column read only the markup's note, which these have none of.
        #expect(rows[0].note == "Check the fire door rating")
        #expect(rows[1].note == "Swap to EI30")
        #expect(rows[1].subject == "Door D-12")
        // A markup's own note still comes first.
        #expect(rows[2].note == "Moved wall")
        #expect(rows[2].subject == "Revision")
    }

    @Test("L-83: the pane is never laid out smaller than its bar and a few rows")
    func paneHasAMinimumSize() {
        // Old: no minimum; the panel took the bar's height, about 45 pt.
        #expect(ReviewListPane.minimumSize.width >= 700)
        #expect(ReviewListPane.minimumSize.height >= 300)
    }
}
