import AppKit
import Observation
import ZPDFAppCore
import ZPDFContracts
import ZPDFExport
import ZPDFUIPresentation

/// Tools ▸ Mark Area for Redaction, Apply Redactions to a Copy…, Clear Redaction Marks
/// (NL-PDF-14).
///
/// Marks are boxes dragged on the sheet, shown as solid boxes over it, and kept for the open
/// document only: they are never markups, never enter the Quantity Ledger and are never saved —
/// a redaction list that lingered in a project would be a record of exactly what was secret.
/// Applying writes a **new file**, after a confirmation that says what happens, and keeps it
/// only when every check passes. The confirmation offers **Keep drawings sharp (vector)**
/// (`VectorRedactor`: only what lies under the boxes is cut out, text outside them stays
/// searchable), ticked when every marked sheet qualifies, and names the sheets that would become
/// pictures instead (`RasterRedactor`) and why.
///
/// A mark is kept by its sheet's identity, so in a project of several drawings any sheet can be
/// marked (C-09). Apply redacts each marked drawing into a copy of its own. With one drawing
/// marked, a save panel names the copy. With several, an open panel chooses a folder and each
/// drawing's copy is written inside it as `<drawing> — Redacted.pdf`, all or nothing
/// (`RedactionCopySet`). The app is sandboxed with user-selected read-write access only: a save
/// panel grants the one file it names, so copies written beside that file were refused in the
/// shipped app. A folder's grant covers every file inside it.
@MainActor
enum RedactionWorkflow {

    static let confirmIdentifier = "redaction.confirm"
    static let panelIdentifier = "redaction.savePanel"
    /// The folder chooser for the copies of several marked drawings (C-09).
    static let folderPanelIdentifier = "redaction.folderPanel"
    static let resultNoteID = UUID(uuidString: "8D4F2A61-3C7B-4E95-B0A2-6F1E9D8C7B40")!
    /// Holds what the assessment prepared, so Keep Sharp does not read and rewrite the drawing
    /// a second time (S-071).
    static let vectorSession = VectorRedactionSession()

    /// The marks of each open document, forgotten with it.
    private static let store = NSMapTable<ZenitPDFProjectDocument, Box>.weakToStrongObjects()

    /// A box marked on one sheet of the project: the sheet's identity, which also names the
    /// drawing it comes from, and the box in that sheet's page space (C-09). Kept by index in the
    /// primary PDF, a mark on an added drawing's sheet would have redacted the sheet at the same
    /// index of another file, so such sheets used to be refused.
    struct SheetMark: Equatable, Sendable {
        let pageID: UUID
        let rect: CGRect
    }

    /// One marked drawing, ready for the redactors: its file, its password, the name it is
    /// shown under, and each mark at its sheet's index in that file.
    struct DrawingMarks: Sendable {
        let documentID: DocumentID
        let source: URL
        let password: String?
        let displayName: String
        let marks: [RedactionMark]
    }

    final class Box {
        var marks: [SheetMark] = []
        var observing = false
    }

    /// Where Apply writes: the file a save panel named, for one marked drawing; or a folder an
    /// open panel chose, with one copy of each marked drawing inside it (C-09).
    enum Destination: Equatable, Sendable {
        case file(URL)
        case folder(URL)
    }

    /// Why Apply refused before writing anything.
    enum Refusal: LocalizedError, Equatable {
        /// Marks on several drawings and one file named for them: their copies need a folder,
        /// the only grant that covers more than one file in the sandbox.
        case severalDrawingsNeedAFolder(count: Int)

        var errorDescription: String? {
            switch self {
            case let .severalDrawingsNeedAFolder(count):
                String(
                    format: NSLocalizedString(
                        "Nothing was redacted: the marks are on %lld drawings, and each drawing's copy is a file of its own. Choose a folder for them.",
                        comment: "Redaction refusal: several drawings marked but one file named; the drawing count"
                    ),
                    Int64(count)
                )
            }
        }
    }

