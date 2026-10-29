import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation

/// IM-019: the measurement presenter adopts the two seams the input state machine drives —
/// removing one count mark by index, and committing a cutout into a named parent — and tells
/// the canvas whether a click's snap is still resolving.
@MainActor
struct MeasurementInputEditingTests {

    private func makePresenter() throws -> AppMeasurementToolPresenter {
        let documentID = DocumentID(UUID())
        let pageID = PageID(UUID())
        let page = ZPDFContracts.PageDescriptor(
            id: pageID,
            documentID: documentID,
            index: 0,
            label: "1",
            boxes: PageBoxes(
                media: PDFRect(x: 0, y: 0, width: 595, height: 842),
                crop: PDFRect(x: 0, y: 0, width: 595, height: 842)
            )
        )
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        return AppMeasurementToolPresenter(session: session, documentID: documentID, pageID: pageID)
    }

    private func p(_ x: Double, _ y: Double) -> PDFPointValue { PDFPointValue(x: x, y: y) }

    @Test("The presenter is the CountPointEditing and CutoutCommitting host the input flow asks for")
    func adoptsBothSeams() throws {
        let presenter: AnyObject = try makePresenter()
        #expect(presenter is any CountPointEditing)
        #expect(presenter is any CutoutCommitting)
    }

    @Test("removePoint(at:) removes exactly that count mark and keeps the rest in order")
    func removesCountMarkByIndex() throws {
        let presenter = try makePresenter()
        presenter.activate(kind: .count)
        presenter.appendRawPoints([p(10, 10), p(50, 10), p(90, 10)])
        presenter.removePoint(at: 1)
        #expect(presenter.placedPoints == [p(10, 10), p(90, 10)])
        // Out of range: nothing happens, nothing traps.
        presenter.removePoint(at: 5)
        presenter.removePoint(at: -1)
        #expect(presenter.placedPoints == [p(10, 10), p(90, 10)])
    }

    @Test("removePoint(at:) never takes a vertex out of a path tool")
    func removeIgnoresPathTools() throws {
        let presenter = try makePresenter()
        presenter.activate(kind: .polylength)
        presenter.appendRawPoints([p(0, 0), p(10, 0), p(10, 10)])
        presenter.removePoint(at: 1)
        #expect(presenter.placedPoints.count == 3)
    }

    @Test("A count commit after an index removal records the remaining marks")
    func countCommitAfterRemoval() throws {
        let presenter = try makePresenter()
        var records: [MarkupRecord] = []
        presenter.onCommit = { records.append($0) }
        presenter.activate(kind: .count)
        presenter.appendRawPoints([p(10, 10), p(50, 10), p(90, 10)])
        presenter.removePoint(at: 0)
        presenter.commitActiveMeasurement()
        #expect(records.count == 1)
        #expect(records.first?.geometry?.countPoints.map(\.position) == [PDFPoint(x: 50, y: 10), PDFPoint(x: 90, y: 10)])
    }

    @Test("commitActiveCutout routes to the cutout door with the named parent, never to onCommit")
    func cutoutCommitsIntoParent() throws {
        let presenter = try makePresenter()
        var cutouts: [(MarkupID, MarkupRecord)] = []
        var markups: [MarkupRecord] = []
        presenter.onCommitCutout = { cutouts.append(($0, $1)) }
        presenter.onCommit = { markups.append($0) }
        let parent = UUID()
        presenter.activate(kind: .polygonCutout)
        presenter.appendRawPoints([p(10, 10), p(60, 10), p(60, 60)])
        presenter.commitActiveCutout(parentMarkupID: parent)
        #expect(cutouts.count == 1)
        #expect(cutouts.first?.0 == MarkupID(parent))
        #expect(markups.isEmpty)
        #expect(presenter.placedPoints.isEmpty)
    }

    @Test("commitActiveCutout does nothing on a tool that is not a cutout")
    func cutoutCommitIgnoresOtherTools() throws {
        let presenter = try makePresenter()
        var cutouts = 0
        var markups = 0
        presenter.onCommitCutout = { _, _ in cutouts += 1 }
        presenter.onCommit = { _ in markups += 1 }
        presenter.activate(kind: .area)
        presenter.appendRawPoints([p(10, 10), p(60, 10), p(60, 60)])
        presenter.commitActiveCutout(parentMarkupID: UUID())
        #expect(cutouts == 0)
        #expect(markups == 0)
        #expect(presenter.placedPoints.count == 3, "the area is still being drawn")
    }

