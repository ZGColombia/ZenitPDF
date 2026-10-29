import Foundation
import ZPDFAppCore
import ZPDFContracts
import ZPDFPDFKitBridge
import ZPDFPersistence
import ZPDFUIPresentation

/// The points of a document load at which it checks whether it should go on, in order (IM-047).
///
/// Each one follows an await that hands the load a resource. A test seam as well: a stage hook
/// runs at each checkpoint and can fail the load or close the document there.
enum DocumentLoadStage: String, CaseIterable, Sendable {
    /// Before anything has been opened.
    case started
    /// The project package (and its photo sidecar) is open. Reached in Quick PDF Mode too,
    /// with nothing opened.
    case packageOpened
    /// The drawing's raster source is open and its password, if any, answered.
    case drawingOpened
    /// The stored takeoff, or a restored container autosave, has been read.
    case takeoffRead
    /// The session exists and is hydrated; the search index and tool library are opening.
    case sessionBuilt
    /// The engine environment exists and the tool library has loaded.
    case environmentBuilt
    /// The search index is open, or refused.
    case searchIndexAttached
}

/// Everything one document load builds, held off to the side until the document adopts it in
/// one synchronous step (IM-047).
///
/// Before this existed, `load()` assigned the package, drawing, container autosave, core,
/// search index and more onto the document between awaits, guarded by eight "closed yet?"
/// checkpoints (CR-150): every new await was one more place a resource could be assigned to a
/// document that had closed and then orphaned. Now nothing reaches the document until
/// ``ZenitPDFProjectDocument/adopt(_:)``, and a load that fails, is cancelled or is closed
/// shuts down exactly what this value holds.
///
/// A reference type so the document can reach an unfinished load's resources from
/// `shutDownStorage()` — quit must close a project package still opening, or its crash marker
/// stays armed — without the load ever writing to the document.
@MainActor
final class LoadedDocumentState {

    /// A container autosave of an earlier session that the person chose to restore (CR-153).
    struct RestoredAutosave {
        let package: ProjectPackage
        let directory: URL
    }

    /// Identity every markup on the drawing is stamped with.
    let documentID: DocumentID

    init(documentID: DocumentID = DocumentID(UUID())) {
        self.documentID = documentID
    }

    // MARK: Resources — closed by `shutDown()` unless adopted

    /// The open project package, in Project Mode.
    fileprivate(set) var projectPackage: ProjectPackage?
    /// The opened drawing.
    fileprivate(set) var drawing: LoadedDrawing?
    /// The project's other drawings, in set order (NL-DOCS-04), each with its package row.
    var addedDrawings: [DrawingSet.Member] = []
    /// The package row of ``drawing``, in Project Mode.
    var primaryRow: String?
    /// The restored container autosave, in Quick PDF Mode.
    fileprivate(set) var restoredAutosave: RestoredAutosave?
    /// The search index while it opens in the background (IM-179).
    fileprivate(set) var searchIndexOpening: Task<DocumentSearchIndex, any Error>?
    /// The search index, once open.
    fileprivate(set) var searchIndex: DocumentSearchIndex?
    /// The Tool Library read, started beside hydration (IM-179).
    fileprivate(set) var toolLibraryLoad: Task<ToolPresetLibrary, Never>?

    // MARK: Values

    /// The autosave directory this load is restoring from, claimed before the package opens so
    /// neither a second tab nor the launch sweep can take it meanwhile.
    fileprivate(set) var claimedAutosaveDirectory: URL?
    /// The opened package, when its folder could not be looked in for sync-conflict copies
    /// (X-049): the adopting document says so in its tray.
    fileprivate(set) var conflictFolderUnchecked: URL?
    fileprivate(set) var photoStore: PhotoStore?
    fileprivate(set) var photoStoreFailure: (any Error)?
    fileprivate(set) var drawingPassword: String?
    fileprivate(set) var restoredFromAutosave = false
    fileprivate(set) var pages: [ZPDFContracts.PageDescriptor] = []
    fileprivate(set) var storedTakeoff: TakeoffArchive.StoredTakeoff?
    fileprivate(set) var session: TakeoffSession?
    fileprivate(set) var importedColumns: [LedgerColumnDefinition] = []
    fileprivate(set) var environment: AppCoreEnvironment?
    fileprivate(set) var toolLibrary: ToolPresetLibrary?
    /// Whether the search index was tried and could not be opened.
    fileprivate(set) var searchIndexFailed = false
    fileprivate(set) var hydrationStartedAt: Date?
    fileprivate(set) var searchIndexOpenStartedAt: Date?

