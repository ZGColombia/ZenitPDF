import AppKit
import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

/// File ▸ Index a Folder of Drawings…, Search Indexed Drawings… and Forget Indexed Folder
/// (NL-DOCS-15): the commands over ``FolderIndex``, the search sheet, and opening a drawing at the
/// sheet a hit is on.
@MainActor
enum FolderIndexCommand {

    static let chooseFolderIdentifier = "folderIndex.chooseFolder"
    static let searchSheetIdentifier = "folderIndex.search"
    static let refusalIdentifier = "folderIndex.refused"
    static let noteID = UUID(uuidString: "7C1E4A93-2D5B-4F08-9A6C-3E8B1D7F0A25")!

    /// The index the commands work on. A test injects its own.
    static var index: FolderIndex = .shared

    // MARK: - Index a Folder of Drawings…

    /// With no project window (`controller` `nil`, T-009) the chooser and the result are
    /// app-modal.
    ///
    /// Refused while a rebuild runs (T-012): granting another folder mid-run stopped the running
    /// run's security scope, so its unchanged drawings failed to reread, and it then saved its
    /// catalogue and deleted their indexes and titled its note with the new folder's name — which
    /// was itself never indexed. Checked before the panel, and again once a folder is chosen, in
    /// case an Update Index started while the panel was open.
    static func chooseAndIndex(controller: ProjectWindowController?, document: ZenitPDFProjectDocument?) {
        let window = controller?.window
        guard !index.isIndexing else {
            refuse(alreadyIndexingMessage, window: window)
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = NSLocalizedString("Index Folder", comment: "Folder index panel: confirm button")
        panel.message = NSLocalizedString(
            "Choose a folder of drawings. The text of every PDF in it and its subfolders becomes searchable here, without opening them. Nothing is written into the folder.",
            comment: "Folder index panel message"
        )
        ZenitModalPresenter.runOpenPanel(panel, identifier: chooseFolderIdentifier, sheetedOn: window) { answer in
            guard let folder = answer.firstURL else { return }
            guard !index.isIndexing else {
                refuse(alreadyIndexingMessage, window: window)
                return
            }
            index.grant(folder)
            Task { @MainActor in _ = await rebuild(document: document, window: window) }
        }
    }

    static var alreadyIndexingMessage: String {
        NSLocalizedString(
            "A folder is being indexed. Choose another folder when that run has finished.",
            comment: "Folder index refusal: Index a Folder chosen while a rebuild runs"
        )
    }

    /// Rebuilds the index and says what it did: in the document's notes when a document is in
    /// front, as an alert otherwise.
    @discardableResult
    static func rebuild(document: ZenitPDFProjectDocument?, window: NSWindow?) async -> FolderIndex.Report? {
        guard index.folder != nil else {
            refuse(noFolderMessage, window: window)
            return nil
        }
        guard !index.isIndexing else {
            refuse(NSLocalizedString("The folder is already being indexed.", comment: "Folder index refusal: a rebuild is running"), window: window)
            return nil
        }
        // The folder this run is for, named in its note whatever is granted by the time it ends
        // (T-012).
        let folderName = index.folder?.lastPathComponent ?? ""
        let report = await index.rebuild { done, total in
            document?.core?.status.setActiveToolNote(String(
                format: NSLocalizedString("Indexing drawings: %1$lld of %2$lld.", comment: "Folder index progress; done, total"),
                Int64(done), Int64(total)
            ))
        }
        document?.core?.status.setActiveToolNote(nil)
        guard let report else { return nil }
        let title = String(
            format: NSLocalizedString("Indexed “%@”", comment: "Folder index result title; the folder name"),
            folderName
        )
        let message = resultMessage(report)
        if let core = document?.core {
            core.document.post(AppWarning(
                id: noteID, severity: report.skipped.isEmpty ? .info : .warning,
                title: title, message: message,
                source: NSLocalizedString("Folder index", comment: "Status note source for the folder index"),
                isDismissible: true, timestamp: Date()
            ))
        } else {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: NSLocalizedString("OK", comment: "Button: OK"))
            ZenitModalPresenter.runAlert(alert, identifier: noteIdentifier, sheetedOn: window, answerWithoutAUser: .button(0)) { _ in }
        }
        return report
    }

    static let noteIdentifier = "folderIndex.result"

