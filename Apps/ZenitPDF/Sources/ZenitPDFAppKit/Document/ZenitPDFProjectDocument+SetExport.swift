import AppKit
import Foundation
import ZPDFAppCore
import ZPDFContracts
import ZPDFPDFKitBridge
import ZPDFServiceClient
import ZPDFUIPresentation

/// Physical PDFs of the arranged set, only on export (NL-DOCS-08): the set in its order with its
/// turns, a selection of sheets, or one file per sheet named by its sheet number. Pages may come
/// from any drawing of the project. Page labels carry the sheet numbers and, when asked, the
/// bookmarks are the sheet names by discipline (NL-DOCS-05/06). No drawing is ever written.
extension ZenitPDFProjectDocument {

    static let exportArrangedSetPanelIdentifier = "documents.export-arranged-set"
    static let splitIntoSheetsPanelIdentifier = "documents.split-into-sheets"

    /// One sheet of the export, as the session holds it.
    struct SetExportPage: Sendable {
        let pageID: PageID
        let drawing: LoadedDrawing
        let password: String?
        let viewRotation: Int
        let sheetNumber: String?
        let sheetTitle: String?
        let label: String
    }

    /// The sheets to export, in set order; `only` narrows to a selection (kept in set order).
    func setExportPages(only: Set<PageID>? = nil) async -> [SetExportPage] {
        guard let core else { return [] }
        let pages = await core.session.pageDescriptors
        let identities = await core.session.sheetIdentities
        var result: [SetExportPage] = []
        for page in pages where only?.contains(page.id) ?? true {
            guard let drawing = loadedDrawing(forPage: page.id.rawValue) else { continue }
            let view = await core.session.pageView(of: page.id)
            let identity = identities[page.id]
            result.append(SetExportPage(
                pageID: page.id, drawing: drawing, password: drawingPassword(forPage: page.id.rawValue),
                viewRotation: view.rotation, sheetNumber: identity?.number, sheetTitle: identity?.title,
                label: page.label
            ))
        }
        return result
    }

    /// The bookmarks "Create Bookmarks from Sheet Names" writes: one group per discipline (the
    /// letters a sheet number starts with), a bookmark per named sheet. Pure, for tests.
    static func sheetNameBookmarks(_ pages: [SetExportPage]) -> [ComposedBookmark] {
        var groups: [(String, [ComposedBookmark])] = []
        for (position, page) in pages.enumerated() {
            guard let title = ZPDFUIPresentation.PageDescriptor.composedSheetName(number: page.sheetNumber, title: page.sheetTitle) else { continue }
            let discipline = String((page.sheetNumber ?? "").prefix { $0.isLetter }).uppercased()
            let name = discipline.isEmpty ? NSLocalizedString("Sheets", comment: "Bookmark group for sheets whose number has no discipline letters") : discipline
            let bookmark = ComposedBookmark(title: title, resultPageIndex: position)
            if let index = groups.firstIndex(where: { $0.0 == name }) {
                groups[index].1.append(bookmark)
            } else {
                groups.append((name, [bookmark]))
            }
        }
        return groups.map { ComposedBookmark(title: $0.0, resultPageIndex: nil, children: $0.1) }
    }

    /// The qpdf route (NL-DOCS-08): the drawing, and its pages in export order, when the sheets can
    /// be extracted by qpdf in the repair service instead of composed by PDFKit in the app.
    ///
    /// PDFKit's composition turns pages, writes sheet numbers, carries and re-points bookmarks and
    /// links, but it cannot carry a drawing's layer definitions or named destinations — and
    /// without the layer definitions, layered content draws every layer, the ones the drawing
    /// keeps off included. qpdf's extraction keeps the layer definitions, the page labels and the
    /// named destinations of the pages it takes, but not the bookmarks. So the route is taken
    /// when the sheets need nothing only PDFKit does: all from one drawing, none turned, each
    /// sheet number (if any) the drawing's own page label, no sheet-name bookmarks — and the
    /// drawing has layer definitions, the one loss that changes what a sheet shows. A drawing
    /// with named destinations and no layers stays with PDFKit, which keeps its bookmarks and
    /// re-points its links (it1r: the named destinations alone are not worth the bookmarks).
    /// Pure apart from reading the drawing's catalog through `hasLayerDefinitions`.
    static func repairServiceRoute(
        _ pages: [SetExportPage], sheetBookmarks: Bool,
        hasLayerDefinitions: (URL, String?) -> Bool = { drawingHasLayerDefinitions($0, password: $1) }
    ) -> (drawing: URL, password: String?, indices: [Int])? {
        guard !sheetBookmarks, let first = pages.first else { return nil }
        var indices: [Int] = []
        for page in pages {
            guard page.drawing.documentID == first.drawing.documentID,
                  ((page.viewRotation % 360) + 360) % 360 == 0,
                  page.sheetNumber == nil || page.sheetNumber == page.label,
                  let index = page.drawing.pages.first(where: { $0.id == page.pageID })?.index
            else { return nil }
            indices.append(index)
        }
        guard Set(indices).count == indices.count,
              hasLayerDefinitions(first.drawing.url, first.password) else { return nil }
        return (first.drawing.url, first.password, indices)
    }

