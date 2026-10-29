import AppKit
import Foundation
import ZPDFAppCore
import ZPDFContracts
import ZPDFPDFKitBridge
import ZPDFPersistence
import ZPDFUIPresentation
import ZPDFUIShell
import ZPDFVectorExtraction

/// A project of several drawings (NL-DOCS-04, ADR-0027 (documents)): the document side.
///
/// Every drawing opens with the project, a PDF dropped on the Navigator becomes a drawing of
/// the project with its sheets inserted at the drop position — one undo step — and a save
/// writes each drawing's share of the takeoff under its own package row.
extension ZenitPDFProjectDocument {

    /// Builds the set from a finished load: the drawing the project was created from, then
    /// every drawing added to it, in set order.
    func adoptDrawingSet(from state: LoadedDocumentState) {
        guard let drawing = state.drawing else { drawingSet = nil; return }
        let set = DrawingSet(primary: DrawingSet.Member(
            drawing: drawing,
            row: state.primaryRow,
            password: state.drawingPassword,
            displayName: displayName ?? drawing.url.deletingPathExtension().lastPathComponent
        ))
        for member in state.addedDrawings { set.add(member) }
        if let package = state.projectPackage, set.rows.count == set.members.count {
            set.rowsByPackage[ObjectIdentifier(package)] = set.rows
        }
        drawingSet = set
    }

    /// The package rows to write a set under, or `nil` for a project of one drawing, which is
    /// written exactly as before. A package this set has not been written into yet — a Save As
    /// — gains a row for every added drawing first, copied read-only like any added drawing.
    func drawingSetRows(for package: ProjectPackage) async throws -> [DocumentID: String]? {
        guard let set = drawingSet, set.isMultiDrawing else { return nil }
        return try await packageRows(for: package, of: set)
    }

    /// The rows `package` holds for every drawing of `set`, keyed by drawing: the ones recorded
    /// when the package was opened or last written, or — for a package this set has not been
    /// written into yet — its primary row plus a row for every added drawing, copied read-only
    /// like any added drawing. Never a member's own ``DrawingSet/Member/row``, which can name
    /// the package the project was opened from: Save As mints new rows, and one stale row made
    /// every later save fail its foreign key (X-011).
    func packageRows(for package: ProjectPackage, of set: DrawingSet) async throws -> [DocumentID: String] {
        let key = ObjectIdentifier(package)
        if let known = set.rowsByPackage[key] { return known }
        var rows: [DocumentID: String] = [:]
        let primaryRow = try await TakeoffArchive.drawingRows(of: package).first(where: \.isPrimary)?.id
        guard let primaryRow else {
            throw ZPDFPersistenceError.packageMalformed(reason: "the package has no document row")
        }
        rows[set.primary.drawing.documentID] = primaryRow
        for member in set.members.dropFirst() {
            rows[member.drawing.documentID] = try await package.addDocument(
                originalPDF: member.drawing.url,
                displayName: member.displayName,
                pageCount: member.drawing.pages.count
            )
        }
        set.rowsByPackage[key] = rows
        return rows
    }

    /// After a Save As or Create Project, the set's rows are the new package's (X-011): every
    /// member's ``DrawingSet/Member/row`` — and the added drawings' index keys built from it —
    /// follows the package being written, and no row map of the package left behind survives.
    /// The map is keyed by object identity, so one kept for a closed package could be found
    /// again by a later package at the same address.
    func adoptPackageRows(of package: ProjectPackage) async {
        guard let set = drawingSet else { return }
        let key = ObjectIdentifier(package)
        // The write just made recorded a set's rows under the new package; keep only those.
        set.rowsByPackage = set.rowsByPackage[key].map { [key: $0] } ?? [:]
        guard let rows = try? await packageRows(for: package, of: set) else { return }
        set.setRows(rows)
    }

