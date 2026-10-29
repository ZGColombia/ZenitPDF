import Foundation
import ZPDFUIPresentation

/// A weak link from a document's own core to one second window's view of it (NL-UX-20).
struct WindowViewLink {
    weak var environment: AppCoreEnvironment?
}

/// NL-UX-20: several windows on one document.
///
/// `NSDocument` lets one document own several windows, and the macOS convention for them is one
/// document state — one undo stack, one set of edits, one save — seen through views that each
/// keep their own place. That is the split here:
///
/// - **Shared, through the document's own core:** the ``TakeoffSession``, the
///   ``DocumentCommandBus`` (and therefore the undo manager it registers on), the History and the
///   review threads. A view is built by ``makeWindowView(of:)`` over those same instances, and
///   its ``wire()`` leaves the bus's hooks to the core that owns them.
/// - **Per window, in the view:** the page on screen, the viewport, the canvas and ledger
///   selection, the armed tool of either family, the Tool Library's armed preset and the status
///   strip. They are separate presenter instances, so selecting in one window selects nothing in
///   the other.
///
/// Every change the bus publishes refreshes the core, and ``refresh()`` fans out to every linked
/// view (and from a view back to the core and its siblings), so an edit made in either window is
/// on screen in both. Warnings stay one tray: a view forwards its posts to the core's document
/// presenter (``AppDocumentPresenter/warningAuthority``) and mirrors the core's list.
extension AppCoreEnvironment {

    /// Whether this environment is a second window's view of a document rather than the
    /// document's own core.
    public var isWindowView: Bool { primaryEnvironment != nil }

    /// The live second-window views of this core, oldest first. Empty for a view.
    public var windowViews: [AppCoreEnvironment] {
        windowViewLinks.compactMap(\.environment)
    }

    /// Joins `root`'s windows: registers the link and gives the new view the document-level facts
    /// the core holds outside the snapshot, so the new window opens on the same sheet with the
    /// same tools, tray and stamp facts as the window it came from.
    func linkAsWindowView(of root: AppCoreEnvironment) {
        root.windowViewLinks.removeAll { $0.environment == nil }
        root.windowViewLinks.append(WindowViewLink(environment: self))
        documentDisplayName = root.documentDisplayName
        documentRevisionName = root.documentRevisionName
        projectDisplayName = root.projectDisplayName
        rateLibraryStore = root.rateLibraryStore
        toolLibrary.setPresets(root.toolLibrary.presets)
        toolLibrary.adoptSetModes(root.toolLibrary.setModes)
        if toolLibrary.reuseToolEnabled != root.toolLibrary.reuseToolEnabled {
            toolLibrary.setReuseToolEnabled(root.toolLibrary.reuseToolEnabled)
        }
        status.adoptSnapToggles(root.status.toggles)
        document.sheetOutlineTitles = root.document.sheetOutlineTitles
        document.setTabs(root.document.tabs, active: root.document.activeTabID)
        document.warningAuthority = root.document
        document.mirrorWarnings(root.document.warnings)
        doubleCountRegions = root.doubleCountRegions
        if let search = root.search { attachSearch(search) }
        if let page = root.document.currentPageID, page != document.currentPageID {
            document.goToPage(id: page)
        }
    }

    /// Leaves the document's windows: the core stops refreshing this view. Called when the
    /// window showing it closes; the document, its core and its other windows are untouched.
    public func unlinkWindowView() {
        guard let root = primaryEnvironment else { return }
        root.windowViewLinks.removeAll { $0.environment == nil || $0.environment === self }
    }

    /// The other windows' presenters after this environment refreshed its own: for the core,
    /// every linked view; for a view, the core and the core's other views.
    func refreshLinkedWindowViews() async {
        if let root = primaryEnvironment {
            await root.refreshOwnPresenters()
            for view in root.windowViews where view !== self {
                await view.refreshOwnPresenters()
            }
        } else {
            for view in windowViews {
                await view.refreshOwnPresenters()
            }
        }
    }

    /// Hands the core's warning list to every linked view's tray.
    func mirrorWarningsToWindowViews(_ warnings: [AppWarning]) {
        for view in windowViews {
            view.document.mirrorWarnings(warnings)
        }
    }
}