    /// Whether the drawing's catalog carries layer definitions (`/OCProperties`).
    static func drawingHasLayerDefinitions(_ url: URL, password: String?) -> Bool {
        guard let document = CGPDFDocument(url as CFURL) else { return false }
        if document.isEncrypted, !document.isUnlocked {
            guard let password, document.unlockWithPassword(password) else { return false }
        }
        guard let catalog = document.catalog else { return false }
        var dictionary: CGPDFDictionaryRef?
        return CGPDFDictionaryGetDictionary(catalog, "OCProperties", &dictionary)
    }

    /// The pages through qpdf in the repair service; `nil` when the service could not write them
    /// (the caller then composes them with PDFKit). The drawing is never the destination.
    func extractThroughRepairService(
        _ route: (drawing: URL, password: String?, indices: [Int]), to destination: URL
    ) async -> DocumentWriteReceipt? {
        guard !StagedFileReplacement.sameItem(route.drawing, destination) else { return nil }
        do {
            let before = try FileDigestReader.digest(ofFileAt: route.drawing, maximumByteCount: Int.max)
            _ = try await DamagedDrawingRepair.client.extractPages(
                input: route.drawing, output: destination, pageIndices: route.indices, password: route.password
            )
            let after = try FileDigestReader.digest(ofFileAt: route.drawing, maximumByteCount: Int.max)
            return DocumentWriteReceipt(
                destination: destination,
                digest: try FileDigestReader.digest(ofFileAt: destination, maximumByteCount: Int.max),
                pageCount: route.indices.count,
                sourceDigestBefore: before,
                sourceDigestAfter: after,
                // qpdf keeps the labels, the layer definitions and the named destinations of the
                // pages taken (the shim's assemble(), it1r); the drawing's bookmarks stay behind.
                structureNotCarried: [.outline]
            )
        } catch {
            return nil
        }
    }

    /// Writes `pages` to `destination` as one PDF. `sheetBookmarks` replaces the carried
    /// bookmarks with the sheet names. Returns the receipt, or `nil` with the reason in the tray.
    @discardableResult
    func writeComposed(_ pages: [SetExportPage], sheetBookmarks: Bool, to destination: URL) async -> DocumentWriteReceipt? {
        guard !pages.isEmpty else { return nil }
        // The one rule for what no output may replace — a drawing of the set, one with no sheet
        // chosen, a revision dropped on it, the document's own file (W-023). Export Arranged Set
        // and Extract Page(s)… used to compare only with the files their writer opened.
        do {
            try DerivedCopyGuard.refuseIfDocumentFile(destination, document: self)
        } catch {
            postSetExportFailure(error)
            return nil
        }
        if let route = Self.repairServiceRoute(pages, sheetBookmarks: sheetBookmarks),
           let receipt = await extractThroughRepairService(route, to: destination) {
            return receipt
        }
        return await composeWithPDFKit(pages, sheetBookmarks: sheetBookmarks, to: destination)
    }

    /// PDFKit's half of ``writeComposed(_:sheetBookmarks:to:)``.
    private func composeWithPDFKit(_ pages: [SetExportPage], sheetBookmarks: Bool, to destination: URL) async -> DocumentWriteReceipt? {
        let provider = PDFKitDocumentProvider(thumbnailCacheCapacity: 0)
        var handles: [DocumentID: DocumentHandle] = [:]
        defer {
            let opened = Array(handles.values)
            Task { for handle in opened { await provider.close(handle) } }
        }
        do {
            for page in pages where handles[page.drawing.documentID] == nil {
                handles[page.drawing.documentID] = try await provider.open(fileAt: page.drawing.url, password: page.password).handle
            }
            let composed = pages.compactMap { page -> ComposedPage? in
                guard let handle = handles[page.drawing.documentID],
                      let index = page.drawing.pages.first(where: { $0.id == page.pageID })?.index else { return nil }
                return ComposedPage(document: handle, pageIndex: index, viewRotation: page.viewRotation, label: page.sheetNumber)
            }
            let bookmarks = sheetBookmarks ? Self.sheetNameBookmarks(pages) : nil
            return try await provider.composeDocument(
                composed,
                bookmarks: (bookmarks?.isEmpty ?? true) ? nil : bookmarks,
                to: DocumentDestination(url: destination, overwritePolicy: .replace)
            )
        } catch {
            postSetExportFailure(error)
            return nil
        }
    }

