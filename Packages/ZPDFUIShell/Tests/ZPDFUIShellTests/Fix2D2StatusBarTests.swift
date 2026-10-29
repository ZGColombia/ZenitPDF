import Foundation
import Testing
import ZPDFDesignSystem
import ZPDFUIMeasurement
import ZPDFUIPresentation
@testable import ZPDFUIShell

/// Fix round 2, shell part D2: the status bar and the measurement controls row.
///
/// | ID | Rule | Test |
/// |---|---|---|
/// | BH-299 | a typed page number is a page turn like any other | ``typedPageTurnReachesThePanels()`` |
/// | IM-022 | the zoom field reads through the shared parser | ``zoomFieldUsesTheSharedParser()`` |
/// | IM-134 | a warning can take the canvas to its markup or page | ``warningShowGoesThere()`` |
/// | BH-819, IM-221 | the snap segment's words, state and tooltip agree | ``snapSegmentAgrees()`` |
/// | IM-222 | zoom presets follow the locale and show their shortcuts | ``zoomPresetsFollowTheLocale()`` |
/// | BH-822, IM-137 | "1 more point" | ``remainingPointsArePluralised()`` |
/// | BH-823 | the pill names the blocking warning | ``pillNamesTheBlockingWarning()`` |
@Suite("Fix2 D2 — status bar and measurement row", .shellTierSerialised)
@MainActor
struct Fix2D2StatusBarTests {

    // MARK: - BH-299

