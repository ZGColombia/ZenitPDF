import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation

/// NL-MEASURE-05 (ADR-0030 §5.6): an arc segment drawn while placing points, through the shipping
/// measurement presenter. A three-point arc: after A, the next click is the point the arc passes
/// through and the click after it is the end. Page scale 1 m per point, so page numbers are metres.
@MainActor
@Suite("Arc segment while drawing, presenter (NL-MEASURE-05)")
struct NLMeasureArcDrawingTests {

    static func rel(_ value: Double, _ expected: Double) -> Double {
        Swift.abs(value - expected) / Swift.abs(expected)
    }

    private func makePresenter() async throws -> (AppMeasurementToolPresenter, TakeoffSession, PageID) {
        let documentID = DocumentID(UUID())
        let page = PageID(UUID())
        let descriptor = ZPDFContracts.PageDescriptor(id: page, documentID: documentID, index: 0, label: "A",
                                                      boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 1000, height: 1000)))
        let session = try TakeoffSession(documentID: documentID, pages: [descriptor])
        _ = try await session.calibrate(page: page, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0), knownLength: 100, knownLengthUnit: .metre)
        let presenter = AppMeasurementToolPresenter(session: session, documentID: documentID, pageID: page)
        return (presenter, session, page)
    }

    private func place(_ presenter: AppMeasurementToolPresenter, _ x: Double, _ y: Double) async {
        presenter.placePoint(PDFPointValue(x: x, y: y))
        await presenter.settlePlacements()
    }

    private func value(_ field: MeasurementFieldSummary?) -> Double {
        NSDecimalNumber(decimal: field?.quantity.value ?? 0).doubleValue
    }

    /// Polylength (0,0) → (10,0), then A, through (12.5, 2.5), end (10,5): the second edge is the
    /// semicircle of radius 2.5, bulge tan(π/4) = 1. While the end follows the pointer at (10, 5)
    /// the running length is 10 + 2.5π and the arc's own length 2.5π; the committed record carries
    /// pointBulges [0, 1, 0] and measures 10 + 2.5π in the session.
    @Test("Polylength with an arc: live 10 + 2.5π, arc 2.5π, committed exactly")
    func polylengthArc() async throws {
        let (presenter, session, _) = try await makePresenter()
        var committed: MarkupRecord?
        presenter.onCommit = { committed = $0 }
        presenter.activate(kind: .polylength)
        await place(presenter, 0, 0)
        await place(presenter, 10, 0)
        presenter.setArcNextSegment(true)
        #expect(presenter.isArcNextSegment)
        presenter.placeArcThroughPoint(PDFPointValue(x: 12.5, y: 2.5))
        await presenter.settlePlacements()
        #expect(presenter.arcThroughPoint == PDFPointValue(x: 12.5, y: 2.5))
        #expect(presenter.placedPoints.count == 2, "the through point is not a vertex")

        presenter.updateLiveCursor(PDFPointValue(x: 10, y: 5))
        await presenter.settlePreviewsForTesting()
        #expect(Self.rel(value(presenter.liveFields.first { $0.field == .planLength }), 10 + 2.5 * .pi) <= 1e-12)
        #expect(Self.rel(value(presenter.liveArcSegmentField), 2.5 * .pi) <= 1e-12)

        await place(presenter, 10, 5)
        #expect(!presenter.isArcNextSegment && presenter.arcThroughPoint == nil)
        #expect(Swift.abs((presenter.placedArcBulges[1] ?? 0) - 1) <= 1e-12)
        presenter.commitActiveMeasurement()
        let record = try #require(committed)
        let bulges = try #require(record.geometry?.validPointBulges)
        #expect(bulges.count == 3 && Swift.abs(bulges[1] - 1) <= 1e-12 && bulges[0] == 0 && bulges[2] == 0)
        _ = try await session.apply(.addMarkup(record))
        let stored = await session.markup(record.id)?.measurement?[.planLength]?.value ?? 0
        #expect(Self.rel(NSDecimalNumber(decimal: stored).doubleValue, 10 + 2.5 * .pi) <= 1e-12)
    }

    /// Backspace: the arc that ended at the removed vertex goes with it. After (0,0), (10,0), the arc
    /// to (10,5) and a straight (0,5), removing (0,5) keeps the arc; removing (10,5) removes it.
    @Test("Undo of the last vertex removes its arc, and only its arc")
    func removeLastVertex() async throws {
        let (presenter, _, _) = try await makePresenter()
        presenter.activate(kind: .polylength)
        await place(presenter, 0, 0)
        await place(presenter, 10, 0)
        presenter.setArcNextSegment(true)
        presenter.placeArcThroughPoint(PDFPointValue(x: 12.5, y: 2.5))
        await place(presenter, 10, 5)
        await place(presenter, 0, 5)
        #expect(presenter.placedArcBulges.keys.sorted() == [1])
        presenter.removeLastPoint()
        #expect(presenter.placedArcBulges.keys.sorted() == [1])
        presenter.removeLastPoint()
        #expect(presenter.placedArcBulges.isEmpty)
        #expect(presenter.geometry(for: .polylength).validPointBulges == nil)
        // A through point removed by Backspace leaves the arc armed and no bulge behind.
        presenter.setArcNextSegment(true)
        presenter.placeArcThroughPoint(PDFPointValue(x: 5, y: 3))
        await presenter.settlePlacements()
        presenter.removeArcThroughPoint()
        #expect(presenter.isArcNextSegment && presenter.arcThroughPoint == nil)
    }

    /// The golden area drawn with the arc: (0,0), (10,0), A, through (12.5, 2.5), (10,5), (0,5),
    /// close. Area 50 + 3.125π, perimeter 25 + 2.5π. And the closing edge as the arc: (10,5),
    /// (0,5), (0,0), (10,0), A, through (12.5, 2.5), then the click on the first vertex closes with
    /// the closing edge (10,0) → (10,5) bent through the point — the same shape.
    @Test("Area with an arc edge, and with the closing edge as the arc: 50 + 3.125π")
    func areaArc() async throws {
        let (presenter, session, _) = try await makePresenter()
        var committed: [MarkupRecord] = []
        presenter.onCommit = { committed.append($0) }

        presenter.activate(kind: .area)
        await place(presenter, 0, 0)
        await place(presenter, 10, 0)
        presenter.setArcNextSegment(true)
        presenter.placeArcThroughPoint(PDFPointValue(x: 12.5, y: 2.5))
        await place(presenter, 10, 5)
        await place(presenter, 0, 5)
        presenter.commitActiveMeasurement()

        presenter.activate(kind: .polylength)
        presenter.activate(kind: .area)
        await place(presenter, 10, 5)
        await place(presenter, 0, 5)
        await place(presenter, 0, 0)
        await place(presenter, 10, 0)
        presenter.setArcNextSegment(true)
        presenter.placeArcThroughPoint(PDFPointValue(x: 12.5, y: 2.5))
        await presenter.settlePlacements()
        presenter.commitActiveMeasurement()

        #expect(committed.count == 2)
        for record in committed {
            _ = try await session.apply(.addMarkup(record))
            let measurement = await session.markup(record.id)?.measurement
            let area = NSDecimalNumber(decimal: measurement?[.netArea]?.value ?? 0).doubleValue
            let perimeter = NSDecimalNumber(decimal: measurement?[.perimeter]?.value ?? 0).doubleValue
            #expect(Self.rel(area, 50 + 3.125 * .pi) <= 1e-12)
            #expect(Self.rel(perimeter, 25 + 2.5 * .pi) <= 1e-12)
            #expect(record.geometry?.polygons.first?.outer.validBulges?.filter { $0 != 0 }.count == 1)
        }
    }

    /// Continue on a polylength with an arc keeps the arc (old output: appending points made the
    /// bulges misaligned and every arc straight).
    @Test("Continue keeps a chain's arcs")
    func continuationKeepsArcs() async throws {
        let (presenter, _, page) = try await makePresenter()
        var continued: MeasurementGeometry?
        presenter.onCommitContinuation = { _, geometry in continued = geometry }
        let stamp = Date(timeIntervalSince1970: 0)
        let record = MarkupRecord(id: MarkupID(UUID()), documentID: DocumentID(UUID()), pageID: page, kind: .measurement, tool: .polylength,
                                  subject: "Wall", author: "t",
                                  geometry: MeasurementGeometry(pageID: page, points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 10, y: 0)], pointBulges: [1, 0]),
                                  createdAt: stamp, modifiedAt: stamp)
        #expect(presenter.beginContinuation(of: record))
        await place(presenter, 10, 5)
        presenter.commitActiveMeasurement()
        #expect(continued?.validPointBulges == [1, 0, 0])
    }
}
