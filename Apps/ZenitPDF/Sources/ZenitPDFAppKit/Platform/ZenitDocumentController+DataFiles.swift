import AppKit
import UniformTypeIdentifiers
import ZPDFAppCore
import ZPDFExport
import ZPDFExtensions
import ZPDFUIWorkflows

/// Zenit's own data files, opened from Finder, File ▸ Open or a drop (NL-PLAT-03).
///
/// None of them is a document of its own, so none opens a window. Each goes to the import review
/// that already exists for it, acting on the drawing in front:
///
/// | file            | where it goes                                                        |
/// |-----------------|----------------------------------------------------------------------|
/// | `.zpdfoverlay`  | the overlay import onto the drawing in front                          |
/// | `.zpdfprofile`  | an export of the ledger in front through the profile                  |
/// | `.zpdftools`    | the Tool Library, open on its import review                           |
/// | `.zpdftemplate` | the job template import (with its same-name choice)                   |
/// | `.zpdfjson`     | the ledger review, reconciled against the ledger in front when one is |
/// | `.zpdfpack`     | the pack review (NL-PLAT-23)                                          |
enum ZenitDataFileKind: String, CaseIterable, Sendable {
    case overlay
    case exportProfile
    case toolSet
    case jobTemplate
    case ledgerJSON
    case pack

    /// The file-name extension, lower case.
    var fileExtension: String {
        switch self {
        case .overlay: return ZenitAppInfo.overlayExtension
        case .exportProfile: return LedgerExportProfile.fileExtension
        case .toolSet: return "zpdftools"
        case .jobTemplate: return JobTemplateFile.fileExtension
        case .ledgerJSON: return "zpdfjson"
        case .pack: return ZenitPack.fileExtension
        }
    }

    /// The kind of file at `url`, by extension, or `nil` when it is not one of Zenit's data files.
    static func of(_ url: URL) -> ZenitDataFileKind? {
        let ext = url.pathExtension.lowercased()
        return allCases.first { $0.fileExtension == ext }
    }

    /// Whether the file can be read with nothing open. A ledger export is only reviewed, and a
    /// pack and a job template install into the person's own library (U-023: a template was
    /// refused with "Open the drawing or project first" though its import reads no document);
    /// everything else acts on a drawing.
    var needsADrawing: Bool {
        switch self {
        case .ledgerJSON, .pack, .jobTemplate: return false
        default: return true
        }
    }

    /// The declared types, for File ▸ Open and the drop targets.
    static var contentTypes: [UTType] {
        allCases.compactMap { UTType(filenameExtension: $0.fileExtension) }
    }
}

extension ZenitDocumentController {

    nonisolated static func isDataFile(_ url: URL) -> Bool {
        ZenitDataFileKind.of(url) != nil
    }

    /// What a data file does once its kind and target are known. Injectable, so a test observes
    /// the route without a review sheet reaching the screen; the shipping value runs the review.
    static var dataFileRouter: @MainActor (ZenitDataFileKind, URL, ZenitPDFProjectDocument?) async -> Void = { kind, url, document in
        await ZenitDataFileRoutes.run(kind, url: url, document: document)
    }

    func openDataFile(_ url: URL, release: (() -> Void)?, completionHandler: @escaping (NSDocument?, Bool, (any Error)?) -> Void) {
        guard let kind = ZenitDataFileKind.of(url) else {
            release?()
            completionHandler(nil, false, ZenitDocumentError.unsupportedFileType(url.lastPathComponent))
            return
        }
        let front = ZenitDataFileRoutes.frontDocument(
            current: currentDocument as? ZenitPDFProjectDocument,
            documents: documents.compactMap { $0 as? ZenitPDFProjectDocument }
        )
        if kind.needsADrawing, front == nil {
            release?()
            completionHandler(nil, false, NSError(domain: "com.zenitgroup.zenitpdf.data-file", code: 1, userInfo: [
                NSLocalizedDescriptionKey: String(format: NSLocalizedString("“%@” belongs to a drawing or project.", comment: "Data file opened with nothing open; the file name"), url.lastPathComponent),
                NSLocalizedRecoverySuggestionErrorKey: NSLocalizedString("Open the drawing or project first, then open this file again.", comment: "Data file opened with nothing open: what to do"),
            ]))
            return
        }
        Task { @MainActor in
            defer { release?() }
            await Self.dataFileRouter(kind, url, front)
            completionHandler(front, true, nil)
        }
    }
}

/// The shipping routes, one per data file kind. Each reuses the flow its menu command runs, with
/// the file already chosen instead of an open panel.
@MainActor
enum ZenitDataFileRoutes {