    /// The tray note when a set export wrote nothing, with the reason.
    private func postSetExportFailure(_ error: any Error) {
        core?.document.post(AppWarning(
            id: UUID(), severity: .warning,
            title: NSLocalizedString("The PDF could not be written.", comment: "Set export failed"),
            message: DerivedCopyGuard.message(for: error),
            source: NSLocalizedString("Export Arranged Set", comment: "Warning source"),
            timestamp: Date()
        ))
    }

    /// The name Export Arranged Set proposes (L-56): "<name> — Arranged Set.pdf", as the other
    /// exports add " — Marked" or " — Redacted". It proposed the set's own name — for a drawing
    /// opened on its own, the drawing's file name in the drawing's folder — so Save offered to
    /// replace the drawing the set is made of.
    static func arrangedSetFileName(displayName: String?) -> String {
        (displayName ?? "Set") + " — "
            + NSLocalizedString("Arranged Set", comment: "Export Arranged Set file-name suffix") + ".pdf"
    }

    /// The status note after a set export (L-48): "1 sheet exported…", "3 sheets exported…".
    static func setExportedNote(sheetCount: Int) -> String {
        LocalizedPlural.string(
            "%lld sheets exported. No drawing was changed.",
            count: sheetCount,
            one: NSLocalizedString("%lld sheet exported. No drawing was changed.", comment: "Status note after a set export of one sheet; the count"),
            other: NSLocalizedString("%lld sheets exported. No drawing was changed.", comment: "Status note after a set export; the count")
        )
    }

    /// Export Arranged Set…: the set in its order and turns, as one new PDF.
    func exportArrangedSet(window: NSWindow?) {
        Task { @MainActor in
            let pages = await setExportPages()
            guard !pages.isEmpty else { return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.pdf]
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = Self.arrangedSetFileName(displayName: displayName)
            panel.message = NSLocalizedString("Export the arranged set as a new PDF", comment: "Save panel message for Export Arranged Set")
            let bookmarks = NSButton(
                checkboxWithTitle: NSLocalizedString("Create Bookmarks from Sheet Names", comment: "Export option: bookmarks from the sheets' numbers and titles"),
                target: nil, action: nil
            )
            bookmarks.state = pages.contains { $0.sheetNumber != nil || $0.sheetTitle != nil } ? .on : .off
            panel.accessoryView = bookmarks
            ZenitModalPresenter.runSavePanel(panel, identifier: Self.exportArrangedSetPanelIdentifier, sheetedOn: window) { [weak self] answer in
                guard let destination = answer.firstURL else { return }
                let useBookmarks = bookmarks.state == .on
                Task { @MainActor [weak self] in
                    guard let self, let receipt = await self.writeComposed(pages, sheetBookmarks: useBookmarks, to: destination) else { return }
                    ExportCompletion.remember(destination, document: self)   // R-028
                    self.core?.status.setActiveToolNote(Self.setExportedNote(sheetCount: receipt.pageCount))
                }
            }
        }
    }

    /// Extract Page(s)… over a project of several drawings: the chosen sheets, in set order.
    func extractSetPages(_ ids: Set<PageID>, window: NSWindow?) {
        Task { @MainActor in
            let pages = await setExportPages(only: ids)
            guard !pages.isEmpty else { return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.pdf]
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = pages.count == 1
                ? Self.splitFileNames(pages)[0]
                : (displayName ?? "Set") + " extract.pdf"
            panel.message = NSLocalizedString("Extract pages to a new PDF", comment: "Save panel message for Extract Pages")
            ZenitModalPresenter.runSavePanel(panel, identifier: Self.extractPagesPanelIdentifier, sheetedOn: window) { [weak self] answer in
                guard let destination = answer.firstURL else { return }
                Task { @MainActor [weak self] in
                    guard let self, await self.writeComposed(pages, sheetBookmarks: false, to: destination) != nil else { return }
                    ExportCompletion.remember(destination, document: self)   // R-028
                }
            }
        }
    }

    /// The file names Split writes: the sheet number where the sheet has one, else the drawing
    /// name and page label; unique, and safe for any file system. Pure, for tests.
    static func splitFileNames(_ pages: [SetExportPage]) -> [String] {
        var used: Set<String> = []
        return pages.map { page in
            let base = page.sheetNumber?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
                ?? "\(page.drawing.url.deletingPathExtension().lastPathComponent) \(page.label)"
            let safe = String(base.map { "/:\\?%*|\"<>".contains($0) ? "-" : $0 })
            var name = safe
            var suffix = 2
            while used.contains(name.lowercased()) { name = "\(safe) \(suffix)"; suffix += 1 }
            used.insert(name.lowercased())
            return name + ".pdf"
        }
    }

