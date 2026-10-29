import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// NL-MEASURE-03 through the calibration sheet: Keep Existing Values, the stale notice, and
/// Measure ▸ Recalculate Stale Measurements.
@MainActor
@Suite(.appTierSerialised)
struct NLMeasureKeepValuesAppTests {

    /// Calibrated 100 pt = 10 m, a 100 pt wall is 10 m. Recalibrating to 1:100 would make it
    /// 100 × 0.0254 / 72 × 100 = 3.5277… m (254/72). Keep leaves 10 m, flagged; Recalculate
    /// Stale then gives 254/72 m.
    @Test("Keep Existing Values keeps the 10 m wall, flagged stale; Recalculate Stale makes it 254/72 m")
    func keepThenRecalculate() async throws {
        let harness = try await NLMeasureR2Harness.make("Keep.pdf")
        defer { NLMeasureR2Harness.tearDown(harness) }
        let core = harness.core
        try await core.commands.calibrate(page: harness.page, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0), knownLength: 10, knownLengthUnit: .metre)
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let wall = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: DocumentID(core.snapshot.documentID), pageID: harness.page,
            kind: .measurement, tool: .length, subject: "Wall", author: "t",
            geometry: MeasurementGeometry(pageID: harness.page, points: [PDFPoint(x: 200, y: 200), PDFPoint(x: 300, y: 200)]),
            createdAt: stamp, modifiedAt: stamp
        )
        try await core.commands.perform(.addMarkup(wall))
        await core.refresh()

        var asked: [ZenitModalRequest] = []
        ZenitModalPresenter.handler = { request in
            asked.append(request)
            return .button(2)
        }
        harness.controller.presentPageScaleSheet(for: harness.document)
        let sheet = try #require(ScaleSheetCoordinator.active(for: harness.document))
        sheet.model.draft.mode = .drawingScale
        sheet.model.draft.drawingScaleDenominator = 100
        await sheet.commit()
        let question = try #require(asked.first { $0.identifier == ScaleImpactConfirmation.modalIdentifier })
        #expect(question.buttons.contains(NSLocalizedString("Keep Existing Values", comment: "")))
        #expect(sheet.isFinished)
        #expect(await core.session.scale(onPage: harness.page)?.source == .preset)
        #expect(await core.session.markup(wall.id)?.measurement?[.planLength]?.value == 10, "kept")
        #expect(await core.session.staleMeasurementIDs == [wall.id])
        await core.refresh()
        let summary = try #require(core.snapshot.markups.first { $0.id == wall.id.rawValue })
        #expect(summary.warnings.contains(.staleScaleVersion), "the Inspector's notice reads this")

        ProjectWindowController.recalculateStale(for: harness.document)
        var value: Decimal = 10
        for _ in 0..<150 {
            value = await core.session.markup(wall.id)?.measurement?[.planLength]?.value ?? 10
            if value != 10 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(Swift.abs(NSDecimalNumber(decimal: value).doubleValue - 254.0 / 72.0) < 1e-9)
        #expect(await core.session.staleMeasurementIDs.isEmpty)
    }
}