    /// The result in words: what was read, what was kept, what could not be read and why.
    static func resultMessage(_ report: FolderIndex.Report) -> String {
        var parts = [String(
            format: NSLocalizedString(
                "%1$lld drawings read, %2$lld unchanged since the last time.",
                comment: "Folder index result; read, unchanged"
            ),
            Int64(report.indexed), Int64(report.unchanged)
        )]
        if !report.skipped.isEmpty {
            parts.append(String(
                format: NSLocalizedString("Not indexed: %@.", comment: "Folder index result: skipped files and reasons"),
                report.skipped.map { "\($0.relativePath) (\($0.reason))" }.joined(separator: ", ")
            ))
        }
        if report.truncated {
            parts.append(String(
                format: NSLocalizedString(
                    "The folder holds more than %lld PDFs; the first %lld by name were indexed.",
                    comment: "Folder index result: too many files; the limit twice"
                ),
                Int64(FolderIndex.maximumDrawings), Int64(FolderIndex.maximumDrawings)
            ))
        }
        return parts.joined(separator: " ")
    }

    static var noFolderMessage: String {
        String(
            format: NSLocalizedString(
                "No folder is indexed yet. Choose %@ first.",
                comment: "Folder index refusal: nothing indexed; the Index a Folder menu command's path in the menu bar"
            ),
            ZenitAppCommandTable.menuPath(for: .indexDrawingFolder)
        )
    }

    static func refuse(_ message: String, window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Folder index", comment: "Folder index refusal title")
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("OK", comment: "Button: OK"))
        ZenitModalPresenter.runAlert(alert, identifier: refusalIdentifier, sheetedOn: window, answerWithoutAUser: .button(0)) { _ in }
    }

    // MARK: - Forget Indexed Folder

    static func forget(document: ZenitPDFProjectDocument?, window: NSWindow?) {
        guard let folder = index.folder else {
            refuse(noFolderMessage, window: window)
            return
        }
        index.revoke()
        let title = String(
            format: NSLocalizedString("Forgot “%@”", comment: "Folder index forgotten title; the folder name"),
            folder.lastPathComponent
        )
        let message = NSLocalizedString(
            "Its index is deleted and the folder's access is given back. The drawings themselves are untouched.",
            comment: "Folder index forgotten detail"
        )
        if let core = document?.core {
            core.document.post(AppWarning(
                id: noteID, severity: .info, title: title, message: message,
                source: NSLocalizedString("Folder index", comment: "Status note source for the folder index"),
                isDismissible: true, timestamp: Date()
            ))
        } else {
            // No document to note it in — Forget chosen with no project open (T-009): said in
            // an alert, as a rebuild's result is.
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: NSLocalizedString("OK", comment: "Button: OK"))
            ZenitModalPresenter.runAlert(alert, identifier: noteIdentifier, sheetedOn: window, answerWithoutAUser: .button(0)) { _ in }
        }
    }

    // MARK: - Search Indexed Drawings…

    /// How the search sheet reaches the screen, returning its dismissal. A test injects a capture.
    ///
    /// With no project window (T-009) it is a panel of its own rather than a sheet: the command
    /// is offered with nothing open, and used to do nothing there.
    static var searchPresenter: (@MainActor (FolderSearchModel, NSWindow?) -> () -> Void) = { model, window in
        guard let window else {
            let panel = NSPanel(contentViewController: NSHostingController(rootView: FolderSearchView(model: model)))
            panel.styleMask = [.titled, .closable, .resizable]
            panel.title = NSLocalizedString("Search Indexed Drawings", comment: "Folder search sheet title")
            panel.isReleasedWhenClosed = false
            guard ZenitModalPresenter.presentPanel(panel, identifier: searchSheetIdentifier) else { return {} }
            return { [weak panel] in panel?.close() }
        }
        let panel = NSWindow(contentViewController: NSHostingController(rootView: FolderSearchView(model: model)))
        panel.styleMask = [.titled, .resizable]
        panel.title = NSLocalizedString("Search Indexed Drawings", comment: "Folder search sheet title")
        ZenitModalPresenter.beginSheet(panel, on: window, identifier: searchSheetIdentifier) {}
        return { [weak window, weak panel] in
            guard let window, let panel else { return }
            window.endSheet(panel)
        }
    }

    /// Opens the search sheet over the window. Returns its model, so a test drives it.
    @discardableResult
    static func presentSearch(controller: ProjectWindowController?, document: ZenitPDFProjectDocument?) -> FolderSearchModel? {
        let window = controller?.window
        guard let folder = index.folder else {
            refuse(noFolderMessage, window: window)
            return nil
        }
        let model = FolderSearchModel(index: index, folderName: folder.lastPathComponent)
        var dismiss: () -> Void = {}
        model.onClose = { dismiss() }
        model.onOpen = { hit in
            dismiss()
            open(hit)
        }
        model.onUpdate = { [weak document, weak window] in
            _ = await rebuild(document: document, window: window)
        }
        dismiss = searchPresenter(model, window)
        return model
    }

    // MARK: - Opening at a hit

    /// Opens the hit's drawing at its sheet: turns the page when it is already open, otherwise
    /// opens it through the same opener drops use and turns to the sheet once it is on screen.
    static func open(_ hit: FolderIndex.Hit) {
        index.startAccess()
        let target = hit.fileURL.standardizedFileURL.resolvingSymlinksInPath()
        if let document = NSDocumentController.shared.documents
            .compactMap({ $0 as? ZenitPDFProjectDocument })
            .first(where: { $0.fileURL?.standardizedFileURL.resolvingSymlinksInPath() == target }),
           let host = document.hostWindowController {
            host.activateTab(id: document.documentIdentity)
            ProjectWindowController.turn(document, toPageIndex: hit.pageIndex)
            return
        }
        ProjectWindowController.pendingPagesOnOpen[hit.fileURL.path] = hit.pageIndex
        ProjectWindowController.dropOpener([hit.fileURL])
    }
}