    /// Adds a PDF to the open project as a drawing of its own (NL-DOCS-04): copied into the
    /// package read-only and hashed, opened, and its sheets inserted into the set at
    /// `position` as one undoable step. Answers whether the drawing was added.
    @discardableResult
    func addDrawingToSet(fileAt url: URL, at position: Int) async -> Bool {
        guard let core, let member = await attachDrawing(fileAt: url) else { return false }
        do {
            let pageCount = await core.session.pageOrderIDs.count
            _ = try await core.commands.perform(.insertPages(member.drawing.pages, at: max(0, min(position, pageCount))))
            return true
        } catch {
            postDrawingAddFailed(fileName: url.lastPathComponent)
            return false
        }
    }

    /// Copies a PDF into the package as a drawing of the project (read-only, hashed), opens it
    /// and adds it to the set's registry — without putting its sheets into the set order; the
    /// caller decides where they go (a drop, a slip-sheet). `nil`, said in the tray, on failure.
    func attachDrawing(fileAt url: URL) async -> DrawingSet.Member? {
        guard let core, let set = drawingSet, let package = projectPackage else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        let row: String
        do {
            row = try await package.addDocument(originalPDF: url, displayName: name)
        } catch {
            postDrawingAddFailed(fileName: url.lastPathComponent)
            return nil
        }
        let copy = package.url.member(ProjectPackageLayout.addedDocumentPath(id: row))
        let documentID = DocumentID(UUID())
        var password: String?
        do {
            var loaded = try await DocumentSessionLoader.load(pdfAt: copy, documentID: documentID)
            if await loaded.rasterSource.isLocked {
                await loaded.rasterSource.close()
                guard let answer = Self.passwordPrompt(url.lastPathComponent), !answer.isEmpty else {
                    postDrawingAddFailed(fileName: url.lastPathComponent)
                    return nil
                }
                loaded = try await DocumentSessionLoader.load(
                    pdfAt: copy, documentID: documentID, password: answer, knownDigest: loaded.digest
                )
                password = answer
            }
            guard !isClosed else { await loaded.rasterSource.close(); return nil }
            // The rows this package holds for the drawings already in the set, plus the new
            // one's (X-011). Taken from the package, never from the members: after a Save As a
            // member's row still named the package the project was opened from, and the next
            // save — ⌘S and autosave alike — failed until the project was reopened.
            var rows = try await packageRows(for: package, of: set)
            let member = DrawingSet.Member(drawing: loaded, row: row, password: password, displayName: name)
            set.add(member)
            // Known to the session and saved, outside the set until placed.
            await core.session.holdPagesOutsideSet(loaded.pages)
            rows[loaded.documentID] = row
            set.rowsByPackage[ObjectIdentifier(package)] = rows
            set.setRows(rows)
            var titles = core.document.sheetOutlineTitles
            titles.merge(DocumentSessionLoader.sheetOutlineTitles(for: loaded, password: password)) { first, _ in first }
            for window in allWindowCores { window.document.sheetOutlineTitles = titles }   // NL-UX-20
            onDrawingSetChange?()
            openDrawingSetSearch()
            refineNavigatorBookmarks()
            return member
        } catch {
            postDrawingAddFailed(fileName: url.lastPathComponent)
            return nil
        }
    }

    /// Every added drawing with a sheet in the set, for the batch sheet's search-term scope
    /// (V-040): mapped as the Search panel maps it, so a hit turns to the sheet here. An index
    /// still opening is waited for; a drawing whose index could not be opened comes as
    /// ``BatchSearchScopeResolver/Drawing/withoutIndex(title:)``, so the scope says it could
    /// not search it rather than counting the set without its sheets. A drawing none of whose
    /// sheets is in the set is not asked: no page of it could be stamped.
    func batchSearchScopeDrawings() async -> [BatchSearchScopeResolver.Drawing] {
        guard let core, let set = drawingSet, set.isMultiDrawing else { return [] }
        let inSet = Set(await core.session.pageOrderIDs)
        let identity = documentIdentity
        var drawings: [BatchSearchScopeResolver.Drawing] = []
        for member in set.members.dropFirst() where member.drawing.pages.contains(where: { inSet.contains($0.id) }) {
            if let index = await searchIndex(forDrawing: member.drawing.documentID) {
                drawings.append(BatchSearchScopeResolver.Drawing(
                    index: index, documentUUID: identity, title: member.displayName, pages: member.drawing.pages
                ))
            } else {
                drawings.append(.withoutIndex(title: member.displayName))
            }
        }
        return drawings
    }

