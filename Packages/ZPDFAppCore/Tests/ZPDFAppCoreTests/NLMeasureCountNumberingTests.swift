import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFAppCore

/// NL-MEASURE-12: numbering a count is 1…n in placement order, one undo, and the count is unchanged.
@Suite("Count numbering (NL-MEASURE-12)")
struct NLMeasureCountNumberingTests {

    static func count(_ page: PageID, _ documentID: DocumentID, _ positions: [(Double, Double)]) -> ZPDFContracts.MarkupRecord {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        return ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: documentID, pageID: page, kind: .measurement, tool: .count,
            subject: "Doors", author: "t",
            geometry: MeasurementGeometry(pageID: page, countPoints: positions.map {
                CountPoint(id: CountPointID(UUID()), position: PDFPoint(x: $0.0, y: $0.1))
            }),
            createdAt: stamp, modifiedAt: stamp
        )
    }

    @Test("On numbers 1…n in placement order; off removes them; the count stays 4; one undo each")
    func toggle() async throws {
        let documentID = DocumentID(UUID())
        let page = ZPDFContracts.PageDescriptor(id: PageID(UUID()), documentID: documentID, index: 0, label: "A",
                                                boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 1000, height: 1000)))
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        _ = try await session.setPresetScale(page: page.id, ratioDenominator: 100)
        // Placed right to left on purpose: numbering follows placement, not position.
        let record = Self.count(page.id, documentID, [(400, 10), (300, 10), (200, 10), (100, 10)])
        _ = try await session.apply(.addMarkup(record))
        #expect(CountNumbering.numbers(of: try #require(await session.markup(record.id))).isEmpty)

        let (commands, turnsOn) = CountNumbering.toggleCommands(for: [try #require(await session.markup(record.id))])
        #expect(turnsOn)
        let outcome = try await session.applyBatch(commands)
        let numbered = try #require(await session.markup(record.id))
        #expect(CountNumbering.numbers(of: numbered) == [1, 2, 3, 4])
        #expect(numbered.geometry?.countPoints.map(\.position.x) == [400, 300, 200, 100], "positions untouched")
        #expect(numbered.geometry?.countPoints.map(\.id) == record.geometry?.countPoints.map(\.id), "mark identities kept")
        #expect(numbered.measurement?[.count]?.value == 4)

        let (off, turnsOff) = CountNumbering.toggleCommands(for: [numbered])
        #expect(!turnsOff)
        _ = try await session.applyBatch(off)
        #expect(CountNumbering.numbers(of: try #require(await session.markup(record.id))).isEmpty)

        // Undo of the "on" step restores the unnumbered record (after re-applying off, undo on).
        _ = try await session.revert(outcome.inverse)
        #expect(CountNumbering.isNumbered(await session.markup(record.id)?.geometry) == false)
    }

    @Test("A mixed selection turns numbering on for all; non-counts are skipped")
    func mixed() {
        let page = PageID(UUID()), documentID = DocumentID(UUID())
        let plain = Self.count(page, documentID, [(0, 0), (1, 1)])
        var numbered = Self.count(page, documentID, [(5, 5)])
        numbered.geometry = CountNumbering.numbered(numbered.geometry!, on: true)
        var length = plain
        length.tool = .length
        let (commands, turnsOn) = CountNumbering.toggleCommands(for: [plain, numbered, length])
        #expect(turnsOn)
        #expect(commands.count == 2)
    }
}
