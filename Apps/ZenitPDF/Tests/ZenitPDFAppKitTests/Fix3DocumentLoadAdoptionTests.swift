import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
import ZPDFAppCore
import ZPDFPersistence
@testable import ZenitPDFAppKit

/// IM-047: a document load builds one `LoadedDocumentState` off to the side and the document
/// adopts it in a single synchronous step. Old behaviour: `load()` assigned the package, drawing,
/// container autosave, core and search index onto the document between awaits, so a failure or a
/// close mid-load left whatever had been assigned so far on a document that never finished.
@MainActor
@Suite(.appTierSerialised)
struct Fix3DocumentLoadAdoptionTests {

    struct InjectedFailure: Error, Equatable {
        let stage: DocumentLoadStage
    }

    /// What the stage hook saw, kept in a reference so the hook can write to it.
    @MainActor
    final class Recorder {
        var reached: [DocumentLoadStage] = []
        var state: LoadedDocumentState?
        /// Whether the document held any load resource of its own while the load ran.
        var documentHeldSomethingMidLoad = false
        var released = 0
        /// Observations a test's stage handler makes mid-load.
        var flags: [String: Bool] = [:]
        weak var document: ZenitPDFProjectDocument?
    }

    private func document(
        opening url: URL,
        ofType type: String = UTType.pdf.identifier,
        recorder: Recorder,
        onStage: @escaping @MainActor (DocumentLoadStage, ZenitPDFProjectDocument) async throws -> Void
    ) throws -> ZenitPDFProjectDocument {
        let document = ZenitPDFProjectDocument()
        try document.read(from: url, ofType: type)
        recorder.document = document
        document.scopedAccessRelease = { [recorder] in recorder.released += 1 }
        document.loadStageHook = { [recorder] stage, state in
            recorder.reached.append(stage)
            recorder.state = state
            if let document = recorder.document,
               document.core != nil || document.shell != nil || document.drawing != nil
                || document.projectPackage != nil || document.searchIndex != nil {
                recorder.documentHeldSomethingMidLoad = true
            }
            if let document = recorder.document { try await onStage(stage, document) }
        }
        return document
    }

    /// A project package on disk, closed clean: no crash marker, a working PDF inside.
    private func makeProject(_ name: String) async throws -> URL {
        let pdf = try AppTestSupport.writeFixturePDF(named: "\(name).pdf")
        let url = pdf.deletingLastPathComponent().appendingPathComponent("\(name).zpdfproj", isDirectory: true)
        let package = try await ProjectPackage.create(at: url, displayName: name, originalPDF: pdf, pageCount: 1)
        _ = try await package.save()
        try await package.close()
        #expect(!FileManager.default.fileExists(atPath: url.member(ProjectPackageLayout.crashMarker).path))
        return url
    }