    /// The drawing a data file opened from Finder is for (S-020): the current document; else the
    /// tab in front of the key, then the main, project window — Settings or another panel can be
    /// in front with no current document; else the first open drawing.
    static func frontDocument(
        current: ZenitPDFProjectDocument?,
        documents: [ZenitPDFProjectDocument],
        windows: [NSWindow?] = [NSApp.keyWindow, NSApp.mainWindow]
    ) -> ZenitPDFProjectDocument? {
        if let current { return current }
        for window in windows {
            if let active = (window?.windowController as? ProjectWindowController)?.activeDocument,
               documents.contains(where: { $0 === active }) {
                return active
            }
        }
        return documents.first
    }

    /// The window a document's data-file flow runs on: its host window's (the controller that
    /// shows it as a tab), which a background tab has although it owns no window controller of
    /// its own (S-020; `windowControllers.first` was nil there, and the flows lost their window).
    /// The document's tab is brought to the front first, so the sheet is over its drawing.
    static func window(for document: ZenitPDFProjectDocument?) -> NSWindow? {
        guard let document else { return nil }
        guard let host = document.hostWindowController else { return document.windowControllers.first?.window }
        if host.activeDocument !== document, host.documents.contains(where: { $0 === document }) {
            host.activateTab(id: document.documentIdentity)
        }
        return host.window
    }

    static func run(_ kind: ZenitDataFileKind, url: URL, document: ZenitPDFProjectDocument?) async {
        let window = window(for: document)
        switch kind {
        case .overlay:
            guard let document else { return }
            _ = await MeasurementOverlayTransfer.importOverlay(from: url, into: document)
        case .exportProfile:
            guard let document else { return }
            exportThroughProfile(url, document: document, window: window)
        case .toolSet:
            guard let document else { return }
            await reviewToolSet(url, document: document)
        case .jobTemplate:
            await importJobTemplate(url, document: document)
        case .ledgerJSON:
            await reviewLedgerJSON(url, document: document)
        case .pack:
            await ZenitPackFlow.review(url, window: window, document: document)
        }
    }

    private static func exportThroughProfile(_ url: URL, document: ZenitPDFProjectDocument, window: NSWindow?) {
        do {
            let profile = try LedgerExportProfile.read(Data(contentsOf: url))
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.commaSeparatedText]
            panel.nameFieldStringValue = profile.fileName(project: document.displayName ?? "Takeoff", date: Date())
            ZenitModalPresenter.runSavePanel(panel, identifier: ExportProfiles.saveCSVIdentifier, sheetedOn: window) { answer in
                guard case let .urls(urls) = answer, let destination = urls.first else { return }
                Task { @MainActor in _ = await ExportProfiles.write(profile: profile, document: document, to: destination) }
            }
        } catch {
            ZenitErrorPresenter.present(error, in: window)
        }
    }

    /// Opens the Tool Library (or uses the open one) and puts the file on its import review —
    /// the same review, validator and strategies Import Tool Set… shows.
    ///
    /// - Returns: the model the review landed on, so a test reads the review.
    @discardableResult
    static func reviewToolSet(_ url: URL, document: ZenitPDFProjectDocument) async -> ToolLibraryEditingModel? {
        let window = window(for: document)
        guard let data = try? Data(contentsOf: url) else {
            ZenitErrorPresenter.present(ZenitDocumentError.unsupportedFileType(url.lastPathComponent), in: window)
            return nil
        }
        let model: ToolLibraryEditingModel?
        if let open = ToolChestPanel.open[ObjectIdentifier(document)] {
            model = open.model
        } else {
            // The host window, not `windowControllers.first`: a background tab owns no window
            // controller, and the import used to return silently there (S-020).
            let controller = document.hostWindowController ?? document.windowControllers.first as? ProjectWindowController
            model = controller?.presentToolLibrary(for: document)?.model
        }
        guard let model else { return nil }
        await model.reviewImport(data: data, fileName: url.lastPathComponent)
        return model
    }

    /// Imports a job template through the store, asking what to do when its name is taken —
    /// the same store, conflict prompt and merge as Tools ▸ Job Templates ▸ Import….
    static func importJobTemplate(_ url: URL, document: ZenitPDFProjectDocument?) async {
        await ProjectWindowController.importJobTemplateFile(
            at: url, document: document, window: window(for: document)
        )
    }

    /// The ledger review of a `.zpdfjson`, held against the ledger in front when there is one.
    /// Nothing in the file is written into the project (see ``ZenitJSONImport``).
    ///
    /// - Returns: the outcome shown, so a test reads the review.
    @discardableResult
    static func reviewLedgerJSON(_ url: URL, document: ZenitPDFProjectDocument?) async -> ZenitJSONImport.Outcome? {
        // The menu's own review, against the menu's own comparison ledger (R-040).
        let ledger = await ProjectWindowController.comparisonLedger(for: document)
        return await ZenitJSONImport.review(url, against: ledger, window: window(for: document))
    }
}
