import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
@testable import ZPDFUIMeasurement
@testable import ZPDFUIShell
@testable import ZenitPDFAppKit

/// L-38, end to end. A separate X / Y calibration — X 848.0 pt = 14,8 m,
/// Y 839.6 pt = 15 m, a Swedish-format machine — gave one scale three spellings: the Calibrate
/// sheet "1:49,5" / "1:50,6", the status strip "1:49 × 1:51 @ 1.00m" (after the first fix
/// "1:49,47 × 1:50,64 @ 1,00 m"), and the Inspector's Scale row and the Scale Regions panel
/// "1:49 × 1:51". This drives the sheet's own validator and Apply request through the command
/// bus into a document formatted in sv_SE, then reads the strip, the Inspector the window builds
/// and a Scale Region on that scale, and requires one text.
@MainActor
@Suite("One scale, one spelling (L-38)", .appTierSerialised, .serialized)
struct L8UIShellScaleAgreementTests {

    @Test("The live X/Y calibration reads 1:49,5 × 1:50,6 in the sheet, the strip, the Inspector and Scale Regions")
    func liveCalibrationReadsTheSameEverywhere() async throws {
        let swedish = Locale(identifier: "sv_SE")

        // The Calibrate sheet, with the live picks.
        var draft = CalibrationDraft(mode: .separateAxes, unitIdentifier: ZPDFUIPresentation.LengthUnit.metre.rawValue)
        draft.primary = CalibrationAxisInput(
            start: PDFPointValue(x: 100, y: 100), end: PDFPointValue(x: 948, y: 100), knownLength: 14.8
        )
        draft.secondary = CalibrationAxisInput(
            start: PDFPointValue(x: 50, y: 1), end: PDFPointValue(x: 50, y: 840.6), knownLength: 15
        )
        let preview = try #require(CalibrationValidator.validate(draft, locale: swedish).preview)
        #expect(preview.ratioString == "1:49,5")
        #expect(preview.secondaryRatioString == "1:50,6")
        let sheet = "\(preview.ratioString) × \(preview.secondaryRatioString ?? "?")"

        // Apply: the request the sheet makes, through the bus, on a document formatted in sv_SE.
        let documentID = DocumentID(UUID())
        let page = ZPDFContracts.PageDescriptor(
            id: PageID(UUID()), documentID: documentID, index: 0, label: "A-101",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 1191, height: 842))
        )
        let session = try TakeoffSession(documentID: documentID, pages: [page], localeIdentifier: "sv_SE")
        let core = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        let request = try #require(CalibrationRequest.make(from: draft))
        try await request.perform(on: core.commands, page: page.id, scaleID: nil)
        await core.refresh()

        // The status strip. Old: "1:49 × 1:51 @ 1.00m"; first fix: "1:49,47 × 1:50,64 @ 1,00 m".
        #expect(core.status.snapshot.activeScaleDisplay == "\(sheet) @ 1,00 m")

        // The Inspector's Scale row, in the shell the document window builds over these presenters.
        // Old: "1:49 × 1:51".
        let shell = ProjectShellEnvironment(
            document: core.document,
            canvas: core.canvas,
            ledger: core.ledger,
            toolLibrary: core.toolLibrary,
            search: MockSearchPresenter(),
            compare: MockComparePresenter(),
            measurement: core.measurement,
            status: core.status
        )
        let inspector = InspectorMeasurementModel(environment: shell, selection: InspectorSelectionSummary(markups: []))
        #expect(inspector.scaleInForce.text == sheet)

        // A Scale Region on that scale: the Scale Regions panel's row and the Bulk Scale sheet show
        // its summary's display string verbatim. Old: "1:49 × 1:51".
        let scale = try #require(await session.scale(onPage: page.id))
        let region = ScaleRegionDefinition(
            id: ScaleRegionID(UUID()), pageID: page.id, name: "Detail",
            boundary: [PDFPoint(x: 200, y: 200), PDFPoint(x: 400, y: 200), PDFPoint(x: 400, y: 400)],
            scaleID: scale.id, priority: 1, colorRGBA: ColorRGBA(red: 0.2, green: 0.4, blue: 0.9, alpha: 1)
        )
        _ = try await core.commands.perform(.setScaleRegions([region]))
        await core.refresh()
        let row = try #require(shell.document.scaleRegions(onPage: page.id.rawValue).first)
        #expect(row.scale.displayString == sheet)
    }
}