    /// The copy file-name suffix, `<drawing> — Redacted.pdf`.
    static var redactedSuffix: String { NSLocalizedString("Redacted", comment: "Redacted copy file-name suffix") }

    /// One Keep Sharp session per marked drawing other than the first, so each copy is built from
    /// the preparation its own assessment made (S-071); the first uses ``vectorSession``.
    private static var addedSessions: [URL: VectorRedactionSession] = [:]

    private static func box(for document: ZenitPDFProjectDocument) -> Box {
        if let existing = store.object(forKey: document) { return existing }
        let created = Box()
        store.setObject(created, forKey: document)
        return created
    }

    static func marks(for document: ZenitPDFProjectDocument) -> [SheetMark] { box(for: document).marks }

    /// A mark on the primary drawing's sheet at `mark.pageIndex`, the index in that PDF.
    static func add(_ mark: RedactionMark, to document: ZenitPDFProjectDocument, canvas: PDFCanvasViewController?) {
        guard let page = document.drawing?.pages.first(where: { $0.index == mark.pageIndex }) else { return }
        add(mark.rect, onPage: page.id.rawValue, to: document, canvas: canvas)
    }

    /// A mark on the sheet `pageID`, of whichever drawing of the project it comes from.
    static func add(_ rect: CGRect, onPage pageID: UUID, to document: ZenitPDFProjectDocument, canvas: PDFCanvasViewController?) {
        let box = box(for: document)
        box.marks.append(SheetMark(pageID: pageID, rect: rect.standardized))
        showMarks(for: document, canvas: canvas)
        observePages(document, canvas: canvas)
        let pages = Set(box.marks.map(\.pageID)).count
        document.core?.status.setActiveToolNote(markedNote(areas: box.marks.count, sheets: pages))
    }

    /// The status note after a mark (L-48): "1 area marked for redaction on 1 sheet. … removes
    /// it." — it read "1 areas … on 1 sheets".
    static func markedNote(areas: Int, sheets: Int) -> String {
        LocalizedPlural.string(
            "%1$lld areas marked for redaction on %2$@. %3$@ removes them.",
            count: areas,
            one: NSLocalizedString(
                "%1$lld area marked for redaction on %2$@. %3$@ removes it.",
                comment: "Status note after marking one redaction area; area count, the sheet count phrase, the Apply command's path in the menu bar"
            ),
            other: NSLocalizedString(
                "%1$lld areas marked for redaction on %2$@. %3$@ removes them.",
                comment: "Status note after marking redaction areas; area count, the sheet count phrase, the Apply command's path in the menu bar"
            ),
            arguments: [sheetPhrase(sheets), ZenitAppCommandTable.menuPath(for: .applyRedactions)]
        )
    }

    /// "1 sheet", "3 sheets".
    static func sheetPhrase(_ count: Int) -> String {
        LocalizedPlural.string(
            "%lld sheets", count: count,
            one: NSLocalizedString("%lld sheet", comment: "A count of sheets, one"),
            other: NSLocalizedString("%lld sheets", comment: "A count of sheets")
        )
    }

    /// The status note while the confirmation is prepared (L-63): replaced by the outcome —
    /// cleared when the confirmation is up, the result when a copy is written.
    static var checkingNote: String {
        NSLocalizedString(
            "Checking which marked sheets can stay sharp…",
            comment: "Status note while the redaction confirmation is prepared"
        )
    }

    /// Takes the "checking" note off the status line, and nothing else that has replaced it.
    static func endChecking(_ document: ZenitPDFProjectDocument) {
        guard let status = document.core?.status, status.snapshot.activeToolNote == checkingNote else { return }
        status.setActiveToolNote(nil)
    }

    static func clear(_ document: ZenitPDFProjectDocument, canvas: PDFCanvasViewController?) {
        box(for: document).marks = []
        canvas?.setAutomationOverlay(nil)
        // L-63: the status line said "Checking which marked sheets can stay sharp…" (or "1 area
        // marked…") long after the marks were gone.
        document.core?.status.setActiveToolNote(NSLocalizedString(
            "Redaction marks cleared.",
            comment: "Status note after Tools ▸ Redaction ▸ Clear Redaction Marks"
        ))
    }

