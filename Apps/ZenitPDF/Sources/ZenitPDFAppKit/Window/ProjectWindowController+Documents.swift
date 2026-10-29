import AppKit
import Foundation
import ZPDFAppCore
import ZPDFContracts
import ZPDFPDFKitBridge
import ZPDFUIPresentation
import ZPDFUIShell

/// The window hooks for arranging a set of documents.
extension ProjectWindowController {

    /// Wires the Navigator's arrange items and card drags (NL-DOCS-07) to the undoable
    /// `.reorderPage` command. A move of several pages is one batch, so one ⌘Z undoes it.
    func wireNextLevelDocuments(shell: ProjectShellEnvironment, document: ZenitPDFProjectDocument) {
        shell.onMovePages = { [weak document] pageIDs, target in
            guard let document else { return }
            Task { @MainActor in
                await document.movePages(pageIDs.map(PageID.init), to: target)
            }
        }
        // Extracting sheets to a new PDF (NL-DOCS-08).
        shell.onExtractPages = { [weak self, weak document] ids in
            guard let self, let document else { return }
            document.extractPages(ids.map(PageID.init), window: self.window)
        }
        // Dragging a tab to another place in the strip (NL-DOCS-14).
        shell.tabBar.onMoveTab = { [weak self] id, target in
            self?.moveTab(id: id, to: target)
        }
        // A Split Canvas pane on its own window (NL-DOCS-14).
        wireSplitPaneDetach(shell: shell)
        // Arranging the set without touching the PDF (NL-DOCS-07/16).
        wireSetArrangement(shell: shell, document: document)
        // Naming a sheet by hand (NL-DOCS-05): a typed name, never replaced by a reading.
        shell.onNameSheet = { [weak document] pageID, number, title in
            guard let document else { return }
            Task { @MainActor in
                await document.nameSheet(PageID(pageID), number: number, title: title)
            }
        }
    }
}

extension ProjectWindowController {

    /// The alert's identifier, for tests that answer it.
    static let openLinkAlertIdentifier = "documents.open-link"

    /// Following the drawing's own links (NL-DOCS-09): a sheet link turns to that sheet through
    /// the shell, so page-scoped panels hear of it; a web address asks first; a script or a
    /// launch is shown and never run.
    func wireDrawingLinks(canvas: PDFCanvasViewController, shell: ProjectShellEnvironment, for document: ZenitPDFProjectDocument) {
        canvas.onFollowLink = { [weak self, weak shell, weak document] target in
            guard let self, let shell, let document else { return }
            self.follow(target, shell: shell, document: document)
        }
        // The drawing's own links land where they point, and are jumps ⌘[ undoes (NL-DOCS-09).
        canvas.onFollowDrawingLink = { [weak self, weak shell, weak document] link in
            guard let self, let shell, let document else { return }
            self.follow(link.target, left: link.left, top: link.top, shell: shell, document: document)
        }
        canvas.describeLinkTarget = { [weak shell, weak document] target in
            guard let shell, let document else { return "" }
            return Self.linkDescription(target, shell: shell, document: document)
        }
        document.currentPlaceProvider = { [weak canvas] in canvas?.currentPlace() }
        // A bookmark lands at its left/top and is a jump ⌘[ undoes (NL-DOCS-06).
        shell.onOpenBookmark = { [weak self, weak canvas, weak shell, weak document] bookmark in
            guard let canvas, let shell, let document, let pageID = bookmark.pageID else { return }
            if let place = canvas.currentPlace() { self?.recordJump(from: place, of: document) }
            canvas.show(pageID: pageID, left: bookmark.left, top: bookmark.top) { id in
                shell.selectPage(id: id, mode: .replace)
            }
        }
        canvas.onNavigateHistory = { [weak self, weak shell, weak document] back in
            guard let self, let shell, let document else { return }
            self.navigateHistory(back: back, shell: shell, document: document)
        }
    }

