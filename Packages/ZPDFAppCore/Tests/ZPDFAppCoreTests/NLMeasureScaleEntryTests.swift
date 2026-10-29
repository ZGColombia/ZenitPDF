import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFAppCore

/// NL-MEASURE-01 / NL-MEASURE-02 / ADR-0019: drawing-ratio scales, separate X/Y calibration and
/// one scale over many pages, each an undoable `.changeScale` with honest evidence.
@Suite("Scale entry points: preset, X/Y, bulk (NL-MEASURE-01/02)")
struct NLMeasureScaleEntryTests {

    static let documentID = DocumentID(UUID())

    /// An A1 sheet (1684 × 2384 pt) and two more, in order.
    static func pages(count: Int = 3) -> [ZPDFContracts.PageDescriptor] {
        (0..<count).map { index in
            ZPDFContracts.PageDescriptor(
                id: PageID(UUID()), documentID: documentID, index: index, label: "A-10\(index + 1)",
                boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 1_684, height: 2_384))
            )
        }
    }

    static func length(on page: PageID, from: (Double, Double), to: (Double, Double)) -> ZPDFContracts.MarkupRecord {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        return ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: documentID, pageID: page, kind: .measurement, tool: .length,
            subject: "Wall", author: "t",
            geometry: MeasurementGeometry(pageID: page, points: [PDFPoint(x: from.0, y: from.1), PDFPoint(x: to.0, y: to.1)]),
            createdAt: stamp, modifiedAt: stamp
        )
    }

    /// 1:50 on an A1 page. Expected factor, hand-derived: 0.0254 × 50 / 72 metres per point
    /// (one division, last, as the contract computes it), exactly `ScaleTransform.preset(1, 50)`.
    @Test("1:50 installs a preset scale, bit for bit, with no evidence")
    func presetIsPresetBitForBit() async throws {
        let pages = Self.pages(count: 1)
        let session = try TakeoffSession(documentID: Self.documentID, pages: pages, units: .metric)
        _ = try await session.setPresetScale(page: pages[0].id, ratioDenominator: 50, label: "1:50")
        let scale = try #require(await session.scale(onPage: pages[0].id))
        #expect(scale.source == .preset)
        let expected = try ScaleTransform.preset(
            id: scale.id, page: pages[0], version: 1, ratioDenominator: 50, units: .metric, label: "1:50"
        )
        #expect(scale.matrix == expected.matrix)
        #expect(scale.matrix.a == Decimal(string: "0.0254")! * 50 / 72)
        #expect(await session.evidence(for: scale.id) == nil, "a preset carries no calibration evidence")
    }

    /// The fake-provenance bug: a proposal's Apply used to calibrate from (0,0)-(100,0), so the
    /// stored scale said `.calibrationTwoPoint` with two points nobody picked. A preset over a
    /// real calibration now removes that calibration's evidence, and ⌘Z brings it back.
    /// Old output: `source == .calibrationTwoPoint`, evidence points [(0,0), (100,0)].
    @Test("A preset over a calibration drops the old evidence; undo restores it")
    func presetOverCalibrationDropsEvidence() async throws {
        let pages = Self.pages(count: 1)
        let page = pages[0].id
        let session = try TakeoffSession(documentID: Self.documentID, pages: pages, units: .metric)
        _ = try await session.calibrate(
            page: page, first: PDFPoint(x: 10, y: 10), second: PDFPoint(x: 110, y: 10),
            knownLength: 5, knownLengthUnit: .metre
        )
        let calibrated = try #require(await session.scale(onPage: page))
        #expect(await session.evidence(for: calibrated.id) != nil)

        let outcome = try await session.setPresetScale(page: page, ratioDenominator: 100)
        let preset = try #require(await session.scale(onPage: page))
        #expect(preset.id == calibrated.id, "the page's own scale is re-versioned, not duplicated")
        #expect(preset.version == 2)
        #expect(preset.source == .preset)
        #expect(await session.evidence(for: preset.id) == nil)

        let redo = try await session.revert(outcome.inverse)
        let restored = try #require(await session.scale(onPage: page))
        #expect(restored.source == .calibrationTwoPoint)
        #expect(await session.evidence(for: restored.id)?.points == [PDFPoint(x: 10, y: 10), PDFPoint(x: 110, y: 10)])
        _ = try await session.revert(redo)
        #expect(await session.scale(onPage: page)?.source == .preset)
        #expect(await session.evidence(for: preset.id) == nil)
    }

    /// X line (0,0)-(100,0) is 10 m, Y line (0,0)-(0,50) is 10 m: sx = 10/100 = 0.1 m/pt and
    /// sy = 10/50 = 0.2 m/pt, exactly. A 30 pt horizontal length measures 3 m, a 30 pt vertical
    /// one 6 m.
    @Test("Separate X/Y installs two exact factors with four points of evidence")
    func separateXYFactors() async throws {
        let pages = Self.pages(count: 1)
        let page = pages[0].id
        let session = try TakeoffSession(documentID: Self.documentID, pages: pages, units: .metric)
        let horizontal = Self.length(on: page, from: (0, 0), to: (30, 0))
        let vertical = Self.length(on: page, from: (0, 0), to: (0, 30))
        _ = try await session.apply(.addMarkup(horizontal))
        _ = try await session.apply(.addMarkup(vertical))
        _ = try await session.calibrateXY(
            page: page,
            xFirst: PDFPoint(x: 0, y: 0), xSecond: PDFPoint(x: 100, y: 0), xKnownLength: 10,
            yFirst: PDFPoint(x: 0, y: 0), ySecond: PDFPoint(x: 0, y: 50), yKnownLength: 10,
            knownLengthUnit: .metre
        )
        let scale = try #require(await session.scale(onPage: page))
        #expect(scale.source == .calibrationXY)
        #expect(scale.matrix.a == Decimal(string: "0.1")!)
        #expect(scale.matrix.d == Decimal(string: "0.2")!)
        let evidence = try #require(await session.evidence(for: scale.id))
        #expect(evidence.points.count == 4)
        #expect(evidence.secondaryEnteredLength == .length(10))
        #expect(await session.markup(horizontal.id)?.measurement?[.planLength]?.value == 3)
        #expect(await session.markup(vertical.id)?.measurement?[.planLength]?.value == 6)
    }

    /// Two parallel lines cannot tell X from Y; the refusal leaves the page uncalibrated.
    @Test("Parallel X/Y lines are refused and change nothing")
    func parallelLinesRefused() async throws {
        let pages = Self.pages(count: 1)
        let page = pages[0].id
        let session = try TakeoffSession(documentID: Self.documentID, pages: pages, units: .metric)
        await #expect(throws: DocumentCommandError.self) {
            _ = try await session.calibrateXY(
                page: page,
                xFirst: PDFPoint(x: 0, y: 0), xSecond: PDFPoint(x: 100, y: 0), xKnownLength: 10,
                yFirst: PDFPoint(x: 0, y: 10), ySecond: PDFPoint(x: 100, y: 10), yKnownLength: 10,
                knownLengthUnit: .metre
            )
        }
        #expect(await session.isCalibrated(page: page) == false)
    }

    /// Three sheets, a 100 pt length on each of the first two. 1:100 applied to all three is one
    /// step: every page is preset at 0.0254 × 100 / 72 m/pt, so each length is
    /// 100 × 2.54 / 72 = 254 / 72 = 3.52777… m, and one revert leaves all three uncalibrated.
    @Test("One scale over many pages is one undoable step")
    func bulkApplyIsOneStep() async throws {
        let pages = Self.pages(count: 3)
        let session = try TakeoffSession(documentID: Self.documentID, pages: pages, units: .metric)
        let first = Self.length(on: pages[0].id, from: (0, 0), to: (100, 0))
        let second = Self.length(on: pages[1].id, from: (0, 0), to: (100, 0))
        _ = try await session.apply(.addMarkup(first))
        _ = try await session.apply(.addMarkup(second))
        #expect(await session.measurementCount(onPages: Set(pages.map(\.id))) == 2)

        let outcome = try await session.applyScale(
            .ratio(numerator: 1, denominator: 100, label: "1:100"),
            toPages: pages.map(\.id)
        )
        #expect(outcome.commands.count == 3)
        let expected = 254.0 / 72.0
        for page in pages {
            let scale = try #require(await session.scale(onPage: page.id))
            #expect(scale.source == .preset)
            #expect(scale.label == "1:100")
        }
        for id in [first.id, second.id] {
            let value = try #require(await session.markup(id)?.measurement?[.planLength]?.value)
            #expect(abs(NSDecimalNumber(decimal: value).doubleValue - expected) / expected < 1e-12)
        }
        #expect(outcome.changedMarkupIDs == [first.id, second.id])

        let redo = try await session.revert(outcome.inverse)
        for page in pages {
            #expect(await session.isCalibrated(page: page.id) == false, "one undo takes every page back")
        }
        #expect(await session.markup(first.id)?.measurement == nil)
        _ = try await session.revert(redo)
        for page in pages {
            #expect(await session.scale(onPage: page.id)?.label == "1:100", "one redo reinstalls every page")
        }
    }

    /// Copying page 1's calibration to page 2 copies the matrix, marks it inherited and cites
    /// no evidence — the points were picked on page 1.
    @Test("Copying a page's scale is inherited, never evidence borrowed from another sheet")
    func copyIsInherited() async throws {
        let pages = Self.pages(count: 2)
        let session = try TakeoffSession(documentID: Self.documentID, pages: pages, units: .metric)
        _ = try await session.calibrate(
            page: pages[0].id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 10, knownLengthUnit: .metre
        )
        _ = try await session.applyScale(.copyOf(page: pages[0].id), toPages: pages.map(\.id))
        let source = try #require(await session.scale(onPage: pages[0].id))
        let copy = try #require(await session.scale(onPage: pages[1].id))
        #expect(copy.id != source.id)
        #expect(copy.matrix == source.matrix)
        #expect(copy.source == .inherited)
        #expect(copy.pageID == pages[1].id)
        #expect(await session.evidence(for: copy.id) == nil)
        #expect(source.version == 1, "the source page is not re-applied to itself")
    }

    /// Bulk copy from a page with no scale is refused, and nothing moves.
    @Test("Copying from an uncalibrated page is refused")
    func copyFromNothingRefused() async throws {
        let pages = Self.pages(count: 2)
        let session = try TakeoffSession(documentID: Self.documentID, pages: pages, units: .metric)
        await #expect(throws: DocumentCommandError.noScale(pages[0].id)) {
            _ = try await session.applyScale(.copyOf(page: pages[0].id), toPages: [pages[1].id])
        }
        #expect(await session.isCalibrated(page: pages[1].id) == false)
    }
}