    /// The marks on the sheet on screen, as solid boxes over it, whichever drawing it comes from;
    /// a sheet turned to shows its own and never keeps the boxes of the one turned away from.
    static func showMarks(for document: ZenitPDFProjectDocument, canvas: PDFCanvasViewController?) {
        guard let canvas else { return }
        guard let current = document.core?.document.currentPageID else {
            canvas.setAutomationOverlay(nil)
            return
        }
        let rects = marks(for: document).filter { $0.pageID == current }.map {
            PDFRectValue(x: $0.rect.minX, y: $0.rect.minY, width: $0.rect.width, height: $0.rect.height)
        }
        canvas.setAutomationOverlay(rects.isEmpty ? nil : CanvasAutomationOverlay(hits: rects))
    }

    /// Keeps the boxes on the right sheet as the person turns pages.
    static func observePages(_ document: ZenitPDFProjectDocument, canvas: PDFCanvasViewController?) {
        let box = box(for: document)
        guard !box.observing else { return }
        box.observing = true
        trackPage(document, canvas: canvas)
    }

    private static func trackPage(_ document: ZenitPDFProjectDocument, canvas: PDFCanvasViewController?) {
        guard let core = document.core else { return }
        withObservationTracking {
            _ = core.document.currentPageID
        } onChange: { [weak document, weak canvas] in
            Task { @MainActor [weak document, weak canvas] in
                guard let document else { return }
                showMarks(for: document, canvas: canvas)
                if marks(for: document).isEmpty {
                    box(for: document).observing = false
                } else {
                    trackPage(document, canvas: canvas)
                }
            }
        }
    }

    /// The marks grouped by drawing, in the project's drawing order (the one it was made from
    /// first), each at its sheet's index in its own PDF, with that drawing's file and password.
    /// A mark whose sheet no drawing of the project holds any longer is left out.
    static func drawingMarks(for document: ZenitPDFProjectDocument) -> [DrawingMarks] {
        var order: [DocumentID] = []
        var grouped: [DocumentID: (drawing: LoadedDrawing, password: String?, name: String, marks: [RedactionMark])] = [:]
        for mark in marks(for: document) {
            guard let drawing = document.loadedDrawing(forPage: mark.pageID),
                  let page = drawing.pages.first(where: { $0.id.rawValue == mark.pageID }) else { continue }
            let id = drawing.documentID
            if grouped[id] == nil {
                order.append(id)
                let name = document.drawingSet?.member(for: id)?.displayName
                    ?? drawing.url.deletingPathExtension().lastPathComponent
                grouped[id] = (drawing, document.drawingPassword(forPage: mark.pageID), name, [])
            }
            grouped[id]?.marks.append(RedactionMark(pageIndex: page.index, rect: mark.rect))
        }
        let setOrder = document.drawingSet?.members.map(\.drawing.documentID) ?? []
        order.sort { (setOrder.firstIndex(of: $0) ?? Int.max) < (setOrder.firstIndex(of: $1) ?? Int.max) }
        return order.compactMap { id in
            grouped[id].map {
                DrawingMarks(documentID: id, source: $0.drawing.url, password: $0.password, displayName: $0.name, marks: $0.marks)
            }
        }
    }

    /// The Keep Sharp session for the drawing at `position` among the marked ones.
    private static func session(for job: DrawingMarks, position: Int) -> VectorRedactionSession {
        guard position > 0 else { return vectorSession }
        if let existing = addedSessions[job.source] { return existing }
        let made = VectorRedactionSession()
        addedSessions[job.source] = made
        return made
    }

    /// Lets every kept preparation go: the person cancelled, or chose pictures.
    static func discardSessions() async {
        await vectorSession.discard()
        let added = addedSessions.values
        addedSessions = [:]
        for session in added { await session.discard() }
    }

