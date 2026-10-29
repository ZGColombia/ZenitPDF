import AppKit
import Foundation
import Testing
import ZPDFContracts
@testable import ZenitPDFAppKit

/// Loop iteration 2, render-extract-search: what Find Walls and Find Repeated Sheets tell the
/// person. The alerts themselves are injected away in tests (`wallReviewDecision`,
/// `repeatedSheetsDecision`), so the words they show are asserted at the functions that build
/// them — the same functions the shipping alerts call.
@MainActor
@Suite("Iter2 automation review text (S-098 / S-099)", .appTierSerialised)
struct Iter2AutomationReviewTextTests {

    private static func proposal(millimetres: Int, metres: Double, incomplete: Bool) -> ProjectWindowController.WallProposal {
        ProjectWindowController.WallProposal(
            thicknessMillimetres: millimetres, lengthMetres: metres, centrelines: [],
            openingWidthsMetres: [], thicknessMetres: Decimal(millimetres) / 1000,
            mayBeIncomplete: incomplete
        )
    }

    @Test("S-098: a truncated wall search is said in the review, on the class, and when nothing was found")
    func truncatedWallSearchIsSaid() {
        let complete = [Self.proposal(millimetres: 150, metres: 4.6, incomplete: false)]
        let partial = [Self.proposal(millimetres: 150, metres: 4.6, incomplete: true)]
        let warning = "some walls may be missing"
        // Old output: the same body for both — the search's truncation never reached the app.
        #expect(!ProjectWindowController.wallReviewMessage(for: complete).contains(warning))
        #expect(ProjectWindowController.wallReviewMessage(for: partial).contains(warning))
        #expect(ProjectWindowController.wallReviewRowTitle(complete[0]) == "Wall 150 mm: 4.60 m")
        #expect(ProjectWindowController.wallReviewRowTitle(partial[0]) == "Wall 150 mm: 4.60 m (may be incomplete)")
        #expect(ProjectWindowController.noWallsNote(searchTruncated: false).hasPrefix("No wall classes found on this sheet"))
        #expect(ProjectWindowController.noWallsNote(searchTruncated: true).hasPrefix("No complete wall class found"))
    }

    @Test("S-099: the repeated-sheets prompt states the bound the sheets matched within, not 'the same drawing'")
    func repeatedSheetsPromptStatesTheBound() {
        let group = ProjectWindowController.RepeatedSheetGroup(
            firstPageID: PageID(UUID()), pageIDs: [PageID(UUID()), PageID(UUID())], labels: ["A-101", "A-103"]
        )
        let message = ProjectWindowController.repeatedSheetsMessage(group, measurementCount: 3)
        // Hand-derived: 0.5 pt × 25.4 / 72 = 0.176 mm → "0.18".
        // Old output: "Sheets A-101 and A-103 are the same drawing. …" (the list join follows
        // the test machine's locale, so only the words after it are pinned).
        #expect(message.hasPrefix("Sheets A-101"), "\(message)")
        #expect(message.contains(" have the same linework: every line lies within 0.18 mm of a line on the other sheet."), "\(message)")
        #expect(!message.contains("same drawing"))
        #expect(message.contains("The 3 measurements on A-101 can count ×2"))
    }
}
