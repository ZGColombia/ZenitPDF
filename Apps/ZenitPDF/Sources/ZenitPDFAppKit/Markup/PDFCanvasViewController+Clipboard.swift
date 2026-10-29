import AppKit
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation

/// Cut, Copy, Paste, Paste in Place, Paste Here, Duplicate and Paste to Pages for markups
/// (nl-markup, NL-MARKUP-05, NL-UX-03).
///
/// Before this, Copy copied ledger rows only, so a cloud or a callout had to be redrawn for
/// every sheet it belonged on. The canvas is in the responder chain when it has focus, so the
/// Edit menu's Cut, Copy and Paste reach these handlers there and the ledger's when the ledger
/// has focus. Every paste is **one** undo step, and a measurement pasted onto a sheet with
/// another scale is recomputed from that sheet's scale and said so in the warning tray —
/// never carried across as a number.
extension PDFCanvasViewController {

    // MARK: Plumbing

    /// The window controller the canvas sits in, when it is in one.
    var markupWindowController: ProjectWindowController? {
        view.window?.windowController as? ProjectWindowController
    }

    /// The document whose core this canvas draws.
    var markupDocument: ZenitPDFProjectDocument? {
        markupWindowController?.documents.first { $0.core === core }
    }

    /// The clipboard the canvas copies to: the window controller's (injected by tests), or the
    /// system clipboard for a canvas that is not in a window.
    var markupPasteboard: any MarkupPasteboardAccess {
        markupWindowController?.markupPasteboard ?? MarkupPasteRepeat.fallbackPasteboard
    }

    /// The payload on the clipboard, or `nil`.
    var pasteboardMarkups: MarkupClipboardPayload? {
        markupPasteboard.readMarkups().flatMap(MarkupClipboardPayload.decoded(from:))
    }

    // MARK: Edit menu (responder chain)

    @objc public func copy(_ sender: Any?) {
        Task { @MainActor in _ = await copySelectedMarkups() }
    }

    @objc public func cut(_ sender: Any?) {
        Task { @MainActor in _ = await cutSelectedMarkups() }
    }

    @objc public func paste(_ sender: Any?) {
        Task { @MainActor in _ = await pasteMarkups(placement: nil) }
    }

    /// The Edit menu's clipboard rows, enabled for what the canvas can do. `nil` for an action
    /// this extension does not own.
    func validateMarkupClipboardItem(_ item: NSMenuItem) -> Bool? {
        switch item.action {
        case #selector(copy(_:)), #selector(cut(_:)):
            return !core.canvas.selectedMarkupIDs.isEmpty
        case #selector(paste(_:)):
            return pasteboardMarkups != nil
        default:
            return nil
        }
    }

    // MARK: Verbs

    /// Copies the selection. Returns the payload written, or `nil` when nothing was selected.
    @discardableResult
    func copySelectedMarkups() async -> MarkupClipboardPayload? {
        let ids = core.canvas.selectedMarkupIDs
        guard !ids.isEmpty, let payload = await core.markupClipboardPayload(for: ids),
              let data = payload.encoded() else { return nil }
        let token = markupPasteboard.writeMarkups(data, plainText: plainText(for: ids))
        MarkupPasteRepeat.forget()
        attachPicture(of: ids, token: token)
        return payload
    }

    /// Cuts the selection: copied, then removed as one "Cut" step.
    @discardableResult
    func cutSelectedMarkups() async -> MarkupClipboardPayload? {
        let ids = core.canvas.selectedMarkupIDs
        guard !ids.isEmpty else { return nil }
        let text = plainText(for: ids)
        let (payload, failure) = await core.cutMarkups(ids)
        if let failure {
            ZenitPDFProjectDocument.reportRefusedEdit(MarkupClipboardRefusal(message: failure), core: core)
            return nil
        }
        guard let payload, let data = payload.encoded() else { return nil }
        markupPasteboard.writeMarkups(data, plainText: text)
        MarkupPasteRepeat.forget()
        refresh()
        return payload
    }

    /// Pastes the clipboard onto the page in view.
    ///
    /// - Parameter placement: `nil` is plain Paste — offset a further ``visiblePasteOffset`` each
    ///   time on the page it was copied from, where it was on any other page.
    @discardableResult
    func pasteMarkups(placement: MarkupPastePlacement?) async -> MarkupPasteReceipt? {
        guard let payload = pasteboardMarkups else { return nil }
        let pageID = core.canvas.viewport.pageID
        let resolved = placement ?? {
            guard payload.sourcePageID == pageID, payload.sourceDocumentID == core.snapshot.documentID else {
                return .inPlace
            }
            let step = Double(MarkupPasteRepeat.next(for: payload)) * visiblePasteOffset
            // Down and to the right on the sheet: page space is y-up.
            return .offset(dx: step, dy: -step)
        }()
        return await land(payload, onto: [pageID], placement: resolved, actionName: nil)
    }

    /// How far Paste and Duplicate move a copy from what it copies, in page points (L-76): ten
    /// points on screen at the zoom in view, and never less than ten page points.
    ///
    /// The step was ten page points at every zoom. On a large sheet viewed whole that is a
    /// fraction of a screen point — at 9 % less than one — so every copy landed visibly on top of
    /// its original, and two pasted copies sat hidden under a rectangle until it was dragged away.
    var visiblePasteOffset: Double {
        Self.pasteOffset(zoom: core.canvas.viewport.zoom)
    }

    /// ``visiblePasteOffset`` for a zoom (view points per page point).
    nonisolated static func pasteOffset(zoom: Double) -> Double {
        guard zoom.isFinite, zoom > 0, zoom < 1 else { return MarkupClipboard.repeatOffset }
        return MarkupClipboard.repeatOffset / zoom
    }