    /// ⌘[ / ⌘]: the sheet and viewport a jump left, and back again — in this window's own
    /// history (C-07).
    func navigateHistory(back: Bool, shell: ProjectShellEnvironment, document: ZenitPDFProjectDocument) {
        guard let canvas = canvasController(for: document), let current = canvas.currentPlace() else { return }
        let live = Set(shell.document.pages.map(\.id))
        var history = navigationHistory(of: document)
        history.keep(only: live)
        let target = back ? history.goBack(from: current) : history.goForward(from: current)
        setNavigationHistory(history, of: document)
        guard let target else { NSSound.beep(); return }
        canvas.show(pageID: target.pageID, left: target.left, top: target.top) { shell.goToPage(id: $0) }
    }

    /// This window's jumps on `document` (C-07): a second window's own, or the first window's.
    func navigationHistory(of document: ZenitPDFProjectDocument) -> NavigationHistory {
        windowViews[document.documentIdentity]?.navigationHistory ?? document.firstWindowNavigationHistory
    }

    func setNavigationHistory(_ history: NavigationHistory, of document: ZenitPDFProjectDocument) {
        if let view = windowViews[document.documentIdentity] {
            view.navigationHistory = history
        } else {
            document.firstWindowNavigationHistory = history
        }
    }

    /// Records a jump leaving `place` in this window's history.
    func recordJump(from place: NavigationPlace, of document: ZenitPDFProjectDocument) {
        var history = navigationHistory(of: document)
        history.willJump(from: place)
        setNavigationHistory(history, of: document)
    }

    /// The page a sheet link's index names, within the drawing of the sheet on screen — a PDF
    /// page index names a page only within its own PDF (NL-DOCS-04).
    static func linkedPageID(pdfIndex: Int, shell: ProjectShellEnvironment, document: ZenitPDFProjectDocument) -> UUID? {
        if let current = shell.document.currentPageID, let drawing = document.loadedDrawing(forPage: current),
           document.drawingSet?.isMultiDrawing == true {
            let ids = Set(drawing.pages.map(\.id.rawValue))
            return shell.document.pages.first { $0.index == pdfIndex && ids.contains($0.id) }?.id
        }
        return shell.document.pages.first { $0.index == pdfIndex }?.id
    }

    /// The tooltip over a drawing's link: where it goes, never what it would run.
    static func linkDescription(_ target: DrawingLink.Target, shell: ProjectShellEnvironment, document: ZenitPDFProjectDocument) -> String {
        switch target {
        case let .page(index):
            let page = linkedPageID(pdfIndex: index, shell: shell, document: document)
                .flatMap { id in shell.document.pages.first { $0.id == id } }
            let name = page.map { $0.sheetNumber ?? ($0.label.isEmpty ? String($0.index + 1) : $0.label) } ?? String(index + 1)
            return String(format: NSLocalizedString("Go to %@", comment: "Tooltip over a drawing link: the sheet it goes to"), name)
        case let .sheet(pageID):
            let page = shell.document.pages.first { $0.id == pageID }
            let name = page.map { $0.sheetNumber ?? ($0.label.isEmpty ? String($0.index + 1) : $0.label) } ?? ""
            return String(format: NSLocalizedString("Go to %@", comment: "Tooltip over a drawing link: the sheet it goes to"), name)
        case let .namedDestination(name):
            return String(format: NSLocalizedString("Go to %@", comment: "Tooltip over a drawing link: the sheet it goes to"), name)
        case let .uri(address):
            return address
        case .script, .launch:
            return NSLocalizedString("Runs a script or a program; Zenit PDF will not run it", comment: "Tooltip over a drawing link with a script or launch action")
        case .unsupported:
            return ""
        }
    }