    /// Where each marked drawing's copy is written in the chosen `folder`: `<drawing> —
    /// Redacted.pdf`, numbered past a file that is already there or a name already taken by this
    /// Apply (`RedactionCopySet.targets`, the names the writer itself uses).
    static func outputs(for jobs: [DrawingMarks], in folder: URL) -> [URL] {
        RedactionCopySet.targets(named: jobs.map(\.displayName), suffix: redactedSuffix, in: folder)
    }

    /// The folder chooser for several marked drawings' copies: a folder's grant covers every
    /// copy written inside it, where a save panel's covers only the file it names.
    static func folderPanel(drawingCount: Int) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = NSLocalizedString("Redact Here", comment: "Open panel button: write the redacted copies into this folder")
        panel.message = String(
            format: NSLocalizedString(
                "Choose a folder for the %lld redacted copies, one for each drawing, named after it.",
                comment: "Open panel message for the copies of several redacted drawings; the drawing count"
            ),
            Int64(drawingCount)
        )
        return panel
    }

    static let sharpCheckboxIdentifier = NSUserInterfaceItemIdentifier("redaction.keepSharp")

    /// The confirmation. Two buttons: Redact a Copy, Cancel; and the Keep drawings sharp
    /// (vector) checkbox, returned so the answer can be read after the alert closes.
    ///
    /// `drawingNames` are the marked drawings when there are several — one copy each — and
    /// `sheetNames` names a fallback's sheet (keyed by its `pageIndex`) where a bare number
    /// would not say which drawing it is in.
    static func confirmation(
        markCount: Int, sheetCount: Int, assessment: RedactionAssessment?,
        drawingNames: [String] = [], sheetNames: [Int: String] = [:]
    ) -> (alert: NSAlert, keepSharp: NSButton) {
        let alert = NSAlert()
        // L-48: "Redact 1 area on 1 sheet…", not "Redact 1 areas on 1 sheets…".
        alert.messageText = drawingNames.count > 1
            ? LocalizedPlural.string(
                "Redact %1$lld areas on %2$@ of %3$lld drawings into a new file for each drawing?",
                count: markCount,
                one: NSLocalizedString("Redact %1$lld area on %2$@ of %3$lld drawings into a new file for each drawing?", comment: "Redaction confirmation headline for several drawings, one area; areas, the sheet count phrase, drawings"),
                other: NSLocalizedString("Redact %1$lld areas on %2$@ of %3$lld drawings into a new file for each drawing?", comment: "Redaction confirmation headline for several drawings; areas, the sheet count phrase, drawings"),
                arguments: [sheetPhrase(sheetCount), Int64(drawingNames.count)]
            )
            : LocalizedPlural.string(
                "Redact %1$lld areas on %2$@ into a new file?",
                count: markCount,
                one: NSLocalizedString("Redact %1$lld area on %2$@ into a new file?", comment: "Redaction confirmation headline, one area; areas, the sheet count phrase"),
                other: NSLocalizedString("Redact %1$lld areas on %2$@ into a new file?", comment: "Redaction confirmation headline; areas, the sheet count phrase"),
                arguments: [sheetPhrase(sheetCount)]
            )
        var detail = NSLocalizedString(
            "Everything under the boxes — text, drawing, pictures, comments — is removed for good. With Keep drawings sharp, the marked sheets stay vector: only what lies under the boxes is cut out, and text outside them stays searchable. Without it, each marked sheet becomes a picture of itself with the boxes painted black. The copy is a fresh file with no metadata, attachments, scripts or earlier versions. It is checked before it is kept; the original drawing is not changed.",
            comment: "Redaction confirmation detail"
        )
        if drawingNames.count > 1 {
            detail += "\n\n" + String(
                format: NSLocalizedString("The marks are on %1$@. Each drawing's redacted copy is a file of its own, named after its drawing, in a folder you choose next.", comment: "Redaction confirmation: several drawings, one copy each in a chosen folder; the drawing names"),
                // Joined plainly: ListFormatter follows the system's region, not the app's
                // language, and put "och" into an English sentence on a Swedish Mac.
                drawingNames.map { "“\($0)”" }.joined(separator: ", ")
            )
        }
        let fallbacks = assessment?.fallbacks ?? []
        if let assessment, !fallbacks.isEmpty {
            func sheet(_ fallback: RedactionFallback) -> String { sheetNames[fallback.pageIndex] ?? String(fallback.pageIndex + 1) }
            let sheets = fallbacks.map(sheet).joined(separator: ", ")
            let reasons = fallbacks.map {
                String(format: NSLocalizedString("sheet %1$@: %2$@", comment: "Redaction fallback reason; sheet number or name, the reason"), sheet($0), $0.reason)
            }.joined(separator: "; ")
            detail += "\n\n" + String(
                format: assessment.anyVector
                    ? NSLocalizedString("Sheets %1$@ cannot be cut exactly and will become pictures even when kept sharp (%2$@).", comment: "Redaction confirmation: sheets that fall back to pictures; sheet list, reasons")
                    : NSLocalizedString("No marked sheet can be cut exactly, so every marked sheet will become a picture (%2$@). Sheets: %1$@.", comment: "Redaction confirmation: every sheet falls back to pictures; sheet list, reasons"),
                sheets, reasons
            )
        }
        alert.informativeText = detail
        let keepSharp = NSButton(
            checkboxWithTitle: NSLocalizedString("Keep drawings sharp (vector)", comment: "Redaction confirmation checkbox: keep the marked sheets vector"),
            target: nil, action: nil
        )
        keepSharp.identifier = sharpCheckboxIdentifier
        keepSharp.state = (assessment?.vectorQualifies ?? false) ? .on : .off
        keepSharp.isEnabled = assessment?.anyVector ?? false
        keepSharp.setAccessibilityHelp(NSLocalizedString(
            "When ticked, only what lies under the boxes is cut out and the rest of each marked sheet stays vector and searchable.",
            comment: "Accessibility help for the Keep drawings sharp checkbox"
        ))
        keepSharp.sizeToFit()
        alert.accessoryView = keepSharp
        alert.addButton(withTitle: NSLocalizedString("Redact a Copy", comment: "Redaction confirmation: confirm"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Button: cancel"))
        return (alert, keepSharp)
    }

    static func resultNote(_ outcome: RedactionOutcome, output: URL, now: Date = Date()) -> AppWarning {
        AppWarning(
            id: resultNoteID,
            severity: .info,
            title: String(format: NSLocalizedString("Redacted copy saved as “%@”", comment: "Redaction result headline; the file name"), output.lastPathComponent),
            message: resultMessage(outcome),
            source: NSLocalizedString("Export", comment: "Warning source for print and export"),
            isDismissible: true,
            timestamp: now
        )
    }

    /// The note after an Apply: ``resultNote(_:output:now:)`` for one copy, and for a copy of
    /// each of several drawings one note naming every file, with each drawing's result.
    static func resultNote(_ copies: [(name: String, output: URL, outcome: RedactionOutcome)], now: Date = Date()) -> AppWarning {
        if copies.count == 1 { return resultNote(copies[0].outcome, output: copies[0].output, now: now) }
        let files = copies.map { "“\($0.output.lastPathComponent)”" }.joined(separator: ", ")
        let message = copies.map { copy in
            String(format: NSLocalizedString("“%1$@”: %2$@", comment: "Redaction result for one drawing of several; the drawing name, its result"),
                   copy.name, resultMessage(copy.outcome))
        }.joined(separator: " ")
        return AppWarning(
            id: resultNoteID,
            severity: .info,
            title: String(format: NSLocalizedString("Redacted copies saved as %@", comment: "Redaction result headline for several drawings; the file names"), files),
            message: message,
            source: NSLocalizedString("Export", comment: "Warning source for print and export"),
            isDismissible: true,
            timestamp: now
        )
    }

    static func resultMessage(_ outcome: RedactionOutcome) -> String {
        var message = LocalizedPlural.string(
            "%1$lld areas removed on %2$@. Checked: %3$@.",
            count: outcome.markCount,
            one: NSLocalizedString("%1$lld area removed on %2$@. Checked: %3$@.", comment: "Redaction result detail, one area; areas, the sheet count phrase, the checks"),
            other: NSLocalizedString("%1$lld areas removed on %2$@. Checked: %3$@.", comment: "Redaction result detail; areas, the sheet count phrase, the checks"),
            arguments: [sheetPhrase(outcome.redactedPages.count), outcome.checks.joined(separator: "; ")]
        )
        guard outcome.method == .vector else { return message }
        let kept = LocalizedPlural.string(
            "%lld sheets kept sharp", count: outcome.vectorPages.count,
            one: NSLocalizedString("%lld sheet kept sharp", comment: "Redaction result: one sheet kept vector"),
            other: NSLocalizedString("%lld sheets kept sharp", comment: "Redaction result: sheets kept vector")
        )
        let pictures = LocalizedPlural.string(
            "%lld became pictures", count: outcome.rasterFallbacks.count,
            one: NSLocalizedString("%lld became a picture", comment: "Redaction result: one sheet that became a picture"),
            other: NSLocalizedString("%lld became pictures", comment: "Redaction result: sheets that became pictures")
        )
        message += " " + String(
            format: NSLocalizedString("%1$@; %2$@.", comment: "Redaction result: the kept-sharp phrase, the became-pictures phrase"),
            kept, pictures
        )
        for fallback in outcome.rasterFallbacks {
            message += " " + String(
                format: NSLocalizedString("Sheet %1$lld became a picture: %2$@.", comment: "Redaction result: a sheet that fell back to a picture; sheet number, reason"),
                Int64(fallback.pageIndex + 1), fallback.reason
            )
        }
        return message
    }

    /// Which marked sheets can stay vector, read off the main thread.
    static func assess(document: ZenitPDFProjectDocument) async -> RedactionAssessment? {
        await assessSet(document: document)?.assessment
    }

    /// Which marked sheets can stay vector, every marked drawing assessed with its own session.
    /// One drawing: its own assessment, sheets by number. Several: one assessment over them all,
    /// each marked sheet at a position of its own, with `sheetNames` saying which drawing's
    /// sheet each position is.
    static func assessSet(document: ZenitPDFProjectDocument) async -> (assessment: RedactionAssessment, sheetNames: [Int: String])? {
        let jobs = drawingMarks(for: document)
        guard !jobs.isEmpty else { return nil }
        if jobs.count == 1, let job = jobs.first {
            return (await vectorSession.assess(source: job.source, password: job.password, marks: job.marks), [:])
        }
        var marked: [Int] = []
        var fallbacks: [RedactionFallback] = []
        var names: [Int: String] = [:]
        for (position, job) in jobs.enumerated() {
            let assessment = await session(for: job, position: position).assess(source: job.source, password: job.password, marks: job.marks)
            for page in assessment.markedPages {
                let slot = marked.count
                marked.append(slot)
                names[slot] = String(
                    format: NSLocalizedString("%1$lld of “%2$@”", comment: "A sheet of one drawing in a project of several; sheet number, drawing name"),
                    Int64(page + 1), job.displayName
                )
                if let fallback = assessment.fallbacks.first(where: { $0.pageIndex == page }) {
                    fallbacks.append(RedactionFallback(pageIndex: slot, reason: fallback.reason))
                }
            }
        }
        return (RedactionAssessment(markedPages: marked, fallbacks: fallbacks), names)
    }

    /// Writes the redacted copy of the one marked drawing to `output`; the half of Apply worth
    /// asserting. Marks on several drawings are refused (``Refusal/severalDrawingsNeedAFolder(count:)``):
    /// their copies go into a folder, ``applyAll(document:to:keepSharp:)`` with `.folder`.
    static func apply(document: ZenitPDFProjectDocument, to output: URL, keepSharp: Bool = false) async throws -> RedactionOutcome {
        let copies = try await applyAll(document: document, to: .file(output), keepSharp: keepSharp)
        guard let first = copies.first else { throw RedactionRefusal.noMarks }
        return first.outcome
    }

    /// Writes a redacted copy of every marked drawing, each from its own file with its own marks,
    /// and posts one note naming them all.
    ///
    /// `.file` takes one marked drawing, written to the file the save panel named. `.folder`
    /// takes any number, one copy each inside the folder (``outputs(for:in:)``), all or nothing:
    /// a drawing that cannot be redacted leaves no copy of any of them there
    /// (`RedactionCopySet.write`), and nothing but those copies is written in the folder.
    static func applyAll(document: ZenitPDFProjectDocument, to destination: Destination, keepSharp: Bool = false) async throws -> [(name: String, output: URL, outcome: RedactionOutcome)] {
        guard document.drawing != nil else { throw FlattenedDrawingExport.PreparationFailure.noDocument }
        let jobs = drawingMarks(for: document)
        // Never over any file the project is made of, nor inside its package: that would replace
        // the only unredacted copy of a drawing (R-026), whichever drawing's copy it is.
        switch destination {
        case let .file(output):
            try DerivedCopyGuard.refuseIfDocumentFile(output, document: document)
            guard !jobs.isEmpty else { throw RedactionRefusal.noMarks }
            guard jobs.count == 1 else { throw Refusal.severalDrawingsNeedAFolder(count: jobs.count) }
        case let .folder(folder):
            guard !jobs.isEmpty else { throw RedactionRefusal.noMarks }
            for target in outputs(for: jobs, in: folder) { try DerivedCopyGuard.refuseIfDocumentFile(target, document: document) }
        }
        if !keepSharp { await discardSessions() }
        defer { addedSessions = [:] }
        let copies: [(name: String, output: URL, outcome: RedactionOutcome)]
        switch destination {
        case let .file(output):
            copies = [(jobs[0].displayName, output, try await redact(jobs[0], position: 0, to: output, keepSharp: keepSharp))]
            ExportCompletion.remember(output, document: document)
        case let .folder(folder):
            let written = try await RedactionCopySet.write(
                names: jobs.map(\.displayName), suffix: redactedSuffix, into: folder,
                protecting: DerivedCopyGuard.documentFiles(of: document)
            ) { index, staged in
                try await redact(jobs[index], position: index, to: staged, keepSharp: keepSharp)
            }
            copies = zip(jobs, written).map { (name: $0.displayName, output: $1.output, outcome: $1.outcome) }
        }
        let note = resultNote(copies)
        document.core?.document.post(note)
        // L-63: the result replaces the progress note on the status line.
        document.core?.status.setActiveToolNote(note.title)
        return copies
    }

    /// One drawing's copy at `target`: Keep Sharp through the drawing's own session (S-071), or
    /// pictures off the main thread.
    private static func redact(_ job: DrawingMarks, position: Int, to target: URL, keepSharp: Bool) async throws -> RedactionOutcome {
        if keepSharp {
            return try await session(for: job, position: position).redact(source: job.source, password: job.password, marks: job.marks, to: target)
        }
        let (source, password, marks) = (job.source, job.password, job.marks)
        return try await Task.detached(priority: .userInitiated) {
            try RasterRedactor.redact(source: source, password: password, marks: marks, to: target)
        }.value
    }
}

extension ProjectWindowController {

    /// Tools ▸ Mark Area for Redaction: the next box dragged on the sheet is marked.
    ///
    /// On any sheet of the project (C-09): the mark is kept by the sheet's identity, and Apply
    /// redacts each drawing's marks into a copy of that drawing. It used to be refused on a sheet
    /// of an added drawing (T-007), because a mark kept by the primary PDF's page index would
    /// have redacted the same-index sheet of another file.
    func beginRedactionMark(for document: ZenitPDFProjectDocument) {
        guard let canvas = canvasController(for: document) else { return }
        document.core?.status.setActiveToolNote(NSLocalizedString(
            "Drag a box over what must be removed. Escape cancels.",
            comment: "Status note after Tools ▸ Mark Area for Redaction"
        ))
        beginRegionCapture(
            on: canvas,
            for: document,
            cancelNote: NSLocalizedString("No area marked.", comment: "Status note when redaction marking ends without a box")
        ) { [weak document, weak canvas] rect in
            guard let document, let current = document.core?.document.currentPageID,
                  document.pageDescriptor(forPage: current) != nil else { return }
            RedactionWorkflow.add(rect.cgRect, onPage: current, to: document, canvas: canvas)
        }
    }

    /// Tools ▸ Clear Redaction Marks.
    func clearRedactionMarks(for document: ZenitPDFProjectDocument) {
        RedactionWorkflow.clear(document, canvas: canvasController(for: document))
    }

    /// Tools ▸ Apply Redactions to a Copy….
    func applyRedactions(for document: ZenitPDFProjectDocument) {
        guard document.drawing != nil else { return }
        let marks = RedactionWorkflow.marks(for: document)
        guard !marks.isEmpty else {
            document.core?.status.setActiveToolNote(String(
                format: NSLocalizedString(
                    "Mark an area first: %@.",
                    comment: "Status note when applying redactions with none marked; the Mark command's path in the menu bar"
                ),
                ZenitAppCommandTable.menuPath(for: .markRedaction)
            ))
            return
        }
        let window = self.window
        document.core?.status.setActiveToolNote(RedactionWorkflow.checkingNote)
        Task { @MainActor [weak document] in
            guard let document else { return }
            let jobs = RedactionWorkflow.drawingMarks(for: document)
            guard let firstJob = jobs.first else {
                RedactionWorkflow.endChecking(document)
                return
            }
            let assessed = await RedactionWorkflow.assessSet(document: document)
            // L-63: the check is done; the note said "Checking…" until the next note replaced it.
            RedactionWorkflow.endChecking(document)
            let (alert, keepSharp) = RedactionWorkflow.confirmation(
                markCount: marks.count, sheetCount: Set(marks.map(\.pageID)).count, assessment: assessed?.assessment,
                drawingNames: jobs.count > 1 ? jobs.map(\.displayName) : [], sheetNames: assessed?.sheetNames ?? [:]
            )
            ZenitModalPresenter.runAlert(alert, identifier: RedactionWorkflow.confirmIdentifier, sheetedOn: window, answerWithoutAUser: .button(1)) { answer in
                guard answer.buttonIndex == 0 else {
                    Task { await RedactionWorkflow.discardSessions() }
                    return
                }
                let sharp = keepSharp.isEnabled && keepSharp.state == .on
                let write: @MainActor (RedactionWorkflow.Destination?) -> Void = { destination in
                    guard let destination else {
                        Task { await RedactionWorkflow.discardSessions() }
                        return
                    }
                    Task { @MainActor in
                        do {
                            _ = try await RedactionWorkflow.applyAll(document: document, to: destination, keepSharp: sharp)
                        } catch {
                            ZenitErrorPresenter.present(error, in: window)
                        }
                    }
                }
                guard jobs.count == 1 else {
                    // Several drawings, one copy each: a folder, whose grant covers every copy
                    // (C-09). A save panel grants only the file it names, and a copy written
                    // beside it is refused in the sandboxed app.
                    let panel = RedactionWorkflow.folderPanel(drawingCount: jobs.count)
                    ZenitModalPresenter.runOpenPanel(panel, identifier: RedactionWorkflow.folderPanelIdentifier, sheetedOn: window) { chosen in
                        write(chosen.firstURL.map { .folder($0) })
                    }
                    return
                }
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.pdf]
                panel.nameFieldStringValue = firstJob.displayName + " — " + RedactionWorkflow.redactedSuffix + ".pdf"
                ZenitModalPresenter.runSavePanel(panel, identifier: RedactionWorkflow.panelIdentifier, sheetedOn: window) { chosen in
                    write(chosen.firstURL.map { .file($0) })
                }
            }
        }
    }
}
