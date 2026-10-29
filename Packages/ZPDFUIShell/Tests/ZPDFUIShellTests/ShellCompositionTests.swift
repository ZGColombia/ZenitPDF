import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIShell

/// Asserts the parts of the shell that are pure logic: how the Inspector decides a value is
/// shared or mixed, how a tab is labelled, and how the Navigator derives its layer list.
@MainActor
@Suite("Shell composition", .shellTierSerialised)
struct ShellCompositionTests {

    private let project = ZenitSampleProject.shared

    @Test("A single selection reports every value as shared")
    func singleSelectionHasNoMixedValues() throws {
        let markup = try #require(project.markups.first)
        let summary = InspectorSelectionSummary(markups: [markup])
        #expect(summary.isSingle)
        #expect(!summary.isMixed(\.subject))
        #expect(summary.common(\.subject) == markup.subject)
        #expect(summary.headerTitle == markup.subject)
    }

    @Test("A multi-selection separates shared values from mixed ones")
    func multiSelectionSeparatesSharedFromMixed() throws {
        let markups = Array(project.markups.prefix(3))
        try #require(markups.count == 3)
        let summary = InspectorSelectionSummary(markups: markups)
        #expect(summary.isMultiple)
        #expect(summary.count == 3)

        for keyPath in [\MarkupSummary.subject, \MarkupSummary.author] {
            let distinct = Set(markups.map { $0[keyPath: keyPath] })
            if distinct.count == 1 {
                #expect(!summary.isMixed(keyPath))
                #expect(summary.common(keyPath) == distinct.first)
            } else {
                #expect(summary.isMixed(keyPath))
                #expect(summary.common(keyPath) == nil)
                #expect(
                    summary.displayText(keyPath) { $0 }
                        == InspectorSelectionSummary.mixedPlaceholder
                )
            }
        }
    }

    @Test("An empty selection has no header subtitle and no shared fields")
    func emptySelection() {
        let summary = InspectorSelectionSummary(markups: [])
        #expect(summary.isEmpty)
        #expect(summary.headerSubtitle == nil)
        #expect(summary.sharedMeasurementFields.isEmpty)
        #expect(summary.common(\.subject) == nil)
    }

    @Test("A measurement field is only shared when every selected markup has it")
    func sharedMeasurementFields() throws {
        let withFields = project.markups.filter { !$0.measurementFields.isEmpty }
        let first = try #require(withFields.first)
        let single = InspectorSelectionSummary(markups: [first])
        #expect(single.sharedMeasurementFields == first.measurementFields.map(\.field))

        let plain = project.markups.first { $0.measurementFields.isEmpty }
        if let plain {
            let mixed = InspectorSelectionSummary(markups: [first, plain])
            #expect(mixed.sharedMeasurementFields.isEmpty)
        }
    }

    @Test("A tab speaks its title, revision, save state and page count")
    func tabAccessibilityLabel() throws {
        let summary = try #require(project.tabs.first)
        let item = DocumentTabItem(summary: summary, revisions: project.revisions)
        #expect(item.accessibilityLabel.contains(summary.title))
        // The unsaved dot is never the only signal.
        let saveWord = summary.hasUnsavedChanges ? "unsaved changes" : "saved"
        #expect(item.accessibilityLabel.contains(saveWord))
        #expect((item.unsavedStateText != nil) == summary.hasUnsavedChanges)
    }

    @Test("The tab bar follows the presenter without needing a refresh call")
    func tabBarFollowsThePresenter() throws {
        let environment = ProjectShellEnvironment.mock()
        #expect(environment.tabBar.items.count == environment.document.tabs.count)
        let active = try #require(environment.tabBar.items.first { $0.isActive })
        #expect(active.id == environment.document.activeTabID)

        // Switching documents through the presenter must move the tab bar's active mark
        // with no explicit refresh, or the bar goes stale the first time anyone opens a file.
        let other = try #require(environment.document.tabs.first { $0.id != active.id })
        environment.tabBar.select(other.id)
        #expect(environment.tabBar.items.first { $0.isActive }?.id == other.id)
    }

    @Test("A model with no source renders an empty bar rather than crashing")
    func tabBarWithoutSource() {
        let model = DocumentTabBarModel()
        #expect(model.isEmpty)
        #expect(model.items.first { $0.isActive } == nil)
    }

    @Test("The ledger pane's dock control follows the live detached state")
    func ledgerDetachMirror() {
        let state = ShellPanelState()
        #expect(!state.isLedgerDetached)
        var changes = 0
        state.onChange = { changes += 1 }
        state.isLedgerDetached = true
        #expect(changes == 1)
        state.isLedgerDetached = true
        #expect(changes == 1)
    }

    @Test("Layers are derived from the markups, counted and sorted")
    func layerDerivation() {
        let markups = ZenitSampleProject.shared.markups
        let layers = NavigatorLayersList.layers(in: markups)
        #expect(layers == layers.sorted(by: NavigatorLayersList.readingOrder))
        for layer in layers {
            let expected = markups.filter { $0.layer == layer.name }.count
            #expect(layer.markupCount == expected)
        }
        #expect(NavigatorLayersList.layers(in: []).isEmpty)
    }

    @Test("Arming a plain tool leaves the measurement palette memory intact")
    func toolSwitchKeepsPaletteMemory() {
        let toolbar = ZenitToolbarModel()
        toolbar.activateMeasurement(.volume)
        #expect(toolbar.activeTool == .measure)
        toolbar.selectTool(.pan)
        #expect(toolbar.activeTool == .pan)
        #expect(toolbar.lastUsedMeasurementKind == .volume)
        toolbar.activateLastUsedMeasurement()
        #expect(toolbar.activeTool == .measure)
        #expect(toolbar.measureButtonTitle == MeasurementKind.volume.displayName)
    }

    @Test("A cutout kind arms the Cutout tool, not the Measure tool")
    func cutoutRoutesToItsOwnTool() {
        let toolbar = ZenitToolbarModel()
        toolbar.activateMeasurement(.polygonCutout)
        #expect(toolbar.activeTool == .cutout)
        #expect(toolbar.showsMeasurementControls)
    }

    @Test("The environment routes view commands to the canvas presenter")
    func environmentRoutesViewCommands() {
        let environment = ProjectShellEnvironment.mock()
        environment.perform(.actualSize)
        #expect(environment.canvas.viewport.zoom == 1.0)
        environment.perform(.zoomIn)
        #expect(environment.canvas.viewport.zoom > 1.0)
        environment.perform(.zoomOut)
        #expect(abs(environment.canvas.viewport.zoom - 1.0) < 0.000_001)
    }

    @Test("Commands the shell cannot service reach the app target instead of being dropped")
    func environmentForwardsExternalCommands() {
        let environment = ProjectShellEnvironment.mock()
        var received: [ZPDFCommandID] = []
        environment.externalCommandHandler = { received.append($0) }
        environment.perform(.save)
        environment.perform(.export)
        #expect(received == [.save, .export])
    }

    @Test("The page fit keeps the page's aspect ratio inside the viewport")
    func canvasPageFit() throws {
        let page = try #require(ZenitSampleProject.shared.pages.first)
        let layout = CanvasHostPlaceholder.pageLayout(
            page: page,
            viewport: CGSize(width: 800, height: 600)
        )
        #expect(layout.rect.width <= 800)
        #expect(layout.rect.height <= 600)
        let pageRatio = page.visibleBox.size.width / page.visibleBox.size.height
        let laidOutRatio = Double(layout.rect.width / layout.rect.height)
        #expect(abs(pageRatio - laidOutRatio) < 0.001)

        // The page origin maps to the top-left of the laid-out sheet.
        let topLeft = layout.convert(
            PDFPointValue(x: page.visibleBox.minX, y: page.visibleBox.maxY)
        )
        #expect(abs(topLeft.x - layout.rect.minX) < 0.001)
        #expect(abs(topLeft.y - layout.rect.minY) < 0.001)
    }

    @Test("Every Navigator and Inspector section is named")
    func sectionsAreNamed() {
        for section in NavigatorSection.allCases {
            #expect(!section.displayName.isEmpty)
            #expect(!section.helpText.isEmpty)
        }
        for section in InspectorSection.allCases {
            #expect(!section.displayName.isEmpty)
        }
        #expect(InspectorSection.allCases.count == 10)
    }

    @Test("The Navigator switcher is Drawings, Pages, Layers, Zones, Search")
    func navigatorSections() {
        // The mockup fixed four sections. A fifth was added on 2026-08-27 — every
        // open drawing as a thumbnail — and it outranks the mockup, the same precedence the
        // Tool segment follows. `drawings` leads
        // because it is one level *above* the others: documents, then one document's insides.
        #expect(NavigatorSection.allCases == [.drawings, .pages, .layers, .zones, .search])
    }

    @Test("Only the Measurement section is open by default, per the mockup")
    func inspectorOpensOnMeasurementOnly() {
        #expect(InspectorSection.defaultExpanded == [.measurement])
    }

    @Test("The tab strip's new-tab button opens a document")
    func newTabButtonOpensADocument() {
        let environment = ProjectShellEnvironment.mock()
        var received: [ZPDFCommandID] = []
        environment.externalCommandHandler = { received.append($0) }
        environment.tabBar.newTab()
        #expect(received == [.openDocument])
    }

    /// S-055 (iteration 2): the tab strip's own Export and Inspector controls were deleted —
    /// never shown in the product — so the paths they tested are the toolbar's: its Export chip
    /// (the chooser, else the ledger export) and the Inspector command.
    @Test("The toolbar's Export exports and the Inspector command toggles the Inspector")
    func toolbarExportAndInspectorPaths() {
        let environment = ProjectShellEnvironment.mock()
        var received: [ZPDFCommandID] = []
        environment.externalCommandHandler = { received.append($0) }
        environment.presentExportChooser()
        #expect(received == [.export])
        // The Inspector toggle routes to the layout controller; without one it is a no-op,
        // never a crash on a half-assembled window.
        environment.perform(.toggleInspector)
        #expect(received == [.export])
    }

    @Test("Calibrate arms its own tool and hands the flow to the app tier")
    func calibrateArmsAndForwards() {
        let environment = ProjectShellEnvironment.mock()
        var received: [ZPDFCommandID] = []
        environment.externalCommandHandler = { received.append($0) }
        environment.perform(.calibrateScale)
        #expect(environment.toolbar.activeTool == .calibrate)
        #expect(received == [.calibrateScale])
        #expect(!environment.toolbar.activeTool.showsMeasurementControls)
    }

    @Test("Length and Area are first class: the palette carries only the rarer tools")
    func firstClassToolsAreNotInThePalette() {
        #expect(!ZenitToolbarModel.defaultMeasurementPalette.contains(.length))
        #expect(!ZenitToolbarModel.defaultMeasurementPalette.contains(.area))
        // The rarer tools stay reachable from the popup.
        for kind in [MeasurementKind.polylength, .perimeter, .volume, .wallArea, .slope, .radius, .arcLength] {
            #expect(ZenitToolbarModel.defaultMeasurementPalette.contains(kind))
        }
    }

    @Test("The ledger's bar-collapse mirror reports changes for persistence")
    func ledgerBarCollapseMirror() {
        let state = ShellPanelState()
        #expect(!state.isLedgerCollapsedToBar)
        var changes = 0
        state.onChange = { changes += 1 }
        state.isLedgerCollapsedToBar = true
        #expect(changes == 1)
        state.isLedgerCollapsedToBar = true
        #expect(changes == 1)
    }

    @Test("The bar-collapsed ledger is shorter than the shortest expanded ledger")
    func collapsedBarIsShorterThanTheMinimumPane() {
        #expect(Double(QuantityLedgerPane.collapsedBarHeight) < ProjectWindowLayoutState.minimumLedgerHeight)
    }

    @Test("With no document the status bar says so, and claims nothing else")
    func statusBarHonestEmptyState() {
        let empty = StatusBarSnapshot(
            pageLabel: "",
            pageIndex: 0,
            pageCount: 0,
            pageDimensionsText: "",
            activeScaleDisplay: "",
            outputUnitSymbol: "",
            zoomDisplayString: "",
            geometryIndexStatus: .unavailable
        )
        #expect(!StatusBarDisplay.hasDocument(empty))
        #expect(StatusBarDisplay.pageText(empty) == "No document")
        // Never the `1 of 0` contradiction, never a snap-availability claim.
        #expect(!StatusBarDisplay.pageText(empty).contains("of"))
        #expect(!StatusBarDisplay.pageText(empty).contains("0"))
    }

    @Test("With a document the status bar shows the real page indicator")
    func statusBarWithDocument() {
        let snapshot = StatusBarSnapshot(
            pageLabel: "A-101",
            pageIndex: 0,
            pageCount: 4,
            pageDimensionsText: "841 × 594 mm",
            activeScaleDisplay: "1:100",
            outputUnitSymbol: "m",
            cursorDisplayText: "(124.5, 331.0)",
            zoomDisplayString: "145%"
        )
        #expect(StatusBarDisplay.hasDocument(snapshot))
        #expect(StatusBarDisplay.pageText(snapshot) == snapshot.pageIndicatorText)
        #expect(StatusBarDisplay.coordinateText(snapshot) == "(124.5, 331.0)")
    }

    @Test("An off-page pointer reads as an em dash, not as an empty segment")
    func statusBarCoordinatePlaceholder() {
        let snapshot = StatusBarSnapshot(
            pageLabel: "A-101",
            pageIndex: 0,
            pageCount: 4,
            pageDimensionsText: "841 × 594 mm",
            activeScaleDisplay: "1:100",
            outputUnitSymbol: "m",
            cursorDisplayText: "",
            zoomDisplayString: "145%"
        )
        #expect(StatusBarDisplay.coordinateText(snapshot) == "—")
    }
}