    func follow(
        _ target: DrawingLink.Target,
        left: Double? = nil,
        top: Double? = nil,
        shell: ProjectShellEnvironment,
        document: ZenitPDFProjectDocument
    ) {
        func turn(toPDFIndex index: Int) {
            guard let pageID = Self.linkedPageID(pdfIndex: index, shell: shell, document: document) else { return }
            turn(toPage: pageID)
        }
        func turn(toPage pageID: UUID) {
            guard shell.document.pages.contains(where: { $0.id == pageID }) else { return }
            // This window's canvas and history (C-07), not whichever window has focus.
            if let place = canvasController(for: document)?.currentPlace() ?? document.currentPlaceProvider?() {
                recordJump(from: place, of: document)
            }
            if let canvas = canvasController(for: document) {
                canvas.show(pageID: pageID, left: left, top: top) { shell.goToPage(id: $0) }
            } else {
                shell.goToPage(id: pageID)
            }
        }
        switch target {
        case let .page(index):
            turn(toPDFIndex: index)
        case let .sheet(pageID):
            turn(toPage: pageID)
        case let .namedDestination(name):
            guard let current = shell.document.currentPageID,
                  let source = document.loadedDrawing(forPage: current)?.rasterSource ?? document.drawing?.rasterSource else { return }
            Task { @MainActor in
                if let index = await source.namedDestinationPage(name) { turn(toPDFIndex: index) }
            }
        case let .uri(address):
            guard DrawingLink.isOpenableAddress(address), let url = URL(string: address) else {
                document.core?.status.setActiveToolNote(NSLocalizedString(
                    "This link is not a web address Zenit PDF will open.",
                    comment: "Status note: a drawing link with an address that is not http, https or mail"
                ))
                return
            }
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Open this link in your browser?", comment: "Alert title: follow a web link in a drawing")
            alert.informativeText = address
            alert.addButton(withTitle: NSLocalizedString("Open Link", comment: "Alert button: open the web link"))
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Alert button"))
            ZenitModalPresenter.runAlert(alert, identifier: Self.openLinkAlertIdentifier, sheetedOn: window) { answer in
                if answer.buttonIndex == 0 { NSWorkspace.shared.open(url) }
            }
        case .script, .launch:
            document.core?.status.setActiveToolNote(NSLocalizedString(
                "This link would run a script or open a program. Zenit PDF shows it and never runs it.",
                comment: "Status note: a drawing link with a JavaScript or launch action"
            ))
        case .unsupported:
            break
        }
    }

    /// The window's documents with `id` moved to `target`, clamped. Pure, for the tests.
    static func reordered(_ ids: [UUID], moving id: UUID, to target: Int) -> [UUID] {
        guard let from = ids.firstIndex(of: id) else { return ids }
        var result = ids
        result.remove(at: from)
        result.insert(id, at: min(max(0, target), result.count))
        return result
    }
}

extension ZenitPDFProjectDocument {

    /// Moves `pageIDs` as a block so the first lands at `target` in the set, as one undo step.
    func movePages(_ pageIDs: [PageID], to target: Int) async {
        guard let core else { return }
        let order = await core.session.pageOrderIDs
        let commands = Self.reorderCommands(from: order, moving: pageIDs, to: target)
        guard !commands.isEmpty else { return }
        let name = pageIDs.count == 1
            ? NSLocalizedString("Move Page", comment: "Undo name: a page moved within the set")
            : NSLocalizedString("Move Pages", comment: "Undo name: several pages moved within the set")
        do {
            _ = try await core.commands.performBatch(commands, actionName: name)
            // The step is on the document's undo manager, which marks the document edited
            // (and clean again on undo); no manual change count.
            await core.refresh()
        } catch {
            // The session refused (an unknown page): nothing was applied, nothing to undo.
        }
    }

    /// The `.reorderPage` steps that turn `order` into the order with `block` starting at
    /// `target`. Each step moves one page to its final place, left to right.
    static func reorderCommands(from order: [PageID], moving block: [PageID], to target: Int) -> [DocumentCommand] {
        let moving = Set(block)
        let kept = order.filter { !moving.contains($0) }
        let inOrder = order.filter { moving.contains($0) }
        let at = min(max(0, target), kept.count)
        let goal = Array(kept[..<at]) + inOrder + Array(kept[at...])
        var working = order
        var commands: [DocumentCommand] = []
        for (position, id) in goal.enumerated() {
            guard let current = working.firstIndex(of: id), current != position else { continue }
            commands.append(.reorderPage(from: current, to: position))
            working.insert(working.remove(at: current), at: position)
        }
        return commands
    }

    /// Names one sheet by hand, as one undo step; both parts empty clears its name.
    func nameSheet(_ page: PageID, number: String?, title: String?) async {
        guard let core else { return }
        let identity = SheetIdentity(number: number, title: title, source: .manual)
        do {
            _ = try await core.commands.perform(
                .setSheetIdentities([page: identity.isEmpty ? nil : identity], overwriteManual: true)
            )
            await core.refresh()
        } catch {
            // An unknown page: nothing applied.
        }
    }

