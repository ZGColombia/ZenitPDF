import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation

/// CR-128: every point-to-real conversion that starts from a *ratio* honours the page's
/// `/UserUnit`. A two-point calibration needs no correction — its points live in the very user
/// space the content is drawn in — but a preset, a proposal, the nominal ratio a scale displays
/// and the page-size readout all convert page units, and until this change none of them read
/// the field. Each test states the old output.
@Suite("Scale presets honour /UserUnit")
struct UserUnitScaleTests {

    private static let units = ScaleUnitPolicy(length: .metre, area: .squareMetre, volume: .cubicMetre)

    private static func page(documentID: DocumentID, index: Int, userUnit: Double) -> ZPDFContracts.PageDescriptor {
        ZPDFContracts.PageDescriptor(
            id: PageID(UUID()),
            documentID: documentID,
            index: index,
            label: "P\(index)",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 612, height: 792)),
            userUnit: userUnit
        )
    }

    private static func line(documentID: DocumentID, pageID: PageID) -> MarkupRecord {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        return MarkupRecord(
            id: MarkupID(UUID()),
            documentID: documentID,
            pageID: pageID,
            kind: .measurement,
            tool: .polylength,
            subject: "Wall",
            author: "test",
            geometry: MeasurementGeometry(pageID: pageID, points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 100, y: 0)]),
            createdAt: stamp,
            modifiedAt: stamp
        )
    }

    @Test("A page whose user unit is 2 doubles the real length of the same drawn line")
    func userUnitDoublesRealLength() async throws {
        let documentID = DocumentID(UUID())
        let plain = Self.page(documentID: documentID, index: 0, userUnit: 1)
        let doubled = Self.page(documentID: documentID, index: 1, userUnit: 2)
        let session = try TakeoffSession(documentID: documentID, pages: [plain, doubled])
        for page in [plain, doubled] {
            _ = try await session.apply(.changeScale(try ScaleTransform.preset(
                id: ScaleID(UUID()), page: page, ratioDenominator: 100, units: Self.units
            )))
        }
        let onPlain = Self.line(documentID: documentID, pageID: plain.id)
        let onDoubled = Self.line(documentID: documentID, pageID: doubled.id)
        _ = try await session.apply(.addMarkup(onPlain))
        _ = try await session.apply(.addMarkup(onDoubled))

        let plainLength = try #require(await session.markup(onPlain.id)?.measurement?[.planLength]?.value)
        let doubledLength = try #require(await session.markup(onDoubled.id)?.measurement?[.planLength]?.value)
        // 100 pt at 1:100 is 100 × 0.0254 / 72 × 100 m ≈ 3.5278 m; at /UserUnit 2 twice that.
        // Old output: the two lengths were equal — the factor read the ratio and never the page.
        let expectedPlain = try AffineScaleMatrix.metresPerPoint(ratioDenominator: 100, userUnit: 1) * 100
        #expect(abs(plainLength - expectedPlain) < Decimal(string: "1e-9")!)
        #expect(abs(doubledLength - plainLength * 2) < Decimal(string: "1e-9")!)
    }

    @Test("The proposal's factor honours the page's user unit")
    func proposalFactorHonoursUserUnit() throws {
        let line = RecognisedTextLine(text: "SKALA 1:100")
        let box = PDFSizeValue(width: 2384, height: 1684)
        let engine = ScaleProposalEngine()
        let plain = try #require(engine.proposal(forRecognisedLines: [line], pageBoxSizeInPoints: box))
        let doubled = try #require(engine.proposal(forRecognisedLines: [line], pageBoxSizeInPoints: box, userUnit: 2))
        #expect(plain.ratio.denominator == 100)
        #expect(plain.userUnit == 1)
        #expect(doubled.userUnit == 2)
        // Old output: the same factor for both — `userUnit` did not exist on the proposal.
        // The contract divides once, last, so `doubled` is one quotient and `plain × 2` is a
        // doubled quotient: they agree to 37 significant digits, not 38.
        #expect(abs(doubled.metresPerPointExact - plain.metresPerPointExact * 2) < Decimal(string: "1e-30")!)
        #expect(doubled.metresPerPointExact == (try AffineScaleMatrix.metresPerPoint(ratioDenominator: 100, userUnit: 2)))
        #expect(abs(doubled.metresPerPoint - plain.metresPerPoint * 2) < 1e-15)
        #expect(try ScaleRatio(denominator: 100)?.metresPerPointExact(userUnit: 2) == doubled.metresPerPointExact)
        #expect(ScaleRatio(denominator: 100)?.metresPerPointExact == plain.metresPerPointExact)
    }

    @Test("The nominal ratio a preset displays divides the user unit back out")
    func nominalRatioDividesOutUserUnit() throws {
        let page = Self.page(documentID: DocumentID(UUID()), index: 0, userUnit: 2)
        let preset = try ScaleTransform.preset(id: ScaleID(UUID()), page: page, ratioDenominator: 100, units: Self.units)
        // Old output: "1:200".
        #expect(ScaleBridge.ratioText(for: preset, userUnit: 2) == "1:100")
        #expect(ScaleBridge.ratioText(for: preset) == "1:200", "read without the page, the factor is what it is")
        #expect(ScaleSummary(domain: preset, name: nil, userUnit: 2).displayString == "1:100")
    }

    @Test("The session's snapshot names a preset by its nominal ratio on a user-unit page")
    func snapshotNamesNominalRatio() async throws {
        let documentID = DocumentID(UUID())
        let page = Self.page(documentID: documentID, index: 0, userUnit: 2)
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        _ = try await session.apply(.changeScale(try ScaleTransform.preset(
            id: ScaleID(UUID()), page: page, ratioDenominator: 50, units: Self.units
        )))
        let snapshot = try await session.snapshot()
        #expect(snapshot.userUnit(onPage: page.id.rawValue) == 2)
        #expect(snapshot.userUnit(onPage: UUID()) == 1)
        // Old output: "1:100".
        #expect(snapshot.scale(onPage: page.id.rawValue)?.displayString == "1:50")
    }

    @Test("The page-size readout honours the user unit")
    func pageSizeHonoursUserUnit() {
        let page = ZPDFUIPresentation.PageDescriptor(
            domain: Self.page(documentID: DocumentID(UUID()), index: 0, userUnit: 2)
        )
        #expect(page.dimensionsText(units: .metric) == "216 × 279 mm")
        // Old output: "216 × 279 mm" — a letter sheet, on a page physically twice that size.
        #expect(page.dimensionsText(units: .metric, userUnit: 2) == "432 × 559 mm")
        #expect(page.dimensionsText(units: .imperial, userUnit: 2) == "17.0 × 22.0 in")
    }

}
