import AppKit
import UniformTypeIdentifiers
import ZPDFAppCore
import ZPDFExport
import ZPDFUIPresentation

/// Export profiles in the app (NL-PLAT-08): File ▸ Save Columns as Export Profile… writes the
/// ledger's current columns as a `.zpdfprofile` (a JSON file an office can adjust once — headers,
/// decimals, dialect, encoding — and share), and File ▸ Export with Profile… renders the ledger on
/// screen through a chosen profile, byte for byte what the receiving system expects.
@MainActor
enum ExportProfiles {

    static let profileTypeIdentifier = "com.zenitgroup.zenitpdf.export-profile"
    static let chooseIdentifier = "exportProfile.choose"
    static let saveProfileIdentifier = "exportProfile.save"
    static let saveCSVIdentifier = "exportProfile.saveCSV"
    static let noteID = UUID(uuidString: "3F0A7C1E-8B2D-4E6F-9A1B-5C4D3E2F1A50")!

    static var profileType: UTType {
        if let declared = UTType(profileTypeIdentifier), declared.isDeclared { return declared }
        return UTType(filenameExtension: LedgerExportProfile.fileExtension, conformingTo: .json) ?? .json
    }

    static func note(_ title: String, _ message: String, severity: AppWarningSeverity = .info) -> AppWarning {
        AppWarning(id: noteID, severity: severity, title: title, message: message,
                   source: NSLocalizedString("Export profile", comment: "Status note source for export profiles"),
                   isDismissible: true, timestamp: Date())
    }

    /// A starting profile from the ledger's columns as they are on screen: same order, same
    /// titles, the ledger's own decimals, semicolon and decimal comma (the Nordic default).
    nonisolated static func profile(from projection: ExportProjection, name: String) -> LedgerExportProfile {
        LedgerExportProfile(name: name, columns: projection.table.columns.map { .init(key: $0.key, header: $0.title) })
    }

    static func saveColumnsAsProfile(document: ZenitPDFProjectDocument, window: NSWindow?) {
        guard let core = document.core else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [profileType]
        panel.nameFieldStringValue = NSLocalizedString("Export profile", comment: "Default export profile file name") + "." + LedgerExportProfile.fileExtension
        ZenitModalPresenter.runSavePanel(panel, identifier: saveProfileIdentifier, sheetedOn: window) { answer in
            guard case let .urls(urls) = answer, let url = urls.first else { return }
            Task { @MainActor in
                do {
                    let projection = try await ProjectWindowController.projection(
                        core: core, documentName: document.displayName ?? "Takeoff",
                        scaleDescription: core.snapshot.documentScaleDescription, request: core.ledger.request)
                    let profile = profile(from: projection, name: url.deletingPathExtension().lastPathComponent)
                    try profile.encoded().write(to: url, options: .atomic)
                    core.document.post(note(
                        String(format: NSLocalizedString("Saved export profile “%@”", comment: "Status note after saving an export profile; file name"), url.lastPathComponent),
                        NSLocalizedString("Adjust its headers, decimals, delimiter or encoding once, then use File ▸ Export with Profile….", comment: "Status note detail after saving an export profile")))
                } catch {
                    ZenitErrorPresenter.present(error, in: window)
                }
            }
        }
    }

    static func exportWithProfile(document: ZenitPDFProjectDocument, window: NSWindow?) {
        // The office's installed profiles first, by name (a pack or a template put them there);
        // a file is still one choice away.
        let installed = ExportProfileLibrary.standard().profiles().profiles
        if !installed.isEmpty {
            Task { @MainActor in
                guard let choice = await installedProfilePicker(installed.map(\.name), window) else { return }
                if installed.indices.contains(choice) {
                    saveThrough(profile: installed[choice], document: document, window: window)
                } else {
                    exportWithProfileFile(document: document, window: window)
                }
            }
            return
        }
        exportWithProfileFile(document: document, window: window)
    }

    static let pickInstalledIdentifier = "exportProfile.pickInstalled"