    /// Opens the text index of every added drawing that has none yet and makes each a source of
    /// this project's Search panel, which then searches the whole set (NL-DOCS-04). Hits come
    /// back under this document's identity, so revealing one turns to the sheet here. Each open
    /// is recorded while it runs (``DrawingSet/searchIndexOpenings``), and a drawing whose open
    /// failed is tried again the next time this runs.
    ///
    /// Each index file is keyed by the project and the drawing's package row
    /// (``addedDrawingSearchIndexKey(digest:projectID:row:)``), both stable across reopens, as
    /// the primary drawing's is (W-019).
    func openDrawingSetSearch() {
        guard let set = drawingSet, set.isMultiDrawing, let package = projectPackage,
              let presenter = searchPresenter as? AppSearchPresenter else { return }
        let identity = documentIdentity
        let root = Self.searchIndexRoot
        for member in set.members.dropFirst() {
            let drawing = member.drawing
            guard let row = member.row,
                  set.searchIndexes[drawing.documentID] == nil,
                  set.searchIndexOpenings[drawing.documentID] == nil else { continue }
            let name = member.displayName
            // The password that unlocked the drawing (V-040): without it the index opens the
            // file locked, reads every page as not permitted and holds none of its text.
            let password = member.password
            set.searchIndexOpenings[drawing.documentID] = Task { @MainActor [weak self, weak set] in
                defer { set?.searchIndexOpenings[drawing.documentID] = nil }
                let projectID = await package.manifest.projectId
                let key = Self.addedDrawingSearchIndexKey(digest: drawing.digest.sha256, projectID: "\(projectID)", row: row)
                let databaseURL = root.appendingPathComponent(key, isDirectory: false).appendingPathExtension("sqlite")
                guard let index = try? await DocumentSearchIndex.open(
                    databaseAt: databaseURL, drawingAt: drawing.url, displayName: name,
                    pages: drawing.pages, knownDigest: drawing.digest, password: password
                ) else { return nil }
                guard let self, let set, !self.isClosed else { await index.shutDown(); return nil }
                set.searchIndexes[drawing.documentID] = index
                let memberPresenter = AppSearchPresenter(
                    service: index.service,
                    projectID: index.projectKey,
                    identity: index.identityMap(documentUUID: identity, documentTitle: name, pages: drawing.pages, currentPageIndex: 0)
                )
                set.searchSources.append(ZPDFUIPresentation.ProjectSearchSource(
                    documentID: drawing.documentID.rawValue,
                    title: name,
                    search: { text, options in await memberPresenter.hitsForProjectSearch(text, options: options) }
                ))
                presenter.searchesAllDrawings = true
                self.installProjectSearchSources(self.windowSearchSources)
                _ = try? await index.indexDrawingText()
                return index
            }
        }
    }

    /// The index file of a drawing added to a project (W-019): the drawing's bytes, the project
    /// and the drawing's package row — each stable across reopens — in line with the primary
    /// drawing's `"<digest>-project-<id>"`. It used to name the document's per-open identity
    /// and the drawing's per-open runtime id, so every reopen made a new file: recognised text
    /// was not found again and the old files piled up.
    nonisolated static func addedDrawingSearchIndexKey(digest: String, projectID: String, row: String) -> String {
        "\(digest)-project-\(projectID)-\(row)"
    }

    /// The marker of the retired per-open key of an added drawing's index,
    /// `"<digest>-set-<document>-<drawing>"` (W-019). Nothing names a file this way any more.
    nonisolated static let retiredSetSearchIndexMarker = "-set-"