    // MARK: Lifecycle

    /// Whether the document adopted this value. From then on its resources are the document's.
    private(set) var isAdopted = false

    /// Whether the load was abandoned: failed, cancelled or closed. Set by ``shutDown()``.
    private(set) var isShutDown = false

    /// Whether this value still holds anything that must be closed.
    var holdsResources: Bool {
        projectPackage != nil || drawing != nil || restoredAutosave != nil
            || searchIndexOpening != nil || searchIndex != nil || !addedDrawings.isEmpty
    }

    /// Hands every resource over to the adopting document: this value holds nothing after it,
    /// so no later `shutDown()` can close what the document now owns.
    func markAdopted() {
        precondition(!isShutDown, "an abandoned load cannot be adopted")
        isAdopted = true
        projectPackage = nil
        drawing = nil
        addedDrawings = []
        restoredAutosave = nil
        searchIndexOpening = nil
        searchIndex = nil
        toolLibraryLoad = nil
        photoStore = nil
        session = nil
        environment = nil
    }

    /// Closes whatever this load has built so far. Idempotent, and safe to call again after a
    /// resource arrived late: each call closes what is held at that moment. A no-op once adopted.
    func shutDown() async {
        guard !isAdopted else { return }
        isShutDown = true
        toolLibraryLoad?.cancel()
        toolLibraryLoad = nil
        let source = drawing?.rasterSource
        let added = addedDrawings.map(\.drawing.rasterSource)
        addedDrawings = []
        let package = projectPackage
        let autosave = restoredAutosave?.package
        let index = searchIndex
        let opening = searchIndexOpening
        drawing = nil
        projectPackage = nil
        restoredAutosave = nil
        searchIndex = nil
        searchIndexOpening = nil
        environment = nil
        session = nil
        photoStore = nil
        // The password goes with the drawing it unlocked (BH-069).
        drawingPassword = nil
        await source?.close()
        for other in added { await other.close() }
        try? await package?.close()
        try? await autosave?.close()
        await index?.shutDown()
        // An index still opening when the load was abandoned is closed too, not leaked.
        if let opened = try? await opening?.value { await opened.shutDown() }
    }
}

/// Builds a ``LoadedDocumentState`` for one document without touching the document (IM-047).
///
/// Everything it needs from the document arrives in ``Request`` and a few closures; the three
/// prompts — recovery, password, quick restore — are injected, defaulting to the shipping ones.
/// On any failure, cancellation or close it shuts down what it built and rethrows, so a caller
/// is left with either a complete value to adopt or nothing open at all.
@MainActor
struct DocumentLoadPipeline {

    /// What the document tells the load up front.
    struct Request {
        /// The file to open; `nil` for an untitled document.
        let url: URL?
        let mode: ZenitPDFProjectDocument.Mode
        /// The file the prompts name.
        let promptURL: URL?
        /// The document's display name, for the search index.
        let displayName: String?
        let undoManager: UndoManager
        let toolPresetContainer: ToolPresetContainerStore
    }

    let request: Request

    /// Whether the document closed or the load was cancelled. Read at every checkpoint.
    var isAbandoned: @MainActor () -> Bool

    /// Claims the search index key for this document on the main actor, so two documents can
    /// never share one (BH-358). Answers the key to open.
    var claimSearchIndexKey: @MainActor (_ digest: String, _ projectID: String?) -> String

    var askRecovery: @MainActor (RecoveryAssessment, _ packageName: String) async -> RecoveryDecision = {
        await RecoveryPrompt.ask(assessment: $0, packageName: $1)
    }
    /// NL-COLLAB-13: a project open on another Mac is asked about with this, never with
    /// ``askRecovery``. See `DocumentLoadPipeline+SharedStorage.swift`.
    var askForeignSession: @MainActor (ForeignSession, _ packageName: String) -> ForeignSessionDecision = {
        SharedStoragePrompt.ask(session: $0, packageName: $1)
    }
    /// NL-COLLAB-13: sync-conflict copies of the project found at open.
    var reportSyncConflicts: @MainActor (_ copyNames: [String], _ unresolvedVersions: Int, _ packageName: String) -> Void = {
        SharedStoragePrompt.reportConflicts(copyNames: $0, unresolvedVersions: $1, packageName: $2)
    }
    var askPassword: @MainActor (_ fileName: String) -> String? = {
        ZenitPDFProjectDocument.passwordPrompt($0)
    }
    var askQuickRestore: @MainActor (_ drawingName: String, _ autosavedAt: Date?) -> QuickTakeoffRestoreDecision = {
        QuickTakeoffRestorePrompt.ask(drawingName: $0, autosavedAt: $1)
    }
    var findRestorableAutosave: @MainActor (_ digest: String) -> QuickTakeoffStorage.Restorable? = {
        ZenitPDFProjectDocument.restorableQuickAutosave(matchingDigest: $0)
    }