    /// Paste Here: the clipboard with its top-left corner at a page point (the context menu).
    @discardableResult
    func pasteMarkups(at point: PDFPointValue) async -> MarkupPasteReceipt? {
        await pasteMarkups(placement: .at(point))
    }

    /// Duplicate (⌘D): the selection, again, ``visiblePasteOffset`` down and right, without
    /// touching the clipboard.
    @discardableResult
    func duplicateSelectedMarkups() async -> MarkupPasteReceipt? {
        let ids = core.canvas.selectedMarkupIDs
        guard !ids.isEmpty, let payload = await core.markupClipboardPayload(for: ids) else { return nil }
        return await land(
            payload,
            onto: [payload.sourcePageID],
            placement: .offset(dx: visiblePasteOffset, dy: -visiblePasteOffset),
            actionName: NSLocalizedString("Duplicate", comment: "Undo action name: markups duplicated")
        )
    }

    /// Paste to Pages…: the clipboard in place on every page selected in the Navigator, as one
    /// undo step.
    @discardableResult
    func pasteMarkupsToSelectedPages() async -> MarkupPasteReceipt? {
        guard let payload = pasteboardMarkups else { return nil }
        let pages = core.document.selectedPageIDs
        guard !pages.isEmpty else { return nil }
        return await land(
            payload,
            onto: pages,
            placement: .inPlace,
            actionName: String(
                format: NSLocalizedString("Paste to %ld Pages", comment: "Undo action name: markups pasted onto several pages"),
                pages.count
            )
        )
    }

    // MARK: Private

    private func land(
        _ payload: MarkupClipboardPayload,
        onto pages: [UUID],
        placement: MarkupPastePlacement,
        actionName: String?
    ) async -> MarkupPasteReceipt {
        let receipt = await core.pasteMarkups(payload, onto: pages, placement: placement, actionName: actionName)
        if let failure = receipt.failureDescription {
            ZenitPDFProjectDocument.reportRefusedEdit(MarkupClipboardRefusal(message: failure), core: core)
        } else if receipt.recalculatedCount > 0 {
            core.document.post(Self.rescaledWarning(count: receipt.recalculatedCount, pages: pages, core: core))
        }
        refresh()
        return receipt
    }

    /// The warning a scale-changing paste posts: which sheets, how many measurements.
    static func rescaledWarning(count: Int, pages: [UUID], core: AppCoreEnvironment) -> AppWarning {
        let labels = pages.compactMap { id in core.snapshot.pages.first { $0.id == id }?.label }
            .filter { !$0.isEmpty }
        let where_ = labels.isEmpty
            ? NSLocalizedString("this sheet", comment: "Paste scale warning: the target when it has no label")
            // Joined plainly: `ListFormatter` follows the system locale, not the app's language.
            : labels.joined(separator: ", ")
        return AppWarning(
            id: UUID(),
            severity: .warning,
            title: count == 1
                ? NSLocalizedString("A pasted measurement was recalculated.", comment: "Paste scale warning title, one measurement")
                : String(
                    format: NSLocalizedString("%ld pasted measurements were recalculated.", comment: "Paste scale warning title, several"),
                    count
                ),
            message: String(
                format: NSLocalizedString(
                    "They were measured under another scale. Their values now come from the scale of %@, so they differ from the copied ones where the scales differ.",
                    comment: "Paste scale warning detail; the placeholder names the target sheets"
                ),
                where_
            ),
            source: NSLocalizedString("Paste", comment: "Warning source: the markup clipboard"),
            isDismissible: true,
            timestamp: Date(),
            relatedPageID: pages.first
        )
    }

    /// One line per copied markup, for a plain-text field in another program.
    private func plainText(for ids: Set<UUID>) -> String {
        core.snapshot.markups
            .filter { ids.contains($0.id) }
            .map { markup in
                let caption = markup.primaryField?.displayTextWithUnit ?? ""
                let words = markup.drawnText ?? ""
                return [markup.kind.displayName, markup.label, words, caption]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · ")
            }
            .joined(separator: "\n")
    }

    /// Renders the copied markups' picture and adds it to the clipboard, when nothing has
    /// replaced the clipboard in the meantime.
    private func attachPicture(of ids: Set<UUID>, token: Int) {
        guard let controller = markupWindowController, let document = markupDocument else { return }
        let pasteboard = markupPasteboard
        Task { @MainActor in
            guard let inputs = try? await controller.snippetInputs(for: document, of: .selection(ids)),
                  let image = try? await SnippetExport.render(inputs, pageSource: inputs.pageSource),
                  let payload = try? image.pasteboardPayload()
            else { return }
            pasteboard.addPicture(payload.png, ifStill: token)
        }
    }
}

/// A refused cut or paste, carrying the engine's sentence.
struct MarkupClipboardRefusal: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// How many times the same clipboard has been pasted onto its own page, so each paste lands
/// 10 pt further on rather than on top of the last one.
@MainActor
enum MarkupPasteRepeat {
    private static var lastPayload: MarkupClipboardPayload?
    private static var count = 0

    /// The clipboard of a canvas outside a window: the system one only in the shipping app.
    static let fallbackPasteboard: any MarkupPasteboardAccess = MarkupPasteboards.makeDefault()

    /// 1 for the first paste of a payload, 2 for the second, …
    static func next(for payload: MarkupClipboardPayload) -> Int {
        if lastPayload == payload {
            count += 1
        } else {
            lastPayload = payload
            count = 1
        }
        return count
    }

    /// Starts counting again: a new copy.
    static func forget() {
        lastPayload = nil
        count = 0
    }
}