    /// Every test here opens the same fixture bytes: a private autosave root keeps another
    /// test's container autosave from turning into a restore offer mid-load.
    private func isolateAutosaveRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-im047-\(UUID().uuidString)", isDirectory: true)
        ZenitPDFProjectDocument.quickPDFAutosaveRootOverride = root
        return root
    }

    private func restoreAutosaveRoot(_ root: URL) {
        ZenitPDFProjectDocument.quickPDFAutosaveRootOverride = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func expectNothingAdopted(_ document: ZenitPDFProjectDocument, _ comment: Comment) {
        #expect(document.core == nil, comment)
        #expect(document.shell == nil, comment)
        #expect(document.drawing == nil, comment)
        #expect(document.projectPackage == nil, comment)
        #expect(document.searchIndex == nil, comment)
        #expect(document.photoStore == nil, comment)
        #expect(document.pendingLoad == nil, comment)
        #expect(!document.hasOpenStorage, comment)
    }

    // MARK: - A failing load

    @Test("IM-047: a load that fails at any stage adopts nothing, closes what it built, and keeps scoped access for the close",
          arguments: DocumentLoadStage.allCases)
    func failingLoadAdoptsNothing(stage: DocumentLoadStage) async throws {
        let autosaveRoot = isolateAutosaveRoot()
        defer { restoreAutosaveRoot(autosaveRoot) }
        let url = try AppTestSupport.writeFixturePDF(named: "IM047-Fail-\(stage.rawValue).pdf")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let recorder = Recorder()
        let document = try document(opening: url, recorder: recorder) { current, _ in
            if current == stage { throw InjectedFailure(stage: stage) }
        }
        document.startLoadingIfNeeded()
        #expect(await AppTestSupport.wait { !document.isLoading })

        #expect((document.loadFailure as? InjectedFailure) == InjectedFailure(stage: stage))
        #expect(recorder.reached.last == stage, "the load stopped at the stage that failed")
        #expect(!recorder.documentHeldSomethingMidLoad, "nothing reaches the document before adoption")
        expectNothingAdopted(document, "failed at \(stage)")
        let state = try #require(recorder.state)
        #expect(state.isShutDown && !state.isAdopted)
        #expect(!state.holdsResources, "the pipeline closes what it built when it fails")
        #expect(state.environment == nil && state.session == nil && state.drawingPassword == nil)

        // Scoped access stays held for the repair and grant-access flows, which read the file
        // again, and is released exactly once by the close every failed open ends in (CR-163).
        #expect(recorder.released == 0)
        document.close()
        #expect(await AppTestSupport.wait(upTo: 5) { recorder.released == 1 })
        try await Task.sleep(for: .milliseconds(50))
        #expect(recorder.released == 1)
    }

    @Test("IM-047: a project load that fails after its package opened closes the package — no crash marker, and it reopens clean",
          arguments: [DocumentLoadStage.packageOpened, .drawingOpened, .takeoffRead, .environmentBuilt])
    func failingProjectLoadClosesItsPackage(stage: DocumentLoadStage) async throws {
        let autosaveRoot = isolateAutosaveRoot()
        defer { restoreAutosaveRoot(autosaveRoot) }
        let url = try await makeProject("IM047-Project-\(stage.rawValue)")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let recorder = Recorder()
        let document = try document(
            opening: url, ofType: ZenitAppInfo.projectTypeIdentifier, recorder: recorder
        ) { current, _ in
            guard current == stage else { return }
            recorder.flags["markerWhileOpen"] = FileManager.default.fileExists(
                atPath: url.member(ProjectPackageLayout.crashMarker).path
            )
            throw InjectedFailure(stage: stage)
        }
        document.startLoadingIfNeeded()
        #expect(await AppTestSupport.wait { !document.isLoading })
        #expect(recorder.flags["markerWhileOpen"] == true, "the package was open (marker armed) when the load failed")
        #expect((document.loadFailure as? InjectedFailure) == InjectedFailure(stage: stage))
        expectNothingAdopted(document, "project failed at \(stage)")
        // Old: the package stayed on the failed document, marker armed, until something closed it.
        #expect(!FileManager.default.fileExists(atPath: url.member(ProjectPackageLayout.crashMarker).path),
                "the failed load closed its package")
        document.close()

        let reopened = ZenitPDFProjectDocument()
        try reopened.read(from: url, ofType: ZenitAppInfo.projectTypeIdentifier)
        reopened.startLoadingIfNeeded()
        defer { reopened.close() }
        #expect(await AppTestSupport.wait { reopened.core != nil })
        #expect(reopened.loadFailure == nil)
        #expect(reopened.projectPackage != nil)
    }

    // MARK: - Closing during the load

    @Test("IM-047: closing the document during any stage of its load adopts nothing and releases scoped access once",
          arguments: DocumentLoadStage.allCases)
    func closeDuringLoadAdoptsNothing(stage: DocumentLoadStage) async throws {
        let autosaveRoot = isolateAutosaveRoot()
        defer { restoreAutosaveRoot(autosaveRoot) }
        let url = try AppTestSupport.writeFixturePDF(named: "IM047-Close-\(stage.rawValue).pdf")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let recorder = Recorder()
        let document = try document(opening: url, recorder: recorder) { current, document in
            if current == stage { document.close() }
        }
        document.startLoadingIfNeeded()
        #expect(await AppTestSupport.wait { !document.isLoading })
        #expect(document.isClosed)
        #expect(document.loadFailure == nil, "a closed document is not a failed one")
        #expect(recorder.reached.last == stage, "the load went no further than the stage it closed at")
        expectNothingAdopted(document, "closed at \(stage)")
        let state = try #require(recorder.state)
        #expect(state.isShutDown && !state.isAdopted && !state.holdsResources)
        #expect(await AppTestSupport.wait(upTo: 5) { recorder.released == 1 })
    }

    @Test("IM-047: quit during a project load closes the package the load is holding, before the load notices")
    func shutdownDuringLoadClosesThePendingPackage() async throws {
        let autosaveRoot = isolateAutosaveRoot()
        defer { restoreAutosaveRoot(autosaveRoot) }
        let url = try await makeProject("IM047-Quit")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let recorder = Recorder()
        let document = try document(
            opening: url, ofType: ZenitAppInfo.projectTypeIdentifier, recorder: recorder
        ) { current, document in
            guard current == .drawingOpened else { return }
            // What `shutDownAllDocumentStorage` asks at quit: the load's package counts.
            recorder.flags["heldStorage"] = document.hasOpenStorage
            await document.shutDownStorage()
            recorder.flags["markerAfterShutdown"] = FileManager.default.fileExists(
                atPath: url.member(ProjectPackageLayout.crashMarker).path
            )
        }
        document.startLoadingIfNeeded()
        #expect(await AppTestSupport.wait { !document.isLoading })
        #expect(recorder.flags["heldStorage"] == true, "a package still loading is storage quit must wait for")
        #expect(recorder.flags["markerAfterShutdown"] == false, "shutDownStorage closed the load's package: no false recovery prompt")
        #expect(document.loadFailure == nil)
        expectNothingAdopted(document, "shut down mid-load")
        document.close()
    }

    // MARK: - A load that succeeds

    @Test("IM-047: a successful load reaches every stage with nothing on the document, then adopts the whole value at once")
    func successfulLoadAdoptsInOneStep() async throws {
        let autosaveRoot = isolateAutosaveRoot()
        defer { restoreAutosaveRoot(autosaveRoot) }
        let url = try AppTestSupport.writeFixturePDF(named: "IM047-Success.pdf")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let recorder = Recorder()
        let document = try document(opening: url, recorder: recorder) { _, _ in }
        defer { document.close() }
        document.startLoadingIfNeeded()
        #expect(document.pendingLoad != nil)
        #expect(await AppTestSupport.wait { !document.isLoading })

        #expect(recorder.reached == DocumentLoadStage.allCases, "every stage, in order")
        #expect(!recorder.documentHeldSomethingMidLoad, "old: core, drawing and package landed on the document mid-load")
        #expect(document.loadFailure == nil)
        #expect(document.core != nil && document.shell != nil && document.drawing != nil)
        #expect(document.searchIndex != nil)
        #expect(document.pendingLoad == nil)
        let state = try #require(recorder.state)
        #expect(state.isAdopted && !state.isShutDown)
        #expect(!state.holdsResources, "the adopted value hands every resource to the document")
        // A shutdown of the adopted value is a no-op: it cannot close what the document owns.
        await state.shutDown()
        #expect(document.drawing != nil && document.hasOpenStorage)
    }

    // MARK: - Wiring done at adoption

    @Test("d2 author badge: the adopted shell's toolbar shows the Settings author name, not the account name")
    func adoptedToolbarReadsTheAuthorIdentity() async throws {
        let autosaveRoot = isolateAutosaveRoot()
        defer { restoreAutosaveRoot(autosaveRoot) }
        let url = try AppTestSupport.writeFixturePDF(named: "D2-Author.pdf")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try AppTestSupport.makeDocument(opening: url)
        defer { document.close() }
        #expect(await AppTestSupport.wait { document.shell != nil })
        let toolbar = try #require(document.shell?.toolbar)
        try ScratchDefaults.with(prefix: "zenit-author-app-tests") { scratch, _ in
            let previous = AuthorIdentity.defaults
            AuthorIdentity.defaults = scratch
            defer {
                AuthorIdentity.defaults = previous
                toolbar.refreshAuthorName()
            }
            AuthorIdentity.set("Kalkylatorn")
            toolbar.refreshAuthorName()
            // Old: the provider was never installed, so the badge showed the macOS account name.
            #expect(toolbar.authorName == "Kalkylatorn")
        }
    }
}