    /// Runs at every checkpoint before the abandon check. A test seam: it may throw to fail
    /// the load at that stage, or close the document.
    var stageHook: (@MainActor (DocumentLoadStage, LoadedDocumentState) async throws -> Void)?

    /// Builds `state`. On return it is complete; on a throw it holds nothing open.
    func run(into state: LoadedDocumentState) async throws {
        do {
            try await build(state)
        } catch {
            await state.shutDown()
            throw error
        }
    }

    private func checkpoint(_ stage: DocumentLoadStage, _ state: LoadedDocumentState) async throws {
        try await stageHook?(stage, state)
        if state.isShutDown || isAbandoned() { throw CancellationError() }
    }

    private func build(_ state: LoadedDocumentState) async throws {
        try await checkpoint(.started, state)
        var pdfURL: URL?

        if let url = request.url {
            switch request.mode {
            case .quickPDF:
                pdfURL = url
            case .project:
                // Crash recovery, or "open on another Mac" (NL-COLLAB-13), then the heartbeat.
                let opened = try await openProjectPackage(at: url)
                state.projectPackage = opened.package
                state.conflictFolderUnchecked = opened.conflictFolderChecked ? nil : url
                let working = url.member(ProjectPackageLayout.workingPDF)
                guard FileManager.default.fileExists(atPath: working.path) else {
                    throw ZenitDocumentError.projectMissingDocument(url.lastPathComponent)
                }
                pdfURL = working
                switch ZenitPDFProjectDocument.openPhotoStore(packageURL: url) {
                case .success(let store): state.photoStore = store
                case .failure(let error): state.photoStoreFailure = error
                }
            }
        }
        try await checkpoint(.packageOpened, state)

        if let pdfURL {
            try await openDrawing(at: pdfURL, into: state)
            // A project of several drawings opens every one of them (NL-DOCS-04).
            try await openAddedDrawings(into: state)
            try await checkpoint(.drawingOpened, state)
        }

        try await readStoredTakeoff(into: state)
        try await checkpoint(.takeoffRead, state)

        // The search index opens beside hydration and the tool library, not after them: it
        // needs only the drawing and its pages (IM-179). It is awaited before the document
        // adopts anything, so the panel is still never handed a placeholder.
        await beginSearchIndexOpen(state)
        let package = state.projectPackage
        let container = request.toolPresetContainer
        state.toolLibraryLoad = Task.detached(priority: .userInitiated) {
            await ToolPresetLibraryStore.load(package: package, container: container)
        }
        let session = try TakeoffSession(
            documentID: state.documentID,
            pages: state.pages,
            // NL-UX-14 (r2-markup): a drawing with no saved takeoff starts in the units the
            // person chose for new projects in Settings.
            // ADR-0032 (r2-layers): a project saved with its display units reopens in them.
            units: state.storedTakeoff?.displayUnits
                ?? (state.storedTakeoff?.hasSavedTakeoff == true ? .metric : NewProjectUnits.current.selection),
            localeIdentifier: Locale.current.identifier
        )
        state.session = session
        // A table import's columns, before hydration, so the archived cells find their
        // columns and number cells are re-tagged by them (BH-075). One at a time so a
        // definition the session already knows cannot take the others down with it.
        // Their durable home is the takeoff database now (custom_column.definition_json,
        // BH-075). A package written by
        // the build before that still carries the attachments file; it is read once more here
        // and retired on the next save.
        let legacyColumns = ImportedLedgerColumnStore.read(
            fromPackage: (state.projectPackage ?? state.restoredAutosave?.package)?.url
        )
        let restoredColumns = (state.storedTakeoff?.customColumns ?? []) + legacyColumns
        state.importedColumns = await session.restoreCustomColumns(restoredColumns)
        // ADR-0032 (r2-layers): the project's markup layers and the active one; a project written
        // before schema v18 gets the default layer alone, and every markup belongs to it.
        await session.restoreMarkupLayers(
            state.storedTakeoff?.markupLayers ?? [],
            active: state.storedTakeoff?.activeMarkupLayerID
        )
        // NL-QTY-07-UI: the assembly recipes saved in the project.
        await session.restoreProjectAssemblyRecipes(state.storedTakeoff?.projectAssemblyRecipes ?? .none)
        // Hydration: scale, markups, values — recomputed through the pure engine, no
        // undo registered. The status bar, canvas and ledger all read the snapshot the
        // environment is about to take, so they show the saved takeoff immediately.
        if let storedTakeoff = state.storedTakeoff, storedTakeoff.hasSavedTakeoff {
            state.hydrationStartedAt = Date()
            try await session.hydrate(
                markups: storedTakeoff.markups,
                scales: storedTakeoff.scales,
                pageScaleIDs: storedTakeoff.pageScaleIDs,
                calibrationEvidence: storedTakeoff.calibrationEvidence,
                scaleRegions: storedTakeoff.scaleRegions,
                projectZones: storedTakeoff.projectZones
            )
        }
        // Named sheets (NL-DOCS-05), stored beside the page order in `page_set_entry`.
        if let identities = state.storedTakeoff?.sheetIdentities, !identities.isEmpty {
            await session.restoreSheetIdentities(identities)
        }
        // Sheets removed from the set and each sheet's view (NL-DOCS-07/16).
        if let stored = state.storedTakeoff, !stored.excludedPageIDs.isEmpty || !stored.pageViews.isEmpty {
            await session.restoreArrangement(excluded: stored.excludedPageIDs, views: stored.pageViews)
        }
        // The ledger store of a saved takeoff is built with its formula columns evaluated
        // concurrently (IM-081), so the environment's first snapshot reuses it instead of
        // evaluating every row on the session actor (R-064). A build that fails or is outrun is
        // discarded, and the first snapshot builds as it always did. It reports no progress: the
        // "Opening…" placeholder is indeterminate for every stage of the load.
        if state.storedTakeoff?.hasSavedTakeoff == true {
            try? await session.prebuildLedger()
        }
        try await checkpoint(.sessionBuilt, state)

        state.environment = try await AppCoreEnvironment.make(
            session: session,
            documentID: state.documentID,
            undoManager: request.undoManager
        )
        // Sheet names for the Navigator's page cards, from the drawing's own outline. The page
        // contract carries none, so they ride beside it on the document presenter.
        if let drawing = state.drawing {
            var titles = DocumentSessionLoader.sheetOutlineTitles(for: drawing, password: state.drawingPassword)
            for member in state.addedDrawings {
                titles.merge(DocumentSessionLoader.sheetOutlineTitles(for: member.drawing, password: member.password)) { first, _ in first }
            }
            state.environment?.document.sheetOutlineTitles = titles
        }
        // Started beside hydration (IM-179); the package it read is the one still open.
        state.toolLibrary = await state.toolLibraryLoad?.value
        try await checkpoint(.environmentBuilt, state)

        // Search over the real index, before the shell is built.
        await attachSearchIndex(state)
        try await checkpoint(.searchIndexAttached, state)
    }

