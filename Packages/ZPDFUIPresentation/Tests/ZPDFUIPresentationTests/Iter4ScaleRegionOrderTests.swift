import Foundation
import Testing
@testable import ZPDFUIPresentation

/// Quality-loop iteration 4, area "ui-presentation-measure", U-075: the document's per-page Scale
/// Region list — what the Inspector's region popup reads — is in the one resolution order.
@MainActor
@Suite("Iteration 4 ui-presentation-measure (document Scale Region order)")
struct Iter4ScaleRegionOrderTests {

    /// The smallest conforming presenter: the protocol's own `scaleRegions(onPage:)` is what is
    /// under test, so nothing here overrides it.
    private final class RegionListPresenter: DocumentPresenting {
        let tabs: [DocumentTabSummary] = []
        let activeTabID: DocumentTabSummary.ID? = nil
        let pages: [PageDescriptor] = []
        let currentPageID: PageDescriptor.ID? = nil
        let zones: [ProjectZoneSummary] = []
        let scaleRegions: [ScaleRegionSummary]
        let defaultScale: ScaleSummary? = nil
        let warnings: [AppWarning] = []

        init(scaleRegions: [ScaleRegionSummary]) { self.scaleRegions = scaleRegions }

        func selectTab(_ id: DocumentTabSummary.ID) {}
        func closeTab(_ id: DocumentTabSummary.ID) {}
        func goToPage(id: PageDescriptor.ID) {}
        func goToPage(index: Int) {}
        func dismissWarning(id: AppWarning.ID) {}
    }

    private static let page = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    private static let otherPage = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!

    private static func region(_ name: String, priority: Int, on pageID: UUID = page) -> ScaleRegionSummary {
        ScaleRegionSummary(
            id: UUID(),
            name: name,
            pageID: pageID,
            pageLabel: "A-101",
            scale: ScaleSummary(
                id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
                name: "Plan 1:50",
                displayString: "1:50",
                isUniform: true,
                sx: 0.0176,
                sy: 0.0176,
                unit: .metre,
                version: 1,
                locked: false
            ),
            boundary: [PDFPointValue(x: 0, y: 0), PDFPointValue(x: 100, y: 0), PDFPointValue(x: 100, y: 100)],
            priority: priority,
            locked: false,
            colorRGBA: ColorRGBA.Zenit.Dark.cyan
        )
    }

    /// Old output (`scaleRegions(onPage:)` sorting by priority alone): the tie kept its input
    /// order, so the first order below came back ["High", "Zeta", "Alpha"] and the second
    /// ["High", "Alpha", "Zeta"] — the Inspector's popup order depended on storage order and
    /// was not the Scale Regions panel's.
    @Test("U-075: scaleRegions(onPage:) is highest priority first, a tie by name, whatever the input order")
    func documentListBreaksTiesByName() {
        let high = Self.region("High", priority: 5)
        let zeta = Self.region("Zeta", priority: 1)
        let alpha = Self.region("Alpha", priority: 1)
        let elsewhere = Self.region("Elsewhere", priority: 9, on: Self.otherPage)

        let reverseNameOrder = RegionListPresenter(scaleRegions: [zeta, elsewhere, alpha, high])
        #expect(reverseNameOrder.scaleRegions(onPage: Self.page).map(\.name) == ["High", "Alpha", "Zeta"])

        let nameOrder = RegionListPresenter(scaleRegions: [alpha, high, zeta, elsewhere])
        #expect(nameOrder.scaleRegions(onPage: Self.page).map(\.name) == ["High", "Alpha", "Zeta"])

        #expect(nameOrder.scaleRegions(onPage: Self.otherPage).map(\.name) == ["Elsewhere"])
    }
}
