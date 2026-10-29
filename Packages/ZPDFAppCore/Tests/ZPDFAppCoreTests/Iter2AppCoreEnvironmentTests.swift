import Foundation
import Testing
import ZPDFContracts
import ZPDFUIPresentation
@testable import ZPDFAppCore

/// Iteration 2, appcore: the warning tray (S-029, S-032) and Search across windows (S-033).
@Suite("Iter2 appcore: environment")
@MainActor
struct Iter2AppCoreEnvironmentTests {

    static func environment(pages count: Int = 1) async throws -> (AppCoreEnvironment, [ZPDFContracts.PageDescriptor]) {
        let documentID = DocumentID(UUID())
        let pages = (0..<count).map { index in
            ZPDFContracts.PageDescriptor(
                id: PageID(UUID()), documentID: documentID, index: index, label: "A-10\(index + 1)",
                boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 612, height: 792))
            )
        }
        let session = try TakeoffSession(documentID: documentID, pages: pages)
        return (try await AppCoreEnvironment.make(session: session, documentID: documentID), pages)
    }

    static func warning(_ title: String, id: UUID = UUID()) -> AppWarning {
        AppWarning(id: id, severity: .warning, title: title, message: "", source: "Test", isDismissible: true, timestamp: Date())
    }

    // MARK: S-029

    @Test("A warning dismissed in the tray stays dismissed after the next post and the next refresh")
    func trayDismissalLasts() async throws {
        let (environment, _) = try await Self.environment()
        let first = Self.warning("First")
        let second = Self.warning("Second")
        environment.document.post(first)
        environment.document.post(second)
        #expect(Set(environment.status.warnings.map(\.id)) == [first.id, second.id])

        environment.status.dismissWarning(id: first.id)
        #expect(environment.status.warnings.map(\.id) == [second.id])
        #expect(environment.document.warnings.map(\.id) == [second.id], "the document presenter dropped it too")

        // Old output: after this post the tray read [First, Second, Third] again — the document's
        // list, dismissed warning included, was pushed back into the tray.
        environment.document.post(Self.warning("Third"))
        #expect(!environment.status.warnings.contains { $0.id == first.id })
        await environment.refresh()
        #expect(!environment.status.warnings.contains { $0.id == first.id })

        // Dismiss All empties both lists, and a refresh brings nothing back.
        environment.status.dismissAllWarnings()
        #expect(environment.status.warnings.isEmpty)
        #expect(environment.document.warnings.isEmpty)
        await environment.refresh()
        #expect(environment.status.warnings.isEmpty)
    }

    @Test("A second window's tray dismissal reaches the one tray every window shows")
    func secondWindowDismissalReachesTheOwner() async throws {
        let (root, _) = try await Self.environment()
        let view = try await AppCoreEnvironment.makeWindowView(of: root)
        let warning = Self.warning("Shared")
        root.document.post(warning)
        #expect(view.status.warnings.map(\.id) == [warning.id])
        view.status.dismissWarning(id: warning.id)
        #expect(root.document.warnings.isEmpty)
        #expect(root.status.warnings.isEmpty)
        #expect(view.status.warnings.isEmpty)
        root.document.post(Self.warning("Later"))
        #expect(!view.status.warnings.contains { $0.id == warning.id })
    }

    @Test("Dismissing a warning that is not there announces nothing")
    func noOpDismissalIsQuiet() async throws {
        let (environment, _) = try await Self.environment()
        var announcements = 0
        let wired = environment.document.onWarningsChange
        environment.document.onWarningsChange = { warnings in
            announcements += 1
            wired?(warnings)
        }
        // Old output: 1 — every refresh's dismissal of the refresh-failure warning re-announced the list.
        environment.document.dismissWarning(id: AppCoreEnvironment.refreshFailureWarningID)
        environment.document.dismissAllWarnings()
        #expect(announcements == 0)
    }

    // MARK: S-032

    @Test("Every fixed AppCore warning identity is distinct, so none replaces another")
    func staticWarningIDsAreDistinct() {
        let ids: [String: UUID] = [
            "commitFailure": AppCoreEnvironment.commitFailureWarningID,
            "refreshFailure": AppCoreEnvironment.refreshFailureWarningID,
            "hydrationRepair": AppCoreEnvironment.hydrationRepairWarningID,
            "columnRefusal": AppCoreEnvironment.columnRefusalWarningID,
            "snapSettings": AppCoreEnvironment.snapSettingsWarningID,
            "unevaluatedScaleRegions": AppCoreEnvironment.unevaluatedScaleRegionsWarningID,
            "pasteHeldForScaleDecision": AppCoreEnvironment.pasteHeldForScaleDecisionWarningID
        ]
        // Old output: 6 distinct of 7 — unevaluatedScaleRegions and columnRefusal were both …1A04.
        #expect(Set(ids.values).count == ids.count)
    }

    @Test("The Scale Region warning no longer replaces the held-column warning")
    func scaleRegionWarningKeepsTheColumnWarning() async throws {
        let (environment, _) = try await Self.environment()
        environment.document.post(Self.warning("Column held", id: AppCoreEnvironment.columnRefusalWarningID))
        environment.reportUnevaluatedScaleRegions(CancellationError())
        // Old output: only the Scale Region warning — same identity, so `post` removed the other.
        #expect(Set(environment.document.warnings.map(\.id)) == [
            AppCoreEnvironment.columnRefusalWarningID, AppCoreEnvironment.unevaluatedScaleRegionsWarningID
        ])
    }

    // MARK: S-033

    @Test("With two windows, Current Page is the sheet of the window that has focus")
    func currentPageFollowsTheFocusedWindow() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-it2-search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pdf = directory.appendingPathComponent("Floors.pdf")
        try Iter1AppCorePresenterTests.writeTextPDF(pages: 3, to: pdf)
        let documentUUID = UUID()
        let pages = DocumentSearchIndexTests.pages(count: 3, documentID: DocumentID(documentUUID))
        let index = try await DocumentSearchIndex.open(
            databaseAt: directory.appendingPathComponent("search.sqlite"), drawingAt: pdf, displayName: "Floors", pages: pages
        )
        _ = try await index.indexDrawingText()
        let presenter = AppSearchPresenter(
            service: index.service, projectID: index.projectKey,
            identity: index.identityMap(documentUUID: documentUUID, documentTitle: "Floors", pages: pages, currentPageIndex: 0),
            scope: SearchScope(location: .currentPage)
        )
        presenter.debounce = .zero
        let session = try TakeoffSession(documentID: DocumentID(documentUUID), pages: pages)
        let root = try await AppCoreEnvironment.make(session: session, documentID: DocumentID(documentUUID))
        root.attachSearch(presenter)
        root.document.goToPage(id: pages[2].id.rawValue)
        root.takeSearchFocus()

        // A second window opens on sheet 3, takes focus, and turns to sheet 1.
        let view = try await AppCoreEnvironment.makeWindowView(of: root)
        view.takeSearchFocus()
        view.document.goToPage(id: pages[0].id.rawValue)
        #expect(presenter.currentPageID == pages[0].id.rawValue)

        // Back in window 1, still on sheet 3. Old output: the scope stayed on sheet 1, window 2's.
        root.takeSearchFocus()
        #expect(presenter.currentPageID == pages[2].id.rawValue)
        // Window 2 turns a page while window 1 has focus: the scope stays on window 1's sheet.
        view.document.goToPage(id: pages[1].id.rawValue)
        #expect(presenter.currentPageID == pages[2].id.rawValue)

        presenter.query = "SCREED"
        presenter.runSearch()
        #expect(await Iter1AppCorePresenterTests.wait { !presenter.isSearching && !presenter.hits.isEmpty })
        #expect(presenter.hits.map(\.pageID) == [pages[2].id.rawValue], "only window 1's sheet 3")
        await index.shutDown()
    }
}
