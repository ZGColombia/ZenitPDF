import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFAppCore

/// NL-MEASURE-03 / ADR-0030 §2: Keep existing values on a recalibration — kept, flagged stale,
/// surviving a reopen, and brought current by Recalculate Stale.
@Suite("Keep existing values (NL-MEASURE-03)")
struct NLMeasureKeepValuesTests {

    static let documentID = DocumentID(UUID())

    static func setUp() async throws -> (TakeoffSession, ZPDFContracts.PageDescriptor, MarkupID) {
        let page = ZPDFContracts.PageDescriptor(id: PageID(UUID()), documentID: documentID, index: 0, label: "A",
                                                boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 1000, height: 1000)))
        let session = try TakeoffSession(documentID: documentID, pages: [page], units: .metric)
        // 100 pt = 10 m → 0.1 m/pt.
        _ = try await session.calibrate(page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0), knownLength: 10, knownLengthUnit: .metre)
        let line = NLMeasureScaleEntryTests.length(on: page.id, from: (0, 0), to: (50, 0))
        _ = try await session.apply(.addMarkup(line))
        return (session, page, line.id)
    }

    /// Recalibrating to 100 pt = 20 m would make the 50 pt line 10 m. Keep leaves it at 5 m, at
    /// scale version 1, flagged stale; Recalculate would have made it 10 m.
    @Test("Keep leaves values and versions, flags them stale; one undo restores; Recalculate Stale makes them current")
    func keep() async throws {
        let (session, page, line) = try await Self.setUp()
        #expect(await session.markup(line)?.measurement?[.planLength]?.value == 5)
        let outcome = try await session.calibrate(
            page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 20, knownLengthUnit: .metre, keepExisting: true
        )
        let scale = try #require(await session.pageScale(page.id))
        #expect(scale.version == 2)
        let kept = try #require(await session.markup(line))
        #expect(kept.measurement?[.planLength]?.value == 5, "the value is kept")
        #expect(kept.scaleVersion == 1, "the old version is kept")
        #expect(kept.isMeasurementStale(against: scale))
        #expect(kept.measurement?.warnings.contains { $0.code == .staleScaleVersion && $0.field == .planLength } == true)
        #expect(await session.staleMeasurementIDs == [line])
        #expect(await session.keepExistingForScales.isEmpty, "the keep mark is one-shot")

        // Undo: the old scale and the unflagged record.
        let redo = try await session.revert(outcome.inverse)
        #expect(await session.pageScale(page.id)?.version == 1)
        #expect(await session.markup(line)?.measurement?.warnings.contains { $0.code == .staleScaleVersion } == false)
        _ = try await session.revert(redo)
        #expect(await session.staleMeasurementIDs == [line])

        // A new measurement is taken at the new scale: 50 pt → 10 m.
        let fresh = NLMeasureScaleEntryTests.length(on: page.id, from: (0, 10), to: (50, 10))
        _ = try await session.apply(.addMarkup(fresh))
        #expect(await session.markup(fresh.id)?.measurement?[.planLength]?.value == 10)

        // Recalculate Stale brings the kept one current.
        _ = try await session.apply(.recalculateMeasurements(pageID: nil))
        #expect(await session.markup(line)?.measurement?[.planLength]?.value == 10)
        #expect(await session.markup(line)?.scaleVersion == 2)
        #expect(await session.staleMeasurementIDs.isEmpty)
    }

    /// The persistence decision: a kept value opens as saved. Before ADR-0030 §2 hydration
    /// recomputed it under the new scale — the 5 m line reopened as 10 m.
    @Test("A kept value survives a reopen; an ordinary recalibration still recomputes")
    func survivesHydration() async throws {
        let (session, page, line) = try await Self.setUp()
        _ = try await session.calibrate(
            page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 20, knownLengthUnit: .metre, keepExisting: true
        )
        let markups = await session.orderedMarkups
        let scale = try #require(await session.pageScale(page.id))
        let reopened = try TakeoffSession(documentID: Self.documentID, pages: [page], units: .metric)
        _ = try await reopened.hydrate(
            markups: markups, scales: [scale], pageScaleIDs: [page.id: scale.id],
            calibrationEvidence: [scale.id: try #require(await session.evidence(for: scale.id))]
        )
        #expect(await reopened.markup(line)?.measurement?[.planLength]?.value == 5)
        #expect(await reopened.staleMeasurementIDs == [line])

        // Without Keep, the recalibration recomputes as it always did.
        let (plain, plainPage, plainLine) = try await Self.setUp()
        _ = try await plain.calibrate(page: plainPage.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0), knownLength: 20, knownLengthUnit: .metre)
        #expect(await plain.markup(plainLine)?.measurement?[.planLength]?.value == 10)
        #expect(await plain.staleMeasurementIDs.isEmpty)
    }

    @Test("Keep through a preset and through Apply Scale to Pages")
    func presetAndBulk() async throws {
        let (session, page, line) = try await Self.setUp()
        _ = try await session.setPresetScale(page: page.id, ratioDenominator: 50, keepExisting: true)
        #expect(await session.markup(line)?.measurement?[.planLength]?.value == 5)
        #expect(await session.staleMeasurementIDs == [line])
        _ = try await session.apply(.recalculateMeasurements(pageID: nil))
        // 50 pt at 1:50 = 50/72 in × 50 = 0.8819… m: 50 × 0.0254 × 50 / 72.
        let recomputed = NSDecimalNumber(decimal: try #require(await session.markup(line)?.measurement?[.planLength]?.value)).doubleValue
        #expect(Swift.abs(recomputed - 50 * 0.0254 * 50 / 72) < 1e-12)

        let pages = NLMeasureScaleEntryTests.pages(count: 2)
        let bulk = try TakeoffSession(documentID: NLMeasureScaleEntryTests.documentID, pages: pages, units: .metric)
        _ = try await bulk.setPresetScale(page: pages[0].id, ratioDenominator: 100)
        _ = try await bulk.setPresetScale(page: pages[1].id, ratioDenominator: 100)
        let other = NLMeasureScaleEntryTests.length(on: pages[1].id, from: (0, 0), to: (72, 0))
        _ = try await bulk.apply(.addMarkup(other))
        _ = try await bulk.setPresetScale(page: pages[0].id, ratioDenominator: 50)
        _ = try await bulk.applyScale(.copyOf(page: pages[0].id), toPages: [pages[1].id], keepExisting: true)
        // 72 pt at 1:100 = 2.54 m, kept.
        #expect(await bulk.markup(other.id)?.measurement?[.planLength]?.value == Decimal(string: "2.54"))
        #expect(await bulk.staleMeasurementIDs == [other.id])
    }
}
