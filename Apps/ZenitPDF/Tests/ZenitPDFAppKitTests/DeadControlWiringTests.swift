import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
import ZPDFAppCore
import ZPDFContracts
import ZPDFUILedger
import ZPDFUIPresentation
import ZPDFUIShell
import ZPDFUIWorkflows
@testable import ZenitPDFAppKit

/// Five controls that were once live defects: each one reachable in the
/// shipping application, each one with no effect at all.
///
/// A control a person can press that does nothing is the same defect class as a fabricated
/// search result — the interface makes a promise the product does not keep — and the register
/// was the score. This suite is what makes the score stay at zero: every test drives the
/// **shipping** object that owns the control (the real document, the real window controller,
/// the real `LedgerPaneModel` over the real `LedgerTableHost`) and never assigns the hook it is
/// about to check, because a test that installs its own closure proves only that closures work.
///
/// | Control | Hook | Test |
/// |---|---|---|
/// | Accept / Accept All in Revision Compare | `AppComparePresenter.onPromoteDiff` | ``acceptingADifferenceCreatesTheMarkupItPromised()`` |
/// | The Revision Compare tolerance slider | `RevisionCompareModel.onSettingsChange` | ``theToleranceSliderAsksTheCoreToDetectAgain()`` |
/// | Clicking a difference, Next / Previous | `RevisionCompareModel.onFocusDifference` | ``focusingADifferenceTellsTheCanvasWhereItIs()`` |
/// | Save Layout… in the ledger header menu | `LedgerTableHost.onSaveLayoutRequested` | ``saveLayoutOpensTheNamingPromptAndPersistsTheLayout()`` |
/// | Import Tool Set, on a file that cannot be read | `ToolLibraryEditingModel.onImportFailure` | ``anUnreadableToolSetSaysSoInsteadOfNothing()`` |
@MainActor
@Suite(.appTierSerialised, .serialized)
struct DeadControlWiringTests {

    private func wait(
        upTo seconds: Double = 60,
        for condition: @MainActor () -> Bool
    ) async -> Bool {
        await AppTestSupport.wait(upTo: seconds, for: condition)
    }

    /// Opens a fixture into a real window controller and waits for the layout and the core.
    private func openWindow() async throws -> (
        url: URL,
        document: ZenitPDFProjectDocument,
        controller: ProjectWindowController
    ) {
        let url = try AppTestSupport.writeFixturePDF()
        let document = ZenitPDFProjectDocument()
        try document.read(from: url, ofType: UTType.pdf.identifier)
        document.makeWindowControllers()
        let controller = try #require(document.windowControllers.first as? ProjectWindowController)
        #expect(await wait { controller.contentViewController is ProjectWindowLayoutController })
        #expect(await wait { document.core != nil && document.shell != nil })
        controller.window?.layoutIfNeeded()
        return (url, document, controller)
    }

    private func diff(
        kind: CompareChangeKind = .added,
        bounds: PDFRectValue = PDFRectValue(x: 120, y: 200, width: 80, height: 40)
    ) -> CompareDiffSummary {
        CompareDiffSummary(
            id: UUID(),
            changeKind: kind,
            pageLabel: "Rev B",
            baselineBounds: bounds,
            comparisonBounds: bounds,
            areaInSquarePoints: bounds.size.width * bounds.size.height,
            confidence: 0.9,
            isAccepted: false
        )
    }

    // MARK: - 1. Accept turns a difference into a markup

