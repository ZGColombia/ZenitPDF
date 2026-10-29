import AppKit
import UniformTypeIdentifiers
import ZPDFAppCore
import ZPDFExport
import ZPDFUIPresentation

/// Feature 35's export command and feature 18's four template commands.
///
/// Everything modal is injectable: the save/open panels run through `ZenitModalPresenter`
/// like every other export, and the two small prompts (a template's name, which template
/// to apply) are static closures a test replaces — a test may never put a window or a
/// sheet on screen.
extension ProjectWindowController {

    // MARK: - Feature 35: export with the markups as a real PDF layer

    /// File ▸ Export with Markups as a PDF Layer…
    ///
    /// The artefact is the source drawing byte for byte plus an incremental update — never
    /// a re-render — so the sheet another office opens is exactly the sheet they sent.
    func exportLayeredDrawing(for document: ZenitPDFProjectDocument) {
        guard document.drawing != nil, let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.message = NSLocalizedString(
            "The drawing is kept byte for byte; your markups become a layer any reader can switch off.",
            comment: "Save panel message for the layered PDF export"
        )
        // Same "— Suffix" convention as the Marked/Annotated/Clean exports; "(layered)"
        // was the one sibling that named itself differently (LT-21, 2026-08-29).
        panel.nameFieldStringValue = (document.displayName ?? "Drawing") + " — "
            + NSLocalizedString("Layered", comment: "Layered PDF file-name suffix") + ".pdf"
        ZenitModalPresenter.runSavePanel(
            panel,
            identifier: Self.exportLayeredModalIdentifier,
            sheetedOn: window
        ) { answer in
            guard let url = answer.firstURL else { return }
            Task { @MainActor in
                do {
                    let outcome = try await self.writeLayeredDrawing(for: document, to: url)
                    // One phrase for every count and one or many layers (L-22, L-26).
                    document.core?.status.setActiveToolNote(LayeredExportLayers.statusNote(for: outcome))
                } catch {
                    ZenitErrorPresenter.present(error, in: window)
                }
            }
        }
    }

    static let exportLayeredModalIdentifier = "export.layered.savePanel"

    /// The panel-free half, so a test can write and re-open the artefact.
    ///
    /// A project of several drawings writes the whole set (T-008), as the Marked, Clean,
    /// Annotated and Print outputs do: the set is composed first (`DrawingSetOutput`) and the
    /// layer is written over the composed file, which is then what is kept byte for byte. The
    /// public `job(for:)` used to be called with no set, so every added drawing's sheets and
    /// markups were dropped while the note reported success.
    @discardableResult
    func writeLayeredDrawing(
        for document: ZenitPDFProjectDocument,
        to url: URL
    ) async throws -> LayeredExportOutcome {
        // A set that could not be composed is refused rather than exported as its first drawing
        // alone — the one refusal every output of the set shares (U-019).
        let set = try await DrawingSetOutput.make(for: document)
        defer { set?.cleanUp() }
        // Never onto the drawing, or any drawing of the set, it is made from (S-060): the
        // same-file check below sees only the composed temporary file for a set.
        try DerivedCopyGuard.refuseIfSource(url, document: document, set: set)
        // Each markup layer its own PDF layer, hidden layers off by default (ADR-0042, L-22).
        let (job, options) = try await LayeredExportLayers.prepare(
            for: document,
            artwork: { [weak document] digest in
                guard let package = document?.projectPackage else { return nil }
                return try? await ProjectArtworkStore.geometry(forDigest: digest, in: package)
            },
            set: set
        )
        // By file identity, not by spelling: "plan.pdf" beside "Plan.pdf" on case-insensitive
        // APFS, or a path through a symlinked folder, is the same file, and a naive `!=` let
        // the export replace the drawing it promised to preserve (BH-366). The exporter's own
        // write then applies its resolved-path guard too.
        guard !SaveAsCarryOver.sameItem(url, job.sourceURL) else {
            throw ExportError.layeredSourceUnreadable(
                "the layered export must not overwrite the drawing it preserves."
            )
        }
        let outcome = try LayeredMarkupExporter().write(
            source: job.sourceURL, pages: job.pages, to: url, options: options,
            protecting: [job.sourceURL] + (set?.sources ?? [])
        )
        // The layer is written over the composed set, kept byte for byte — so what the set lost
        // of the drawing's layer definitions is in the file, and is said (it5r V-018).
        if let note = set?.lostLayerDefinitionsNote, let core = document.core {
            core.document.post(AppWarning(
                id: FlattenedDrawingExport.reportWarningID,
                severity: .warning,
                title: String(
                    format: NSLocalizedString(
                        "“%@” was exported without the drawing's own layers.",
                        comment: "Layered export report headline when the composed set lost the drawing's layer definitions; the file name"
                    ),
                    url.lastPathComponent
                ),
                message: note,
                source: NSLocalizedString("Export", comment: "Warning source for print and export"),
                isDismissible: true,
                timestamp: Date()
            ))
        }
        ExportCompletion.remember(url, document: document)
        return outcome
    }

