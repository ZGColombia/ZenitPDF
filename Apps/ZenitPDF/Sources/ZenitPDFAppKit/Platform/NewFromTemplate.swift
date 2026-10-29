import AppKit
import ZPDFUIPresentation
import UniformTypeIdentifiers
import ZPDFAppCore

/// File ▸ New from Template… (NL-PLAT-22): choose a job template — the person's own first, then
/// the shipped starters — choose the drawing, and the takeoff opens with the template's tools,
/// subjects, columns, units and export profiles already in place. The scale is never set: a
/// template cannot carry one (``JobTemplate``), so the new takeoff starts uncalibrated exactly as
/// `JobTemplateTests` pins. Saving makes it a project, as for any opened drawing.
@MainActor
enum NewFromTemplate {

    static let drawingChooserIdentifier = "newFromTemplate.chooseDrawing"
    static let noteID = UUID(uuidString: "2C7D9E1F-3A4B-4C5D-8E6F-9A0B1C2D3E4F")!

    /// The templates the menu offers, in order: the person's own, then the starters.
    static func templates() async -> [JobTemplate] {
        ((try? await ProjectWindowController.jobTemplateStore().read()) ?? []) + StarterJobTemplates.all
    }

    /// How the chosen drawing is opened, and whether it was open already. The shipping value
    /// opens it through the document controller, which hands back the open document when one
    /// has that file; a test replaces it with a document it made, so no window appears.
    static var drawingOpener: @MainActor (URL) async -> (document: ZenitPDFProjectDocument, alreadyOpen: Bool)? = { url in
        await withCheckedContinuation { continuation in
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { document, alreadyOpen, error in
                if let error { ZenitErrorPresenter.present(error) }
                continuation.resume(returning: (document as? ZenitPDFProjectDocument).map { ($0, alreadyOpen) })
            }
        }
    }

    /// What starting from a template did.
    enum StartOutcome: Equatable {
        /// The drawing opened and took the template.
        case started(appliedPresetCount: Int)
        /// The drawing was open already, with a takeoff of its own: nothing was changed.
        case refusedAlreadyOpen
        /// The drawing reopened with the takeoff a crash autosave kept: nothing was changed.
        case refusedRestoredTakeoff
        /// The drawing did not open, or its takeoff never loaded.
        case notOpened
    }

    /// Opens the drawing at `url` and starts it from `template` — unless it was open already
    /// (U-021). The document controller then hands back that open takeoff, and the template
    /// used to be applied to it under the new-takeoff words, "The scale is not set", on a sheet
    /// that might be calibrated. A new takeoff never alters an existing one: the person is told
    /// where the command that applies a template to an open takeoff is.
    @discardableResult
    static func start(_ template: JobTemplate, onDrawingAt url: URL) async -> StartOutcome {
        guard let opened = await drawingOpener(url) else { return .notOpened }
        let document = opened.document
        if opened.alreadyOpen {
            refuseAlreadyOpen(template, document: document)
            return .refusedAlreadyOpen
        }
        guard await waitForCore(document) else { return .notOpened }
        // Opening the drawing can restore the takeoff a crash autosave kept — calibrated, with
        // markups. That is an existing takeoff too (V-024): the template used to land on it and
        // say "The scale is not set".
        if document.restoredFromAutosave {
            refuseAlreadyOpen(template, document: document, restored: true)
            return .refusedRestoredTakeoff
        }
        guard let receipt = await apply(template, to: document) else { return .notOpened }
        return .started(appliedPresetCount: receipt.appliedPresetCount)
    }

    /// Says, in the open takeoff's own tray, that New from Template left it alone — because the
    /// drawing was open already, or because it reopened with a restored takeoff (`restored`).
    static func refuseAlreadyOpen(_ template: JobTemplate, document: ZenitPDFProjectDocument, restored: Bool = false) {
        let name = document.displayName ?? document.fileURL?.lastPathComponent ?? ""
        let title = restored
            ? String(
                format: NSLocalizedString("“%@” reopened with its recovered takeoff, so no new takeoff was started.", comment: "New from Template refusal title: the chosen drawing reopened with the takeoff a crash autosave kept; its name"),
                name
            )
            : String(
                format: NSLocalizedString("“%@” is already open, so no new takeoff was started.", comment: "New from Template refusal title: the chosen drawing is open already; its name"),
                name
            )
        let message = String(
            format: NSLocalizedString("Nothing in it was changed. To use the template “%1$@” on this takeoff, choose %2$@.", comment: "New from Template refusal detail; the template name, the Apply Job Template command's path in the menu bar"),
            template.name, ZenitAppCommandTable.menuPath(for: .applyJobTemplate)
        )
        guard let core = document.core else {
            ZenitErrorPresenter.present(NSError(domain: "com.zenitgroup.zenitpdf.new-from-template", code: 1, userInfo: [
                NSLocalizedDescriptionKey: title, NSLocalizedRecoverySuggestionErrorKey: message
            ]))
            return
        }
        core.document.post(AppWarning(
            id: noteID, severity: .info, title: title, message: message,
            source: NSLocalizedString("Job template", comment: "Status note source for job templates"),
            isDismissible: true, timestamp: Date()))
    }

