import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFTestingSupport

/// NL-DOCS-12 foundation: carrying measurements to the next revision's sheet, re-measured,
/// classified, reported, and undone in one step. Expected values derived by hand in the comments.
struct NextLevelDocumentsCarryForwardTests {

    private func length(_ page: ZPDFContracts.PageDescriptor, _ documentID: DocumentID, from: PDFPoint, points: Double, subject: String) -> ZPDFContracts.MarkupRecord {
        ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: documentID, pageID: page.id, kind: .measurement, tool: .polylength,
            subject: subject,
            geometry: MeasurementGeometry(pageID: page.id, points: [from, PDFPoint(x: from.x + points, y: from.y)]),
            createdAt: Date(timeIntervalSince1970: 1_790_000_000), modifiedAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
    }

    @Test("Carried lengths land through the alignment, are re-measured, classified and reported; one undo")
    @MainActor
    func carryForward() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-nl-docs-carry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try await OpenedFixture.open(.set30SheetsTitleBlocks, in: directory)
        let pages = fixture.pages
        let session = try TakeoffSession(documentID: fixture.documentID, pages: pages, units: .metric)
        // 100 pt = 1 m on every sheet involved.
        for page in pages.prefix(4) {
            _ = try await session.calibrate(page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
                                            knownLength: 1, knownLengthUnit: .metre)
        }
        let l1 = length(pages[0], fixture.documentID, from: PDFPoint(x: 100, y: 100), points: 200, subject: "L1")
        let l2 = length(pages[0], fixture.documentID, from: PDFPoint(x: 100, y: 500), points: 300, subject: "L2")
        let l3 = length(pages[2], fixture.documentID, from: PDFPoint(x: 100, y: 900), points: 200, subject: "L3")
        for record in [l1, l2, l3] { _ = try await session.apply(.addMarkup(record)) }
        let environment = try await AppCoreEnvironment.make(session: session, documentID: fixture.documentID)

        // Rev B: A-101's drawing shifted by (10, 5) on A-102, and changed around L2's new place
        // (L2 lands on y = 505, x 110…410). A-103's drawing is at half size on A-104.
        let pairs: [PageID: CarryPair] = [
            pages[0].id: CarryPair(target: pages[1].id, alignment: PageAlignment(dx: 10, dy: 5),
                                   changedRegions: [PDFRect(x: 200, y: 495, width: 50, height: 20)]),
            pages[2].id: CarryPair(target: pages[3].id, alignment: PageAlignment(scale: 0.5))
        ]
        let source = await session.orderedMarkups
        let plan = CarryForwardPlanner.plan(markups: source, pairs: pairs, now: Date(timeIntervalSince1970: 1_790_000_100))
        #expect(plan.items.map(\.classification) == [.moved, .needsReview, .moved])
        #expect(plan.skipped.isEmpty)
        _ = try await environment.commands.performBatch(plan.commands, actionName: "Carry Forward")

        var carried: [MarkupID: ZPDFContracts.MarkupRecord] = [:]
        for item in plan.items { carried[item.carriedID] = await session.markup(item.carriedID) }
        // L1: (100, 100)→(110, 105) and (300, 100)→(310, 105): residual 0 pt, far inside 1 pt.
        let first = try #require(carried[plan.items[0].carriedID]?.geometry?.points)
        #expect(first == [PDFPoint(x: 110, y: 105), PDFPoint(x: 310, y: 105)])
        #expect(carried[plan.items[0].carriedID]?.pageID == pages[1].id)

        let report = CarryForwardReport.make(
            plan: plan,
            source: Dictionary(uniqueKeysWithValues: source.map { ($0.id, $0) }),
            carried: carried
        )
        // L1 2 m → 2 m, L2 3 m → 3 m (translation keeps length); L3 200 pt = 2 m → 100 pt = 1 m.
        #expect(report.rows.map(\.oldValue) == [2, 3, 2])
        #expect(report.rows.map(\.newValue) == [2, 3, 1])
        #expect(report.rows.map(\.delta) == [0, 0, -1])
        #expect(report.totalDelta[.planLength] == -1)
        #expect(await session.orderedMarkups.count == 6, "the old revision keeps its markups")

        await environment.commands.undo()
        #expect(await session.orderedMarkups.map(\.id) == [l1.id, l2.id, l3.id], "one undo reverts the whole carry")
    }

    @Test("A cutout is carried with its parent; a markup on an unpaired sheet is skipped")
    func cutoutsAndSkips() {
        let documentID = DocumentID(UUID())
        let old = PageID(UUID()), new = PageID(UUID()), other = PageID(UUID())
        func record(_ page: PageID, parent: MarkupID? = nil) -> ZPDFContracts.MarkupRecord {
            var r = ZPDFContracts.MarkupRecord(
                id: MarkupID(UUID()), documentID: documentID, pageID: page, kind: .measurement, tool: .area, subject: "A",
                geometry: MeasurementGeometry(pageID: page, points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 10, y: 0), PDFPoint(x: 10, y: 10)]),
                createdAt: Date(), modifiedAt: Date()
            )
            r.parentMarkupID = parent
            return r
        }
        let parent = record(old)
        let cutout = record(old, parent: parent.id)
        let stray = record(other)
        let plan = CarryForwardPlanner.plan(markups: [cutout, parent, stray], pairs: [old: CarryPair(target: new, alignment: .identity)], now: Date())
        #expect(plan.items.map(\.sourceID) == [parent.id, cutout.id], "parent first, then its cutout")
        #expect(plan.items.allSatisfy { $0.classification == .unchanged })
        #expect(plan.skipped == [stray.id])
        guard case let .addCutout(carriedParent, _) = plan.commands.last else {
            Issue.record("the cutout must be carried as a cutout"); return
        }
        #expect(carriedParent == plan.items[0].carriedID)
    }
}