    // MARK: - Feature 18: job templates

    /// How "Save as Job Template…" asks for the template's name. Injectable for tests.
    static var templateNamePrompt: (@MainActor (NSWindow?) async -> String?) = { window in
        await withCheckedContinuation { continuation in
            let alert = NSAlert()
            alert.messageText = NSLocalizedString(
                "Save as Job Template",
                comment: "Template name prompt title"
            )
            alert.informativeText = NSLocalizedString(
                "The current tools, subjects, colours, ledger columns and units are saved. A template never carries a scale.",
                comment: "Template name prompt body"
            )
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            field.placeholderString = NSLocalizedString(
                "Template name",
                comment: "Template name field placeholder"
            )
            alert.accessoryView = field
            alert.addButton(withTitle: NSLocalizedString("Save", comment: "Template prompt confirm"))
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Template prompt cancel"))
            ZenitModalPresenter.runAlert(
                alert,
                identifier: "jobTemplate.namePrompt",
                sheetedOn: window
            ) { answer in
                let name = field.stringValue.trimmingCharacters(in: .whitespaces)
                continuation.resume(returning: answer.buttonIndex == 0 && !name.isEmpty ? name : nil)
            }
        }
    }

    /// The words on the template-picker dialog. Apply and Export share the picker
    /// mechanism but must not share a title: the export flow wearing "Apply Job Template"
    /// with an Apply button read as a mis-wired menu item live (LT-30, 2026-08-29).
    struct TemplatePickerCopy: Sendable {
        let title: String
        let body: String
        let confirmTitle: String

        static let apply = TemplatePickerCopy(
            title: NSLocalizedString("Apply Job Template", comment: "Template picker title"),
            body: NSLocalizedString(
                "Tools, subjects, colours, columns and units are applied. The drawing's scale is never touched.",
                comment: "Template picker body"
            ),
            confirmTitle: NSLocalizedString("Apply", comment: "Template picker confirm")
        )

        static let export = TemplatePickerCopy(
            title: NSLocalizedString("Export Job Template", comment: "Template export picker title"),
            body: NSLocalizedString(
                "The chosen template is written to a file you can share or import on another Mac.",
                comment: "Template export picker body"
            ),
            confirmTitle: NSLocalizedString("Export…", comment: "Template export picker confirm")
        )
    }