    /// Removes the index files of added drawings keyed the retired per-open way (W-019): the
    /// ones of `digests` only, or, with `nil`, every one in `root` — the one-time sweep, safe
    /// because no file of that shape can be in use. A file counts when its name is a SHA-256,
    /// the marker, and more (the database and its `-wal`/`-shm`). Answers what was removed.
    @discardableResult
    nonisolated static func removeRetiredSetSearchIndexes(in root: URL, digests: Set<String>? = nil) -> [URL] {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: root.path) else { return [] }
        var removed: [URL] = []
        for name in names {
            guard let marker = name.range(of: retiredSetSearchIndexMarker) else { continue }
            let digest = String(name[..<marker.lowerBound])
            guard digest.count == 64, digest.allSatisfy(\.isHexDigit),
                  digests?.contains(digest) ?? true else { continue }
            let url = root.appendingPathComponent(name, isDirectory: false)
            if (try? fileManager.removeItem(at: url)) != nil { removed.append(url) }
        }
        return removed
    }

    /// The one-time sweep of retired added-drawing index files, off the main thread (W-019).
    @discardableResult
    static func sweepRetiredSetSearchIndexesInBackground() -> Task<[URL], Never> {
        let root = searchIndexRoot
        return Task.detached(priority: .utility) { removeRetiredSetSearchIndexes(in: root) }
    }

    /// Adds other open drawings to this project, each with its takeoff (NL-DOCS-04, "Combine
    /// Open Drawings"): the drawing joins the set at the end, every page scale is installed on
    /// its new sheet, and every markup is carried onto the same sheet and re-measured by the
    /// engine — never copied as a number. One undo step per drawing for its sheets, one for its
    /// takeoff. Its Scale Regions go with their sheets, so a detail keeps its scale (U-030); its
    /// Project Zones are not carried (the note says so). Answers how many drawings joined.
    @discardableResult
    func combine(openDrawings others: [ZenitPDFProjectDocument]) async -> Int {
        // The empty untitled start window has no drawing to combine into, and Save refuses it,
        // so "save this takeoff as a project first" was a sentence nobody could act on (L-40).
        guard drawing != nil else {
            core?.status.setActiveToolNote(Self.combineNeedsADrawingNote)
            return 0
        }
        guard let core, drawingSet != nil, projectPackage != nil else {
            core?.status.setActiveToolNote(NSLocalizedString(
                "Save this takeoff as a project first, then combine the open drawings into it.",
                comment: "Status note: Combine Open Drawings needs a project"
            ))
            return 0
        }
        var joined = 0
        var leftBehind = 0
        for other in others where other !== self {
            guard let otherDrawing = other.drawing, let otherCore = other.core,
                  other.drawingSet?.isMultiDrawing != true else { continue }
            let end = await core.session.pageOrderIDs.count
            guard await addDrawingToSet(fileAt: otherDrawing.url, at: end),
                  let member = drawingSet?.members.last else { continue }
            joined += 1
            let state = await otherCore.session.takeoffState()
            let targetByIndex = Dictionary(member.drawing.pages.map { ($0.index, $0.id) }, uniquingKeysWith: { first, _ in first })
            var pairs: [PageID: CarryPair] = [:]
            for page in state.pages {
                if let target = targetByIndex[page.index] { pairs[page.id] = CarryPair(target: target, alignment: .identity) }
            }
            // Page scales and Scale Regions, onto the new sheets (U-030).
            let scales = CarryForwardPlanner.carriedScales(
                from: state, pairs: pairs, keeping: await core.session.scaleRegionDefinitions
            )
            var commands: [DocumentCommand] = scales.commands
            let plan = CarryForwardPlanner.plan(markups: state.markups, pairs: pairs, now: Date(), scales: scales)
            commands += plan.commands
            var names: [PageID: SheetIdentity?] = [:]
            for (page, identity) in state.sheetIdentities { if let target = pairs[page]?.target { names[target] = identity } }
            if !names.isEmpty { commands.append(.setSheetIdentities(names, overwriteManual: true)) }
            leftBehind += state.projectZones.count + plan.heldForScale.count
            guard !commands.isEmpty else { continue }
            do {
                _ = try await core.commands.performBatch(
                    commands,
                    actionName: NSLocalizedString("Combine Open Drawings", comment: "Undo action name: another drawing's takeoff carried into this project")
                )
            } catch {
                postDrawingAddFailed(fileName: otherDrawing.url.lastPathComponent)
            }
        }
        await core.refresh()
        var note = Self.drawingsCombinedNote(joined)
        if leftBehind > 0 {
            note += " " + NSLocalizedString(
                "Project Zones, and measurements whose Scale Region could not be carried, stay in the drawings they were made in.",
                comment: "Status note: what Combine Open Drawings does not carry"
            )
        }
        core.status.setActiveToolNote(note)
        return joined
    }

    /// Combine Open Drawings chosen where there is no drawing to combine into (L-40).
    static var combineNeedsADrawingNote: String {
        NSLocalizedString(
            "This tab has no drawing to combine into. Bring forward the drawing that should hold the others, then choose Combine Open Drawings again.",
            comment: "Status note: Combine Open Drawings chosen on the empty untitled window"
        )
    }

    /// The status note after Combine Open Drawings, singular and plural: "1 drawing added…",
    /// "2 drawings added…" (L-26: the bare `%d` format read "1 drawings added").
    static func drawingsCombinedNote(_ count: Int) -> String {
        LocalizedPlural.string(
            "%lld drawings added to this project with their takeoffs. Their own tabs are unchanged.", count: count,
            one: NSLocalizedString(
                "%lld drawing added to this project with its takeoff. Its own tab is unchanged.",
                comment: "Status note after Combine Open Drawings added one drawing"
            ),
            other: NSLocalizedString(
                "%lld drawings added to this project with their takeoffs. Their own tabs are unchanged.",
                comment: "Status note after Combine Open Drawings; the count"
            )
        )
    }

    /// What an output that writes the primary drawing alone says in a project of several
    /// drawings (W-017, W-022): its panel or confirmation, and its result note, name the drawing
    /// written and what stays out, as Clean Up Scanned Sheets names its drawing (V-053). `nil`
    /// in a project of one drawing, where there is nothing to leave out.
    func primaryDrawingOnlySentence() -> String? {
        guard let set = drawingSet, set.isMultiDrawing else { return nil }
        let others = set.members.count - 1
        return others == 1
            ? String(
                format: NSLocalizedString(
                    "Only “%@” is written. The sheets and markups of the project's other drawing are not in this file.",
                    comment: "Output of the primary drawing alone, in a project of two drawings; the drawing's name"
                ),
                set.primary.displayName
            )
            : String(
                format: NSLocalizedString(
                    "Only “%1$@” is written. The sheets and markups of the project's %2$lld other drawings are not in this file.",
                    comment: "Output of the primary drawing alone, in a project of several drawings; the drawing's name, the count of the others"
                ),
                set.primary.displayName, Int64(others)
            )
    }

    /// The tray note when a dropped drawing could not become part of the project.
    func postDrawingAddFailed(fileName: String) {
        core?.document.post(AppWarning(
            id: UUID(),
            severity: .warning,
            title: NSLocalizedString(
                "The drawing could not be added to the project.",
                comment: "Warning title: a dropped PDF could not be added to the project"
            ),
            message: String(
                format: NSLocalizedString(
                    "%@ was not added. The project is unchanged.",
                    comment: "Warning detail: which drawing was not added; the project is unchanged"
                ),
                fileName
            ),
            source: NSLocalizedString("Drawings", comment: "Warning source: the project's drawings"),
            isDismissible: true,
            timestamp: Date()
        ))
    }

    /// The drawing a page comes from; the primary drawing when the page is not known.
    func loadedDrawing(forPage pageID: UUID) -> LoadedDrawing? {
        drawingSet?.drawing(forPage: pageID) ?? drawing
    }

    /// The text index of the drawing a page comes from (T-006): the document's own for the
    /// primary drawing, the added drawing's own otherwise, and `nil` when that drawing has none
    /// yet. Recognised words are keyed by page index *within one PDF*, so the primary drawing's
    /// index read at an added sheet's index is another sheet's text.
    func searchIndex(forPage page: ZPDFContracts.PageDescriptor) -> DocumentSearchIndex? {
        guard let set = drawingSet, page.documentID != set.primary.drawing.documentID else { return searchIndex }
        return set.searchIndexes[page.documentID]
    }

    /// A drawing's text index, waiting for one still opening (V-040): the document's own for the
    /// primary drawing, the added drawing's own otherwise; `nil` when it could not be opened.
    func searchIndex(forDrawing documentID: DocumentID) async -> DocumentSearchIndex? {
        guard let set = drawingSet, documentID != set.primary.drawing.documentID else { return searchIndex }
        if let index = set.searchIndexes[documentID] { return index }
        return await set.searchIndexOpenings[documentID]?.value
    }

    /// One drawing's share of a recognition run (W-016): its PDF-local page indices, and the
    /// identity each index was asked for, so a committed page is reported as the sheet it is.
    struct RecognitionBatch {
        let documentID: DocumentID
        var pageIndices: [Int] = []
        var pageIDByIndex: [Int: UUID] = [:]
    }

    /// The pages to recognise, grouped by the drawing they come from, drawings in the order
    /// their first page was asked for. A page no drawing holds is left out.
    func recognitionBatches(for pageIDs: [UUID]) -> [RecognitionBatch] {
        var batches: [RecognitionBatch] = []
        for id in pageIDs {
            guard let page = pageDescriptor(forPage: id) else { continue }
            let at = batches.firstIndex { $0.documentID == page.documentID } ?? {
                batches.append(RecognitionBatch(documentID: page.documentID))
                return batches.count - 1
            }()
            guard batches[at].pageIDByIndex[page.index] == nil else { continue }
            batches[at].pageIndices.append(page.index)
            batches[at].pageIDByIndex[page.index] = id
        }
        return batches
    }

    /// The words text recognition stored for a page, read from its own drawing's index; none
    /// when that drawing has no index or nothing was recognised on the page.
    ///
    /// One page's rows only (U-015): the whole drawing's recognised words were read and decoded
    /// to keep one page's, so Prepare This Set on a scanned set of N sheets read the table N times.
    func recognisedWords(onPage page: ZPDFContracts.PageDescriptor) async -> [DocumentSearchIndex.RecognisedWord] {
        guard let index = searchIndex(forPage: page) else { return [] }
        return (try? await index.recognisedWords(onPage: page.index)) ?? []
    }

    /// Whether a page comes from the drawing the project was created from — the only drawing
    /// whose layers the layer panel shows and hides (NL-DOCS-04).
    func isPrimaryDrawingPage(_ page: ZPDFContracts.PageDescriptor) -> Bool {
        guard let primary = drawingSet?.primary.drawing ?? drawing else { return false }
        return page.documentID == primary.documentID
    }

    /// The marked-content names a detector must leave out on `page`: the layers hidden in the
    /// layer panel (and, with `snap`, every other layer under a measure lock — the snap index's
    /// set). The panel is the primary drawing's, and a marked-content name is a per-page resource
    /// name that one CAD exporter reuses across files, so on a sheet of another drawing it names
    /// nothing and the answer is empty (U-012). The one rule every detector and auto-trace use.
    func hiddenLayerNames(for page: ZPDFContracts.PageDescriptor, snap: Bool) -> Set<String> {
        guard isPrimaryDrawingPage(page) else { return [] }
        return snap
            ? layerVisibility.snapHiddenMarkedContentNames(onPageIndex: page.index)
            : layerVisibility.hiddenMarkedContentNames(onPageIndex: page.index)
    }

    /// A page by its identity, from the drawing it comes from; `nil` when no drawing holds it.
    func pageDescriptor(forPage pageID: UUID) -> ZPDFContracts.PageDescriptor? {
        loadedDrawing(forPage: pageID)?.pages.first { $0.id.rawValue == pageID }
    }

    /// One page's layer-aware extraction from its own drawing's store (U-007); `nil` when the
    /// page cannot be read. A page index names a page only within one PDF, so there is no
    /// index-only form of this.
    func automationExtraction(forPage page: ZPDFContracts.PageDescriptor) async -> VectorPageExtraction? {
        guard let resolved = automationExtractionStore(forPage: page.id.rawValue) else { return nil }
        return try? await resolved.store.extraction(url: resolved.drawing.url, pageIndex: page.index, password: resolved.password)
    }

    /// The drawing of the page on screen (NL-DOCS-04): a tool that reads the current sheet's
    /// text or linework reads it from that sheet's own PDF.
    var currentPageDrawing: LoadedDrawing? {
        core?.document.currentPageID.flatMap(loadedDrawing(forPage:)) ?? drawing
    }

    /// The automation extraction store for a page's drawing: the document's own for the
    /// primary drawing, one per added drawing otherwise, so page 1 of one drawing is never
    /// served as page 1 of another. Each gets its drawing's on-disk store.
    func automationExtractionStore(forPage pageID: UUID) -> (store: AutomationExtractionStore, drawing: LoadedDrawing, password: String?)? {
        guard let set = drawingSet else {
            guard let drawing else { return nil }
            automation.attachPersistentStore(digest: drawing.digest.sha256)
            return (automation.extractions, drawing, drawingPassword)
        }
        let member = set.member(forPage: pageID)
        if member.drawing.documentID == set.primary.drawing.documentID {
            automation.attachPersistentStore(digest: member.drawing.digest.sha256)
            return (automation.extractions, member.drawing, member.password)
        }
        let store = set.extractionStores[member.drawing.documentID] ?? {
            let made = AutomationExtractionStore()
            made.persistent = PersistentExtractionStore(
                documentDigest: member.drawing.digest.sha256, root: PersistentExtractionStore.defaultRoot
            )
            set.extractionStores[member.drawing.documentID] = made
            return made
        }()
        return (store, member.drawing, member.password)
    }

    /// The password of the drawing a page comes from.
    func drawingPassword(forPage pageID: UUID) -> String? {
        drawingSet?.member(forPage: pageID).password ?? drawingPassword
    }
}