    /// `AppComparePresenter.onPromoteDiff` is called by both `acceptDiff(id:)` and
    /// `acceptAllDiffs()`. Nothing assigned it, so Accept ticked the row and created nothing.
    ///
    /// Driven through `promoteCompareDifference`, the method the document installs on the
    /// presenter, and asserted against the **snapshot** — the markup has to exist in the
    /// document's own state, not merely in a closure that ran.
    @Test("Accepting a Revision Compare difference creates the markup it promised")
    func acceptingADifferenceCreatesTheMarkupItPromised() async throws {
        let opened = try await openWindow()
        defer { opened.document.close() }
        let core = try #require(opened.document.core)
        let presenter = try #require(opened.document.comparePresenter)
        let before = core.snapshot.markups.count

        // The hook itself, not a stand-in: the document assigned it when it built the presenter.
        #expect(presenter.onPromoteDiff != nil, "nothing installed onPromoteDiff")
        presenter.onPromoteDiff?(diff())

        #expect(await wait { core.snapshot.markups.count == before + 1 })
        let promoted = try #require(core.snapshot.markups.last)
        #expect(promoted.kind == .revisionCloud)
        #expect(promoted.subject.contains("Revision Compare"))
        // The geometry is the difference's own bounds, not an invented box.
        let bounds = promoted.boundsInPageSpace
        #expect(abs(bounds.origin.x - 120) < 0.001)
        #expect(abs(bounds.origin.y - 200) < 0.001)
        #expect(abs(bounds.size.width - 80) < 0.001)
        #expect(abs(bounds.size.height - 40) < 0.001)
    }

    // MARK: - 2. The tolerance slider re-detects