    /// One popup row per template, in store order. `addItems(withTitles:)` drops an earlier
    /// row whose title repeats, so the chosen index named a different template than the one
    /// the person saw (BH-902); repeated names are told apart instead.
    static func makeTemplatePopup(_ names: [String]) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26), pullsDown: false)
        popup.setAccessibilityLabel(NSLocalizedString("Job template", comment: "Accessibility label of the template picker popup"))
        for title in templatePickerTitles(names) {
            popup.menu?.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
        }
        return popup
    }

    /// The titles the picker shows: each name as stored, with a repeat numbered — "Roofing",
    /// "Roofing (2)".
    nonisolated static func templatePickerTitles(_ names: [String]) -> [String] {
        var seen: [String: Int] = [:]
        return names.map { name in
            let count = (seen[name] ?? 0) + 1
            seen[name] = count
            guard count > 1 else { return name }
            return String(
                format: NSLocalizedString("%@ (%ld)", comment: "A repeated template name, numbered"),
                name, count
            )
        }
    }

    /// How Apply and Export ask which stored template to use. Injectable for tests.
    static var templatePicker: (@MainActor ([String], NSWindow?, TemplatePickerCopy) async -> Int?) = { names, window, copy in
        await withCheckedContinuation { continuation in
            let alert = NSAlert()
            alert.messageText = copy.title
            alert.informativeText = copy.body
            let popup = makeTemplatePopup(names)
            alert.accessoryView = popup
            alert.addButton(withTitle: copy.confirmTitle)
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Template picker cancel"))
            ZenitModalPresenter.runAlert(
                alert,
                identifier: "jobTemplate.picker",
                sheetedOn: window
            ) { answer in
                continuation.resume(
                    returning: answer.buttonIndex == 0 ? popup.indexOfSelectedItem : nil
                )
            }
        }
    }

    /// The store the commands read and write. Injectable, and guarded by construction (S-021):
    /// the person's library only in the assembled application, a per-process temporary directory
    /// anywhere else, so a test that forgets to inject never touches the real Application Support.
    static var jobTemplateStore: () -> JobTemplateStore = {
        ZenitProcessDefaults.isAssembledApplication
            ? JobTemplateStore.standard()
            : JobTemplateStore(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("zenitpdf-job-templates-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true))
    }

    /// Said when there is no job template to apply or export: where Save as Job Template… is,
    /// read from the command table (it has been in Tools ▸ Job Templates since IM-250).
    static var noJobTemplatesNote: String {
        String(
            format: NSLocalizedString(
                "No job templates saved yet — %@",
                comment: "Status note when Apply Job Template finds none; the Save as Job Template command's path in the menu bar"
            ),
            ZenitAppCommandTable.menuPath(for: .saveJobTemplate)
        )
    }

    func saveJobTemplate(for document: ZenitPDFProjectDocument) {
        Task { @MainActor in
            guard let core = document.core,
                  let toolLibrary = core.toolLibrary as? AppToolLibraryPresenter,
                  let ledger = core.ledger as? AppLedgerPresenter else { return }
            guard let name = await Self.templateNamePrompt(self.window) else { return }
            let units = await core.session.displayUnits
            var template = JobTemplateApplier.capture(
                name: name,
                toolLibrary: toolLibrary,
                ledger: ledger,
                units: units
            )
            // r2-platform (NL-PLAT-08): the installed export profiles travel with the template.
            template.exportProfiles = ExportProfiles.templateAttachments()
            let store = Self.jobTemplateStore()
            do {
                let templates = (try await store.read()) ?? []
                // A reused name replaced the stored template without a word; the import path
                // has asked since BH-904, and saving now asks the same question (R-032).
                var choice = TemplateImportChoice.add
                if templates.contains(where: { $0.name == template.name }) {
                    guard let answer = await Self.templateImportConflictPrompt(template.name, self.window) else {
                        core.status.setActiveToolNote(String(
                            format: NSLocalizedString(
                                "Job template “%@” was not saved",
                                comment: "Status note when saving a job template over a taken name is cancelled"
                            ),
                            name
                        ))
                        return
                    }
                    choice = answer
                }
                let merged = Self.mergeImportedTemplate(&template, into: templates, choice: choice)
                try await store.write(merged)
                core.status.setActiveToolNote(String(
                    format: NSLocalizedString(
                        "Job template “%@” saved",
                        comment: "Status note after saving a job template"
                    ),
                    template.name
                ))
            } catch {
                core.status.setActiveToolNote(String(describing: error))
            }
        }
    }

    func applyJobTemplate(for document: ZenitPDFProjectDocument) {
        Task { @MainActor in
            guard let core = document.core else { return }
            // NL-PLAT-22: the shipped starters follow the person's own templates — the one list
            // New from Template and the scripted `apply template` offer too (U-025). The starters
            // are never empty, so there is no "none saved" refusal here; Export keeps it.
            let templates = await NewFromTemplate.templates()
            guard let index = await Self.templatePicker(templates.map(\.name), self.window, .apply),
                  templates.indices.contains(index) else { return }
            let template = templates[index]
            // The one application every door shares (T-010).
            guard let applied = await document.applyJobTemplate(template) else { return }
            core.status.setActiveToolNote(Self.jobTemplateAppliedNote(template, applied))
        }
    }

    /// The note after a job template is applied to an open takeoff, from the menu or a script:
    /// how many presets, the column preferences with no column, and units that were refused.
    static func jobTemplateAppliedNote(_ template: JobTemplate, _ applied: AppliedJobTemplate) -> String {
        var note = String(
            format: NSLocalizedString(
                "Template “%@” applied: %d presets",
                comment: "Status note after applying a job template"
            ),
            template.name, applied.receipt.appliedPresetCount
        )
        if !applied.receipt.unknownColumnIDs.isEmpty {
            note += " " + String(
                format: NSLocalizedString(
                    "(%d column preferences had no matching column)",
                    comment: "Appended when a template names columns this project lacks"
                ),
                applied.receipt.unknownColumnIDs.count
            )
        }
        if let unitFailure = applied.unitFailure {
            note += " " + String(
                format: NSLocalizedString(
                    "The template's units were not applied: %@",
                    comment: "Appended when applying a job template could not change the units"
                ),
                unitFailure.localizedDescription
            )
        }
        return note
    }

    /// Says a job-template note where the person will see it: the takeoff's status line when
    /// one is open, an alert of its own when none is (U-023: the library works with no window).
    static func sayJobTemplateNote(_ note: String, document: ZenitPDFProjectDocument?, window: NSWindow?) {
        if let core = document?.core {
            core.status.setActiveToolNote(note)
            return
        }
        let alert = NSAlert()
        alert.messageText = note
        alert.addButton(withTitle: NSLocalizedString("OK", comment: "Job template note alert: dismiss"))
        ZenitModalPresenter.runAlert(alert, identifier: jobTemplateNoteIdentifier, sheetedOn: window) { _ in }
    }

    static let jobTemplateNoteIdentifier = "jobTemplate.note"

    /// Tools ▸ Job Templates ▸ Export…: one of the person's templates as a file. The library is
    /// the person's, not a document's, so it runs with or without a window (U-023).
    static func exportJobTemplate(document: ZenitPDFProjectDocument?, window: NSWindow?) {
        Task { @MainActor in
            let store = Self.jobTemplateStore()
            let templates = (try? await store.read()) ?? []
            guard !templates.isEmpty else {
                sayJobTemplateNote(Self.noJobTemplatesNote, document: document, window: window)
                return
            }
            guard let index = await Self.templatePicker(templates.map(\.name), window, .export),
                  templates.indices.contains(index) else { return }
            let template = templates[index]
            let panel = NSSavePanel()
            panel.allowedContentTypes = [Self.jobTemplateType]
            panel.nameFieldStringValue = template.name
            ZenitModalPresenter.runSavePanel(
                panel,
                identifier: Self.templateFileModalIdentifier,
                sheetedOn: window
            ) { answer in
                guard let url = answer.firstURL else { return }
                do {
                    try JobTemplateFile.export(template).write(to: url, options: .atomic)
                } catch {
                    ZenitErrorPresenter.present(error, in: window)
                }
            }
        }
    }

    /// Tools ▸ Job Templates ▸ Import…: a `.zpdftemplate` into the person's library, with or
    /// without a window (U-023).
    static func importJobTemplate(document: ZenitPDFProjectDocument?, window: NSWindow?) {
        let panel = jobTemplateOpenPanel()
        ZenitModalPresenter.runOpenPanel(
            panel,
            identifier: Self.templateFileModalIdentifier,
            sheetedOn: window
        ) { answer in
            guard let url = answer.firstURL else { return }
            Task { @MainActor in await Self.importJobTemplateFile(at: url, document: document, window: window) }
        }
    }

    /// Imports one `.zpdftemplate` into the store, asking what to do when its name is taken.
    /// The one body Tools ▸ Job Templates ▸ Import… and a template opened from Finder share;
    /// each used to carry its own copy (R-040).
    static func importJobTemplateFile(at url: URL, document: ZenitPDFProjectDocument?, window: NSWindow?) async {
        do {
            var template = try JobTemplateFile.read(try Data(contentsOf: url))
            let store = jobTemplateStore()
            let templates = (try await store.read()) ?? []
            // A same-named template was replaced without a word — months of preset
            // tuning gone to a colleague's file (BH-904). The person chooses.
            var choice = TemplateImportChoice.add
            if templates.contains(where: { $0.name == template.name }) {
                guard let answer = await templateImportConflictPrompt(template.name, window) else { return }
                choice = answer
            }
            let merged = mergeImportedTemplate(&template, into: templates, choice: choice)
            try await store.write(merged)
            sayJobTemplateNote(String(
                format: NSLocalizedString(
                    "Job template “%@” imported",
                    comment: "Status note after importing a job template"
                ),
                template.name
            ), document: document, window: window)
        } catch {
            ZenitErrorPresenter.present(error, in: window)
        }
    }

    static let templateFileModalIdentifier = "jobTemplate.filePanel"

    /// The chooser Tools ▸ Job Templates ▸ Import… shows: one template file of the declared type.
    static func jobTemplateOpenPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.jobTemplateType]
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.message = NSLocalizedString(
            "Choose a job template file (.zpdftemplate).",
            comment: "Open panel message for importing a job template"
        )
        return panel
    }

    /// The job template's declared type identifier (`Info.plist.in`).
    static let jobTemplateTypeIdentifier = "com.zenitgroup.zenitpdf.jobtemplate"

    /// The type the job-template panels ask for: the declared type when the bundle exports it,
    /// as every other chooser asks for its own (the LT-22 rule, `ZenitAppInfo.overlayType`).
    ///
    /// This is consistency, **not** the cause of L-66 (the selected template looked
    /// selected while Open stayed dimmed until a double-click). The panel asked
    /// `UTType(filenameExtension: "zpdftemplate")` before, and inside the assembled bundle that
    /// lookup already returns this same declared type — checked on a test machine, and
    /// a template written by Export Job Template carries
    /// `kMDItemContentType = com.zenitgroup.zenitpdf.jobtemplate` — so the old and the new panel
    /// ask for the identical type. The chooser is presented exactly as Install Pack's, the
    /// overlay's and the profile's are, which worked in the same session. L-66 stays open until
    /// a live single-click Open reproduces it (`live8-l8-exportio.status`).
    static var jobTemplateType: UTType {
        if let declared = UTType(jobTemplateTypeIdentifier), declared.isDeclared { return declared }
        return UTType(filenameExtension: JobTemplateFile.fileExtension, conformingTo: .json) ?? .json
    }

    /// What an import does with the store.
    enum TemplateImportChoice: Equatable, Sendable {
        /// No template of that name exists; the import is added.
        case add
        /// The stored template of that name is replaced.
        case replace
        /// Both are kept; the imported one is renamed "Name (2)".
        case keepBoth
    }

    /// Asks what to do when an imported template's name is taken. Injectable for tests; `nil`
    /// is Cancel.
    static var templateImportConflictPrompt: (@MainActor (String, NSWindow?) async -> TemplateImportChoice?) = { name, window in
        await withCheckedContinuation { continuation in
            let alert = NSAlert()
            alert.messageText = String(
                format: NSLocalizedString(
                    "A job template named “%@” already exists.",
                    comment: "Template import conflict title; the argument is the name"
                ),
                name
            )
            alert.informativeText = NSLocalizedString(
                "Replacing it discards its presets. Keep Both saves the new template under a new name.",
                comment: "Template name conflict body, on import and on save"
            )
            alert.addButton(withTitle: NSLocalizedString("Keep Both", comment: "Template import conflict: keep both"))
            alert.addButton(withTitle: NSLocalizedString("Replace", comment: "Template import conflict: replace"))
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Template import conflict: cancel"))
            ZenitModalPresenter.runAlert(
                alert,
                identifier: "jobTemplate.importConflict",
                sheetedOn: window
            ) { answer in
                switch answer.buttonIndex {
                case 0: continuation.resume(returning: .keepBoth)
                case 1: continuation.resume(returning: .replace)
                default: continuation.resume(returning: nil)
                }
            }
        }
    }

    /// The store after an import. `keepBoth` renames `template` to the first free "Name (n)".
    static func mergeImportedTemplate(
        _ template: inout JobTemplate,
        into templates: [JobTemplate],
        choice: TemplateImportChoice
    ) -> [JobTemplate] {
        var result = templates
        switch choice {
        case .add:
            break
        case .replace:
            result.removeAll { $0.name == template.name }
        case .keepBoth:
            let names = Set(templates.map(\.name))
            var number = 2
            var candidate = template.name
            while names.contains(candidate) {
                candidate = String(
                    format: NSLocalizedString("%@ (%ld)", comment: "A repeated template name, numbered"),
                    template.name, number
                )
                number += 1
            }
            // Two rows must not share one identity either.
            if templates.contains(where: { $0.id == template.id }) {
                var copy = JobTemplate(
                    formatVersion: template.formatVersion,
                    name: candidate,
                    createdAt: template.createdAt,
                    presets: template.presets,
                    subjects: template.subjects,
                    columnPreferences: template.columnPreferences,
                    units: template.units
                )
                // The initializer has no parameter for them, so the new-identity copy lost the
                // template's export profiles (R-033).
                copy.exportProfiles = template.exportProfiles
                template = copy
            } else {
                template.name = candidate
            }
        }
        result.append(template)
        return result
    }
}