// MARK: - Bookmarks with their landing point (NL-DOCS-06)

extension DocumentSessionLoader {

    /// Bookmarks from the bridge's bounded outline reader, each with the left/top its
    /// destination names (an axis it leaves open stays `nil`). `pageIDs` maps a zero-based PDF
    /// page index to the set's page identity; `prefix` keeps ids unique across drawings.
    static func bookmarks(from outline: DocumentOutline, pageIDs: [Int: UUID], prefix: String = "") -> [NavigatorBookmark] {
        func convert(_ nodes: [OutlineNode], path: String) -> [NavigatorBookmark] {
            nodes.enumerated().compactMap { offset, node in
                let title = node.label.trimmingCharacters(in: .whitespacesAndNewlines)
                let id = path.isEmpty ? "\(prefix)\(offset)" : "\(path).\(offset)"
                let children = convert(node.children, path: id)
                guard !title.isEmpty || !children.isEmpty else { return nil }
                let destination = node.destination
                return NavigatorBookmark(
                    id: id,
                    title: title,
                    pageID: destination?.pageIndex.flatMap { pageIDs[$0] },
                    children: children,
                    left: destination?.left.map(Double.init),
                    top: destination?.top.map(Double.init)
                )
            }
        }
        return convert(outline.roots, path: "")
    }
}