    /// Opens the drawing, asking for its password when it is encrypted (LT-38).
    private func openDrawing(at pdfURL: URL, into state: LoadedDocumentState) async throws {
        // A project's working PDF was hashed by the package's integrity check a moment ago:
        // the provider reuses that verdict instead of reading the whole drawing again (IM-005).
        var loaded = try await DocumentSessionLoader.load(
            pdfAt: pdfURL,
            documentID: state.documentID,
            knownDigest: await ZenitPDFProjectDocument.verifiedWorkingDigest(
                of: state.projectPackage, workingURL: pdfURL
            )
        )
        // LT-38: PDFKit "opens" an encrypted drawing without its password — the page
        // count is right and every page renders blank white, which an estimator reads
        // as an empty drawing. The honest path is one question: the password unlocks
        // the open, Cancel or a refused password fails it in words. Never a blank sheet.
        if await loaded.rasterSource.isLocked {
            let name = (request.promptURL ?? pdfURL).lastPathComponent
            await loaded.rasterSource.close()
            guard let password = askPassword(name), !password.isEmpty else {
                throw ZenitDocumentError.passwordRequired(name)
            }
            // The locked open already hashed the file: the retry reuses its digest
            // rather than reading the whole drawing again (IM-005).
            let verified = loaded.digest
            do {
                loaded = try await DocumentSessionLoader.load(
                    pdfAt: pdfURL,
                    documentID: state.documentID,
                    password: password,
                    knownDigest: verified
                )
                // Kept for the export and print drawer, which opens its own copy (BH-079).
                state.drawingPassword = password
            } catch PDFBridgeError.incorrectPassword {
                throw ZenitDocumentError.wrongPassword(name)
            }
        }
        state.drawing = loaded
        state.pages = loaded.pages
    }

