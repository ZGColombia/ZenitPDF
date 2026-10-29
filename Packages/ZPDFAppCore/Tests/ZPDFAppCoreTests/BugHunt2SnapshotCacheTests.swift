import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFQuantityLedger
import ZPDFUIPresentation

/// IM-001 and IM-002: the session keeps its ledger view and its markup summaries between
/// snapshots and updates only what changed. Those are the quantity and aggregation paths, so the
/// claim tested here is not "faster" first but **identical**: after every step of a random
/// command sequence the cached projection equals a projection built from nothing, row for row,
/// group for group, total for total, and the cached summaries equal freshly rendered ones.
@Suite("Bug hunt 2: snapshot caches")
struct BugHunt2SnapshotCacheTests {

    /// A deterministic generator, so a failing sequence can be replayed.
    private struct Generator {
        var state: UInt64
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(max(1, bound)))
        }
    }

    private static func page(_ documentID: DocumentID) -> ZPDFContracts.PageDescriptor {
        ZPDFContracts.PageDescriptor(
            id: PageID(UUID()), documentID: documentID, index: 0, label: "A-101",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 2_000, height: 2_000))
        )
    }

    private static func record(
        _ generator: inout Generator,
        documentID: DocumentID,
        page: PageID
    ) -> ZPDFContracts.MarkupRecord {
        let x = Double(generator.next(1_500)), y = Double(generator.next(1_500))
        let w = Double(10 + generator.next(200)), h = Double(10 + generator.next(200))
        let subjects = ["Slab", "Wall", "Door", "Beam", ""]
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let geometry: MeasurementGeometry
        let tool: MeasurementTool
        let kind: ZPDFContracts.MarkupKind
        switch generator.next(4) {
        case 0:
            tool = .length; kind = .measurement
            geometry = MeasurementGeometry(pageID: page, points: [PDFPoint(x: x, y: y), PDFPoint(x: x + w, y: y + h)])
        case 1:
            tool = .count; kind = .count
            geometry = MeasurementGeometry(pageID: page, countPoints: (0..<(1 + generator.next(5))).map {
                CountPoint(id: CountPointID(UUID()), position: PDFPoint(x: x + Double($0), y: y))
            })
        default:
            tool = .area; kind = .measurement
            geometry = MeasurementGeometry(pageID: page, polygons: [PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: x, y: y), PDFPoint(x: x + w, y: y), PDFPoint(x: x + w, y: y + h), PDFPoint(x: x, y: y + h)
            ], isClosed: true))])
        }
        return ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: documentID, pageID: page, kind: kind, tool: tool,
            subject: subjects[generator.next(subjects.count)], author: "t", geometry: geometry,
            createdAt: stamp, modifiedAt: stamp
        )
    }

    /// The four views the ledger is asked for: flat, grouped, sorted, filtered.
    private static func requests(_ columns: LedgerColumnSet) throws -> [LedgerRequest] {
        let subject = LedgerColumnID(try #require(columns.column(standard: .subject)).key)
        let area = LedgerColumnID(try #require(columns.column(standard: .planArea)).key)
        return [
            .flat,
            LedgerRequest(grouping: [subject]),
            LedgerRequest(sort: [ZPDFUIPresentation.LedgerSortDescriptor(column: area, ascending: false)]),
            LedgerRequest(filter: LedgerFilterGroup(id: UUID(), rules: [
                LedgerFilterRule(id: UUID(), column: subject, comparison: .contains, operand: .text("a"))
            ]))
        ]
    }

    /// The projection built from nothing — the path every snapshot used to take.
    private static func fresh(_ session: TakeoffSession, _ request: LedgerRequest) async throws -> LedgerProjection {
        let store = try LedgerStore(
            markups: await session.ledgerMarkups,
            columns: await session.ledgerColumns,
            names: await session.nameTable.ledgerCatalog,
            quantityMultiplierColumn: RepetitionColumn.columnID
        )
        let translation = LedgerSpecBuilder.translate(request, columns: store.columns)
        return LedgerBridge.project(
            store.makeView(translation.spec),
            formatter: await session.snapshotFormatter,
            unappliedFilterRules: translation.unappliedFilterRules
        )
    }

    private static func expectSame(_ cached: LedgerProjection, _ built: LedgerProjection, step: Int) {
        #expect(cached.rowCount == built.rowCount, "step \(step): row count")
        #expect(cached.grandTotals == built.grandTotals, "step \(step): grand totals")
        #expect(cached.rootGroups == built.rootGroups, "step \(step): groups and subtotals")
        for index in 0..<min(cached.rowCount, built.rowCount) where cached.row(at: index) != built.row(at: index) {
            Issue.record("step \(step): row \(index) differs")
            return
        }
    }

    @Test("After every step of a random command sequence, the cached ledger and summaries equal a fresh build")
    func incrementalEqualsFull() async throws {
        let documentID = DocumentID(UUID())
        let page = Self.page(documentID)
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        _ = try await session.calibrate(
            page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 10, knownLengthUnit: .metre
        )
        var generator = Generator(state: 0x5EED)
        var inverses: [DocumentCommandInverse] = []
        for _ in 0..<12 {
            let outcome = try await session.apply(.addMarkup(Self.record(&generator, documentID: documentID, page: page.id)))
            inverses.append(outcome.inverse)
        }

        for step in 0..<160 {
            let ids = await session.orderedMarkups.map(\.id)
            let target = ids.isEmpty ? nil : ids[generator.next(ids.count)]
            let command: DocumentCommand?
            switch generator.next(10) {
            case 0, 1:
                command = .addMarkup(Self.record(&generator, documentID: documentID, page: page.id))
            case 2:
                command = target.map { .editSubject(id: $0, subject: ["Slab", "Wall", "Door", "Roof", ""][generator.next(5)]) }
            case 3:
                command = target.map { .moveMarkup(id: $0, dx: Double(generator.next(40)) - 20, dy: 3) }
            case 4:
                command = target.map { RepetitionColumn.edit(markupID: $0, count: 1 + generator.next(4)) }
            case 5:
                command = target.map { .removeMarkup($0) }
            case 6:
                command = .batchStatusChange(ids: Array(ids.prefix(generator.next(ids.count + 1))), status: .open)
            case 7:
                command = nil
                if let last = inverses.popLast() { _ = try? await session.revert(last) }
            case 8:
                command = nil
                _ = try await session.calibrate(
                    page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
                    knownLength: Decimal(5 + generator.next(20)), knownLengthUnit: .metre
                )
            default:
                command = target.map { .editLabel(id: $0, label: "L\(step)") }
                if generator.next(8) == 0 { try await session.setUnits(generator.next(2) == 0 ? .imperial : .metric) }
            }
            if let command, let outcome = try? await session.apply(command) {
                inverses.append(outcome.inverse)
            }

            for request in try Self.requests(await session.ledgerColumns) {
                let cached = try await session.ledgerProjection(request)
                let built = try await Self.fresh(session, request)
                Self.expectSame(cached, built, step: step)
            }
            let snapshot = try await session.snapshot()
            let names = await session.nameTable
            let formatter = await session.snapshotFormatter
            let expected = await session.orderedMarkups.map { MarkupBridge.summary(of: $0, names: names, formatter: formatter) }
            #expect(snapshot.markups == expected, "step \(step): summaries")
            #expect(snapshot.derivations == (await session.derivationSections()), "step \(step): derivations")
        }
    }

    @Test("One subject edit on 5 000 markups costs one row, not the whole takeoff")
    func singleEditIsCheap() async throws {
        let documentID = DocumentID(UUID())
        let page = Self.page(documentID)
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        _ = try await session.calibrate(
            page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 10, knownLengthUnit: .metre
        )
        var generator = Generator(state: 42)
        var records: [ZPDFContracts.MarkupRecord] = []
        for _ in 0..<5_000 { records.append(Self.record(&generator, documentID: documentID, page: page.id)) }
        _ = try await session.applyBatch(records.map { .addMarkup($0) })
        _ = try await session.snapshot()

        let clock = ContinuousClock()
        let target = try #require(records.first { !$0.subject.isEmpty })
        _ = try await session.apply(.editSubject(id: target.id, subject: "Renamed"))
        let incremental = try await clock.measure { _ = try await session.snapshot() }

        // The old path, measured in the same process: a fresh store and view plus every summary.
        let full = try await clock.measure {
            _ = try await Self.fresh(session, .flat)
            let names = await session.nameTable
            let formatter = await session.snapshotFormatter
            _ = await session.orderedMarkups.map { MarkupBridge.summary(of: $0, names: names, formatter: formatter) }
            _ = await session.derivationSections()
        }
        print("IM-001/IM-002 snapshot after one edit, 5 000 markups: incremental \(incremental), full rebuild \(full)")
        #expect(incremental < full, "incremental \(incremental) vs full \(full)")
        let row = try await session.ledgerProjection(.flat)
        let position = try #require(row.positionByMarkupID[target.id.rawValue])
        #expect(row.row(at: position)?.displayValue("subject") == "Renamed")
    }
}