    /// The save panel's identifier, for tests that answer it.
    static let extractPagesPanelIdentifier = "documents.extract-pages"

    /// The PDF page indices of `pageIDs`, in the order given (the set order of the block).
    static func pdfIndices(of pageIDs: [PageID], in pages: [ZPDFContracts.PageDescriptor]) -> [Int] {
        pageIDs.compactMap { id in pages.first { $0.id == id }?.index }
    }

    /// Writes the pages to a new PDF the person chooses: labels, bookmarks and links carried,
    /// the drawing itself never written. What could not be
    /// carried (layer definitions, named destinations) is said in the tray.
    func extractPages(_ pageIDs: [PageID], window: NSWindow?) {
        // Sheets of several drawings, turned ones and renumbered ones are composed as the set
        // shows them (NL-DOCS-04/08): labelled with their sheet numbers, in set order. Only a
        // multi-drawing set used to be — a sheet turned or numbered in a one-drawing project
        // was extracted unturned, under its file label (V-027).
        if drawingSet?.isMultiDrawing == true || extractNeedsComposing(pageIDs) {
            extractSetPages(Set(pageIDs), window: window)
            return
        }
        guard let drawing, !pageIDs.isEmpty else { return }
        let indices = Self.pdfIndices(of: pageIDs, in: drawing.pages)
        guard !indices.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        let base = drawing.url.deletingPathExtension().lastPathComponent
        let labels = indices.compactMap { index in drawing.pages.first { $0.index == index }?.label }
        panel.nameFieldStringValue = labels.count == 1 ? "\(base) \(labels[0]).pdf" : "\(base) extract.pdf"
        panel.message = NSLocalizedString("Extract pages to a new PDF", comment: "Save panel message for Extract Pages")
        let source = drawing.url
        let password = drawingPassword
        ZenitModalPresenter.runSavePanel(panel, identifier: Self.extractPagesPanelIdentifier, sheetedOn: window) { [weak self] answer in
            guard let destination = answer.firstURL else { return }
            Task { @MainActor [weak self] in
                await self?.writeExtract(indices: indices, from: source, password: password, to: destination)
            }
        }
    }

    /// Whether a raw copy of the file's pages would not be the sheets as the set shows them:
    /// a chosen sheet is turned in the set, or carries a sheet number other than its page label
    /// — the test ``repairServiceRoute(_:sheetBookmarks:hasLayerDefinitions:)`` applies before it
    /// trusts a raw copy (V-027). A view crop is display only: no route writes it, Export
    /// Arranged Set included, so a crop alone changes nothing here.
    func extractNeedsComposing(_ pageIDs: [PageID]) -> Bool {
        guard let core else { return false }
        let wanted = Set(pageIDs.map(\.rawValue))
        return core.snapshot.pages.contains { page in
            guard wanted.contains(page.id) else { return false }
            if ((page.viewRotation % 360) + 360) % 360 != 0 { return true }
            if let number = page.sheetNumber, !number.isEmpty, number != page.label { return true }
            return false
        }
    }

    /// What PDFKit's extract could not carry, in words — only what this drawing had (it1r
    /// NL-DOCS-08: the note named layer definitions and named destinations whatever the drawing
    /// held). `nil` when everything was carried.
    static func pdfKitExtractNote(notCarried: Set<DocumentStructureFeature>) -> String? {
        switch (notCarried.contains(.optionalContent), notCarried.contains(.namedDestinations)) {
        case (true, true):
            return NSLocalizedString(
                "Sheet labels, bookmarks and links were kept. Layer definitions and named destinations could not be carried into the new file.",
                comment: "Extract Pages: what could not be carried")
        case (true, false):
            return NSLocalizedString(
                "Sheet labels, bookmarks and links were kept. Layer definitions could not be carried into the new file.",
                comment: "Extract Pages: layer definitions could not be carried")
        case (false, true):
            return NSLocalizedString(
                "Sheet labels, bookmarks and links were kept. Named destinations could not be carried into the new file.",
                comment: "Extract Pages: named destinations could not be carried")
        case (false, false):
            return nil
        }
    }