    /// The saved takeoff, in Project Mode (ADR-0009). Read before the session exists so the
    /// freshly parsed pages can adopt their stored identities — a markup's geometry references
    /// the page id it was saved under.
    ///
    /// In Quick PDF Mode the same slot is filled by the container autosave of an earlier
    /// session that ended without saving, when the person chooses to restore it (CR-153). The
    /// drawing is matched by digest, so a moved or renamed file still finds its takeoff.
    private func readStoredTakeoff(into state: LoadedDocumentState) async throws {
        if let package = state.projectPackage, !state.addedDrawings.isEmpty {
            try await readStoredSet(from: package, into: state)
            return
        } else if let package = state.projectPackage {
            // K-03: a project never saved has no takeoff, but its pages still adopt the ids
            // every copy of it derives from the document row, not the random ones just minted.
            // Spelled out: `??` cannot await its right-hand side.
            if let stored = try await TakeoffArchive.read(from: package) {
                state.storedTakeoff = stored
            } else {
                state.storedTakeoff = try await TakeoffArchive.unsavedTakeoff(of: package)
            }
        } else if request.mode == .quickPDF, let loaded = state.drawing,
                  let candidate = findRestorableAutosave(loaded.digest.sha256) {
            let name = (request.promptURL ?? loaded.url).lastPathComponent
            switch askQuickRestore(name, candidate.autosavedAt) {
            case .restore:
                state.claimedAutosaveDirectory = candidate.directory
                // `.recover`: the session that wrote it died, so its crash marker is still
                // armed, and the person has just answered the recovery question.
                let package = try await ProjectPackage.open(at: candidate.packageURL, resolving: .recover)
                state.restoredAutosave = LoadedDocumentState.RestoredAutosave(
                    package: package, directory: candidate.directory
                )
                state.storedTakeoff = try await TakeoffArchive.read(from: package)
                state.restoredFromAutosave = true
            case .discard:
                try? FileManager.default.removeItem(at: candidate.directory)
            case .ignore:
                break
            }
        }
        if let storedTakeoff = state.storedTakeoff {
            state.pages = TakeoffArchive.adoptingStoredPageIDs(state.pages, stored: storedTakeoff)
            if let loaded = state.drawing {
                // Keep the drawing's own page list in step: snap rebuilds and layer
                // re-renders read it, and a stale id there would build an index no
                // canvas query can ever hit.
                state.drawing = LoadedDrawing(
                    documentID: loaded.documentID,
                    pages: state.pages,
                    rasterSource: loaded.rasterSource,
                    digest: loaded.digest,
                    url: loaded.url
                )
            }
        }
    }

    /// Starts opening the search index in the background (IM-179). The key is claimed on the
    /// main actor, so two documents can still never share one.
    private func beginSearchIndexOpen(_ state: LoadedDocumentState) async {
        guard let drawing = state.drawing, state.searchIndexOpening == nil else { return }
        let name = request.displayName ?? drawing.url.deletingPathExtension().lastPathComponent
        let projectID = await state.projectPackage?.manifest.projectId
        let key = claimSearchIndexKey(drawing.digest.sha256, projectID.map { "\($0)" })
        let databaseURL = ZenitPDFProjectDocument.searchIndexRoot
            .appendingPathComponent(key, isDirectory: false)
            .appendingPathExtension("sqlite")
        let drawingURL = drawing.url
        // The index reads text from this drawing's PDF by page index, so only its own pages go
        // in (NL-DOCS-04); the other drawings' pages are not in this file.
        let pages = state.pages.filter { $0.documentID == drawing.documentID }
        // The drawing was hashed when it opened in this process; the index's own open does
        // not hash it again (IM-005, appcore half returned done).
        let verified = drawing.digest
        // The password that unlocked the drawing, or its text is never read into the index:
        // a locked open reads every page as not permitted (V-040).
        let password = state.drawingPassword
        state.searchIndexOpenStartedAt = Date()
        state.searchIndexOpening = Task.detached(priority: .userInitiated) {
            try await DocumentSearchIndex.open(
                databaseAt: databaseURL,
                drawingAt: drawingURL,
                displayName: name,
                pages: pages,
                knownDigest: verified,
                password: password
            )
        }
    }

