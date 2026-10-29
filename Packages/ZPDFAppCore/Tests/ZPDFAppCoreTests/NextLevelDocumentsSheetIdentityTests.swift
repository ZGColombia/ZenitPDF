import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFPersistence
import ZPDFTestingSupport

/// NL-DOCS-05: sheet identity — number, title, source — as undoable, persisted data over the
/// page (ADR-0022). Recognition is the title-block reader's; this is the model it writes through.
struct NextLevelDocumentsSheetIdentityTests {

    private func workspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-nl-docs-sheets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Naming is one undo step; an automatic reading never replaces a typed name")
    @MainActor
    func namingUndoAndManualWins() async throws {
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try await OpenedFixture.open(.set30SheetsTitleBlocks, in: directory)
        let session = try TakeoffSession(documentID: fixture.documentID, pages: fixture.pages)
        let environment = try await AppCoreEnvironment.make(session: session, documentID: fixture.documentID)
        let p0 = fixture.pages[0].id, p1 = fixture.pages[1].id

        _ = try await environment.commands.perform(.setSheetIdentities([
            p0: SheetIdentity(number: "A-101", title: "SITE PLAN", source: .titleBlockText),
            p1: SheetIdentity(number: "A-102", title: "FLOOR PLAN LEVEL 1", source: .titleBlockText)
        ], overwriteManual: false))
        #expect(await session.sheetIdentity(of: p0)?.displayName == "A-101 · SITE PLAN")
        #expect(await session.sheetIdentity(of: p0)?.discipline == "A")

        await environment.refresh()
        #expect(environment.document.pages[0].sheetTitle == "A-101 · SITE PLAN")
        #expect(environment.document.pages[0].sheetNumber == "A-101")
        // The sheet number as a typed destination ("a102" reaches A-102) is the shell's rule,
        // `StatusBarDisplay.pageDestination(forTyped:pages:)`, over these published pages (T-033).
        #expect(environment.document.pages[1].sheetNumber == "A-102")

        // A person renames A-102; a second automatic pass leaves that name alone.
        _ = try await environment.commands.perform(.setSheetIdentities([
            p1: SheetIdentity(number: "A-102", title: "GROUND FLOOR", source: .manual)
        ], overwriteManual: true))
        _ = try await environment.commands.perform(.setSheetIdentities([
            p1: SheetIdentity(number: "A-102", title: "FLOOR PLAN LEVEL 1", source: .titleBlockOCR)
        ], overwriteManual: false))
        #expect(await session.sheetIdentity(of: p1)?.title == "GROUND FLOOR")

        await environment.commands.undo()   // the refused pass registered nothing
        #expect(await session.sheetIdentity(of: p1)?.title == "FLOOR PLAN LEVEL 1", "undo took back the manual rename")
        await environment.commands.undo()
        #expect(await session.sheetIdentity(of: p0) == nil, "undo took back the whole batch")
    }

    @Test("A number two sheets share is no destination; comparison ignores case and separators")
    func duplicatesAndMatching() async throws {
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try await OpenedFixture.open(.set30SheetsTitleBlocks, in: directory)
        let session = try TakeoffSession(documentID: fixture.documentID, pages: fixture.pages)
        _ = try await session.apply(.setSheetIdentities([
            fixture.pages[0].id: SheetIdentity(number: "S-201", title: nil, source: .titleBlockText),
            fixture.pages[1].id: SheetIdentity(number: "s 201", title: nil, source: .titleBlockText),
            fixture.pages[2].id: SheetIdentity(number: "M-301", title: nil, source: .titleBlockText)
        ], overwriteManual: false))
        #expect(await session.page(withSheetNumber: "S201") == nil, "two sheets claim it: no guess")
        #expect(await session.page(withSheetNumber: "m-301") == fixture.pages[2].id)
        #expect(SheetIdentity.discipline(of: "FP2.01") == "FP")
        #expect(SheetIdentity(number: "  ", title: " ", source: .manual).isEmpty)
    }

    @Test("Names survive save and reopen, with their source")
    func namesSurviveReopen() async throws {
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try await OpenedFixture.open(.set30SheetsTitleBlocks, in: directory)
        let session = try TakeoffSession(documentID: fixture.documentID, pages: fixture.pages)
        let named = fixture.pages[12].id
        _ = try await session.apply(.setSheetIdentities([
            named: SheetIdentity(number: "S-203", title: "FRAMING PLAN LEVEL 2", source: .titleBlockOCR)
        ], overwriteManual: false))
        let packageURL = directory.appendingPathComponent("Names.zpdfproj", isDirectory: true)
        let package = try await ProjectPackage.create(at: packageURL, displayName: "Names", originalPDF: fixture.url)
        try await TakeoffArchive.write(await session.takeoffState(), into: package)
        _ = try await package.save()
        try await package.close()
        guard case .opened(let reopened) = try await ProjectPackage.open(at: packageURL) else {
            Issue.record("reopen required recovery"); return
        }
        let stored = try #require(try await TakeoffArchive.read(from: reopened))
        try await reopened.close()
        let adopted = TakeoffArchive.adoptingStoredPageIDs(fixture.pages, stored: stored)
        let restored = try TakeoffSession(documentID: DocumentID(UUID()), pages: adopted)
        await restored.restoreSheetIdentities(stored.sheetIdentities)
        let identity = try #require(await restored.sheetIdentity(of: named))
        #expect(identity == SheetIdentity(number: "S-203", title: "FRAMING PLAN LEVEL 2", source: .titleBlockOCR))
        #expect(await restored.sheetIdentities.count == 1)
    }
}