    @Test("hasPlacementsInFlight is true from a click until its snap lands")
    func placementsInFlight() async throws {
        let presenter = try makePresenter()
        presenter.activate(kind: .length)
        #expect(!presenter.hasPlacementsInFlight)
        presenter.placePoint(p(20, 20))
        #expect(presenter.hasPlacementsInFlight)
        await presenter.settlePlacements()
        #expect(!presenter.hasPlacementsInFlight)
        #expect(presenter.placedPoints == [p(20, 20)])
    }
}

/// Since 2026-09-23 the default measurement ink is
/// `#1A55CF`, closed areas fill at 20 %, a new Length is dashed, and the markup tools share the
/// same default. Defaults only: nothing restyles what is already stored.
@MainActor
struct MeasurementDefaultInkTests {

    private func makePresenter() throws -> AppMeasurementToolPresenter {
        let documentID = DocumentID(UUID())
        let pageID = PageID(UUID())
        let page = ZPDFContracts.PageDescriptor(
            id: pageID,
            documentID: documentID,
            index: 0,
            label: "1",
            boxes: PageBoxes(
                media: PDFRect(x: 0, y: 0, width: 595, height: 842),
                crop: PDFRect(x: 0, y: 0, width: 595, height: 842)
            )
        )
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        return AppMeasurementToolPresenter(session: session, documentID: documentID, pageID: pageID)
    }

    private func commit(_ kind: MeasurementKind, _ points: [PDFPointValue]) throws -> MarkupRecord {
        let presenter = try makePresenter()
        var record: MarkupRecord?
        presenter.onCommit = { record = $0 }
        presenter.activate(kind: kind)
        presenter.appendRawPoints(points)
        presenter.commitActiveMeasurement()
        return try #require(record)
    }

    /// WCAG relative luminance of an sRGB colour.
    private func luminance(_ red: Double, _ green: Double, _ blue: Double) -> Double {
        func linear(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    @Test("The default measurement ink is #1A55CF and reads at better than 6:1 on the white sheet")
    func inkIsTheDefaultBlue() {
        let ink = AppMeasurementToolPresenter.measurementInk
        #expect(Int((ink.red * 255).rounded()) == 0x1A)
        #expect(Int((ink.green * 255).rounded()) == 0x55)
        #expect(Int((ink.blue * 255).rounded()) == 0xCF)
        #expect(ink.alpha == 1)
        // By hand: L(#1A55CF) ≈ 0.1122, so (1.05) / (0.1122 + 0.05) ≈ 6.47. The old cyan was ≈ 1.7.
        let contrast = 1.05 / (luminance(ink.red, ink.green, ink.blue) + 0.05)
        #expect(contrast > 6.4 && contrast < 6.55)
    }

    @Test("A closed area fills at 20 % of its stroke; a length has no fill and is dashed")
    func areaFillAndDashedLength() throws {
        let area = try commit(.area, [PDFPointValue(x: 0, y: 0), PDFPointValue(x: 50, y: 0), PDFPointValue(x: 50, y: 50)])
        #expect(area.style.color == AppMeasurementToolPresenter.measurementInk)
        #expect(area.style.fill?.alpha == 0.20)
        #expect(area.style.lineStyle == .solid)

        let length = try commit(.length, [PDFPointValue(x: 0, y: 0), PDFPointValue(x: 50, y: 0)])
        #expect(length.style.lineStyle == .dashed)
        #expect(length.style.fill == nil)

        let polylength = try commit(.polylength, [PDFPointValue(x: 0, y: 0), PDFPointValue(x: 50, y: 0)])
        #expect(polylength.style.lineStyle == .solid, "only Length is dashed by default")
    }

    @Test("A preset colour still wins, and a Length drawn in it is still dashed")
    func presetColourKeepsDashes() throws {
        let presenter = try makePresenter()
        var record: MarkupRecord?
        presenter.onCommit = { record = $0 }
        let orange = RGBAColor(red: 0.9, green: 0.5, blue: 0.1, alpha: 1)
        presenter.activate(kind: .length)
        presenter.color = orange
        presenter.appendRawPoints([PDFPointValue(x: 0, y: 0), PDFPointValue(x: 50, y: 0)])
        presenter.commitActiveMeasurement()
        let committed = try #require(record)
        #expect(committed.style.color == orange)
        #expect(committed.style.lineStyle == .dashed)
    }

    @Test("Markup and measurement tools share one default ink")
    func markupSharesTheDefault() {
        let markup = ToolStyleSelection.zenitInk
        let ink = AppMeasurementToolPresenter.measurementInk
        #expect(markup.stroke.red == ink.red && markup.stroke.green == ink.green && markup.stroke.blue == ink.blue)
        let fill = markup.fill
        #expect(fill?.red == ink.red && fill?.alpha == AppMeasurementToolPresenter.measurementFillAlpha)
    }
}
