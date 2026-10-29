import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIShell

/// Pins the shell to the design mockups, item by item:
/// the status bar's Snap listing, the Navigator switcher's
/// labels, and the docked ledger's default column order.
@MainActor
@Suite("Mockup convergence", .shellTierSerialised)
struct MockupConvergenceTests {

    // Thumbnail badge: S-057 (iteration 2) deleted `NavigatorPageBadge`, whose "P1"
    // text only the page card's ⋯ hint still used; the card draws the bare position (DesignD4).

    // MARK: Switcher

    @Test("The Navigator switcher segments are Pages, Layers, Zones, Search — labelled, short")
    func switcherTitles() {
        #expect(NavigatorSection.pages.switcherTitle == "Pages")
        #expect(NavigatorSection.layers.switcherTitle == "Layers")
        #expect(NavigatorSection.zones.switcherTitle == "Zones")
        #expect(NavigatorSection.search.switcherTitle == "Search")
        // The full name survives for menus and VoiceOver.
        #expect(NavigatorSection.zones.displayName == "Project Zones")
    }

    // MARK: Snap listing

    @Test("An active snap source is listed by its bare name; an off source keeps words, not colour")
    func snapSourceListing() {
        #expect(StatusBarDisplay.snapSourceText(name: "Vector", isActive: true) == "Vector")
        #expect(StatusBarDisplay.snapSourceText(name: "Markup", isActive: true) == "Markup")
        let off = StatusBarDisplay.snapSourceText(name: "Grid", isActive: false)
        #expect(off.contains("Grid"))
        #expect(off != "Grid", "an off source must be distinguished by text, not tint")
    }

    // MARK: Docked ledger default columns

    @Test("The ledger default is Page · Type · Label · Subject · Comment · Value · Unit, on screen")
    func ledgerDefaultColumns() {
        let environment = ProjectShellEnvironment.mock()
        let published = environment.ledger.visibleColumns
        let arranged = LedgerDefaultColumns.arranged(published)
        let visible = arranged.filter(\.visible)

        // The leading band is whichever of the mockup's five identity columns the
        // presenter published — in mockup order — then Value and Unit.
        let available = Set(published.map(\.id))
        let expectedLeading: [LedgerColumnID] =
            [LedgerColumnID.pageLabel, .icon, .label, .subject, .comment].filter(available.contains)
            + [LedgerDefaultColumns.valueColumnID, LedgerDefaultColumns.unitColumnID]
        #expect(Array(visible.map(\.id).prefix(expectedLeading.count)) == expectedLeading)

        // The whole visible band fits the minimum window width, so Value and Unit are on
        // screen — not scrolled off behind thirty hidden quality columns.
        let totalWidth = visible.reduce(0.0) { $0 + $1.width }
        #expect(totalWidth <= 1_000, "default columns are \(totalWidth) pt wide")

        // Value is right-aligned with monospaced digits; Unit is narrow.
        let value = visible.first { $0.id == LedgerDefaultColumns.valueColumnID }
        #expect(value?.alignment == .trailing)
        #expect(value.map { $0.kind == .number } == true)
        let unit = visible.first { $0.id == LedgerDefaultColumns.unitColumnID }
        #expect((unit?.width ?? .infinity) <= 60)
    }

    /// CR-120 — this compared a literal to the same literal.
    ///
    /// `NSLocalizedString("Panel (Quantity Ledger)", …) == "Panel (Quantity Ledger)"` is true
    /// whatever the pane draws, so the header could have been renamed to anything without a
    /// failure. It now reads the constant the pane itself renders. Old output, against the code
    /// before the fix:
    ///
    /// ```
    /// ✘ Test "The pane title is the mockup's, verbatim"
    ///   error: type 'QuantityLedgerPane' has no member 'paneTitle'
    /// ```
    @Test("The pane title is the mockup's, verbatim")
    func paneTitleMatchesTheMockup() {
        // The mockup's transcription is binding for terminology.
        #expect(QuantityLedgerPane.paneTitle == "Panel (Quantity Ledger)")
        // The Zenit name for the pane, spelled out, is part of the transcription.
        #expect(QuantityLedgerPane.paneTitle.contains("Quantity Ledger"))
    }
}
