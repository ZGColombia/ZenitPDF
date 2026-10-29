import AppKit
import ZPDFUIShell

/// The nl-ux window-level hooks, in one place so the big window controller carries a
/// single call (`wireNextLevelUX`) rather than a block per feature.
extension ProjectWindowController {

    func wireNextLevelUX(shell: ProjectShellEnvironment, document: ZenitPDFProjectDocument) {
        // The toolbar's Export chip opens the list of every export (ExportChooser.swift).
        shell.onPresentExportChooser = { [weak self, weak document] in
            guard let self, let document else { return }
            self.presentExportChooser(for: document)
        }
        // NL-UX-13: the first-run guide follows the document in front.
        ZenitOnboardingController.shared.attach(document: document, controller: self)
        // A workspace can follow a canvas mode.
        ZenitWorkspaceMenu.shared.attachFollower(shell: shell)
        // NL-UX-19: the status strip's Unit read-out is a menu.
        OutputUnitsMenu.wire(shell: shell, document: document)
        // NL-UX-12: ⌘Z says on the canvas what it took back.
        UndoToastFeed.attach(document: document, shell: shell)
        // Once per document, not again for a second window on it (NL-UX-20).
        guard windowViews[document.documentIdentity] == nil else { return }
        // NL-UX-04: originals of annotations adopted in an earlier session stay hidden.
        DrawingAnnotationAdoption.restoreOnOpen(document)
        // NL-UX-18: the open project is a current activity (Spotlight recents, Dock menu) — only
        // in the shipping app; a test process publishes nothing to the system.
        if ZenitModalPresenter.canPresentModally, let activity = document.makeViewingActivity() {
            document.userActivity = activity
            activity.becomeCurrent()
        }
    }
}
