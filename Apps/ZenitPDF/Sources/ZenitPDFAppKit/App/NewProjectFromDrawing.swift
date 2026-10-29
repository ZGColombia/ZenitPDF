import AppKit
import UniformTypeIdentifiers

/// File ▸ New Project… (⌘N): choose the drawing, and it opens and becomes a project.
///
/// ## The decision (L-40)
///
/// File ▸ New used to be AppKit's `newDocument(_:)`, which made an empty, untitled Project Mode
/// document with no drawing: Save and Save As refused it ("Nothing to save yet — open a drawing
/// first"), the canvas said only "No document", nothing could be added to it, and Combine Open
/// Drawings had no project to combine into. A dead end, reached from the most prominent command
/// in the File menu.
///
/// Two repairs were possible: give the empty project an Add Drawing… door, or make New start
/// where a project starts. The second is the one this application's model allows. A Zenit project
/// is always made *from* a drawing: the `.zpdfproj` package holds the
/// original PDF, its rows key every takeoff record, and a drawing joins an existing project only
/// as an added drawing of a primary one (ADR-0027). An empty package with no primary drawing is a
/// state nothing else in the program can produce, save, reopen or recover — making it fillable
/// would mean inventing that state, not fixing a menu item.
///
/// So New Project… asks for the drawing — a PDF, a scan or photo, or a DXF, exactly what Open…
/// accepts apart from projects and data files — opens it, and runs Create Zenit PDF Project on it
/// at once, which asks where to keep the project beside the drawing. Cancel that second panel and
/// the drawing stays open as a Quick PDF whose ⌘S still creates the project; nothing is lost and
/// nothing is left empty. The empty untitled window remains only where it is a start screen —
/// a launch with nothing to reopen, and the `zenitpdf://new` link — with its Open… door, and
/// the first drawing that opens into it takes its place rather than becoming a tab beside it
/// (``ProjectWindowController/retireUntouchedStartDocuments()``). Combine Open Drawings needs a
/// drawing in front (``ZenitAppCommandRule/drawingWithOtherTabs``), so it is never offered on
/// the start screen.
@MainActor
enum NewProjectFromDrawing {

    /// The drawing chooser's stable name, for the modal door and its tests.
    static let drawingChooserIdentifier = "newProject.chooseDrawing"

    /// How the chosen drawing is opened, and whether it was open already. The shipping value
    /// opens it through the document controller; a test replaces it with a document it made, so
    /// no window appears. Nothing under `Apps/ZenitPDF/Sources` reassigns it.
    static var drawingOpener: @MainActor (URL) async -> (document: ZenitPDFProjectDocument, alreadyOpen: Bool)? = { url in
        await withCheckedContinuation { continuation in
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { document, alreadyOpen, error in
                if let error { ZenitErrorPresenter.present(error) }
                continuation.resume(returning: (document as? ZenitPDFProjectDocument).map { ($0, alreadyOpen) })
            }
        }
    }

    /// What starting a project did.
    enum Outcome: Equatable {
        /// The drawing opened and Create Zenit PDF Project is asking where to keep it.
        case creatingProject
        /// The file opened as a project already: nothing to create.
        case alreadyAProject
        /// The drawing did not open, or its takeoff never loaded.
        case notOpened
    }

    /// What the chooser offers: every drawing Open… accepts, without projects and data files.
    static var drawingContentTypes: [UTType] {
        ZenitDocumentController.openPanelContentTypes.filter { type in
            !ZenitDataFileKind.contentTypes.contains(type) && type != ZenitAppInfo.projectType
        }
    }

    /// The whole command: the drawing chooser, through the one modal door, then ``start(fromDrawingAt:)``.
    static func run(window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = drawingContentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.message = NSLocalizedString(
            "Choose the drawing for the new project. You will then choose where to keep the project.",
            comment: "New Project drawing chooser message"
        )
        panel.prompt = NSLocalizedString("Choose Drawing", comment: "New Project drawing chooser button")
        ZenitModalPresenter.runOpenPanel(panel, identifier: drawingChooserIdentifier, sheetedOn: window) { answer in
            guard let url = answer.firstURL else { return }
            Task { @MainActor in await start(fromDrawingAt: url) }
        }
    }

    /// Opens the drawing at `url` and, once its takeoff has loaded, creates the project from it.
    /// A drawing that was open already as a Quick PDF becomes the project with the takeoff it has.
    @discardableResult
    static func start(fromDrawingAt url: URL) async -> Outcome {
        guard let opened = await drawingOpener(url) else { return .notOpened }
        let document = opened.document
        guard await NewFromTemplate.waitForCore(document), document.drawing != nil else { return .notOpened }
        guard document.mode == .quickPDF else { return .alreadyAProject }
        document.createProject()
        return .creatingProject
    }
}

extension ZenitDocumentController {

    /// File ▸ New Project… (⌘N). Reached through the responder chain, which ends at the document
    /// controller, so it answers with or without a project window.
    @objc public func newProjectFromDrawing(_ sender: Any?) {
        NewProjectFromDrawing.run(window: NSApplication.shared.mainWindow)
    }
}