    /// The write half of ``extractPages(_:window:)``, split out for tests.
    ///
    /// A drawing with layer definitions is extracted by qpdf in the repair service, which keeps
    /// them, the sheet labels and the named destinations of the pages taken (NL-DOCS-08); PDFKit's
    /// copy, used otherwise and whenever the service cannot write the pages, keeps labels,
    /// bookmarks and links. Each note says what its own route carried.
    @discardableResult
    func writeExtract(indices: [Int], from source: URL, password: String?, to destination: URL) async -> DocumentWriteReceipt? {
        // No file the document is made of — a revision dropped on it, its own file, anything in
        // its package — is ever the extract (W-023). Only the drawing itself used to be refused,
        // by the writer that had opened it.
        do {
            try DerivedCopyGuard.refuseIfDocumentFile(destination, document: self)
        } catch {
            core?.document.post(AppWarning(
                id: UUID(),
                severity: .warning,
                title: NSLocalizedString("The pages could not be extracted.", comment: "Extract Pages failed"),
                message: DerivedCopyGuard.message(for: error),
                source: NSLocalizedString("Extract Pages", comment: "Warning source"),
                timestamp: Date()
            ))
            return nil
        }
        if Self.drawingHasLayerDefinitions(source, password: password),
           let receipt = await extractThroughRepairService((source, password, indices), to: destination) {
            core?.document.post(AppWarning(
                id: UUID(),
                severity: .info,
                title: NSLocalizedString("The pages were extracted.", comment: "Extract Pages: done, with a note"),
                message: NSLocalizedString(
                    "Sheet labels, layer definitions and the named destinations of these pages were kept. The drawing's bookmarks were not carried into the new file.",
                    comment: "Extract Pages through the repair service: what was kept and what was not"
                ),
                source: NSLocalizedString("Extract Pages", comment: "Warning source"),
                timestamp: Date()
            ))
            ExportCompletion.remember(destination, document: self)   // R-028
            return receipt
        }
        let provider = PDFKitDocumentProvider(thumbnailCacheCapacity: 0)
        do {
            let opened = try await provider.open(fileAt: source, password: password)
            let written: Result<DocumentWriteReceipt, any Error>
            do {
                written = .success(try await provider.extractPages(
                    indices, of: opened.handle, to: DocumentDestination(url: destination, overwritePolicy: .replace)
                ))
            } catch {
                written = .failure(error)
            }
            await provider.close(opened.handle)
            let receipt = try written.get()
            ExportCompletion.remember(destination, document: self)   // R-028
            if let message = Self.pdfKitExtractNote(notCarried: receipt.structureNotCarried) {
                core?.document.post(AppWarning(
                    id: UUID(),
                    severity: .info,
                    title: NSLocalizedString("The pages were extracted.", comment: "Extract Pages: done, with a note"),
                    message: message,
                    source: NSLocalizedString("Extract Pages", comment: "Warning source"),
                    timestamp: Date()
                ))
            }
            return receipt
        } catch {
            core?.document.post(AppWarning(
                id: UUID(),
                severity: .warning,
                title: NSLocalizedString("The pages could not be extracted.", comment: "Extract Pages failed"),
                message: String(describing: error),
                source: NSLocalizedString("Extract Pages", comment: "Warning source"),
                timestamp: Date()
            ))
            return nil
        }
    }
}

// MARK: - A project of several drawings (NL-DOCS-04)

extension ProjectWindowController {

    /// Navigator cards draw from the drawing each page comes from.
    func wireDrawingSetThumbnails(shell: ProjectShellEnvironment, document: ZenitPDFProjectDocument) {
        shell.navigatorThumbnails.pageSource = { [weak document] pageID in
            guard let set = document?.drawingSet, set.isMultiDrawing else { return nil }
            let source = set.rasterSource(forPage: pageID)
            return { pageIndex, pixels in try? await source.thumbnail(pageIndex: pageIndex, maximumPixelSize: pixels) }
        }
        // The canvas holds the same set object, so a drawing added later renders at once; the
        // cards re-request when the new pages arrive in the snapshot.
        document.onDrawingSetChange = { [weak shell] in shell?.navigatorThumbnails.invalidate() }
    }
}

