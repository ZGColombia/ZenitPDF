import Foundation
import GRDB
import Testing
@testable import ZPDFSearch

/// IM-057: rebuild only the changed markups' full-text rows.
struct MarkupReindexTests {

    private func hits(_ text: String, _ bed: SearchTestBed) async throws -> Int {
        try await SearchService(database: bed.database).search(
            SearchRequest(text: text, scope: .project(projectId: bed.projectId), resolvesBounds: false)
        ).hits.count
    }

    @Test("IM-057: indexAnnotations(markupIds:) refreshes only the named markups")
    func onlyNamedMarkupsAreRebuilt() async throws {
        try await withSearchTestBed { bed in
            let changed = try await bed.addMarkupOnSyntheticPage(subject: "Kitchen wall", comment: "tiles")
            let untouched = try await bed.addMarkupOnSyntheticPage(subject: "Bedroom floor")
            try await bed.addCustomValue(markupId: changed, columnName: "Finish", value: "Gloss")
            let indexer = TextIndexer(database: bed.database, provider: bed.provider)
            try await indexer.indexProjectAnnotations(projectId: bed.projectId)
            #expect(try await hits("kitchen", bed) == 1)
            #expect(try await hits("gloss", bed) == 1)

            // Edit both markups in the tables; reindex only one.
            try await bed.database.write { db in
                try db.execute(sql: "UPDATE markup SET subject = 'Pantry wall', comment = NULL WHERE id = ?", arguments: [changed])
                try db.execute(sql: "UPDATE custom_value SET value_text = 'Matte' WHERE markup_id = ?", arguments: [changed])
                try db.execute(sql: "UPDATE markup SET subject = 'Hallway floor' WHERE id = ?", arguments: [untouched])
            }
            let report = try await indexer.indexAnnotations(projectId: bed.projectId, markupIds: [changed])
            #expect(report.rowsDeleted == 3)            // subject, comment, custom value
            #expect(report.markupRowsInserted == 1)     // subject only; comment is now empty
            #expect(report.customValueRowsInserted == 1)
            #expect(report.zoneRowsInserted == 0)

            #expect(try await hits("pantry", bed) == 1)
            #expect(try await hits("kitchen", bed) == 0)
            #expect(try await hits("tiles", bed) == 0)
            #expect(try await hits("matte", bed) == 1)
            #expect(try await hits("gloss", bed) == 0)
            // The markup that was not named keeps its old rows until it is.
            #expect(try await hits("bedroom", bed) == 1)
            #expect(try await hits("hallway", bed) == 0)
        }
    }

    @Test("IM-057: a deleted markup loses its rows; an empty list and an unknown project are handled")
    func deletedMarkupAndEdgeCases() async throws {
        try await withSearchTestBed { bed in
            let gone = try await bed.addMarkupOnSyntheticPage(subject: "Scaffold")
            let indexer = TextIndexer(database: bed.database, provider: bed.provider)
            try await indexer.indexProjectAnnotations(projectId: bed.projectId)
            try await bed.database.write { db in
                try db.execute(sql: "DELETE FROM markup WHERE id = ?", arguments: [gone])
            }
            let report = try await indexer.indexAnnotations(projectId: bed.projectId, markupIds: [gone, gone])
            #expect(report.rowsDeleted == 1 && report.markupRowsInserted == 0)
            #expect(try await hits("scaffold", bed) == 0)

            let empty = try await indexer.indexAnnotations(projectId: bed.projectId, markupIds: [])
            #expect(empty.rowsDeleted == 0)
            await #expect(throws: ZPDFSearchError.unknownProject(projectId: "nope")) {
                try await indexer.indexAnnotations(projectId: "nope", markupIds: [gone])
            }
        }
    }
}
