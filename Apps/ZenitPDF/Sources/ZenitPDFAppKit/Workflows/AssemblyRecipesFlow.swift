import AppKit
import UniformTypeIdentifiers
import ZPDFAppCore
import ZPDFUIPresentation
import ZPDFUIShell

/// NL-QTY-07 round 2, the application half of the office recipe library: loads it into each
/// document's ledger, and imports and exports `.zpdfassembly` files through the modal presenter.
@MainActor
enum AssemblyRecipesFlow {

    static let importPanelIdentifier = "assemblies.importRecipes"
    static let exportPanelIdentifier = "assemblies.exportRecipes"

    /// The office library: the person's in the assembled app, none in a test process unless a
    /// test injects one — a test must never write the user's Application Support.
    static var library: AssemblyRecipeLibrary? =
        Bundle.main.bundleIdentifier == ZenitAppInfo.bundleIdentifier ? .standard() : nil

    static var recipeType: UTType {
        UTType(filenameExtension: AssemblyRecipeLibrary.fileExtension, conformingTo: .json) ?? .json
    }

    /// - Parameters:
    ///   - core: the window's core — a second window's own view of the document (NL-UX-20);
    ///     `nil` means the document's ``ZenitPDFProjectDocument/core``.
    ///   - shell: the same window's shell; `nil` means the document's ``ZenitPDFProjectDocument/shell``.
    static func wire(
        _ document: ZenitPDFProjectDocument,
        core windowCore: AppCoreEnvironment? = nil,
        shell windowShell: ProjectShellEnvironment? = nil
    ) {
        // NL-QTY-07-UI: a recipe saved into the project is part of the document — it is saved
        // with it, so the document is edited. (Not an undo step: a recipe is library content.)
        (windowCore ?? document.core)?.ledger.onProjectAssembliesChanged = { [weak document] in
            guard let document else { return }
            Task { await document.projectPackage?.registerEdit() }
            document.updateChangeCount(.changeDone)
        }
        guard let library, let shell = windowShell ?? document.shell, let core = windowCore ?? document.core,
              shell.onImportAssemblyRecipes == nil else { return }
        core.ledger.officeAssemblies = (try? library.read()) ?? []
        core.ledger.officeRecipeLibrary = library   // NL-QTY-07-UI: the recipe editor saves here
        shell.onImportAssemblyRecipes = { [weak document] in
            guard let document else { return nil }
            return await importRecipes(into: document, library: library)
        }
        shell.onExportAssemblyRecipes = { [weak document] in
            guard let document else { return }
            exportRecipes(from: library, window: document.windowForSheet)
        }
    }

    static func importRecipes(into document: ZenitPDFProjectDocument, library: AssemblyRecipeLibrary) async -> [LedgerAssemblySummary]? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [recipeType]
        panel.allowsMultipleSelection = false
        panel.message = NSLocalizedString("Choose a Zenit PDF assembly recipe file (.zpdfassembly).", comment: "Recipe import open panel message")
        let url: URL? = await withCheckedContinuation { continuation in
            ZenitModalPresenter.runOpenPanel(panel, identifier: importPanelIdentifier, sheetedOn: document.windowForSheet) { answer in
                continuation.resume(returning: answer.firstURL)
            }
        }
        guard let url, let core = document.core else { return nil }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            try library.importFile(at: url)
            core.ledger.officeAssemblies = try library.read()
            return core.ledger.availableAssemblies
        } catch {
            ZenitErrorPresenter.present(error, in: document.windowForSheet)
            return nil
        }
    }

    static func exportRecipes(from library: AssemblyRecipeLibrary, window: NSWindow?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [recipeType]
        panel.nameFieldStringValue = NSLocalizedString("Office Assemblies", comment: "Recipe export default file name") + "." + AssemblyRecipeLibrary.fileExtension
        ZenitModalPresenter.runSavePanel(panel, identifier: exportPanelIdentifier, sheetedOn: window) { answer in
            guard let url = answer.firstURL else { return }
            do { try library.exportFile(to: url) } catch { ZenitErrorPresenter.present(error, in: window) }
        }
    }
}
