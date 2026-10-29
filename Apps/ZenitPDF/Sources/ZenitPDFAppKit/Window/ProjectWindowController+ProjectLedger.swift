import AppKit
import ZPDFAppCore
import ZPDFUIPresentation

/// NL-QTY-15: the whole-project summary's wiring, alongside the "All Drawings" search fan-out.
extension ProjectWindowController {

    /// Gives every open drawing's ledger the *other* open drawings as summary sources, and
    /// names its own part. Runs whenever the search fan-out is rewired: on attach and detach.
    func refreshProjectLedgerSources() {
        let parts: [(UUID, String, AppCoreEnvironment)] = documents.compactMap { document in
            // This window's core for the drawing, whichever window has focus (NL-UX-20).
            guard let core = windowCore(for: document) else { return nil }
            let title = document.displayName ?? document.drawing?.url.deletingPathExtension().lastPathComponent ?? ""
            return (document.documentIdentity, title, core)
        }
        let sources = parts.map { $0.2.projectLedgerSource(documentID: $0.0, title: $0.1) }
        // NL-QTY-15 phase 2: every window's Whole Project panel can also total closed projects.
        for document in documents {
            BatchProjectSummaryFlow.wire(document, shell: windowShell(for: document))
            AssemblyRecipesFlow.wire(document, core: windowCore(for: document), shell: windowShell(for: document))
        }
        for (id, title, core) in parts {
            core.installProjectLedgerSources(sources.filter { $0.documentID != id }, ownDocumentID: id, ownTitle: title)
        }
    }
}