    /// Old output, against the field calling `document.goToPage(index:)` directly:
    ///
    /// ```
    /// ✘ Expectation failed: (environment.scaleRegions.draft → ScaleRegionDraft(… pageLabel:
    ///   "A-101" …)) == nil — a boundary drawn on another sheet is still armed over this one
    /// ✘ Expectation failed: (environment.scaleRegions.regions → [… "Stair Detail 1:20" …]).isEmpty
    /// ```
    @Test("A typed page number turns the page for the Scale Regions panel too")
    func typedPageTurnReachesThePanels() throws {
        let environment = ProjectShellEnvironment.mock()
        // The boundary tool needs a canvas to arm, as in ScaleRegionPageTurnTests.
        environment.scaleRegions.onBeginPolygon = {}
        environment.scaleRegions.onCancelPolygonDrawing = {}
        let page = try #require(environment.document.currentPage)
        #expect(environment.scaleRegions.beginRegion())
        #expect(environment.scaleRegions.completePolygon(
            [PDFPointValue(x: 100, y: 100), PDFPointValue(x: 400, y: 100), PDFPointValue(x: 400, y: 400)],
            pageID: page.id,
            pageLabel: page.label
        ))
        #expect(environment.scaleRegions.draft != nil)

        let pages = environment.document.pages
        let empty = try #require(pages.firstIndex { environment.document.scaleRegions(onPage: $0.id).isEmpty })
        try #require(pages[empty].id != page.id)

        #expect(StatusBarDisplay.commitTypedPage(pages[empty].label, environment: environment))
        #expect(environment.document.currentPageID == pages[empty].id)
        #expect(environment.scaleRegions.draft == nil, "a boundary drawn on another sheet is still armed")
        #expect(environment.scaleRegions.regions.isEmpty, "the panel still lists the previous sheet")

        #expect(!StatusBarDisplay.commitTypedPage("hello", environment: environment))
        #expect(environment.document.currentPageID == pages[empty].id)
    }

    // MARK: - IM-022

    /// Old output, against `text.filter { digits , . }` + `Double(...)`: `"1,000"` → 1.0 →
    /// clamped to 5 %; `"nan"` filtered to `""` → refused only by accident; `"inf"` likewise.
    @Test("The zoom field reads typed text through ZPDFDecimalParser")
    func zoomFieldUsesTheSharedParser() {
        #expect(StatusBarDisplay.zoomPercent(fromTyped: "1,000") == nil, "ambiguous: a thousand or one")
        #expect(StatusBarDisplay.zoomPercent(fromTyped: "1.000") == nil)
        #expect(StatusBarDisplay.zoomPercent(fromTyped: "150,5") == 150.5)
        #expect(StatusBarDisplay.zoomPercent(fromTyped: "150.5") == 150.5)
        #expect(StatusBarDisplay.zoomPercent(fromTyped: "200 %") == 200)
        #expect(StatusBarDisplay.zoomPercent(fromTyped: "200%") == 200)
        #expect(StatusBarDisplay.zoomPercent(fromTyped: "1 000") == 1_000)
        #expect(StatusBarDisplay.zoomPercent(fromTyped: "nan") == nil)
        #expect(StatusBarDisplay.zoomPercent(fromTyped: "inf") == nil)
        #expect(StatusBarDisplay.zoomPercent(fromTyped: "-50") == nil)
        #expect(StatusBarDisplay.zoomPercent(fromTyped: "abc") == nil)
        #expect(StatusBarDisplay.zoomPercent(fromTyped: "1") == 5, "clamped to the minimum")
        #expect(StatusBarDisplay.zoomPercent(fromTyped: "99999") == 6_400, "clamped to the maximum")
    }

    // MARK: - IM-134

    @Test("Show takes the canvas to a warning's markup, or to its page")
    func warningShowGoesThere() throws {
        let environment = ProjectShellEnvironment.mock()
        let markup = try #require(ZenitSampleProject.shared.markups.last)
        let markupWarning = AppWarning(
            id: UUID(), severity: .warning, title: "Stale scale", message: "Re-measure.",
            source: "Scale", timestamp: Date(), relatedMarkupID: markup.id
        )
        #expect(WarningTrayView.canShow(markupWarning))
        WarningTrayView.show(markupWarning, environment: environment)
        #expect(environment.canvas.selectedMarkupIDs == [markup.id])

        let target = try #require(environment.document.pages.last)
        let pageWarning = AppWarning(
            id: UUID(), severity: .info, title: "Page", message: "Check it.",
            source: "Import", timestamp: Date(), relatedPageID: target.id
        )
        WarningTrayView.show(pageWarning, environment: environment)
        #expect(environment.document.currentPageID == target.id)

        let bare = AppWarning(
            id: UUID(), severity: .info, title: "Bare", message: "Nothing to show.",
            source: "", timestamp: Date()
        )
        #expect(!WarningTrayView.canShow(bare))
        #expect(WarningTrayView.maximumListHeight > 0)
    }

    // MARK: - BH-819 / IM-221

    /// Old output (BH-819): the toggle's binding returned the stored `isOn` → `true` while the
    /// label read "Vector off".
    @Test("The snap segment lists short names, draws off when unavailable, and explains itself")
    func snapSegmentAgrees() {
        #expect(!StatusBarDisplay.snapToggleIsOn(isOn: true, isAvailable: false))
        #expect(StatusBarDisplay.snapToggleIsOn(isOn: true, isAvailable: true))
        #expect(!StatusBarDisplay.snapToggleIsOn(isOn: false, isAvailable: true))

        #expect(StatusBarDisplay.snapShortName(.vector) == "Vector")
        #expect(StatusBarDisplay.snapShortName(.grid) == "Grid")
        #expect(StatusBarDisplay.snapShortName(.markup) == "Markup")
        #expect(StatusBarDisplay.snapSourceText(name: StatusBarDisplay.snapShortName(.grid), isActive: false) == "Grid off")

        let help = StatusBarDisplay.snapHelp(.vector, isAvailable: true)
        #expect(help.contains(ZPDFSnapKind.vector.title))
        #expect(help.contains(ZPDFSnapKind.vector.icon.helpText))
        #expect(StatusBarDisplay.snapHelp(.vector, isAvailable: false).contains("no vector geometry"))
    }

    // MARK: - IM-222

    @Test("Zoom preset labels follow the locale, and the fit commands show their shortcuts")
    func zoomPresetsFollowTheLocale() throws {
        #expect(StatusBarDisplay.zoomPresetTitle(percent: 25, locale: Locale(identifier: "en_US")) == "25%")
        let swedish = StatusBarDisplay.zoomPresetTitle(percent: 400, locale: Locale(identifier: "sv_SE"))
        #expect(swedish.hasPrefix("400"))
        #expect(swedish.hasSuffix("%"))
        #expect(swedish.count > "400%".count, "Swedish separates the sign: \(swedish)")

        let fitWidth = try #require(ZPDFCommandTable.standard.command(.fitWidth)?.binding)
        #expect(StatusBarDisplay.titleWithShortcut("Fit Width", binding: fitWidth) == "Fit Width (\u{2318}0)")
        #expect(StatusBarDisplay.titleWithShortcut("Fit Width", binding: nil) == "Fit Width")
    }

    // MARK: - BH-822 / BH-823

    /// Old output: `"1 more points"`. The readout now prints the shared phrase (W-074).
    @Test("The live readout says 1 more point")
    func remainingPointsArePluralised() {
        #expect(MeasurementPointPhrases.morePoints(1) == "1 more point")
        #expect(MeasurementPointPhrases.morePoints(2) == "2 more points")
    }

    /// Old output: the pill read `MeasurementWarningSummary.nearlyCollinear.message` while
    /// Finish was disabled for the missing scale.
    @Test("The warning pill names the warning that blocks Finish")
    func pillNamesTheBlockingWarning() {
        #expect(
            MeasurementControlsDisplay.warningPillTitle([.nearlyCollinear, .missingScale])
                == MeasurementWarningSummary.missingScale.message
        )
        #expect(
            MeasurementControlsDisplay.warningPillTitle([.nearlyCollinear])
                == MeasurementWarningSummary.nearlyCollinear.message
        )
        #expect(!MeasurementControlsDisplay.warningPillTitle([]).isEmpty)
    }
}