    /// Asks which installed profile to use; the index past the last name is "Choose a File…",
    /// `nil` is Cancel. Injectable for tests.
    static var installedProfilePicker: @MainActor ([String], NSWindow?) async -> Int? = { names, window in
        await withCheckedContinuation { continuation in
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Export with which profile?", comment: "Installed profile picker title")
            alert.informativeText = NSLocalizedString("These profiles are installed on this Mac. Choose a File… uses a .zpdfprofile from elsewhere.", comment: "Installed profile picker body")
            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26), pullsDown: false)
            popup.addItems(withTitles: names)
            popup.setAccessibilityLabel(NSLocalizedString("Export profile", comment: "Accessibility label of the installed profile picker"))
            alert.accessoryView = popup
            alert.addButton(withTitle: NSLocalizedString("Export…", comment: "Installed profile picker: export"))
            alert.addButton(withTitle: NSLocalizedString("Choose a File…", comment: "Installed profile picker: choose a file"))
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Installed profile picker: cancel"))
            ZenitModalPresenter.runAlert(alert, identifier: pickInstalledIdentifier, sheetedOn: window) { answer in
                switch answer.buttonIndex {
                case 0: continuation.resume(returning: popup.indexOfSelectedItem)
                case 1: continuation.resume(returning: names.count)
                default: continuation.resume(returning: nil)
                }
            }
        }
    }

    private static func saveThrough(profile: LedgerExportProfile, document: ZenitPDFProjectDocument, window: NSWindow?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = profile.fileName(project: document.displayName ?? "Takeoff", date: Date())
        ZenitModalPresenter.runSavePanel(panel, identifier: saveCSVIdentifier, sheetedOn: window) { answer in
            guard case let .urls(urls) = answer, let url = urls.first else { return }
            Task { @MainActor in _ = await write(profile: profile, document: document, to: url) }
        }
    }

    static func exportWithProfileFile(document: ZenitPDFProjectDocument, window: NSWindow?) {
        let chooser = NSOpenPanel()
        chooser.allowedContentTypes = [profileType]
        chooser.allowsMultipleSelection = false
        chooser.message = NSLocalizedString("Choose the export profile of the system you are sending to.", comment: "Open panel message for choosing an export profile")
        ZenitModalPresenter.runOpenPanel(chooser, identifier: chooseIdentifier, sheetedOn: window) { answer in
            guard case let .urls(urls) = answer, let profileURL = urls.first else { return }
            do {
                let profile = try LedgerExportProfile.read(Data(contentsOf: profileURL))
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.commaSeparatedText]
                panel.nameFieldStringValue = profile.fileName(project: document.displayName ?? "Takeoff", date: Date())
                ZenitModalPresenter.runSavePanel(panel, identifier: saveCSVIdentifier, sheetedOn: window) { answer in
                    guard case let .urls(urls) = answer, let url = urls.first else { return }
                    Task { @MainActor in _ = await write(profile: profile, document: document, to: url) }
                }
            } catch {
                ZenitErrorPresenter.present(error, in: window)
            }
        }
    }

    /// Renders and writes; says what was left empty. Separated for tests.
    @discardableResult
    static func write(profile: LedgerExportProfile, document: ZenitPDFProjectDocument, to url: URL) async -> Bool {
        guard let core = document.core else { return false }
        do {
            let projection = try await ProjectWindowController.projection(
                core: core, documentName: document.displayName ?? "Takeoff",
                scaleDescription: core.snapshot.documentScaleDescription, request: core.ledger.request)
            let rendered = try profile.renderDetailed(projection)
            let missing = rendered.missingKeys + rendered.unitMismatchKeys.map {
                String(format: NSLocalizedString("%@ (unit does not fit)", comment: "A profile column whose unit does not fit its values; the column key"), $0)
            }
            try rendered.data.write(to: url, options: .atomic)
            ExportCompletion.remember(url, document: document)
            var details = [missing.isEmpty
                ? NSLocalizedString("Every column the profile asks for was written.", comment: "Profile export detail")
                : String(format: NSLocalizedString("%@ are not in this ledger and were written empty.", comment: "Profile export detail; the missing column keys"), missing.joined(separator: ", "))]
            // A profile's columns are fixed by the system that receives the file, so a value kept
            // under an older scale cannot be marked in it: the note says so instead (it1r K-04).
            if let notice = rendered.staleScaleNotice {
                details.append(String(format: NSLocalizedString("%@ The profile's columns cannot mark this, so tell whoever receives the file.", comment: "Profile export detail; the notice that some values were kept under an older scale"), notice))
            }
            core.document.post(note(
                String(format: NSLocalizedString("Exported “%1$@” with profile “%2$@”", comment: "Status note after a profile export; file name, profile name"), url.lastPathComponent, profile.name),
                details.joined(separator: " "),
                severity: missing.isEmpty && rendered.staleScaleNotice == nil ? .info : .warning))
            return true
        } catch {
            core.document.post(note(NSLocalizedString("The export profile could not be used", comment: "Profile export failure title"),
                                    (error as? CustomStringConvertible)?.description ?? error.localizedDescription, severity: .warning))
            return false
        }
    }
}


// MARK: - Profiles inside job templates (NL-PLAT-08)

extension ExportProfiles {

    /// The installed profiles as template attachments, so a saved template carries them.
    static func templateAttachments(library: ExportProfileLibrary = .standard()) -> [JobTemplateAttachedFile] {
        library.profiles().profiles.compactMap { profile in
            (try? profile.encoded()).map { JobTemplateAttachedFile(name: profile.name, json: String(decoding: $0, as: UTF8.self)) }
        }
    }

    /// Installs the profiles a template carries, each through the profile reader. Returns the
    /// names installed and the names refused.
    @discardableResult
    static func installProfiles(from template: JobTemplate, library: ExportProfileLibrary = .standard()) -> (installed: [String], refused: [String]) {
        var installed: [String] = []
        var refused: [String] = []
        for attached in template.exportProfiles {
            if let profile = try? LedgerExportProfile.read(Data(attached.json.utf8)), (try? library.install(profile)) != nil {
                installed.append(profile.name)
            } else {
                refused.append(attached.name)
            }
        }
        return (installed, refused)
    }
}