    /// The whole command.
    static func run(window: NSWindow?) {
        Task { @MainActor in
            let templates = await templates()
            guard let index = await ProjectWindowController.templatePicker(templates.map(\.name), window, .newProject),
                  templates.indices.contains(index) else { return }
            let template = templates[index]
            let panel = NSOpenPanel()
            panel.allowedContentTypes = NewProjectFromDrawing.drawingContentTypes
            panel.allowsMultipleSelection = false
            panel.message = String(format: NSLocalizedString("Choose the drawing to start “%@” on.", comment: "New from Template drawing chooser message; template name"), template.name)
            ZenitModalPresenter.runOpenPanel(panel, identifier: drawingChooserIdentifier, sheetedOn: window) { answer in
                guard let url = answer.firstURL else { return }
                Task { @MainActor in await start(template, onDrawingAt: url) }
            }
        }
    }

    /// Waits for a freshly opened document's takeoff core (the drawing loads asynchronously),
    /// for at most a minute.
    static func waitForCore(_ document: ZenitPDFProjectDocument, timeout: Duration = .seconds(60)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while document.core == nil {
            guard clock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    /// Applies `template` to a freshly opened drawing and says so in the new-takeoff words:
    /// the steps are the one ``ZenitPDFProjectDocument/applyJobTemplate(_:)`` every door shares.
    @discardableResult
    static func apply(_ template: JobTemplate, to document: ZenitPDFProjectDocument) async -> JobTemplateApplier.Receipt? {
        guard let applied = await document.applyJobTemplate(template), let core = document.core else { return nil }
        var message = String(format: NSLocalizedString("%d tools in place. The scale is not set: calibrate the drawing before you measure. Save to make it a project.", comment: "New from Template status detail; tool count"), applied.receipt.appliedPresetCount)
        if !applied.installedProfiles.isEmpty {
            message += " " + String(format: NSLocalizedString("Export profiles installed: %@.", comment: "New from Template: profiles installed"), applied.installedProfiles.joined(separator: ", "))
        }
        if let unitFailure = applied.unitFailure {
            message += " " + String(format: NSLocalizedString("The template's units were not applied: %@", comment: "Appended when applying a job template could not change the units"), unitFailure.localizedDescription)
        }
        core.document.post(AppWarning(
            id: noteID, severity: .info,
            title: String(format: NSLocalizedString("Started from the template “%@”", comment: "New from Template status title; template name"), template.name),
            message: message,
            source: NSLocalizedString("Job template", comment: "Status note source for job templates"),
            isDismissible: true, timestamp: Date()))
        return applied.receipt
    }
}

/// What applying a job template did (T-010).
struct AppliedJobTemplate {
    let receipt: JobTemplateApplier.Receipt
    /// The export profiles installed on this Mac from the template.
    let installedProfiles: [String]
    /// Why the template's units were not applied, when they were not.
    let unitFailure: (any Error)?
}

extension ZenitPDFProjectDocument {

    /// The one application of a job template (T-010): presets, subjects and column preferences,
    /// the template's export profiles installed on this Mac, its units, the Inspector's precision
    /// following them — never a scale — and the document marked edited, so the close review
    /// offers to save the change. Tools ▸ Job Templates ▸ Apply…, File ▸ New from Template… and
    /// the AppleScript `apply template` command all run this and word their own note; the menu
    /// and New from Template each had a copy, and the scripted one (New from Template's) left a
    /// saved project clean and told a calibrated one its scale was not set.
    func applyJobTemplate(_ template: JobTemplate) async -> AppliedJobTemplate? {
        guard let core,
              let toolLibrary = core.toolLibrary as? AppToolLibraryPresenter,
              let ledger = core.ledger as? AppLedgerPresenter else { return nil }
        // `apply` calls the Tool Library's persistence hook itself.
        let receipt = JobTemplateApplier.apply(template, toolLibrary: toolLibrary, ledger: ledger)
        // r2-platform (NL-PLAT-08): a template's export profiles are installed on this Mac.
        let profiles = ExportProfiles.installProfiles(from: template)
        // A refused unit change was swallowed while the note said "applied", and the person
        // worked on in the old units (BH-903).
        var unitFailure: (any Error)?
        do { try await core.session.setUnits(template.units.selection) } catch { unitFailure = error }
        await core.refresh()
        // The Inspector's precision popup follows the units now in force, not the ones it was
        // seeded with at open (BH-286 host half).
        shell?.inspectorEditing.activePrecision = .decimalPlaces(core.snapshot.units.metricDecimalPlaces)
        updateChangeCount(.changeDone)
        return AppliedJobTemplate(receipt: receipt, installedProfiles: profiles.installed, unitFailure: unitFailure)
    }
}

extension ProjectWindowController.TemplatePickerCopy {
    static let newProject = ProjectWindowController.TemplatePickerCopy(
        title: NSLocalizedString("New from Template", comment: "New from Template picker title"),
        body: NSLocalizedString(
            "Choose the job template, then the drawing. Tools, subjects, colours, columns, units and export profiles are set up; the scale is left for you to calibrate.",
            comment: "New from Template picker body"
        ),
        confirmTitle: NSLocalizedString("Choose Drawing…", comment: "New from Template picker confirm")
    )
}