    /// `RevisionCompareModel.onSettingsChange` was declared, called by the slider and assigned
    /// by nobody, so moving the slider withdrew the standing verdict and never asked for a new
    /// one: the review emptied and stayed empty.
    ///
    /// The sheet is built by the shipping presentation path, then the model's own `setTolerance`
    /// is called — the thing `RevisionCompareView.swift:281` calls. What is asserted is that the
    /// *presenter's* detection settings moved, which is the half that was missing; whether a
    /// raster comparison then finds anything is the comparator's business and not this test's.
    @Test("The Revision Compare tolerance slider asks the core to detect again")
    func theToleranceSliderAsksTheCoreToDetectAgain() async throws {
        let opened = try await openWindow()
        defer { opened.document.close() }
        let presenter = try #require(opened.document.comparePresenter)
        try await opened.document.registerCurrentDrawingAsBaseline()

        let sheet = try #require(opened.controller.presentRevisionCompare(for: opened.document))
        defer { opened.controller.window?.endSheet(sheet.window) }

        #expect(sheet.model.onSettingsChange != nil, "nothing installed onSettingsChange")
        let originalTolerance = presenter.detectionTolerance
        sheet.model.setTolerance(originalTolerance == 0.8 ? 0.2 : 0.8)

        #expect(
            presenter.detectionTolerance == sheet.model.settings.tolerance,
            "the slider moved and the detector did not: \(presenter.detectionTolerance)"
        )
        #expect(presenter.detectionTolerance != originalTolerance)
        // The engine options the new tolerance means, so the sentence under the slider and the
        // detector agree rather than merely both existing.
        #expect(
            presenter.rasterOptions.tolerance.intensityTolerance
                == Int((2 + presenter.detectionTolerance * 30).rounded())
        )
    }

    // MARK: - 3. Focusing a difference moves the canvas

    /// `RevisionCompareModel.onFocusDifference` moved the review's own cursor and told nothing
    /// else, so the sheet read "3 of 17" over a canvas showing something unrelated.
    @Test("Focusing a difference tells the canvas where it is")
    func focusingADifferenceTellsTheCanvasWhereItIs() async throws {
        let opened = try await openWindow()
        defer { opened.document.close() }
        let core = try #require(opened.document.core)
        _ = try #require(opened.controller.canvasController(for: opened.document))
        try await opened.document.registerCurrentDrawingAsBaseline()

        let sheet = try #require(opened.controller.presentRevisionCompare(for: opened.document))
        defer { opened.controller.window?.endSheet(sheet.window) }

        #expect(sheet.model.onFocusDifference != nil, "nothing installed onFocusDifference")
        // The canvas opens fitted to the whole 595 × 842 fixture page. A difference 120 × 90
        // across cannot be revealed at that zoom, so the zoom is what moves — and it is read
        // from `core.canvas.viewport`, the shipping viewport the canvas publishes back into,
        // rather than from anything this test installed.
        let before = core.canvas.viewport.zoom
        let target = diff(bounds: PDFRectValue(x: 40, y: 600, width: 120, height: 90))
        sheet.model.focusDifference(id: target.id, in: [target])

        #expect(sheet.model.focusedDiffID == target.id)
        opened.controller.window?.layoutIfNeeded()
        #expect(
            await wait(upTo: 5) { core.canvas.viewport.zoom != before },
            "the canvas did not move for the focused difference"
        )
    }

    // MARK: - 4. Save Layout saves a layout

    /// `LedgerTableHost.onSaveLayoutRequested` was the fifth of the host's five hooks and the
    /// one `LedgerPaneModel.wire()` left out, so Save Layout… in the column header menu reached
    /// the host and stopped. Worse than a no-op on its own: saved layouts were the only source
    /// of the same menu's Apply Layout list, so that list could never fill either.
    ///
    /// Driven from the host — the object the menu builder calls — through the shipping pane
    /// model, against a scratch defaults suite so the user's real preferences are untouched.
    @Test("Save Layout opens the naming prompt and writes a layout that survives a relaunch")
    func saveLayoutOpensTheNamingPromptAndPersistsTheLayout() throws {
        try ScratchDefaults.with(prefix: "zenit.deadcontrols.ledger") { defaults, _ in
            let preferences = LedgerPanePreferences(defaults: defaults)
            let presenter = MockLedgerPresenter()
            let model = LedgerPaneModel(presenter: presenter, preferences: preferences)

            #expect(model.host.onSaveLayoutRequested != nil, "nothing installed onSaveLayoutRequested")
            #expect(model.pendingLayoutName == nil)
            #expect(model.host.controller.layoutStore.layouts.isEmpty)

            // The menu item's own call path: LedgerColumnMenuBuilder → controller → host.
            model.host.controller.onSaveLayoutRequested?()
            let suggested = try #require(model.pendingLayoutName, "Save Layout… opened no prompt")
            #expect(!suggested.isEmpty)

            let saved = try #require(model.saveLayout(named: "Take-off"))
            #expect(saved.name == "Take-off")
            #expect(model.pendingLayoutName == nil)
            #expect(model.host.controller.layoutStore.layouts.map(\.name) == ["Take-off"])
            #expect(!saved.states.isEmpty, "a layout that captured no column is not a layout")

            // The half that makes it a feature rather than a variable: it is on disk, and the
            // next pane over the same preferences opens holding it.
            #expect(preferences.columnLayouts.layout(named: "Take-off") != nil)
            let reopened = LedgerPaneModel(presenter: presenter, preferences: preferences)
            #expect(reopened.host.controller.layoutStore.layout(named: "Take-off") != nil)

            // An empty name is refused rather than silently discarded. Since BH-815 the
            // refusal is said in the pane and the prompt closes, instead of the alert
            // staying open with no word.
            reopened.beginLayoutNaming()
            #expect(reopened.saveLayout(named: "   ") == nil)
            #expect(reopened.layoutSaveMessage != nil, "a refused name must say so")
            #expect(reopened.pendingLayoutName == nil)
            #expect(reopened.host.controller.layoutStore.layouts.map(\.name) == ["Take-off"])
        }
    }

    // MARK: - 5. A refused Tool Set import says so

    /// `ToolLibraryEditingModel.onImportFailure` was called on the one path where the validator
    /// cannot even describe the file, and assigned by nobody: Import Tool Set on a corrupt
    /// `.zpdftools` looked exactly like a control that did nothing.
    @Test("An unreadable Tool Set says so instead of nothing")
    func anUnreadableToolSetSaysSoInsteadOfNothing() async throws {
        let opened = try await openWindow()
        defer { opened.document.close() }

        ZenitErrorPresenter.reset()
        defer { ZenitErrorPresenter.reset() }

        let sheet = try #require(opened.controller.presentToolLibrary(for: opened.document))
        defer { opened.controller.window?.endSheet(sheet.window) }

        #expect(sheet.model.onImportFailure != nil, "nothing installed onImportFailure")
        await sheet.model.beginImport(data: Data("not a tool set".utf8), fileName: "Broken.zpdftools")

        #expect(sheet.model.importReview == nil, "an undescribable file must not open a review")
        let reported = try #require(
            ZenitErrorPresenter.lastRecorded as? ZPDFUserFacingError,
            "the refusal reached nobody — Import Tool Set is silent again"
        )
        #expect(reported.subject == "Broken.zpdftools" || reported.technicalDetail != nil)
    }
}
