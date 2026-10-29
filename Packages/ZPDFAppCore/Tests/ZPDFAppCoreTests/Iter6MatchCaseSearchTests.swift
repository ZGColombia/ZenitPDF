import Foundation
import Testing
import ZPDFContracts
import ZPDFSearch
import ZPDFUIPresentation

@testable import ZPDFAppCore

/// W-081: the Search options' Match Case toggle reaches the query that runs.
///
/// The menu bound Match Case to `SearchScope.isCaseSensitive` and nothing read it, so flipping
/// it re-ran the same case-folded query. A real index over a real drawing answers here, the
/// way the panel's own search does.
@MainActor
@Suite("Match Case reaches the search (W-081)")
struct Iter6MatchCaseSearchTests {

    private static func wait(upTo seconds: Double = 10, for condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test("W-081: Match Case on lists only the sheet that says ROOM in capitals; off lists all three")
    func matchCaseNarrowsThePanel() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-match-case-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pdf = directory.appendingPathComponent("Plan.pdf")
        try BatchScopeWiringTests.writeTextPDF(to: pdf, pageTexts: ["ROOM 101", "room 202", "Room 303"])

        let documentUUID = UUID()
        let pages = (0..<3).map { position in
            ZPDFContracts.PageDescriptor(
                id: PageID(UUID()),
                documentID: DocumentID(documentUUID),
                index: position,
                label: "A-10\(position)",
                boxes: PageBoxes(
                    media: PDFRect(x: 0, y: 0, width: 595, height: 842),
                    crop: PDFRect(x: 0, y: 0, width: 595, height: 842)
                ),
                rotation: .degrees0
            )
        }
        let index = try await DocumentSearchIndex.open(
            databaseAt: directory.appendingPathComponent("search.sqlite"),
            drawingAt: pdf,
            displayName: "Plan",
            pages: pages
        )
        _ = try await index.indexDrawingText()
        let presenter = AppSearchPresenter(
            service: index.service,
            projectID: index.projectKey,
            identity: index.identityMap(documentUUID: documentUUID, documentTitle: "Plan", pages: pages, currentPageIndex: 0),
            scope: ZPDFUIPresentation.SearchScope(location: .entireProject)
        )
        presenter.debounce = .zero

        presenter.query = "ROOM"
        presenter.runSearch()
        #expect(await Self.wait { !presenter.isSearching && presenter.hits.count == 3 })

        // Old output: still three hits — the toggle changed `scope` and the same case-folded
        // request ran again.
        presenter.scope.isCaseSensitive = true
        presenter.runSearch()
        #expect(await Self.wait { !presenter.isSearching && presenter.hits.count == 1 })
        #expect(presenter.hits.map(\.pageID) == [pages[0].id.rawValue])

        presenter.scope.isCaseSensitive = false
        presenter.runSearch()
        #expect(await Self.wait { !presenter.isSearching && presenter.hits.count == 3 })

        await index.shutDown()
    }

    // MARK: The other drawings of a project-wide search

    /// One drawing with a real text index behind a real presenter.
    private struct Drawing {
        let index: DocumentSearchIndex
        let presenter: AppSearchPresenter
        let pages: [ZPDFContracts.PageDescriptor]
        let documentUUID: UUID
    }

    private static func makeDrawing(in directory: URL, named name: String, pageTexts: [String]) async throws -> Drawing {
        let pdf = directory.appendingPathComponent("\(name).pdf")
        try BatchScopeWiringTests.writeTextPDF(to: pdf, pageTexts: pageTexts)
        let documentUUID = UUID()
        let pages = pageTexts.indices.map { position in
            ZPDFContracts.PageDescriptor(
                id: PageID(UUID()),
                documentID: DocumentID(documentUUID),
                index: position,
                label: "\(name)-\(position)",
                boxes: PageBoxes(
                    media: PDFRect(x: 0, y: 0, width: 595, height: 842),
                    crop: PDFRect(x: 0, y: 0, width: 595, height: 842)
                ),
                rotation: .degrees0
            )
        }
        let index = try await DocumentSearchIndex.open(
            databaseAt: directory.appendingPathComponent("\(name).sqlite"),
            drawingAt: pdf,
            displayName: name,
            pages: pages
        )
        _ = try await index.indexDrawingText()
        let presenter = AppSearchPresenter(
            service: index.service,
            projectID: index.projectKey,
            identity: index.identityMap(documentUUID: documentUUID, documentTitle: name, pages: pages, currentPageIndex: 0),
            scope: ZPDFUIPresentation.SearchScope(location: .entireProject)
        )
        presenter.debounce = .zero
        return Drawing(index: index, presenter: presenter, pages: pages, documentUUID: documentUUID)
    }

    /// What the other drawing was asked and how many times it answered, so "no hits from it"
    /// is asserted after its reply landed, not before it was sent.
    @MainActor
    private final class Replies {
        var options: [ProjectSearchOptions] = []
    }

