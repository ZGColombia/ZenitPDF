import AppKit
import Foundation
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
import ZPDFUIShell

/// The scale sheet's doors (NL-MEASURE-01, LT3-05, LT3-08).
extension ProjectWindowController {

    /// Opens the calibration sheet for the page on screen: a drawing ratio, one line, or
    /// separate X and Y lines.
    ///
    /// - Parameters:
    ///   - points: two points already collected on the canvas, which fill the line in.
    ///   - notice: why the sheet opened, when there is a reason to say.
    @discardableResult
    func presentScaleSheet(
        for document: ZenitPDFProjectDocument,
        points: [PDFPointValue] = [],
        notice: String? = nil
    ) -> ScaleSheetCoordinator? {
        guard let window else { return nil }
        return ScaleSheetCoordinator.present(
            for: document,
            in: window,
            points: points,
            notice: notice,
            beginPicking: { [weak self, weak document] in
                guard let self, let document else { return }
                // "Pick points" collects the sheet's line. A borrowed pick still armed (no
                // Escape since Pick Fall Line…, say) is served first in `finishCalibration`
                // and would take the two clicks — the sheet got nothing and the slope changed
                // (R-001).
                PendingPointPicks.disarmAll(document)
                self.beginCalibration(for: document)
            }
        )
    }

    /// Measure ▸ Calibrate Scale…: the page's own scale, through the sheet. A destination left
    /// behind by an abandoned Scale Regions calibration must not redirect it (CR-149).
    func presentPageScaleSheet(for document: ZenitPDFProjectDocument) {
        document.pendingScaleCalibration = nil
        presentScaleSheet(for: document)
    }

    /// Measure ▸ Apply Scale to Pages…: the page on screen's scale onto other pages, one ⌘Z.
    @discardableResult
    func presentBulkScaleSheet(for document: ZenitPDFProjectDocument) -> BulkScaleCoordinator? {
        guard let window else { return nil }
        return BulkScaleCoordinator.present(for: document, in: window) { [weak self] notice in
            self?.presentScaleSheet(for: document, notice: notice)
        }
    }

    /// Measure ▸ Page Scales…: every sheet's scale status and its proposal.
    @discardableResult
    func presentPageScalesSheet(for document: ZenitPDFProjectDocument) -> PageScalesCoordinator? {
        guard let window else { return nil }
        return PageScalesCoordinator.present(for: document, in: window) { [weak self, weak document] in
            guard let self, let document else { return }
            self.presentBulkScaleSheet(for: document)
        }
    }

    /// Measure ▸ Verify Scale…: two clicks on a stated dimension, compared with the page's
    /// scale (NL-MEASURE-04). A page with no scale opens the calibration sheet instead.
    func beginVerifyScale(for document: ZenitPDFProjectDocument) {
        guard let core = document.core, let current = core.document.currentPageID else { return }
        guard core.snapshot.scale(onPage: current) != nil else {
            presentScaleSheet(for: document, notice: Self.scaleRequiredNotice)
            return
        }
        document.pendingScaleCalibration = nil
        VerifyScale.arm(document)
        beginCalibration(for: document)
        // L-70: the borrowed pick names itself. As a note under the Calibrate tool it read
        // "Tool Calibrate — Verify Scale: click…", naming a tool the person never chose.
        core.status.setActiveTool(
            name: NSLocalizedString("Verify Scale", comment: "Status bar tool name while picking the line to verify the scale against"),
            note: NSLocalizedString(
                "Click both ends of a dimension the drawing states.",
                comment: "Status note while picking the line to verify the scale against"
            )
        )
    }

