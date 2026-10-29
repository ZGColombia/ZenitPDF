import Foundation
import GRDB
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFPersistence

/// BH-075: a table import's ledger columns live in the takeoff database (schema v11
/// `custom_column.definition_json`) and come back from a reopen exactly as they were.
@Suite("Imported ledger columns persist")
struct ImportedColumnPersistenceTests {

    @Test("Import columns, save, reopen: same key, precision, display unit and values")
    func importedColumnsRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-columns-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try await OpenedFixture.open(.titleBlockSheet, in: directory)
        let package = try await ProjectPackage.create(
            at: directory.appendingPathComponent("Columns.zpdfproj", isDirectory: true),
            displayName: "Columns", originalPDF: fixture.url
        )
        defer { Task { try? await package.close() } }

        let length = LedgerColumnDefinition(
            id: ColumnID(UUID()), key: "zenit.import.length", title: "Kerb length", kind: .number,
            dimension: .length, displayUnit: .length(.millimetre), precision: .decimalPlaces(3)
        )
        let note = LedgerColumnDefinition(id: ColumnID(UUID()), key: "zenit.import.note", title: "Note", kind: .text)
        let session = try TakeoffSession(documentID: fixture.documentID, pages: fixture.pages)
        _ = try await session.apply(.addCustomColumns([length, note]))
        let page = fixture.firstPage.id
        let row = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: fixture.documentID, pageID: page, kind: .text,
            subject: "Row 1", author: "t",
            geometry: MeasurementGeometry(pageID: page, points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 10, y: 10)]),
            customValues: [
                length.id: .number(DecimalQuantity(value: Decimal(string: "2.345")!, dimension: .length)),
                note.id: .text("east kerb")
            ],
            createdAt: Date(timeIntervalSince1970: 0), modifiedAt: Date(timeIntervalSince1970: 0)
        )
        _ = try await session.apply(.addMarkup(row))
        try await TakeoffArchive.write(await session.takeoffState(), into: package)

        let stored = try #require(try await TakeoffArchive.read(from: package))
        // Old output: [] — the columns lived only in the app's attachments file.
        #expect(stored.customColumns.map(\.key) == ["zenit.import.length", "zenit.import.note"])
        let restoredLength = try #require(stored.customColumns.first)
        #expect(restoredLength.id == length.id)
        #expect(restoredLength.precision == .decimalPlaces(3))
        #expect(restoredLength.displayUnit == .length(.millimetre))
        #expect(restoredLength.dimension == .length)

        let reopened = try TakeoffSession(documentID: fixture.documentID, pages: fixture.pages)
        #expect(await reopened.restoreCustomColumns(stored.customColumns).count == 2)
        _ = try await reopened.hydrate(
            markups: stored.markups, scales: stored.scales, pageScaleIDs: stored.pageScaleIDs
        )
        let markup = try #require(await reopened.markup(row.id))
        #expect(markup.customValues[length.id] == .number(DecimalQuantity(value: Decimal(string: "2.345")!, dimension: .length)))
        #expect(markup.customValues[note.id] == .text("east kerb"))
        #expect(await reopened.ledgerColumns.column(key: "zenit.import.length")?.precision == .decimalPlaces(3))

        // An import that was undone leaves the file with the next save.
        var removal = DocumentCommandInverse()
        removal.customColumns = []
        _ = try await session.revert(removal)
        try await TakeoffArchive.write(await session.takeoffState(), into: package)
        #expect(try await TakeoffArchive.read(from: package)?.customColumns.isEmpty == true)
    }
}