extension ZenitPDFProjectDocument {

    /// Replaces the CoreGraphics-read bookmarks with the bridge's, which carry each
    /// destination's left/top; in a project of several drawings, each drawing's bookmarks
    /// under its name (NL-DOCS-04/06).
    func refineNavigatorBookmarks() {
        guard !allWindowShells.isEmpty, let set = drawingSet else { return }
        let members = set.members
        Task { @MainActor [weak self] in
            var all: [NavigatorBookmark] = []
            for (ordinal, member) in members.enumerated() {
                guard let outline = await member.drawing.rasterSource.outline(), !outline.roots.isEmpty else { continue }
                var pageIDs: [Int: UUID] = [:]
                for page in member.drawing.pages { pageIDs[page.index] = page.id.rawValue }
                let marks = DocumentSessionLoader.bookmarks(from: outline, pageIDs: pageIDs, prefix: "d\(ordinal)-")
                if members.count > 1 {
                    all.append(NavigatorBookmark(id: "d\(ordinal)", title: member.displayName, pageID: nil, children: marks))
                } else {
                    all.append(contentsOf: marks)
                }
            }
            guard let self, !all.isEmpty else { return }
            // Every window's Pages Index (NL-UX-20).
            for shell in self.allWindowShells { shell.navigatorBookmarks = all }
        }
    }
}
