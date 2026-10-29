import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFQuantityLedger
import ZPDFUIPresentation

/// Re-fix of T-046: the Type cell now holds the measurement tool
/// ("t:length") where it held the markup kind ("t:measurement"). A takeoff snapshot stored
/// before that change keeps the kind token, and the change report compares raw spellings, so
/// every measured row of every older snapshot read as changed, "Type: Length → Length".
@MainActor
@Suite("Iteration 3 re-fix — older snapshots and the Type cell")
struct Iter3RLedgerTypeSnapshotTests {

    struct Fixture {
        let session: TakeoffSession
        let length: MarkupID
        let area: MarkupID
        let count: MarkupID
    }

    static let documentID = DocumentID(UUID())
    static let pageID = PageID(UUID())
    static let stamp = Date(timeIntervalSince1970: 1_700_000_000)

    static func record(_ tool: MeasurementTool, subject: String, _ geometry: MeasurementGeometry) -> MarkupRecord {
        MarkupRecord(
            id: MarkupID(UUID()), documentID: documentID, pageID: pageID,
            kind: .measurement, tool: tool, subject: subject, author: "t",
            geometry: geometry, createdAt: stamp, modifiedAt: stamp
        )
    }

    static func segment(length: Double) -> MeasurementGeometry {
        MeasurementGeometry(pageID: pageID, points: [PDFPoint(x: 0, y: 300), PDFPoint(x: length, y: 300)])
    }

