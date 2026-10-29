import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

/// The Inspector's Tools tab (NL-UX-06, r2-markup): the Tool Library docked beside the drawing.
///
/// The library view and its editing model belong to the application (they join the document's
/// preset store, the artwork import and the undo stack), so the app hands the tab a view to show
/// through ``ProjectShellEnvironment/toolLibraryDock``. The canvas stays live beside it — it is a
/// tab, not a sheet — and one click arms a preset, as in the floating panel.
extension InspectorPanel {

    @ViewBuilder
    var toolsDock: some View {
        if let dock = environment.toolLibraryDock {
            dock()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ZPDFEmptyState(
                glyph: .symbol(.inspector),
                title: NSLocalizedString("Tool Library", comment: "Sheet title"),
                message: NSLocalizedString(
                    "The Tool Library opens here once a drawing is loaded.",
                    comment: "Inspector Tools tab before a document is ready"
                )
            )
            .frame(maxHeight: .infinity)
        }
    }
}