    /// Measure ▸ Split Area: two clicks across the selected area divide it (NL-MEASURE-06).
    func beginSplitArea(for document: ZenitPDFProjectDocument) {
        guard let core = document.core else { return }
        if let refusal = AreaSplitFlow.arm(document) {
            core.status.setActiveToolNote(refusal)
            return
        }
        document.pendingScaleCalibration = nil
        beginCalibration(for: document)
        // L-70: "Tool Split Area — Click the two ends…", not "Tool Calibrate — Split Area: …".
        core.status.setActiveTool(
            name: NSLocalizedString("Split Area", comment: "Status bar tool name while picking the line that splits an area"),
            note: NSLocalizedString(
                "Click the two ends of the dividing line.",
                comment: "Status note while picking the line that splits an area"
            )
        )
    }

    /// Measure ▸ Continue Measurement: the selected polylength or count re-arms with its points
    /// preloaded; new points append and the finish is one `editVertices` on the same markup
    /// (NL-MEASURE-06, NL-MEASURE-12).
    func beginContinueMeasurement(for document: ZenitPDFProjectDocument) {
        guard let core = document.core, let shell = document.shell else { return }
        let selected = core.canvas.selectedMarkupIDs
        guard selected.count == 1, let id = selected.first else {
            core.status.setActiveToolNote(NSLocalizedString(
                "Select one polylength or count to continue.",
                comment: "Continue refusal: nothing or several selected"
            ))
            return
        }
        let commands = core.commands
        Task { @MainActor in
            guard let record = await core.session.markup(MarkupID(id)),
                  AppMeasurementToolPresenter.canContinue(record.tool), let tool = record.tool else {
                core.status.setActiveToolNote(NSLocalizedString(
                    "Only a polylength or a count can be continued.",
                    comment: "Continue refusal: the selected markup's tool cannot continue"
                ))
                return
            }
            // A numbered count stays numbered: the appended marks continue the sequence (NL-MEASURE-12).
            let keepsNumbers = CountNumbering.isNumbered(record.geometry)
            core.measurement.onCommitContinuation = { markupID, geometry in
                Task { @MainActor in
                    do {
                        let geometry = keepsNumbers ? CountNumbering.numbered(geometry, on: true) : geometry
                        try await commands.perform(.editVertices(id: markupID, geometry: geometry))
                    } catch {
                        ZenitPDFProjectDocument.reportRefusedEdit(error, core: core)
                    }
                }
            }
            shell.toolbar.activateMeasurement(Shown.Kind(domain: tool))
            core.measurement.setPage(record.pageID)
            core.measurement.beginContinuation(of: record)
            self.canvasController(for: document)?.refresh()
        }
    }

    /// Joins the status strip's Scale segment and the measurement tool's missing-scale refusal
    /// to the sheet.
    func wireScaleSheet(core: AppCoreEnvironment, shell: ProjectShellEnvironment, for document: ZenitPDFProjectDocument) {
        // NL-MEASURE-07: the Inspector's parameter rows (Measure/InspectorParameterWiring.swift).
        wireInspectorParameters(core: core, shell: shell, for: document)
        // NL-MEASURE-13: the double-count hatch follows the guard's findings.
        core.onDoubleCountRegionsChanged = { [weak self, weak document] in
            guard let self, let document else { return }
            self.canvasController(for: document)?.refresh()
        }
        // LT3-08: clicking "Scale No scale" did nothing.
        shell.onScaleSegmentPressed = { [weak self, weak document] in
            guard let self, let document else { return }
            self.presentPageScaleSheet(for: document)
        }
        // LT3-05: the first point of a measurement on a sheet with no scale opens the sheet,
        // saying why, instead of letting a whole shape be drawn that can never commit.
        core.measurement.onScaleRequired = { [weak self, weak document] _ in
            guard let self, let document else { return }
            guard ScaleSheetCoordinator.active(for: document) == nil else { return }
            document.pendingScaleCalibration = nil
            self.presentScaleSheet(for: document, notice: Self.scaleRequiredNotice)
        }
    }

    /// The sentence the sheet opens with after a refused measurement.
    static var scaleRequiredNotice: String {
        NSLocalizedString(
            "This page has no scale yet, so nothing on it can be measured. Set the scale to start measuring.",
            comment: "Calibration sheet notice after a measurement was refused on a page with no scale"
        )
    }
}