// MARK: - Rotate, crop, remove (NL-DOCS-07/16) and the No-scale badge (NL-MEASURE-02)

extension ProjectWindowController {

    func wireSetArrangement(shell: ProjectShellEnvironment, document: ZenitPDFProjectDocument) {
        shell.onRotatePages = { [weak document] ids, degrees in
            guard let document else { return }
            Task { @MainActor in await document.rotatePages(ids.map(PageID.init), by: degrees) }
        }
        shell.onSetPagesRemoved = { [weak self, weak document] ids, removed in
            guard let document else { return }
            let window = self?.window
            Task { @MainActor in await document.setPagesRemoved(ids.map(PageID.init), removed: removed, window: window) }
        }
        shell.onClearCrop = { [weak document] ids in
            guard let document else { return }
            Task { @MainActor in await document.clearCrop(ids.map(PageID.init)) }
        }
        // Compare with Previous Revision on a card (NL-DOCS-11).
        shell.onCompareWithPreviousRevision = { [weak self, weak document] pageID in
            guard let self, let document, document.prepareCompareWithPreviousRevision(pageID: pageID) else { return }
            self.presentRevisionCompare(for: document)
        }
        // Carry Forward to Revision… on a card (NL-DOCS-12).
        shell.onCarryForward = { [weak self, weak document] ids in
            guard let document else { return }
            let window = self?.window
            Task { @MainActor in await document.carryForward(ids.map(PageID.init), window: window) }
        }
        // Physical PDFs of the set, only on export (NL-DOCS-08).
        shell.onExportArrangedSet = { [weak self, weak document] in
            document?.exportArrangedSet(window: self?.window)
        }
        shell.onLinkSheetReferences = { [weak self, weak document] in
            guard let document else { return }
            let window = self?.window
            Task { @MainActor in await document.linkSheetReferences(window: window) }
        }
        shell.onSetCompareReport = { [weak self, weak document] in
            document?.exportSetCompareReport(window: self?.window)
        }
        shell.onSplitIntoSheets = { [weak self, weak document] in
            document?.splitIntoSheets(window: self?.window)
        }
        // The other open drawings become drawings of this project (NL-DOCS-04).
        shell.onCombineOpenDrawings = { [weak self, weak document] in
            guard let self, let document else { return }
            let others = self.documents.filter { $0 !== document }
            Task { @MainActor in await document.combine(openDrawings: others) }
        }
        shell.onCropPage = { [weak self, weak document] pageID in
            guard let self, let document else { return }
            self.beginViewCrop(of: PageID(pageID), for: document)
        }
        // The Navigator's view of the set follows every refresh: removed sheets, sheets with no
        // scale. Chained, so the refresh hook installed earlier keeps running.
        if let core = document.core {
            let previous = core.onDidRefresh
            core.onDidRefresh = { [weak document, weak shell] snapshot in
                previous?(snapshot)
                guard let document, let shell else { return }
                document.refreshArrangementState(shell: shell, snapshot: snapshot)
            }
            document.refreshArrangementState(shell: shell, snapshot: core.snapshot)
        }
    }

    /// Draws the part of a sheet to show (NL-DOCS-16): the sheet comes to the canvas, the person
    /// drags a box, and the box becomes the sheet's view crop — one undo step.
    func beginViewCrop(of pageID: PageID, for document: ZenitPDFProjectDocument) {
        guard let canvas = canvasController(for: document), let shell = document.shell else { return }
        if document.core?.document.currentPageID != pageID.rawValue { shell.goToPage(id: pageID.rawValue) }
        document.core?.status.setActiveToolNote(NSLocalizedString(
            "Drag a box around the part of the sheet to show.",
            comment: "Status note after Crop View…"
        ))
        beginRegionCapture(
            on: canvas,
            for: document,
            cancelNote: NSLocalizedString("Crop cancelled.", comment: "Status note when a view crop is cancelled")
        ) { [weak document] rect in
            guard let document else { return }
            Task { @MainActor in await document.cropPage(pageID, to: rect) }
        }
    }
}
