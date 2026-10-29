import AppKit
import UniformTypeIdentifiers
import ZPDFAppCore
import ZPDFExport
import ZPDFUIPresentation

/// File ▸ Share Snippet… (NL-PDF-21): the selected measurements' captioned picture on a small
/// shelf, from where it is **dragged** to the Finder, Mail or any app that takes a file (a file
/// promise: the PNG is written where it is dropped, when it is dropped), **shared** through the
/// system's sharing picker, or copied.
///
/// The picture is the one Copy Snippet puts on the pasteboard (ADR-0006), rendered once for the
/// shelf. Nothing leaves the Mac unless the person drops or shares it.
@MainActor
enum SnippetShelf {

    /// Where the shelf is shown. A test injects its own; with no person present nothing appears.
    static var presenter: (@MainActor (SnippetShelfController, NSWindow?) -> Void)?

    /// Where the sharing picker is shown for the snippet file. Injectable like
    /// `ReviewFileFlow.sharingPresenter`.
    static var sharingPresenter: (@MainActor ([URL], NSView) -> Void)?

    static func present(_ shelf: SnippetShelfController, window: NSWindow?) {
        if let presenter { presenter(shelf, window); return }
        guard ZenitModalPresenter.canPresentModally, let view = window?.contentView else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = shelf
        popover.show(relativeTo: NSRect(x: view.bounds.midX, y: view.bounds.maxY - 1, width: 1, height: 1), of: view, preferredEdge: .minY)
    }
}

/// Writes the snippet PNG where a drag lands, when it lands.
final class SnippetFilePromise: NSObject, NSFilePromiseProviderDelegate, Sendable {
    let png: Data
    let fileName: String

    init(png: Data, fileName: String) {
        self.png = png
        self.fileName = fileName
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        fileName
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        do {
            try png.write(to: url, options: .atomic)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }
}

/// The picture a person drags out.
final class SnippetDragView: NSImageView, NSDraggingSource {

    var promise: SnippetFilePromise?

    override func mouseDown(with event: NSEvent) {
        guard let item = draggingItem() else { return }
        beginDraggingSession(with: [item], event: event, source: self)
    }

    /// The dragging item: a PNG file promise with the picture as its image.
    func draggingItem() -> NSDraggingItem? {
        guard let promise else { return nil }
        let provider = NSFilePromiseProvider(fileType: UTType.png.identifier, delegate: promise)
        let item = NSDraggingItem(pasteboardWriter: provider)
        // A shelf not yet laid out still drags a visible picture, never a zero-size frame.
        item.setDraggingFrame(bounds.isEmpty ? NSRect(x: 0, y: 0, width: 96, height: 64) : bounds, contents: image)
        return item
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}

/// The shelf: the picture, and Share and Copy beside it.
@MainActor
final class SnippetShelfController: NSViewController {

    let png: Data
    let fileName: String
    let caption: String
    let dragView = SnippetDragView()
    let shareButton = NSButton(title: NSLocalizedString("Share…", comment: "Snippet shelf: open the sharing picker"), target: nil, action: nil)
    let copyButton = NSButton(title: NSLocalizedString("Copy", comment: "Snippet shelf: copy the picture"), target: nil, action: nil)
    let pasteboard: any SnippetPasteboardWriting
    let payload: SnippetPasteboardPayload

    init(png: Data, fileName: String, payload: SnippetPasteboardPayload, pasteboard: any SnippetPasteboardWriting) {
        self.png = png
        self.fileName = fileName
        self.caption = payload.plainText
        self.payload = payload
        self.pasteboard = pasteboard
        super.init(nibName: nil, bundle: nil)
        dragView.promise = SnippetFilePromise(png: png, fileName: fileName)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        dragView.image = NSImage(data: png)
        dragView.imageScaling = .scaleProportionallyUpOrDown
        dragView.isEditable = false
        dragView.setAccessibilityLabel(NSLocalizedString("Snippet picture", comment: "Accessibility label: the snippet on the shelf"))
        dragView.setAccessibilityHelp(NSLocalizedString(
            "Drag the picture to the Finder or another app to drop it there as a PNG file.",
            comment: "Accessibility help: dragging the snippet out"
        ))
        dragView.toolTip = NSLocalizedString("Drag to the Finder or another app", comment: "Snippet shelf tool tip")
        let hint = NSTextField(labelWithString: NSLocalizedString(
            "Drag the picture out, or share it.", comment: "Snippet shelf hint"
        ))
        hint.font = .preferredFont(forTextStyle: .caption1)
        hint.textColor = .secondaryLabelColor
        shareButton.target = self
        shareButton.action = #selector(share)
        shareButton.setAccessibilityLabel(shareButton.title)
        copyButton.target = self
        copyButton.action = #selector(copyPicture)
        copyButton.setAccessibilityLabel(copyButton.title)
        let buttons = NSStackView(views: [hint, shareButton, copyButton])
        buttons.spacing = 8
        let stack = NSStackView(views: [dragView, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        NSLayoutConstraint.activate([
            dragView.widthAnchor.constraint(equalToConstant: 320),
            dragView.heightAnchor.constraint(equalToConstant: 220)
        ])
        view = stack
    }

    /// The snippet as a file for the sharing picker, in a folder of its own.
    func sharedFileURL() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-snippet-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(fileName)
        try png.write(to: url, options: .atomic)
        return url
    }

    @objc func share() {
        guard let url = try? sharedFileURL() else { return }
        let anchor: NSView = shareButton
        if let presenter = SnippetShelf.sharingPresenter { presenter([url], anchor); return }
        guard ZenitModalPresenter.canPresentModally else { return }
        let picker = NSSharingServicePicker(items: [url])
        picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    @objc func copyPicture() {
        pasteboard.write(payload)
    }
}

extension ProjectWindowController {

    /// File ▸ Share Snippet….
    func shareSnippet(for document: ZenitPDFProjectDocument) {
        guard let core = document.core else { return }
        let window = self.window
        let subject = SnippetExport.Subject.selection(core.canvas.selectedMarkupIDs)
        Task { @MainActor in
            do {
                let shelf = try await self.snippetShelf(for: document, of: subject)
                SnippetShelf.present(shelf, window: window)
            } catch {
                ZenitErrorPresenter.present(error, in: window)
            }
        }
    }

    /// The shelf for one snippet; the half of Share Snippet… worth asserting.
    func snippetShelf(for document: ZenitPDFProjectDocument, of subject: SnippetExport.Subject) async throws -> SnippetShelfController {
        let inputs = try await snippetInputs(for: document, of: subject)
        let image = try await SnippetExport.render(inputs, pageSource: inputs.pageSource)
        let payload = try image.pasteboardPayload()
        let name = SnippetExport.fileName(documentName: document.displayName ?? "Snippet") + ".png"
        return SnippetShelfController(png: payload.png, fileName: name, payload: payload, pasteboard: snippetPasteboard)
    }
}