    /// Wires `other` into `front`'s fan-out the way the app tier does
    /// (`ZenitPDFProjectDocument.projectSearchSource()` and the drawing-set member sources):
    /// the source closure forwards the text and the asker's options to the other presenter.
    private static func wire(_ other: Drawing, into front: Drawing, named title: String, replies: Replies) {
        front.presenter.externalSources = [
            ProjectSearchSource(documentID: other.documentUUID, title: title) { [weak otherPresenter = other.presenter] text, options in
                let hits = await otherPresenter?.hitsForProjectSearch(text, options: options) ?? []
                replies.options.append(options)
                return hits
            }
        ]
        front.presenter.searchesAllDrawings = true
    }

    /// Runs the front panel's query and waits for its own answer and the other drawing's reply.
    private static func run(_ front: Drawing, replies: Replies) async -> Bool {
        let before = replies.options.count
        front.presenter.runSearch()
        let landed = await wait { !front.presenter.isSearching && replies.options.count == before + 1 }
        // The reply is appended on the same main-actor task right after the source returns.
        try? await Task.sleep(for: .milliseconds(50))
        return landed
    }

    @Test("W-081: Match Case reaches the other drawings — a Match Case ROOM lists no room from them")
    func matchCaseReachesTheOtherDrawings() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-match-case-fanout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let front = try await Self.makeDrawing(in: directory, named: "Level1", pageTexts: ["ROOM 101"])
        let other = try await Self.makeDrawing(in: directory, named: "Level2", pageTexts: ["room 202", "Room 303"])
        let replies = Replies()
        Self.wire(other, into: front, named: "Level 2", replies: replies)
        let presenter = front.presenter
        var external: [ZPDFUIPresentation.SearchHit] { presenter.hits.filter({ $0.sourceDocumentID != nil }) }

        presenter.query = "ROOM"
        #expect(await Self.run(front, replies: replies))
        #expect(Set(external.map(\.pageID)) == Set(other.pages.map(\.id.rawValue)), "Match Case off: both rooms of Level 2")

        // Old output: the own drawing narrowed to ROOM 101 and Level 2 still listed `room 202`
        // and `Room 303` — its source heard only the text and answered case-folded.
        presenter.scope.isCaseSensitive = true
        #expect(await Self.run(front, replies: replies))
        #expect(replies.options.last == ProjectSearchOptions(isCaseSensitive: true, isWholeWord: false))
        #expect(external.isEmpty, "Match Case on: Level 2 has no ROOM in capitals")
        #expect(presenter.hits.map(\.pageID) == [front.pages[0].id.rawValue])

        presenter.scope.isCaseSensitive = false
        #expect(await Self.run(front, replies: replies))
        #expect(external.count == 2, "Match Case off again: Level 2's rooms come back")

        // The other drawing's own panel is not what decides: its Match Case on changes nothing
        // about the answer it gives the front drawing's case-folded question.
        other.presenter.scope.isCaseSensitive = true
        #expect(await Self.run(front, replies: replies))
        #expect(external.count == 2, "the answering panel's own toggles do not narrow another drawing's search")

        await front.index.shutDown()
        await other.index.shutDown()
    }

    @Test("W-081: Whole Word reaches the other drawings — ROOM no longer lists ROOMSCHEDULE from them")
    func wholeWordReachesTheOtherDrawings() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-whole-word-fanout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let front = try await Self.makeDrawing(in: directory, named: "Level1", pageTexts: ["ROOM 101"])
        let other = try await Self.makeDrawing(in: directory, named: "Level2", pageTexts: ["ROOMSCHEDULE 9", "room 202"])
        let replies = Replies()
        Self.wire(other, into: front, named: "Level 2", replies: replies)
        let presenter = front.presenter
        var external: [ZPDFUIPresentation.SearchHit] { presenter.hits.filter({ $0.sourceDocumentID != nil }) }

        presenter.query = "ROOM"
        #expect(await Self.run(front, replies: replies))
        #expect(external.count == 2, "find-as-you-type: ROOM is a prefix of ROOMSCHEDULE")

        // Old output: still both — the fan-out always ran find-as-you-type.
        presenter.scope.isWholeWord = true
        #expect(await Self.run(front, replies: replies))
        #expect(replies.options.last == ProjectSearchOptions(isCaseSensitive: false, isWholeWord: true))
        #expect(external.map(\.pageID) == [other.pages[1].id.rawValue], "Whole Word: only `room 202`")

        presenter.scope.isCaseSensitive = true
        #expect(await Self.run(front, replies: replies))
        #expect(external.isEmpty, "Whole Word and Match Case: no capital ROOM token on Level 2")

        await front.index.shutDown()
        await other.index.shutDown()
    }
}
