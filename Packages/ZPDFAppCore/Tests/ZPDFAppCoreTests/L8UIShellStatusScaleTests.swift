import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation

/// L-38. A separate X / Y calibration of X 848.0 pt = 14,8 m and
/// Y 839.6 pt = 15 m — 1:49.47 × 1:50.64. The Calibrate sheet read "1:49,5" and "1:50,6"; the
/// status strip read "1:49 × 1:51 @ 1.00m"; the Inspector's Scale row, the Scale Regions panel and
/// the Bulk Scale sheet (all ``ScaleSummary/displayString``) read "1:49 × 1:51". The first fix
/// gave the strip a fixed two decimals — "1:49,47 × 1:50,64 @ 1,00 m" — so it still disagreed
/// with the sheet, and the display string did not move at all. Every `1:n` now comes from
/// ``ScaleRatioText``, the sheet's rule, in the document's locale.
@Suite("One scale, one spelling, in the document's numbers (L-38)")
struct L8UIShellStatusScaleTests {

    /// The live sheet: A3 landscape, room for the 848 pt X line and the 839.6 pt Y line.
    static func liveSession(locale: String) throws -> (TakeoffSession, ZPDFContracts.PageDescriptor, DocumentID) {
        let documentID = DocumentID(UUID())
        let page = ZPDFContracts.PageDescriptor(
            id: PageID(UUID()), documentID: documentID, index: 0, label: "A-101",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 1191, height: 842))
        )
        return (try TakeoffSession(documentID: documentID, pages: [page], localeIdentifier: locale), page, documentID)
    }

    /// The live picks, through the command bus the Calibrate sheet's Apply uses.
    static func calibrateLive(_ environment: AppCoreEnvironment, page: PageID) async throws {
        _ = try await environment.commands.calibrateXY(
            page: page,
            xFirst: PDFPoint(x: 100, y: 100), xSecond: PDFPoint(x: 948, y: 100),
            xKnownLength: Decimal(string: "14.8")!,
            yFirst: PDFPoint(x: 50, y: 1), ySecond: PDFPoint(x: 50, y: 840.6),
            yKnownLength: 15,
            knownLengthUnit: .metre
        )
        await environment.refresh()
    }

    @Test("The live X/Y calibration reads 1:49,5 × 1:50,6 in the strip, the Inspector and the Scale Regions panel")
    @MainActor
    func liveCalibrationReadsTheSameEverywhere() async throws {
        let (session, page, documentID) = try Self.liveSession(locale: "sv_SE")
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        try await Self.calibrateLive(environment, page: page.id)
        let scale = try #require(await session.scale(onPage: page.id))
        #expect(scale.source == .calibrationXY)

        // The Calibrate sheet's rule on the committed factors: what the sheet showed at Apply.
        let sheetRule = ScaleRatioText.ratio(
            metresPerPointX: scale.matrix.metresPerPointX, metresPerPointY: scale.matrix.metresPerPointY,
            isUniform: false, locale: Locale(identifier: "sv_SE")
        )
        #expect(sheetRule == "1:49,5 × 1:50,6")

        // Status strip. Old: "1:49 × 1:51 @ 1.00m"; first fix: "1:49,47 × 1:50,64 @ 1,00 m".
        #expect(environment.status.snapshot.activeScaleDisplay == "1:49,5 × 1:50,6 @ 1,00 m")
        // The Inspector's Scale row for the page on screen reads `canvas.activeScale`. Old: "1:49 × 1:51".
        #expect(environment.canvas.activeScale?.displayString == "1:49,5 × 1:50,6")

        // A Scale Region on that scale: its panel row and the Bulk Scale sheet read the region's
        // summary. Old: "1:49 × 1:51".
        let region = ScaleRegionDefinition(
            id: ScaleRegionID(UUID()), pageID: page.id, name: "Detail",
            boundary: [PDFPoint(x: 200, y: 200), PDFPoint(x: 400, y: 200), PDFPoint(x: 400, y: 400)],
            scaleID: scale.id, priority: 1, colorRGBA: ColorRGBA(red: 0.2, green: 0.4, blue: 0.9, alpha: 1)
        )
        _ = try await environment.commands.perform(.setScaleRegions([region]))
        await environment.refresh()
        let row = try #require(environment.document.scaleRegions.first)
        #expect(row.scale.displayString == "1:49,5 × 1:50,6")
        // The scale's generated name — the ledger's and the Properties tab's — is the same text.
        #expect(ScaleBridge.ratioText(for: scale, localeIdentifier: "sv_SE") == "1:49,5 × 1:50,6")
    }

    @Test("Without a locale the same scale reads 1:49.5 × 1:50.6 — the files' spelling")
    func fileSpellingKeepsThePoint() async throws {
        let (session, page, documentID) = try Self.liveSession(locale: "en_US_POSIX")
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        try await Self.calibrateLive(environment, page: page.id)
        let scale = try #require(await session.scale(onPage: page.id))
        #expect(ScaleBridge.ratioText(for: scale) == "1:49.5 × 1:50.6")
        #expect(ScaleSummary(domain: scale, name: nil).displayString == "1:49.5 × 1:50.6")
        #expect(ScaleBridge.statusText(for: scale, units: .metric) == "1:49.5 × 1:50.6 @ 1.00 m")
    }

    @Test("Whole ratios print no decimals and no grouping; noise is rounded away; 0.1 m/pt reads 1:283")
    @MainActor
    func wholeRatiosStayWhole() async throws {
        func metresPerPoint(_ ratio: String) -> Decimal { Decimal(string: ratio)! * Decimal(string: "0.0254")! / 72 }
        let fifty = try ScaleTransform.uniform(id: ScaleID(UUID()), metresPerPoint: metresPerPoint("50"), units: .metric, source: .preset)
        #expect(ScaleBridge.statusText(for: fifty, units: .metric, localeIdentifier: "sv_SE") == "1:50 @ 1,00 m")
        #expect(ScaleSummary(domain: fifty, name: nil, localeIdentifier: "sv_SE").displayString == "1:50")
        #expect(ScaleBridge.statusText(for: fifty, units: .imperial, localeIdentifier: "sv_SE") == "1:50 @ 1,00 ft")
        let thousand = try ScaleTransform.uniform(id: ScaleID(UUID()), metresPerPoint: metresPerPoint("1000"), units: .metric, source: .preset)
        // A scale is written 1:1000, never "1 000" with the locale's grouping space.
        #expect(ScaleBridge.statusText(for: thousand, units: .metric, localeIdentifier: "sv_SE") == "1:1000 @ 1,00 m")
        #expect(ScaleBridge.denominator(metresPerPoint: 0) == 1, "a degenerate scale cannot print 1:0")

        // 100 points stand for 10 metres: 0.1 m per point = 1:283.46…, which the Calibrate sheet
        // calls 1:283. The first fix's strip read "1:283,46 @ 1,00 m".
        let (session, page, documentID) = try Self.liveSession(locale: "sv_SE")
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        _ = try await environment.commands.calibrate(
            page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 10, knownLengthUnit: .metre
        )
        await environment.refresh()
        #expect(environment.status.snapshot.activeScaleDisplay == "1:283 @ 1,00 m")
        #expect(environment.canvas.activeScale?.displayString == "1:283")
    }
}