    /// Waits for the search index. A failure is recorded, and the document says "search is
    /// unavailable" once it adopts — never "no results", which would be a lie.
    private func attachSearchIndex(_ state: LoadedDocumentState) async {
        guard state.drawing != nil else { return }
        if state.searchIndexOpening == nil { await beginSearchIndexOpen(state) }
        guard let opening = state.searchIndexOpening else { return }
        do {
            let index = try await opening.value
            // Abandoned while it opened: `shutDown()` took the task and closes the index.
            guard state.searchIndexOpening == opening else { return }
            state.searchIndexOpening = nil
            state.searchIndex = index
        } catch {
            if state.searchIndexOpening == opening { state.searchIndexOpening = nil }
            state.searchIndexFailed = true
        }
    }
}

// MARK: - A project of several drawings (NL-DOCS-04, ADR-0027 (documents))

extension DocumentLoadPipeline {

    /// Opens every drawing of the project other than the one it was created from, in set
    /// order, each with its own runtime identity. A project of one drawing opens nothing here.
    fileprivate func openAddedDrawings(into state: LoadedDocumentState) async throws {
        guard let package = state.projectPackage else { return }
        let rows = try await TakeoffArchive.drawingRows(of: package)
        state.primaryRow = rows.first(where: \.isPrimary)?.id
        for row in rows where !row.isPrimary {
            let url = package.url.member(row.relativePath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ZenitDocumentError.projectMissingDocument(row.displayName)
            }
            let documentID = DocumentID(UUID())
            var password: String?
            var loaded = try await DocumentSessionLoader.load(pdfAt: url, documentID: documentID)
            if await loaded.rasterSource.isLocked {
                await loaded.rasterSource.close()
                guard let answer = askPassword(row.displayName), !answer.isEmpty else {
                    throw ZenitDocumentError.passwordRequired(row.displayName)
                }
                do {
                    loaded = try await DocumentSessionLoader.load(
                        pdfAt: url, documentID: documentID, password: answer, knownDigest: loaded.digest
                    )
                    password = answer
                } catch PDFBridgeError.incorrectPassword {
                    throw ZenitDocumentError.wrongPassword(row.displayName)
                }
            }
            state.addedDrawings.append(DrawingSet.Member(
                drawing: loaded, row: row.id, password: password, displayName: row.displayName
            ))
        }
    }

    /// Reads every drawing's stored takeoff and adopts them as one set: each drawing's pages
    /// take their stored identities, then the whole set takes its stored order.
    fileprivate func readStoredSet(from package: ProjectPackage, into state: LoadedDocumentState) async throws {
        guard let primary = state.drawing, let primaryRow = state.primaryRow else { return }
        let stored = try await TakeoffArchive.readSet(from: package)
        var drawings: [(documentId: String, pages: [ZPDFContracts.PageDescriptor])] = []
        for row in try await TakeoffArchive.documentRows(of: package) {
            if row == primaryRow {
                drawings.append((row, primary.pages))
            } else if let member = state.addedDrawings.first(where: { $0.row == row }) {
                drawings.append((row, member.drawing.pages))
            }
        }
        let adopted = TakeoffArchive.adoptingStoredSet(drawings, stored: stored)
        state.pages = adopted.pages
        state.storedTakeoff = adopted.takeoff
        func own(_ documentID: DocumentID) -> [ZPDFContracts.PageDescriptor] {
            adopted.pages.filter { $0.documentID == documentID }.sorted { $0.index < $1.index }
        }
        state.drawing = LoadedDrawing(
            documentID: primary.documentID, pages: own(primary.documentID),
            rasterSource: primary.rasterSource, digest: primary.digest, url: primary.url
        )
        state.addedDrawings = state.addedDrawings.map { member in
            DrawingSet.Member(
                drawing: LoadedDrawing(
                    documentID: member.drawing.documentID, pages: own(member.drawing.documentID),
                    rasterSource: member.drawing.rasterSource, digest: member.drawing.digest, url: member.drawing.url
                ),
                row: member.row, password: member.password, displayName: member.displayName
            )
        }
    }
}