/// What the search sheet shows and does.
@MainActor
@Observable
final class FolderSearchModel {
    let folderName: String
    var query = ""
    private(set) var results: [FolderIndex.FileHits] = [] {
        didSet {
            // A fresh search keeps nothing selected that it no longer lists; the first hit is
            // selected so Open, Return and the hit's own double-click all have a target (L-41).
            if let selectedHitID, hit(id: selectedHitID) != nil { return }
            selectedHitID = results.first?.hits.first?.id
        }
    }
    private(set) var isSearching = false
    private(set) var hasSearched = false
    /// The hit the list has selected. L-41: the rows were plain buttons inside an unselectable
    /// list, so a click selected nothing, and double-click, Return and an Open button did not
    /// exist — the search found a drawing and could not take the person to it.
    var selectedHitID: FolderIndex.Hit.ID?

    var onOpen: (@MainActor (FolderIndex.Hit) -> Void)?
    var onClose: (@MainActor () -> Void)?
    var onUpdate: (@MainActor () async -> Void)?

    @ObservationIgnored private let index: FolderIndex
    @ObservationIgnored private var running: Task<Void, Never>?

    init(index: FolderIndex, folderName: String) {
        self.index = index
        self.folderName = folderName
    }

    /// Searches for `query` now, replacing a search still running.
    func search() async {
        running?.cancel()
        let text = query
        isSearching = true
        let task = Task { @MainActor [index] in
            let found = await index.search(text)
            guard !Task.isCancelled else { return }
            self.results = found
            self.hasSearched = true
        }
        running = task
        await task.value
        isSearching = false
    }

    func submit() { Task { await search() } }

    /// The listed hit with this identity, if the results still hold it.
    func hit(id: FolderIndex.Hit.ID) -> FolderIndex.Hit? {
        for file in results {
            if let hit = file.hits.first(where: { $0.id == id }) { return hit }
        }
        return nil
    }

    /// The selected hit, while the results still list it.
    var selectedHit: FolderIndex.Hit? { selectedHitID.flatMap(hit(id:)) }

    /// Whether Open has a hit to open.
    var canOpen: Bool { selectedHit != nil }

    /// Opens the hit with this identity — the row's double-click, Return on the list, the
    /// context menu's Open — and selects it first, so the list shows what was opened.
    func open(id: FolderIndex.Hit.ID?) {
        guard let id, let hit = hit(id: id) else { return }
        selectedHitID = id
        onOpen?(hit)
    }

    /// The Open button: the selected hit.
    func openSelected() { open(id: selectedHitID) }