    /// One Length (30 pt = 3 m), one Area (10 × 50 pt = 5 m²) and one Count (3), at 100 pt = 10 m.
    static func fixture() async throws -> Fixture {
        let page = ZPDFContracts.PageDescriptor(
            id: pageID, documentID: documentID, index: 0, label: "A-101",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 1_000, height: 1_000))
        )
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        _ = try await session.calibrate(
            page: pageID, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 10, knownLengthUnit: .metre
        )
        let length = record(.length, subject: "Wall", segment(length: 30))
        let area = record(.area, subject: "Slab", MeasurementGeometry(pageID: pageID, polygons: [PolygonGeometry(outer: PolygonRing(points: [
            PDFPoint(x: 0, y: 0), PDFPoint(x: 10, y: 0), PDFPoint(x: 10, y: 50), PDFPoint(x: 0, y: 50)
        ], isClosed: true))]))
        let count = record(.count, subject: "Lights", MeasurementGeometry(pageID: pageID, countPoints: (0..<3).map { index in
            CountPoint(id: CountPointID(UUID()), position: PDFPoint(x: Double(index) * 10, y: 500))
        }))
        for markup in [length, area, count] { _ = try await session.apply(.addMarkup(markup)) }
        return Fixture(session: session, length: length.id, area: area.id, count: count.id)
    }

    /// `body` as the snapshot store holds it (`takeLedgerSnapshot` encodes with sorted keys),
    /// with every Type cell spelled as it was before T-046 — the markup kind — and decoded back.
    static func storedBeforeTheFix(_ body: LedgerSnapshotBody) throws -> (body: LedgerSnapshotBody, replaced: Int) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var json = String(decoding: try encoder.encode(body), as: UTF8.self)
        var replaced = 0
        for tool in ["length", "area", "count"] {
            let token = "\"raw\":\"t:\(tool)\""
            replaced += json.components(separatedBy: token).count - 1
            json = json.replacingOccurrences(of: token, with: "\"raw\":\"t:measurement\"")
        }
        return (try JSONDecoder().decode(LedgerSnapshotBody.self, from: Data(json.utf8)), replaced)
    }

    static let type = StandardLedgerColumn.icon.rawValue

    @Test("An older snapshot whose Type cells hold the kind (\"t:measurement\") compares clean with the same ledger")
    func olderSnapshotComparesClean() async throws {
        let fixture = try await Self.fixture()
        let now = try await fixture.session.ledgerSnapshotBody()
        let (stored, replaced) = try Self.storedBeforeTheFix(now)
        #expect(replaced == 3, "one Type cell per measured row")
        let wall = try #require(stored.rows.first { $0.markupID == fixture.length.rawValue })
        #expect(wall.cells[Self.type] == LedgerSnapshotBody.Cell(raw: "t:measurement", display: "Length"))
        #expect(now.rows.first { $0.markupID == fixture.length.rawValue }?.cells[Self.type]
                == LedgerSnapshotBody.Cell(raw: "t:length", display: "Length"))

        let report = LedgerChangeReportBuilder.report(name: "Before the fix", date: Date(), before: stored, after: now, formatter: QuantityFormatter())
        // Old output: three changed rows, each with the one field change "Type: Length → Length"
        // (and "Area → Area", "Count → Count").
        #expect(report.rows.isEmpty, "\(report.rows.map { ($0.subject, $0.fields.map { "\($0.column): \($0.before) → \($0.after)" }) })")
        #expect(report.subjectTotals.isEmpty)
        #expect(report.grandTotals.isEmpty)
    }

    @Test("Against an older snapshot a real change, an addition and a removal are still reported, and none of them names Type")
    func olderSnapshotStillReportsRealChanges() async throws {
        let fixture = try await Self.fixture()
        let (stored, _) = try Self.storedBeforeTheFix(try await fixture.session.ledgerSnapshotBody())

        // The wall grows from 30 pt to 60 pt (3 m → 6 m), the count's row leaves the ledger, and
        // a new Length (20 pt = 2 m) arrives.
        _ = try await fixture.session.apply(.editVertices(id: fixture.length, geometry: Self.segment(length: 60)))
        let added = Self.record(.length, subject: "Kerb", Self.segment(length: 20))
        _ = try await fixture.session.apply(.addMarkup(added))
        var now = try await fixture.session.ledgerSnapshotBody()
        now.rows.removeAll { $0.markupID == fixture.count.rawValue }

        let report = LedgerChangeReportBuilder.report(name: "Before the fix", date: Date(), before: stored, after: now, formatter: QuantityFormatter())
        let byID = Dictionary(report.rows.map { ($0.markupID, $0) }, uniquingKeysWith: { first, _ in first })
        #expect(report.rows.count == 3, "wall changed, kerb added, count removed; the slab is untouched")
        #expect(byID[fixture.area.rawValue] == nil)

        let wall = try #require(byID[fixture.length.rawValue])
        #expect(wall.kind == .changed)
        #expect(!wall.fields.isEmpty)
        #expect(!wall.fields.contains { $0.column == "Type" }, "\(wall.fields)")
        #expect(wall.fields.contains { $0.before.hasPrefix("3") && $0.after.hasPrefix("6") }, "the length moved 3 m → 6 m: \(wall.fields)")

        // An added or removed row still says what its Type was or is, in words.
        let kerb = try #require(byID[added.id.rawValue])
        #expect(kerb.kind == .added)
        #expect(kerb.fields.contains { $0.column == "Type" && $0.before.isEmpty && $0.after == "Length" })
        let lights = try #require(byID[fixture.count.rawValue])
        #expect(lights.kind == .removed)
        #expect(lights.fields.contains { $0.column == "Type" && $0.before == "Count" && $0.after.isEmpty })

        // Wall 3 m → 6 m is the only length total that moved; the 2 m kerb is a new subject.
        let wallTotal = try #require(report.subjectTotals.first { $0.title == "Wall" })
        #expect(wallTotal.before.value == 3)
        #expect(wallTotal.after.value == 6)
    }

    @Test("Only the old kind spelling is reconciled: any other stored Type is still a change")
    func onlyTheOldSpellingIsReconciled() async throws {
        #expect(LedgerPreToolTypeToken.isOldSpelling("measurement", of: "length"))
        #expect(LedgerPreToolTypeToken.isOldSpelling("measurement", of: "count"))
        #expect(LedgerPreToolTypeToken.isOldSpelling(canonical: "t:measurement", of: "t:area"))
        // A kind that carries no tool, a current value that is no tool, the same token, or a
        // cell that is not text.
        #expect(!LedgerPreToolTypeToken.isOldSpelling("cloud", of: "length"))
        #expect(!LedgerPreToolTypeToken.isOldSpelling("measurement", of: "cloud"))
        #expect(!LedgerPreToolTypeToken.isOldSpelling("count", of: "count"))
        #expect(!LedgerPreToolTypeToken.isOldSpelling(canonical: "o:measurement", of: "t:length"))

        let fixture = try await Self.fixture()
        let now = try await fixture.session.ledgerSnapshotBody()
        var stored = now
        stored.rows = stored.rows.map { row in
            var row = row
            if row.markupID == fixture.length.rawValue { row.cells[Self.type] = .init(raw: "t:cloud", display: "Cloud") }
            return row
        }
        let report = LedgerChangeReportBuilder.report(name: "Other", date: Date(), before: stored, after: now, formatter: QuantityFormatter())
        #expect(report.rows.count == 1)
        #expect(report.rows.first?.fields.map(\.column) == ["Type"])
        let field = try #require(report.rows.first?.fields.first)
        #expect(field.before == "Cloud")
        #expect(field.after == "Length")
    }
}
