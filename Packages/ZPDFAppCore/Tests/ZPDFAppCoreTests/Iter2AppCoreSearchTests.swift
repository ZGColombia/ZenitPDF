import Foundation
import Testing
import ZPDFContracts
import ZPDFQuantityLedger
import ZPDFUIPresentation
@testable import ZPDFAppCore

/// Iteration 2, appcore S-035: the Search panel's Custom Fields source finds ledger values and
/// Project Zone names.
@Suite("Iter2 appcore: Custom Fields search")
@MainActor
struct Iter2AppCoreSearchTests {

    @Test("Custom Fields finds a text value, a choice value and a zone name, and follows an edit")
    func customFieldsAreIndexed() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-it2-custom-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pdf = directory.appendingPathComponent("Floors.pdf")
        try Iter1AppCorePresenterTests.writeTextPDF(pages: 2, to: pdf)
        let documentUUID = UUID()
        let pages = DocumentSearchIndexTests.pages(count: 2, documentID: DocumentID(documentUUID))
        let index = try await DocumentSearchIndex.open(
            databaseAt: directory.appendingPathComponent("search.sqlite"), drawingAt: pdf, displayName: "Floors", pages: pages
        )
        _ = try await index.indexDrawingText()

        let material = LedgerColumnDefinition(id: ColumnID(UUID()), key: "custom.material", title: "Material", kind: .text)
        let poured = ChoiceOption(id: ChoiceOptionID(UUID()), value: "Poured")
        let method = LedgerColumnDefinition(id: ColumnID(UUID()), key: "custom.method", title: "Method", kind: .choice, choices: [poured])
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        var wall = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: DocumentID(documentUUID), pageID: pages[0].id, kind: .measurement,
            tool: .length, subject: "Wall", author: "t",
            geometry: MeasurementGeometry(pageID: pages[0].id, points: [PDFPoint(x: 10, y: 10), PDFPoint(x: 110, y: 10)]),
            customValues: [material.id: .text("Concrete C30"), method.id: .choice(poured.id)],
            createdAt: stamp, modifiedAt: stamp
        )
        // A markup with no subject, label or comment is found by its values alone.
        let bare = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: DocumentID(documentUUID), pageID: pages[1].id, kind: .measurement,
            tool: .length, subject: "", author: "t",
            geometry: MeasurementGeometry(pageID: pages[1].id, points: [PDFPoint(x: 10, y: 10), PDFPoint(x: 60, y: 10)]),
            customValues: [material.id: .text("Brick")],
            createdAt: stamp, modifiedAt: stamp
        )
        let zone = ProjectZoneDefinition(
            id: ZoneID(UUID()), name: "Level 2 East", kind: .floor, pageID: pages[1].id,
            boundary: [PDFPoint(x: 0, y: 0), PDFPoint(x: 100, y: 0), PDFPoint(x: 100, y: 100)],
            sortOrder: 0, colorRGBA: ColorRGBA(red: 0, green: 0, blue: 1, alpha: 1)
        )
        _ = try await index.indexMarkups([wall, bare], pages: pages, columns: [material, method], zones: [zone])

        let presenter = AppSearchPresenter(
            service: index.service, projectID: index.projectKey,
            identity: index.identityMap(documentUUID: documentUUID, documentTitle: "Floors", pages: pages, currentPageIndex: 0),
            scope: SearchScope(location: .currentDocument, sources: [.customFields])
        )
        presenter.debounce = .zero
        func search(_ text: String) async -> [ZPDFUIPresentation.SearchHit] {
            presenter.query = text
            presenter.runSearch()
            _ = await Iter1AppCorePresenterTests.wait(upTo: 2) { !presenter.isSearching && !presenter.hits.isEmpty }
            try? await Task.sleep(for: .milliseconds(50))
            return presenter.hits
        }

        // Old output: 0 hits for each — nothing wrote custom values or zones into the index.
        let concrete = await search("Concrete")
        #expect(concrete.map(\.markupID) == [wall.id.rawValue])
        #expect(concrete.first?.source == .customFields)
        #expect(await search("Poured").map(\.markupID) == [wall.id.rawValue], "a choice by the words the ledger shows")
        #expect(await search("Brick").map(\.markupID) == [bare.id.rawValue])
        let east = await search("East")
        #expect(east.map(\.pageID) == [pages[1].id.rawValue])
        #expect(east.first?.markupID == nil)

        // An edit of a value is incremental: the old word is gone, the new one is found.
        wall.customValues[material.id] = .text("Timber")
        _ = try await index.indexMarkups([wall, bare], pages: pages, columns: [material, method], zones: [zone])
        #expect(await search("Concrete").isEmpty)
        #expect(await search("Timber").map(\.markupID) == [wall.id.rawValue])
        // A renamed zone is found by its new name only.
        var renamed = zone
        renamed.name = "Level 2 West"
        _ = try await index.indexMarkups([wall, bare], pages: pages, columns: [material, method], zones: [renamed])
        #expect(await search("East").isEmpty)
        #expect(await search("West").map(\.pageID) == [pages[1].id.rawValue])
        // Nothing changed: nothing is written.
        let quiet = try await index.indexMarkups([wall, bare], pages: pages, columns: [material, method], zones: [renamed])
        #expect(quiet.rowsDeleted == 0 && quiet.customValueRowsInserted == 0 && quiet.zoneRowsInserted == 0)
        await index.shutDown()
    }
}