    /// "3 hits in 2 drawings", or why there is nothing to show.
    var summary: String {
        if isSearching { return NSLocalizedString("Searching…", comment: "Folder search status") }
        guard hasSearched else {
            return String(
                format: NSLocalizedString("Search the text of every drawing in “%@”.", comment: "Folder search prompt; the folder name"),
                folderName
            )
        }
        let hits = results.reduce(0) { $0 + $1.hits.count }
        // A folder whose first index has not finished has nothing to search yet (S-014): said,
        // rather than "no drawing contains that text".
        guard hits > 0 || index.isCatalogueCurrent else {
            return index.isIndexing
                ? String(format: NSLocalizedString("“%@” is still being indexed. Search again when it finishes.", comment: "Folder search: the folder's first index is running; the folder name"), folderName)
                : String(format: NSLocalizedString("“%@” has not been indexed yet. Choose Update Index.", comment: "Folder search: the folder has no index yet; the folder name"), folderName)
        }
        guard hits > 0 else { return NSLocalizedString("No drawing in the folder contains that text.", comment: "Folder search: no hits") }
        return Self.summary(hits: hits, drawings: results.count)
    }

    /// "1 hit in 1 drawing.", "3 hits in 2 drawings." — built from two single-count phrases,
    /// because a plural rule takes one number. L-42: it read "1 hits in 1 drawings.".
    static func summary(hits: Int, drawings: Int) -> String {
        String(
            format: NSLocalizedString("%1$@ in %2$@.", comment: "Folder search summary; the hits phrase ('3 hits'), the drawings phrase ('2 drawings')"),
            LocalizedPlural.string(
                "%lld hits", count: hits,
                one: NSLocalizedString("%lld hit", comment: "Folder search summary: one hit"),
                other: NSLocalizedString("%lld hits", comment: "Folder search summary: hits; the count")
            ),
            LocalizedPlural.string(
                "%lld drawings", count: drawings,
                one: NSLocalizedString("%lld drawing", comment: "Folder search summary: one drawing"),
                other: NSLocalizedString("%lld drawings", comment: "Folder search summary: drawings; the count")
            )
        )
    }
}

struct FolderSearchView: View {
    @Bindable var model: FolderSearchModel

    var body: some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.m) {
            Text(NSLocalizedString("Search Indexed Drawings", comment: "Folder search sheet title")).zpdfText(.windowTitle, .textPrimary)
            HStack {
                TextField(NSLocalizedString("Text on the drawings", comment: "Folder search field placeholder"), text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.submit() }
                    .accessibilityLabel(NSLocalizedString("Search the indexed drawings", comment: "Folder search field accessibility label"))
                Button(NSLocalizedString("Search", comment: "Folder search button")) { model.submit() }
                    .keyboardShortcut(.defaultAction)
            }
            Text(model.summary).zpdfText(.caption, .textSecondary)
            List(selection: $model.selectedHitID) {
                ForEach(model.results) { file in
                    Section(file.relativePath) {
                        ForEach(file.hits) { hit in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(String(
                                    format: NSLocalizedString("Sheet %@", comment: "Folder search hit: the sheet label"),
                                    hit.pageLabel
                                )).zpdfText(.body, .textPrimary)
                                Text(hit.snippet).zpdfText(.caption, .textSecondary).lineLimit(2)
                            }
                            .tag(hit.id)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(String(
                                format: NSLocalizedString("Open %1$@ at sheet %2$@", comment: "Folder search hit accessibility label; file, sheet"),
                                file.relativePath, hit.pageLabel
                            ))
                        }
                    }
                }
            }
            .listStyle(.inset)
            // L-41: a click selects, a double-click or Return opens, the context menu offers
            // Open — the list's own selection, not buttons the list could not select.
            .contextMenu(forSelectionType: FolderIndex.Hit.ID.self) { ids in
                Button(NSLocalizedString("Open", comment: "Folder search: open the selected hit's drawing at its sheet")) {
                    model.open(id: ids.first)
                }
                .disabled(ids.isEmpty)
            } primaryAction: { ids in
                model.open(id: ids.first)
            }
            HStack {
                Button(NSLocalizedString("Update Index", comment: "Folder search: re-read the folder")) {
                    Task { await model.onUpdate?() }
                }
                Spacer(minLength: 0)
                Button(NSLocalizedString("Open", comment: "Folder search: open the selected hit's drawing at its sheet")) {
                    model.openSelected()
                }
                .disabled(!model.canOpen)
                .accessibilityHint(NSLocalizedString("Opens the drawing at the selected hit's sheet", comment: "Folder search Open button accessibility hint"))
                Button(NSLocalizedString("Close", comment: "Button: close")) { model.onClose?() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(ZPDFSpacing.l)
        .frame(minWidth: 560, minHeight: 420)
        .background(ZPDFColor.background)
    }
}
