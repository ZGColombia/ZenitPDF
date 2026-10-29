import AppKit
import SwiftUI
import ZPDFAppCore
import ZPDFDesignSystem
import ZPDFUIPresentation
import ZPDFUIShell
import ZPDFUIWorkflows

/// The Tool Library docked on the Inspector's Tools tab (NL-UX-06, r2-markup).
///
/// The same `ToolLibraryPanelView` and the same joins as the floating panel (`ToolChestPanel`):
/// edits reach the document through `applyToolPresets`, artwork imports through the document's
/// importer, and every edit is one undo step. The editing model is synchronised with the library
/// whenever the library changed elsewhere — the floating panel, a job template — so the dock
/// never shows a stale copy.
@MainActor
final class ToolLibraryDock {

    private weak var document: ZenitPDFProjectDocument?
    private weak var window: NSWindow?
    private(set) var model: ToolLibraryEditingModel?

    init(document: ZenitPDFProjectDocument, window: NSWindow?) {
        self.document = document
        self.window = window
    }

    /// The docks, one per open document.
    static var docks: [ObjectIdentifier: ToolLibraryDock] = [:]

    /// The editing model, rebuilt when the library no longer matches it.
    func currentModel() -> ToolLibraryEditingModel? {
        guard let document, let core = document.core else { return nil }
        if let model {
            if model.presets != core.toolLibrary.presets { model.synchronize(with: core.toolLibrary.presets) }
            return model
        }
        let fresh = ToolLibraryEditingModel(presets: core.toolLibrary.presets)
        if let undoManager = document.undoManager {
            fresh.onUndoableChange = { [weak fresh, weak undoManager] step in
                guard let fresh, let undoManager else { return }
                WorkflowSheet.registerToolLibraryUndo(step, model: fresh, undoManager: undoManager)
            }
        }
        fresh.onImportArtwork = { [weak document] choice in
            guard let document else {
                return .refused(NSLocalizedString("This project is no longer open.", comment: "Artwork import refusal when the document has gone"))
            }
            return await document.importPresetArtwork(choice)
        }
        fresh.onImportFailure = { [weak self] failure in
            ZenitErrorPresenter.present(failure, in: self?.window)
        }
        fresh.onChange = { [weak fresh, weak document] _ in
            guard let fresh, let document else { return }
            document.applyToolPresets(fresh.presets)
        }
        model = fresh
        return fresh
    }

    /// The tab's content.
    func view() -> AnyView {
        guard let document, let core = document.core, let model = currentModel() else {
            return AnyView(EmptyView())
        }
        return AnyView(
            ToolLibraryPanelView(
                presenter: core.toolLibrary,
                model: model,
                selectedMarkup: core.canvas.selectedMarkups.first,
                // Docked, "close" returns the Inspector to the markup tab's column: the panel is
                // hidden, the library stays one click away on its tab.
                onClose: { [weak document] in document?.shell?.perform(.toggleInspector) }
            )
            .background(ZPDFColor.color(.background))
        )
    }
}

extension ProjectWindowController {

    /// Installs the docked Tool Library on the document's Inspector (NL-UX-06).
    func wireToolLibraryDock(shell: ProjectShellEnvironment, document: ZenitPDFProjectDocument) {
        let dock = ToolLibraryDock(document: document, window: window)
        ToolLibraryDock.docks[ObjectIdentifier(document)] = dock
        shell.toolLibraryDock = { [weak dock] in dock?.view() ?? AnyView(EmptyView()) }
    }
}
