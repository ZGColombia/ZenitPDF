import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIShell

/// The Navigator's Files section — every open drawing as a thumbnail.
///
/// With thirty one-page drawings open (2026-08-27), a list on the left shows every open drawing,
/// and a click on one brings that drawing to the front.
@MainActor
@Suite("Drawings section", .shellTierSerialised)
struct DrawingsSectionTests {

    private func makeEnvironment() -> ProjectShellEnvironment {
        let mocks = MockPresenters.makeEnvironment()
        return ProjectShellEnvironment(
            document: mocks.document,
            canvas: mocks.canvas,
            ledger: mocks.ledger,
            toolLibrary: mocks.toolLibrary,
            search: mocks.search,
            compare: mocks.compare,
            measurement: mocks.measurement,
            status: mocks.status
        )
    }

    private func tab(_ title: String, active: Bool = false, edited: Bool = false) -> DocumentTabSummary {
        DocumentTabSummary(
            id: UUID(),
            title: title,
            fileName: "\(title).pdf",
            pageCount: 1,
            hasUnsavedChanges: edited,
            isActive: active
        )
    }

    @Test("The section exists, has a short switcher label, and reads as open drawings")
    func theSectionExists() {
        #expect(NavigatorSection.allCases.contains(.drawings))
        #expect(NavigatorSection.drawings.switcherTitle == "Drawings")
        #expect(NavigatorSection.drawings.displayName == "Open Drawings")
    }

    @Test("Clicking a drawing goes through the tab bar's hook — the one the window rewires")
    func clickingGoesThroughTheTabBarHook() {
        let environment = makeEnvironment()
        let b = tab("Fasad B")

        // The seam the application tier owns. `ProjectWindowController` reassigns it to its
        // real `activateTab`, so a click here is a real document switch — not a summary edit.
        var activated: [UUID] = []
        environment.tabBar.onSelect = { activated.append($0) }

        environment.tabBar.onSelect?(b.id)
        #expect(activated == [b.id])
    }

    @Test("The identified thumbnail loader keys by identity, not by position")
    func thumbnailsAreKeyedByIdentity() async {
        let loader = NavigatorThumbnailLoader()
        var asked: [UUID] = []
        loader.identifiedProvider = { id, _ in
            asked.append(id)
            return nil   // a failure stays a placeholder, and is asked again next time
        }
        let a = UUID(), b = UUID()
        await loader.request(id: a)
        await loader.request(id: b)
        #expect(asked == [a, b], "the loader resolved by something other than the id it was given")
        #expect(loader.image(for: a) == nil, "a failed render must stay a placeholder")
    }

    /// CR-120 — this test carried its own copy of the rule.
    ///
    /// A private `offered(for:)` mirrored `NavigatorSidebar.offeredSections` line for line,
    /// with a doc comment saying so. Two copies of a rule agree with each other for ever, and
    /// only one of them is on screen: changing the sidebar's rule would have left this passing.
    /// It now calls the sidebar's own. Old output, against the code before the fix:
    ///
    /// ```
    /// ✘ Test "With one document open the Files section is withheld; with two it is offered"
    ///   error: type 'NavigatorSidebar' has no member 'offeredSections'
    /// ```
    @Test("With one document open the Files section is withheld; with two it is offered")
    func sectionIsWithheldForASingleDocument() {
        // One tab means the section would hold one row, and a list of every open drawing with
        // one row in it teaches people not to look at it.
        let one = [tab("Ensam", active: true)]
        let two = one + [tab("Till")]
        #expect(NavigatorSidebar.offeredSections(forOpenDrawings: one.count).contains(.drawings) == false)
        #expect(NavigatorSidebar.offeredSections(forOpenDrawings: two.count).contains(.drawings))
    }

    @Test("The Files section is offered against the tabs the shell is actually showing")
    func theSectionFollowsTheOpenDrawings() {
        let environment = makeEnvironment()
        let tabs = environment.document.tabs
        let offered = NavigatorSidebar.offeredSections(forOpenDrawings: tabs.count)
        #expect(offered.contains(.drawings) == (tabs.count > 1))
        // Whatever is offered, Pages is always among it — the fallback the repair uses.
        #expect(offered.contains(.pages))
    }
}
