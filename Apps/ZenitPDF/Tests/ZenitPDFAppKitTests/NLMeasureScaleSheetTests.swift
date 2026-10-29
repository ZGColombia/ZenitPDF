import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIMeasurement
import ZPDFUIPresentation
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// NL-MEASURE-01, LT3-05, LT3-07, LT3-08 and the fake-provenance bug, through the shipping
/// window controller. No sheet reaches the screen: the test windows are never ordered front,
/// and every presentation goes through `ZenitModalPresenter.beginSheet`, which records it.
@MainActor
@Suite(.appTierSerialised)
struct NLMeasureScaleSheetTests {

    /// A one-page A1 portrait PDF (1684 × 2384 pt) with one stroked line and no text.
    private func writeA1Fixture(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-nlmeasure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        let content = Data("2 w 0 0 0 RG 100 100 m 500 100 l S\n".utf8)
        var objects: [Data] = [
            Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
            Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
            Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 1684 2384] /Contents 4 0 R >>".utf8)
        ]
        var stream = Data("<< /Length \(content.count) >>\nstream\n".utf8)
        stream.append(content)
        stream.append(Data("\nendstream".utf8))
        objects.append(stream)
        var pdf = Data("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.count)
            pdf.append(Data("\(index + 1) 0 obj\n".utf8))
            pdf.append(object)
            pdf.append(Data("\nendobj\n".utf8))
        }
        let xref = pdf.count
        pdf.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets {
            pdf.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
        }
        pdf.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        try pdf.write(to: url)
        return url
    }

    private struct Harness {
        let document: ZenitPDFProjectDocument
        let controller: ProjectWindowController
        let core: AppCoreEnvironment
        let shell: ProjectShellEnvironment
        let page: PageID
        let directory: URL
    }

    private func makeHarness(_ name: String) async throws -> Harness {
        ZenitModalPresenter.reset()
        let url = try writeA1Fixture(named: name)
        let document = try AppTestSupport.makeDocument(opening: url)
        let controller = ProjectWindowController(document: document)
        #expect(await AppTestSupport.wait { document.core != nil && document.shell != nil && document.drawing != nil })
        document.addWindowController(controller)
        let core = try #require(document.core)
        let shell = try #require(document.shell)
        let page = try #require(await core.session.firstPageID)
        #expect(await AppTestSupport.wait { core.document.currentPageID != nil })
        return Harness(
            document: document, controller: controller, core: core, shell: shell,
            page: page, directory: url.deletingLastPathComponent()
        )
    }

    private func tearDown(_ harness: Harness) {
        if let sheet = ScaleSheetCoordinator.active(for: harness.document) { sheet.cancel() }
        harness.controller.window?.close()
        // A calibrated document is dirty; closing it dirty would raise the unsaved-takeoff
        // review, which nobody is here to answer.
        harness.document.updateChangeCount(.changeCleared)
        harness.document.close()
        try? FileManager.default.removeItem(at: harness.directory)
        ZenitModalPresenter.reset()
    }

    // MARK: NL-MEASURE-01

    /// Measure ▸ Calibrate Scale… opens the sheet (not the known-length alert) on an
    /// uncalibrated page in drawing-scale mode. Choosing 1:50 installs a preset scale equal to
    /// `ScaleTransform.preset(1, 50)` bit for bit: 0.0254 × 50 / 72 m/pt, no evidence.
    @Test("Calibrate Scale… presents the sheet, and 1:50 installs a preset bit for bit")
    func menuOpensSheetAndPresetApplies() async throws {
        let harness = try await makeHarness("Sheet Preset.pdf")
        defer { tearDown(harness) }
        ZenitAppCommandTable.perform(.calibrateScale, controller: harness.controller, document: harness.document)
        let sheet = try #require(ScaleSheetCoordinator.active(for: harness.document), "no calibration sheet opened")
        #expect(ZenitModalPresenter.didRequest(ScaleSheetCoordinator.modalIdentifier))
        #expect(!ZenitModalPresenter.didRequest(CalibrationPrompt.modalIdentifier), "the old alert was used")
        #expect(sheet.model.draft.mode == .drawingScale, "an uncalibrated page opens on the drawing ratio")
        #expect(sheet.model.draft.pageSizePoints == PDFSizeValue(width: 1_684, height: 2_384))

        sheet.model.draft.drawingScaleDenominator = 50
        await sheet.commit()
        #expect(sheet.isFinished)
        let scale = try #require(await harness.core.session.scale(onPage: harness.page))
        #expect(scale.source == .preset)
        #expect(scale.label == "1:50")
        #expect(scale.matrix.a == Decimal(string: "0.0254")! * 50 / 72)
        #expect(scale.matrix.d == scale.matrix.a)
        #expect(await harness.core.session.evidence(for: scale.id) == nil)
        #expect(ScaleSheetCoordinator.active(for: harness.document) == nil)
    }

    /// Separate X/Y through the sheet: X line 100 pt = 10 m, Y line 50 pt = 10 m gives
    /// sx = 0.1 and sy = 0.2 m/pt exactly, `source == .calibrationXY`.
    @Test("A separate X/Y draft installs a calibrationXY scale with both factors")
    func separateAxesDraft() async throws {
        let harness = try await makeHarness("Sheet XY.pdf")
        defer { tearDown(harness) }
        harness.controller.presentPageScaleSheet(for: harness.document)
        let sheet = try #require(ScaleSheetCoordinator.active(for: harness.document))
        sheet.model.draft.mode = .separateAxes
        sheet.model.draft.unitIdentifier = ZPDFUIPresentation.LengthUnit.metre.rawValue
        sheet.model.draft.primary = CalibrationAxisInput(
            start: PDFPointValue(x: 200, y: 200), end: PDFPointValue(x: 300, y: 200), knownLength: 10
        )
        sheet.model.draft.secondary = CalibrationAxisInput(
            start: PDFPointValue(x: 200, y: 200), end: PDFPointValue(x: 200, y: 250), knownLength: 10
        )
        await sheet.commit()
        let scale = try #require(await harness.core.session.scale(onPage: harness.page))
        #expect(scale.source == .calibrationXY)
        #expect(scale.matrix.a == Decimal(string: "0.1")!)
        #expect(scale.matrix.d == Decimal(string: "0.2")!)
        #expect(await harness.core.session.evidence(for: scale.id)?.secondaryEnteredLength == .length(10))
    }

    /// The pure translation. A 10 pt baseline gets the short-baseline advisory (the sheet still
    /// applies); a 3 pt one is refused outright — below the 4 pt minimum the session refuses too.
    @Test("Draft to request: exact decimals, short-baseline advisory, refusal below the minimum")
    func requestTranslation() throws {
        var draft = CalibrationDraft(mode: .uniform, unitIdentifier: ZPDFUIPresentation.LengthUnit.metre.rawValue)
        draft.primary = CalibrationAxisInput(
            start: PDFPointValue(x: 0, y: 0), end: PDFPointValue(x: 10, y: 0), knownLength: 0.1
        )
        #expect(CalibrationValidator.validate(draft).issues.contains(.shortPrimaryBaseline))
        let request = try #require(CalibrationRequest.make(from: draft))
        guard case let .twoPoint(_, _, length, unit, _, _) = request else {
            Issue.record("expected a two-point request, got \(request)")
            return
        }
        #expect(length == Decimal(string: "0.1")!, "0.1 must reach the session as 0.1, not 0.1000000000000000055")
        #expect(unit == .metre)

        draft.primary.end = PDFPointValue(x: 3, y: 0)
        #expect(CalibrationRequest.make(from: draft) == nil)

        var preset = CalibrationDraft(mode: .drawingScale, drawingScaleDenominator: 96)
        preset.unitIdentifier = ZPDFUIPresentation.LengthUnit.foot.rawValue
        #expect(CalibrationRequest.make(from: preset) == .preset(denominator: 96, label: "1/8\" = 1'-0\"", allowExtreme: false))
    }

    /// The toolbar's Calibrate still starts with two clicks; the points land in the sheet in
    /// uniform mode instead of the known-length alert, and applying calibrates two-point.
    @Test("The canvas's two points open the sheet with the line filled in")
    func toolbarPointsFillTheSheet() async throws {
        let harness = try await makeHarness("Sheet Points.pdf")
        defer { tearDown(harness) }
        harness.controller.finishCalibration(
            points: [PDFPointValue(x: 100, y: 100), PDFPointValue(x: 500, y: 100)],
            for: harness.document
        )
        let sheet = try #require(ScaleSheetCoordinator.active(for: harness.document))
        #expect(sheet.model.draft.mode == .uniform)
        #expect(sheet.model.draft.primary.pdfDistance == 400)
        #expect(!ZenitModalPresenter.didRequest(CalibrationPrompt.modalIdentifier))
        sheet.model.draft.unitIdentifier = ZPDFUIPresentation.LengthUnit.metre.rawValue
        sheet.model.draft.primary.knownLength = 20
        await sheet.commit()
        let scale = try #require(await harness.core.session.scale(onPage: harness.page))
        #expect(scale.source == .calibrationTwoPoint)
        #expect(scale.matrix.a == Decimal(20) / Decimal(400))
    }

    /// "Pick points" steps the sheet aside, the canvas collects two points for the Y line, and
    /// the sheet comes back with them.
    @Test("Pick points hands the canvas back and the sheet returns with the line")
    func pickPointsRoundTrip() async throws {
        let harness = try await makeHarness("Sheet Pick.pdf")
        defer { tearDown(harness) }
        let sheet = try #require(harness.controller.presentScaleSheet(for: harness.document))
        let before = sheet.presentationCount
        sheet.model.draft.mode = .separateAxes
        sheet.pick(.yAxisStart)
        #expect(sheet.pendingPick == .yAxisStart)
        #expect(sheet.sheetWindow == nil, "the sheet did not step aside")
        harness.controller.finishCalibration(
            points: [PDFPointValue(x: 50, y: 50), PDFPointValue(x: 50, y: 250)],
            for: harness.document
        )
        #expect(sheet.pendingPick == nil)
        #expect(sheet.model.draft.secondary.pdfDistance == 200)
        #expect(sheet.presentationCount == before + 1)
    }

    // MARK: LT3-08 — the status strip's Scale segment

    /// Old output: `onScaleSegmentPressed` did not exist; the segment was a plain readout.
    @Test("Clicking Scale in the status strip opens the sheet (LT3-08)")
    func statusStripOpensSheet() async throws {
        let harness = try await makeHarness("Sheet Strip.pdf")
        defer { tearDown(harness) }
        let press = try #require(harness.shell.onScaleSegmentPressed, "the Scale segment is not wired")
        press()
        #expect(ScaleSheetCoordinator.active(for: harness.document) != nil)
    }

    // MARK: LT3-05 — refused up front, with the sheet as the call to action

    /// Old output: three vertices drawn, Return committed nothing, no sheet, no row.
    @Test("An area on an uncalibrated page opens the scale sheet at the first click (LT3-05)")
    func areaOnUncalibratedPageOpensSheet() async throws {
        let harness = try await makeHarness("Sheet Refused.pdf")
        defer { tearDown(harness) }
        let canvas = try #require(harness.controller.canvasController(for: harness.document))
        _ = canvas.view
        harness.shell.perform(.measureArea)
        canvas.refresh()
        canvas.handleClick(at: PDFPointValue(x: 200, y: 200), additive: false)
        await harness.core.measurement.settlePlacements()
        #expect(harness.core.measurement.placedPoints.isEmpty)
        let sheet = try #require(ScaleSheetCoordinator.active(for: harness.document), "no call to action")
        #expect(sheet.model.notice == ProjectWindowController.scaleRequiredNotice)
        #expect(harness.core.measurement.liveWarnings.contains(.missingScale))
    }

    // MARK: LT3-07

    /// Calibrate Scale… validates enabled for a window holding a drawing with the Select tool
    /// armed. The live report was taken with the window not key, where no responder answers a
    /// menu at all — standard macOS behaviour, not a rule of this command.
    @Test("Calibrate Scale… is enabled with a drawing open and the Select tool active (LT3-07)")
    func calibrateIsEnabledWithSelectTool() async throws {
        let harness = try await makeHarness("Sheet Menu.pdf")
        defer { tearDown(harness) }
        harness.shell.perform(.selectTool)
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.representedObject = ZenitAppCommand.calibrateScale.rawValue
        #expect(harness.controller.validateMenuItem(item))
    }

    // MARK: NL-MEASURE-03

    /// Page calibrated 100 pt = 10 m, a 100 pt length on it (10 m). Setting 1:100 instead
    /// (0.0254 × 100 / 72 m/pt) would make it 100 × 2.54 / 72 = 3.53 m. The sheet asks first,
    /// naming one measurement and the Plan Length totals; Cancel leaves 10 m, Recalculate
    /// installs the preset. Old output: the scale was replaced and the length restamped with
    /// no question and no count.
    @Test("A recalibration asks Recalculate or Cancel with the count and the totals (NL-MEASURE-03)")
    func recalibrationAsksFirst() async throws {
        let harness = try await makeHarness("Sheet Impact.pdf")
        defer { tearDown(harness) }
        _ = try await harness.core.commands.calibrate(
            page: harness.page, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 10, knownLengthUnit: .metre
        )
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let length = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: DocumentID(harness.core.snapshot.documentID), pageID: harness.page,
            kind: .measurement, tool: .length, subject: "Wall", author: "t",
            geometry: MeasurementGeometry(pageID: harness.page, points: [PDFPoint(x: 200, y: 200), PDFPoint(x: 300, y: 200)]),
            createdAt: stamp, modifiedAt: stamp
        )
        try await harness.core.commands.perform(.addMarkup(length))
        await harness.core.refresh()

        var asked: [ZenitModalRequest] = []
        ZenitModalPresenter.handler = { request in
            asked.append(request)
            return .button(1)
        }
        harness.controller.presentPageScaleSheet(for: harness.document)
        let sheet = try #require(ScaleSheetCoordinator.active(for: harness.document))
        sheet.model.draft.mode = .drawingScale
        sheet.model.draft.drawingScaleDenominator = 100
        await sheet.commit()
        let question = try #require(asked.first { $0.identifier == ScaleImpactConfirmation.modalIdentifier })
        #expect(question.detail.contains("Measurements that change: 1."))
        #expect(question.detail.contains("Plan Length"))
        #expect(!sheet.isFinished, "Cancel keeps the sheet open")
        #expect(await harness.core.session.markup(length.id)?.measurement?[.planLength]?.value == 10)
        #expect(await harness.core.session.scale(onPage: harness.page)?.source == .calibrationTwoPoint)

        ZenitModalPresenter.handler = { _ in .button(0) }
        await sheet.commit()
        #expect(sheet.isFinished)
        #expect(await harness.core.session.scale(onPage: harness.page)?.source == .preset)
        let value = try #require(await harness.core.session.markup(length.id)?.measurement?[.planLength]?.value)
        #expect(abs(NSDecimalNumber(decimal: value).doubleValue - 254.0 / 72.0) < 1e-9)
    }

    // MARK: NL-MEASURE-04

    /// Calibrated 100 pt = 10 m. The line (0,0)-(100,0) measures 10 m. Stated 10.02 m:
    /// 10 / 10.02 − 1 = −0.1996 %, within the 1 % threshold. Stated 9.8 m: 10 / 9.8 − 1 =
    /// +2.04 %, a warning naming both lengths.
    @Test("Verify Scale compares a second stated dimension and says the deviation")
    func verifyScale() async throws {
        let harness = try await makeHarness("Sheet Verify.pdf")
        defer { tearDown(harness) }
        _ = try await harness.core.commands.calibrate(
            page: harness.page, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 10, knownLengthUnit: .metre
        )
        await harness.core.refresh()
        let points = [PDFPointValue(x: 0, y: 300), PDFPointValue(x: 100, y: 300)]
        let close = try await VerifyScale.evaluate(
            points: points, stated: CalibrationPrompt.Entry(length: Decimal(string: "10.02")!, unit: .metre),
            page: harness.page, session: harness.core.session
        )
        #expect(close.measuredMetres == 10)
        #expect(close.agrees)
        let closeWarning = VerifyScale.warning(for: close, page: harness.page, formatter: harness.core.snapshot.ledger.formatter)
        #expect(closeWarning.title.contains("agrees") && closeWarning.title.contains("0.20"))
        #expect(closeWarning.severity == .info)

        let far = try await VerifyScale.evaluate(
            points: points, stated: CalibrationPrompt.Entry(length: Decimal(string: "9.8")!, unit: .metre),
            page: harness.page, session: harness.core.session
        )
        #expect(!far.agrees)
        let farWarning = VerifyScale.warning(for: far, page: harness.page, formatter: harness.core.snapshot.ledger.formatter)
        #expect(farWarning.severity == .warning)
        #expect(farWarning.title.contains("2.04"))

        // The menu path arms the two clicks and asks for the stated length after them.
        harness.controller.beginVerifyScale(for: harness.document)
        #expect(VerifyScale.isArmed(harness.document))
        harness.controller.finishCalibration(points: points, for: harness.document)
        #expect(!VerifyScale.isArmed(harness.document))
        #expect(ZenitModalPresenter.didRequest(VerifyScale.modalIdentifier))
        #expect(ScaleSheetCoordinator.active(for: harness.document) == nil, "verification points never open the calibration sheet")
        #expect(await harness.core.session.scale(onPage: harness.page)?.version == 1, "verification changed the scale")
    }
}
