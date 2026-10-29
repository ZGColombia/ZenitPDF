import Foundation
import Testing
import ZPDFUIMeasurement
import ZPDFUIPresentation
@testable import ZPDFUIShell

/// Quality-loop iteration 3, area "ui-presentation-measure": the Scale Regions scale menus and
/// the Review List's overdue cue. Driven through the mock shell environment; no window.
@MainActor
@Suite("Iteration 3 ui-presentation-measure (shell)", .shellTierSerialised)
struct Iter3UIPresentationMeasureShellTests {

    // MARK: - T-056

    /// The sample project carries a Scale Region on page one ("Stair Detail 1:20") and one on
    /// page three ("Footing Detail 1:10"), each with its own scale.
    ///
    /// Old output: every page's panel offered both regions' scales — page two, which has none,
    /// offered "Stair Detail" and "Footing Detail" — and picking another page's scale was always
    /// refused by the core with "scale <UUID> belongs to another page …".
    @Test("T-056: the scale menus offer only scales calibrated on the sheet on screen")
    func scalesAreFromThisSheetOnly() throws {
        let environment = ProjectShellEnvironment.mock()
        let document = environment.document
        let pages = document.pages
        let regionScalesByPage = Dictionary(
            uniqueKeysWithValues: pages.map { page in
                (page.id, Set(document.scaleRegions(onPage: page.id).map(\.scale.id)))
            }
        )
        let allRegionScales = Set(document.scaleRegions.map(\.scale.id))
        try #require(regionScalesByPage.values.filter { !$0.isEmpty }.count >= 2,
                     "the fixture needs regions with scales on two different pages")

        environment.perform(.firstPage)
        for index in pages.indices {
            if index > 0 { environment.perform(.nextPage) }
            let page = pages[index]
            #expect(document.currentPageID == page.id)
            environment.refreshScaleRegions()
            let offered = Set(environment.scaleRegions.availableScales.map(\.id))
            let own = regionScalesByPage[page.id] ?? []
            let pageDefault = Set([document.defaultScale?.id].compactMap { $0 })
            #expect(offered == own.union(pageDefault), "page \(page.label)")
            let foreign = allRegionScales.subtracting(own).subtracting(pageDefault)
            #expect(offered.isDisjoint(with: foreign), "page \(page.label) offers another sheet's scale")
        }
    }

    // MARK: - T-061

    /// Old output: the Assignee cell coloured an overdue date red and said nothing else — the
    /// colour was the only cue, and VoiceOver read the bare date.
    @Test("T-061: an overdue due date is said in words, by the one overdue rule")
    func overdueIsSaidInWords() throws {
        let calendar = Calendar.current
        let noon = try #require(calendar.date(bySettingHour: 12, minute: 0, second: 0, of: Date(timeIntervalSince1970: 1_790_000_000)))
        let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: noon))
        let day = yesterday.formatted(.dateTime.day().month())
        #expect(ReviewListPane.assigneeAccessibilityLabel(assignee: "Anna", due: yesterday, today: noon) == "Anna, due \(day), overdue")
        let today = noon.formatted(.dateTime.day().month())
        #expect(ReviewListPane.assigneeAccessibilityLabel(assignee: "Anna", due: noon, today: noon) == "Anna, due \(today)")
        #expect(ReviewListPane.assigneeAccessibilityLabel(assignee: "Anna", due: nil, today: noon) == "Anna")
        // The words follow the same rule as the Overdue filter, for every day around today.
        for offset in -3...3 {
            let due = try #require(calendar.date(byAdding: .day, value: offset, to: noon))
            let label = ReviewListPane.assigneeAccessibilityLabel(assignee: "Anna", due: due, today: noon)
            #expect(label.hasSuffix(", overdue") == ReviewAssignment.isOverdue(due: due, today: noon), "offset \(offset)")
        }
    }
}
