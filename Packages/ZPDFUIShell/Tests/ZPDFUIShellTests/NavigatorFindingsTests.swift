import Foundation
import Observation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIShell

/// The Navigator defects from the code review: CR-111, CR-112, CR-113, CR-119.
@MainActor
@Suite("Navigator review findings", .shellTierSerialised)
struct NavigatorFindingsTests {

    private func tab(_ title: String, active: Bool = false) -> DocumentTabSummary {
        DocumentTabSummary(
            id: UUID(),
            title: title,
            fileName: "\(title).pdf",
            pageCount: 1,
            hasUnsavedChanges: false,
            isActive: active
        )
    }

    // MARK: - CR-111: the out-of-range section repair

    /// CR-111 — a restored `.drawings` section with one drawing open left the pane blank.
    ///
    /// The repair was `.onChange(of: offeredSections)` with no `initial: true`, so it ran only
    /// when the offered set *changed*. At launch it never does: one drawing is open, Files is
    /// withheld, and the stored section already points at it. The switcher had no segment for
    /// what it was showing, the pane rendered nothing, and the arrow keys were dead.
    ///
    /// The rule is asserted here, and the `initial: true` that makes it run at launch is in
    /// `NavigatorSidebar.switcherRow`. Old output, against the code before the fix — the two
    /// helpers did not exist, and three Navigator tests carried their own copy of the offering
    /// rule instead (CR-120):
    ///
    /// ```
    /// ✘ Test "A stored section the switcher does not offer falls back to Pages"
    ///   error: type 'NavigatorSidebar' has no member 'repairedSection'
    /// ```
    @Test("A stored section the switcher does not offer falls back to Pages")
    func anUnofferedSectionFallsBackToPages() {
        let oneDrawing = NavigatorSidebar.offeredSections(forOpenDrawings: 1)
        #expect(!oneDrawing.contains(.drawings))

        #expect(NavigatorSidebar.repairedSection(for: .drawings, offered: oneDrawing) == .pages)
        // Every section the switcher does offer is left exactly where it was.
        for section in oneDrawing {
            #expect(
                NavigatorSidebar.repairedSection(for: section, offered: oneDrawing) == nil,
                "\(section) is on offer and must not be repaired away"
            )
        }
    }

    @Test("With two drawings open the Files section is offered and kept")
    func filesIsOfferedForTwoDrawings() {
        let twoDrawings = NavigatorSidebar.offeredSections(forOpenDrawings: 2)
        #expect(twoDrawings == NavigatorSection.allCases)
        #expect(NavigatorSidebar.repairedSection(for: .drawings, offered: twoDrawings) == nil)
    }

    /// The offering rule, asserted against the sidebar rather than restated (CR-120).
    ///
    /// `DrawingsSectionTests` used to carry a private `offered(for:)` that mirrored
    /// `NavigatorSidebar.offeredSections` line for line, with a doc comment saying so. Two
    /// copies of a rule agree with each other for ever; only one of them is on screen.
    @Test("The offering rule is the sidebar's own, for every drawing count")
    func theOfferingRuleIsTheSidebars() {
        #expect(NavigatorSidebar.offeredSections(forOpenDrawings: 0)
                == NavigatorSection.allCases.filter { $0 != .drawings })
        #expect(NavigatorSidebar.offeredSections(forOpenDrawings: 1)
                == NavigatorSection.allCases.filter { $0 != .drawings })
        #expect(NavigatorSidebar.offeredSections(forOpenDrawings: 2) == NavigatorSection.allCases)
        #expect(NavigatorSidebar.offeredSections(forOpenDrawings: 30) == NavigatorSection.allCases)
    }

    // MARK: - CR-112: markup-layer visibility

    /// CR-112 — unticking a markup layer hid nothing.
    ///
    /// Visibility lived in two independent `@State private var hiddenLayers` sets, one in the
    /// layer outline under the page column and one in the Layers page, and neither reached the
    /// canvas. Unticking "Walls" in one list left it ticked in the other and left every one of
    /// its markups on the drawing.
    ///
    /// Neither helper existed before this fix, so the old behaviour was measured by making
    /// `drawsMarkup(onLayer:)` return `true` unconditionally — which is exactly what "neither
    /// set reached the canvas" means. Old output:
    ///
    /// ```
    /// ✘ Test "Unticking a markup layer takes its markups off the canvas" recorded an issue at
    ///   NavigatorFindingsTests.swift:109:9: Expectation failed:
    ///   !(after.contains { $0.layer == layer } → <not evaluated>)
    /// ✘ Test "Unticking a markup layer takes its markups off the canvas" recorded an issue at
    ///   NavigatorFindingsTests.swift:110:9: Expectation failed:
    ///   (after.count → 19) < (before.count → 19)
    /// ✘ Test "The visibility set is one set on the environment, not one per list" recorded an
    ///   issue at NavigatorFindingsTests.swift:132:9: Expectation failed:
    ///   !((environment.navigatorLayers → NavigatorLayerListModel).drawsMarkup(onLayer: "Walls")
    ///   → true)
    /// ```
    @Test("Unticking a markup layer takes its markups off the canvas")
    func untickingAMarkupLayerHidesItsMarkups() throws {
        let environment = ProjectShellEnvironment.mock()
        let pageID = try #require(environment.document.currentPageID)
        let markups = environment.canvas.visibleMarkups
        let layer = try #require(
            markups.compactMap(\.layer).first { name in
                markups.contains { $0.layer != name }
            }
        )
        let layers = environment.navigatorLayers

        let before = CanvasHostPlaceholder.drawnMarkups(markups, onPage: pageID, layers: layers)
        #expect(before.contains { $0.layer == layer }, "the fixture needs markups on \(layer)")

        layers.setMarkupLayerVisible(false, layer: layer)

        let after = CanvasHostPlaceholder.drawnMarkups(markups, onPage: pageID, layers: layers)
        #expect(!after.contains { $0.layer == layer }, "the checkbox hid nothing")
        #expect(after.count < before.count)
        // Nothing else went with it.
        #expect(after.allSatisfy { $0.layer != layer })
        #expect(before.filter { $0.layer != layer }.map(\.id) == after.map(\.id))

        layers.setMarkupLayerVisible(true, layer: layer)
        #expect(CanvasHostPlaceholder.drawnMarkups(markups, onPage: pageID, layers: layers).count
                == before.count)
    }

    @Test("The visibility set is one set on the environment, not one per list")
    func oneSharedVisibilitySet() {
        let environment = ProjectShellEnvironment.mock()
        let layers = environment.navigatorLayers

        #expect(layers.isMarkupLayerVisible("Walls"))
        layers.setMarkupLayerVisible(false, layer: "Walls")

        // Whatever asks — the outline under the page column, the Layers page, the canvas —
        // asks the same object and gets the same answer.
        #expect(!environment.navigatorLayers.isMarkupLayerVisible("Walls"))
        #expect(environment.navigatorLayers.hiddenMarkupLayers == ["Walls"])
        #expect(!environment.navigatorLayers.drawsMarkup(onLayer: "Walls"))
        #expect(environment.navigatorLayers.drawsMarkup(onLayer: "Doors"))
    }

    @Test("A markup with no layer is always drawn, and a toggle that changes nothing is silent")
    func unlayeredMarkupsAndIdempotentToggles() {
        let layers = NavigatorLayerListModel()
        #expect(layers.drawsMarkup(onLayer: nil))
        #expect(layers.drawsMarkup(onLayer: ""))

        // The set's observers are what redraw (the app's by-name hook was dead and is gone,
        // X-009), so "silent" means the observation does not fire.
        func observe() -> DispatchSemaphore {
            let changed = DispatchSemaphore(value: 0)
            withObservationTracking { _ = layers.hiddenMarkupLayers } onChange: { changed.signal() }
            return changed
        }
        func fired(_ changed: DispatchSemaphore) -> Bool { changed.wait(timeout: .now()) == .success }

        var changed = observe()
        layers.setMarkupLayerVisible(true, layer: "Walls")
        #expect(!fired(changed), "it was already visible")

        layers.setMarkupLayerVisible(false, layer: "Walls")
        #expect(fired(changed))
        changed = observe()
        layers.setMarkupLayerVisible(false, layer: "Walls")
        #expect(!fired(changed), "the renderer must not be woken for a state it already has")
        #expect(layers.hiddenMarkupLayers == ["Walls"])
    }

    // MARK: - CR-113: two identical checkboxes

    /// CR-113 — VoiceOver read "Walls, Visible" for both a PDF layer and a markup layer.
    ///
    /// A drawing's `/OCProperties` layer and a markup layer can carry the same name, and both
    /// rows rendered as a bare name and a visibility state, with nothing saying which one hides
    /// the linework and which one hides the takeoff. Old output, against the code before the
    /// fix:
    ///
    /// Measured with the two labels returning the bare name, which is what both rows rendered
    /// before this fix. Old output:
    ///
    /// ```
    /// ✘ Test "A markup layer and a drawing layer of the same name read differently" recorded an
    ///   issue at NavigatorFindingsTests.swift:172:9: Expectation failed:
    ///   (markup → "Walls") != (document → "Walls")
    /// ✘ Test "A markup layer and a drawing layer of the same name read differently" recorded an
    ///   issue at NavigatorFindingsTests.swift:175:9: Expectation failed:
    ///   (markup → "Walls") == "Walls, markup layer"
    /// ✘ Test "A markup layer and a drawing layer of the same name read differently" recorded an
    ///   issue at NavigatorFindingsTests.swift:176:9: Expectation failed:
    ///   (document → "Walls") == "Walls, drawing layer"
    /// ```
    @Test("A markup layer and a drawing layer of the same name read differently")
    func layerRowsAreQualified() {
        let markup = NavigatorLayerLabel.markupLayer("Walls")
        let document = NavigatorLayerLabel.documentLayer("Walls")

        #expect(markup != document, "two identical rows are two rows nobody can tell apart")
        #expect(markup.contains("Walls"))
        #expect(document.contains("Walls"))
        #expect(markup == "Walls, markup layer")
        #expect(document == "Walls, drawing layer")
        #expect(NavigatorLayerLabel.visibility(true) == "Visible")
        #expect(NavigatorLayerLabel.visibility(false) == "Hidden")
    }

    // MARK: - CR-119: the current page versus a selected one

    /// CR-119 — the page on the canvas and a page merely in the selection sounded identical.
    ///
    /// Both carried the `.isSelected` trait and nothing else. On screen they differ by half a
    /// point of border width and by a badge that is `accessibilityHidden`, so a screen-reader
    /// user had no way to tell which sheet the canvas was showing. Old output, against the code
    /// before the fix:
    ///
    /// Measured with `stateText` returning `""` for every state — which is what the thumbnail
    /// spoke before this fix: no accessibility value at all, only the `.isSelected` trait both
    /// states shared. Old output:
    ///
    /// ```
    /// ✘ Test "The page on the canvas says so, and a merely selected page says something else"
    ///   recorded an issue at NavigatorFindingsTests.swift:200:9: Expectation failed:
    ///   (showing → "") == "Showing"
    /// ✘ Test "The page on the canvas says so, and a merely selected page says something else"
    ///   recorded an issue at NavigatorFindingsTests.swift:203:9: Expectation failed:
    ///   (showing → "") != (selected → "")
    /// ```
    @Test("The page on the canvas says so, and a merely selected page says something else")
    func theCurrentPageIsSpokenApartFromASelectedOne() {
        let showing = NavigatorPageThumbnail.stateText(isCurrent: true, isSelected: false)
        let selected = NavigatorPageThumbnail.stateText(isCurrent: false, isSelected: true)
        let neither = NavigatorPageThumbnail.stateText(isCurrent: false, isSelected: false)

        #expect(showing == "Showing")
        #expect(selected == "Selected")
        #expect(neither.isEmpty)
        #expect(showing != selected, "the two states VoiceOver could not tell apart")

        // The page on the canvas is also in the selection; it is still the one being shown.
        #expect(NavigatorPageThumbnail.stateText(isCurrent: true, isSelected: true) == "Showing")
    }
}
