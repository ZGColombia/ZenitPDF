import Foundation
import GRDB
import Testing
import ZPDFPersistence

/// The claim under test: a quantity that goes into the database comes back out with
/// every digit it had. The counter-example each case carries is what the same value
/// does through `Double`, because "store it as REAL" is the thing this design exists to
/// refuse.
struct DecimalStringTests {

    /// Values chosen because a naive binary64 round trip damages every one of them.
    static let hardValues: [String] = [
        "0.1",
        "0.3333333333333333333333333333",   // 1/3 to 28 significant digits
        "12345678901234.5678",              // 18 significant digits; binary64 carries ~15.95
        "0.30000000000000004",              // the classic 0.1 + 0.2 artefact, stored literally
        "-0.1",
        "9999999999999999999999999999",     // 28 nines
        "0.000000000000000000000000001",
        "123456789012345678901234567.8"
    ]

    @Test("Canonical strings survive a parse and a render unchanged")
    func canonicalRoundTrip() throws {
        for text in Self.hardValues {
            let value = try #require(DecimalString(text: text), "should parse \(text)")
            #expect(value.canonicalText == text, "\(text) rendered as \(value.canonicalText)")
        }
    }

    @Test("Double loses digits that Decimal keeps")
    func doubleIsNotGoodEnough() throws {
        // 12345678901234.5678 is the crisp one: binary64 has no representation for it.
        let text = "12345678901234.5678"
        let viaDouble = try #require(Double(text))
        #expect(String(viaDouble) != text)
        #expect(viaDouble == 12345678901234.568)

        let viaDecimal = try #require(DecimalString(text: text))
        #expect(viaDecimal.canonicalText == text)

        // And a third of a unit, to 28 digits.
        let third = try #require(DecimalString(text: "0.3333333333333333333333333333"))
        let thirdViaDouble = try #require(Double("0.3333333333333333333333333333"))
        #expect(third.canonicalText.count == 30)
        #expect(String(thirdViaDouble).count < third.canonicalText.count)
    }

    @Test("Values round-trip through a real SQLite column")
    func roundTripThroughDatabase() async throws {
        let directory = try TestSupport.makeTemporaryDirectory("Decimal")
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try await ProjectDatabaseActor.open(
            at: directory.appendingPathComponent("project.sqlite")
        )
        defer { Task { try? await database.close() } }

        let values = Self.hardValues
        let stored: [String] = try await database.write { db in
            try db.execute(sql: "CREATE TABLE probe (id INTEGER PRIMARY KEY, quantity TEXT NOT NULL)")
            for (index, text) in values.enumerated() {
                guard let decimal = DecimalString(text: text) else { continue }
                try db.execute(
                    sql: "INSERT INTO probe (id, quantity) VALUES (?, ?)",
                    arguments: [index, decimal]
                )
            }
            return try DecimalString
                .fetchAll(db, sql: "SELECT quantity FROM probe ORDER BY id")
                .map(\.canonicalText)
        }
        #expect(stored == values)
    }

    @Test("A measurement_value row keeps its digits across a write and a read")
    func measurementRowRoundTrip() async throws {
        let workspace = try TestSupport.makeWorkspace("DecimalRow")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let package = try await TestSupport.createPackage(workspace)
        let pageId = try await TestSupport.insertPage(into: package)
        let documentId = try await TestSupport.documentIdentifier(of: package)
        let geometry = try TestSupport.sampleGeometry()

        let planArea = try #require(DecimalString(text: "12345678901234.5678"))
        let volume = try #require(DecimalString(text: "0.3333333333333333333333333333"))

        try await package.write { db in
            try MarkupRecord(
                id: "m1", documentId: documentId, pageId: pageId,
                type: "polygon", subject: "Slab",
                geometryBlob: geometry, styleBlob: Data([0x01]),
                createdAt: TestSupport.seedTimestamp, modifiedAt: TestSupport.seedTimestamp
            ).insert(db)
            try MeasurementValueRecord(
                markupId: "m1", planAreaSi: planArea, volumeSi: volume, formulaVersion: 1
            ).insert(db)
        }
        try await package.save()

        let readBack = try await package.read { db in
            try MeasurementValueRecord.fetchOne(db, key: ["markup_id": "m1"])
        }
        let row = try #require(readBack)
        #expect(row.planAreaSi?.canonicalText == "12345678901234.5678")
        #expect(row.volumeSi?.canonicalText == "0.3333333333333333333333333333")
        try await package.close()
    }

    @Test("Exact addition, where Double drifts")
    func exactAddition() throws {
        let tenth = try #require(DecimalString(text: "0.1"))
        var total = DecimalString.zero
        for _ in 0..<10 {
            total = try #require(total.adding(tenth))
        }
        #expect(total.canonicalText == "1")

        var doubleTotal = 0.0
        for _ in 0..<10 { doubleTotal += 0.1 }
        #expect(doubleTotal != 1.0)
    }

    @Test("The parser is strict, not a prefix reader")
    func parserRejectsRubbish() {
        let rejected = [
            "", " ", "1.5; DROP TABLE markup", "12 apples", "1,5", "abc", "1.2.3",
            "--1", "1e", "+", ".", "0x10", "NaN", "inf", "1e99999"
        ]
        for text in rejected {
            #expect(DecimalString(text: text) == nil, "should have rejected \(text)")
        }
        // Decimal(string:) would have accepted several of those.
        #expect(Decimal(string: "12 apples") != nil)
    }

    @Test("A REAL in a decimal column is a decoding failure, not a laundered value")
    func realColumnIsRejected() {
        #expect(DecimalString.fromDatabaseValue(1.5.databaseValue) == nil)
        #expect(DecimalString.fromDatabaseValue(Int64(3).databaseValue) == nil)
        #expect(DecimalString.fromDatabaseValue("2.5".databaseValue)?.canonicalText == "2.5")
    }

    @Test("Codable keeps the text form")
    func codableUsesText() throws {
        let value = try #require(DecimalString(text: "12345678901234.5678"))
        let data = try JSONEncoder().encode(["quantity": value])
        #expect(String(decoding: data, as: UTF8.self).contains("\"12345678901234.5678\""))
        let decoded = try JSONDecoder().decode([String: DecimalString].self, from: data)
        #expect(decoded["quantity"] == value)
    }
}