    /// Writes one PDF per sheet into `folder`, all or nothing: the files are written into a
    /// staging folder first and moved in only when every one succeeded, so a failure or a
    /// cancellation leaves no partial set behind. Returns the files written.
    @discardableResult
    func writeSplit(_ pages: [SetExportPage], into folder: URL, isCancelled: @escaping @Sendable () -> Bool = { false }) async -> [URL] {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-split-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        do { try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true) } catch { return [] }
        let names = Self.splitFileNames(pages)
        // Sheets that take the qpdf route go to the repair service in one request per drawing,
        // which parses the drawing once for all of them; the drawing's catalog is read once and
        // its bytes hashed once before and once after. One request per sheet parsed the drawing
        // once per sheet — 22.7 s of qpdf alone for 300 sheets of a 2 MB layered set, past the
        // 20 s budget — and hashed it twice per sheet (NL-DOCS-08, it1r).
        var layered: [URL: Bool] = [:]
        func hasLayerDefinitions(_ url: URL, _ password: String?) -> Bool {
            if let known = layered[url] { return known }
            let answer = Self.drawingHasLayerDefinitions(url, password: password)
            layered[url] = answer
            return answer
        }
        struct Batch { var password: String?; var indices: [Int] = []; var sheets: [(SetExportPage, URL)] = [] }
        var batches: [(drawing: URL, batch: Batch)] = []
        var composed: [(SetExportPage, URL)] = []
        for (page, name) in zip(pages, names) {
            let target = staging.appendingPathComponent(name)
            guard let route = Self.repairServiceRoute([page], sheetBookmarks: false, hasLayerDefinitions: hasLayerDefinitions) else {
                composed.append((page, target))
                continue
            }
            if let index = batches.firstIndex(where: { $0.drawing == route.drawing }) {
                batches[index].batch.indices += route.indices
                batches[index].batch.sheets.append((page, target))
            } else {
                batches.append((route.drawing, Batch(password: route.password, indices: route.indices, sheets: [(page, target)])))
            }
        }
        var drawingDigests: [URL: FileDigest] = [:]
        for (drawing, batch) in batches {
            guard !isCancelled() else { return [] }
            if let before = try? FileDigestReader.digest(ofFileAt: drawing, maximumByteCount: Int.max),
               (try? await DamagedDrawingRepair.client.extractPageGroups(
                   input: drawing, outputs: batch.sheets.map(\.1), pageGroups: batch.indices.map { [$0] }, password: batch.password
               )) != nil {
                drawingDigests[drawing] = before
            } else {
                // The service could not write them: PDFKit composes these sheets instead.
                composed += batch.sheets
            }
        }
        for (page, target) in composed {
            guard !isCancelled() else { return [] }
            guard await composeWithPDFKit([page], sheetBookmarks: false, to: target) != nil else { return [] }
        }
        // All or nothing, and never a set cut from a drawing that changed while it was read.
        for (drawing, before) in drawingDigests {
            guard (try? FileDigestReader.digest(ofFileAt: drawing, maximumByteCount: Int.max)) == before else { return [] }
        }
        guard !isCancelled() else { return [] }
        var written: [URL] = []
        for name in names {
            var target = folder.appendingPathComponent(name)
            var suffix = 2
            while FileManager.default.fileExists(atPath: target.path) {
                target = folder.appendingPathComponent("\((name as NSString).deletingPathExtension) \(suffix).pdf")
                suffix += 1
            }
            do {
                try FileManager.default.moveItem(at: staging.appendingPathComponent(name), to: target)
                written.append(target)
            } catch {
                for url in written { try? FileManager.default.removeItem(at: url) }
                return []
            }
        }
        return written
    }

    /// Split into Sheets…: one PDF per sheet of the set (or of the selection), named by sheet number.
    func splitIntoSheets(only: Set<PageID>? = nil, window: NSWindow?) {
        Task { @MainActor in
            let pages = await setExportPages(only: only)
            guard !pages.isEmpty else { return }
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = NSLocalizedString("Split Here", comment: "Open panel button: write one PDF per sheet into this folder")
            panel.message = NSLocalizedString("Choose a folder for one PDF per sheet", comment: "Open panel message for Split into Sheets")
            ZenitModalPresenter.runOpenPanel(panel, identifier: Self.splitIntoSheetsPanelIdentifier, sheetedOn: window) { [weak self] answer in
                guard let folder = answer.firstURL else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let written = await self.writeSplit(pages, into: folder)
                    self.core?.status.setActiveToolNote(written.isEmpty
                        ? NSLocalizedString("The sheets were not split; nothing was written.", comment: "Status note: Split failed, no partial files")
                        : String(format: NSLocalizedString("%d sheet files written. No drawing was changed.", comment: "Status note after Split into Sheets; the count"), written.count))
                }
            }
        }
    }
}

private extension String {
    var nilIfBlank: String? { isEmpty ? nil : self }
}
