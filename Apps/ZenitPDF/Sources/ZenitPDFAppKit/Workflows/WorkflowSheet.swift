import AppKit
import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation
import ZPDFUIShell
import ZPDFUIWorkflows

/// Presents the two workflow panels that are not part of the window's permanent furniture.
///
/// Both are sheets rather than panes: the Tool Library and Revision Compare are things a person
/// goes to, does something in, and leaves, and giving them permanent screen area would take it
/// from the canvas, which is the surface the estimator actually works on.
///
/// No dead ends: every sheet built here closes three ways — its own
/// close control in the panel header, the Done button, and `Escape`. The `onEnd` callback fires
/// exactly once however the sheet closes, so the window controller can unregister the mode.
/// A panel whose footer already carries its own dismiss button (the recognition sheet's Close)
/// gets no Done under it: two buttons that do one thing is one too many (L-30).
@MainActor
public enum WorkflowSheet {

    /// A presented Tool Library: the sheet window, and the working copy the panel edits.
    ///
    /// The model is returned rather than kept private because it *is* the thing that was once
    /// joined to nothing. A caller that cannot reach it cannot prove the join exists, and a hook
    /// nobody can see is how that defect survived a whole round of wiring.
    public struct ToolLibrarySheet {
        /// The sheet window, so a caller (or a test) can end it programmatically.
        public let window: NSWindow
        /// The panel's working copy of the library.
        public let model: ToolLibraryEditingModel
    }

    /// The Tool Library, bound to the document's own Tool Library presenter.
    ///
    /// Generic over the presenter rather than taking `any ToolLibraryPresenting`, because the
    /// panel is a `View` generic over its presenter and an existential cannot satisfy that.
    /// Returns the sheet window so a caller (or a test) can end it programmatically.
    ///
    /// `onPresetsChanged` is the missing join: `ToolLibraryEditingModel.onChange`
    /// is the change stream the model's own documentation says the host persists, and until now
    /// nothing in any package or test assigned it. Every create, rename, duplicate, delete,
    /// reorder, star and import therefore succeeded on screen and reached nothing. The sheet
    /// hands the *whole* working copy out rather than the individual change, because the host's
    /// two consumers — the presenter and the package — both want the library, not a delta.
    /// A caller that passes nothing gets the old behaviour, which is what a preview wants.
    @discardableResult
    public static func presentToolLibrary<Presenter: ToolLibraryPresenting>(
        in parent: NSWindow,
        presenter: Presenter,
        selectedMarkup: MarkupSummary?,
        onPresetsChanged: (@MainActor ([ToolPresetSummary]) -> Void)? = nil,
        onImportArtwork: ArtworkImportHandler? = nil,
        onImportFailure: (@MainActor (ZPDFUserFacingError) -> Void)? = nil,
        undoManager: UndoManager? = nil,
        onEnd: @escaping @MainActor () -> Void = {}
    ) -> ToolLibrarySheet {
        let model = ToolLibraryEditingModel(presets: presenter.presets)
        // Each library edit is one ⌘Z on the document's undo stack (IM-154); the model reports
        // the step and its inverse, the host registers it. Removed when the sheet ends, so no
        // undo action outlives the model it reverts.
        if let undoManager {
            model.onUndoableChange = { [weak model, weak undoManager] step in
                guard let model, let undoManager else { return }
                registerToolLibraryUndo(step, model: model, undoManager: undoManager)
            }
        }
        let endWithUndoCleanup: @MainActor () -> Void = { [weak model, weak undoManager] in
            if let model { undoManager?.removeAllActions(withTarget: model) }
            onEnd()
        }
        // The preset editor's Artwork row was read-only text because nothing
        // could compile a chosen file. The compiler exists; this is the wire from the sheet to
        // it. A caller that passes nothing keeps the read-only row, which is what a preview and
        // a document with no package want.
        model.onImportArtwork = onImportArtwork
        // A `.zpdftools` file the validator cannot even describe was once rejected in
        // silence. `ToolLibraryEditingModel.beginImport` calls
        // `onImportFailure` on that path (`ToolLibraryEditingModel.swift:534`) and nothing
        // assigned it, so Import Tool Set on a corrupt or foreign file looked like a control
        // that did nothing at all — indistinguishable, from the person's side, from a file
        // that imported zero tools successfully.
        model.onImportFailure = onImportFailure
        if let onPresetsChanged {
            model.onChange = { [weak model] _ in
                guard let model else { return }
                onPresetsChanged(model.presets)
            }
        }
        let closer = SheetCloser()
        let root = ToolLibraryPanelView(
            presenter: presenter,
            model: model,
            selectedMarkup: selectedMarkup,
            onClose: { closer.close() }
        )
        let window = present(
            content: root,
            title: NSLocalizedString("Tool Library", comment: "Sheet title"),
            size: CGSize(width: 720, height: 520),
            in: parent,
            closer: closer,
            onEnd: endWithUndoCleanup
        )
        return ToolLibrarySheet(window: window, model: model)
    }

    /// Registers one Tool Library step with the document's undo manager; undoing it registers
    /// the inverse, so Redo works too.
    static func registerToolLibraryUndo(
        _ step: ToolLibraryUndoStep,
        model: ToolLibraryEditingModel,
        undoManager: UndoManager
    ) {
        undoManager.registerUndo(withTarget: model) { [weak undoManager] model in
            MainActor.assumeIsolated {
                model.revert(step)
                if let undoManager {
                    registerToolLibraryUndo(step.inverse, model: model, undoManager: undoManager)
                }
            }
        }
        undoManager.setActionName(NSLocalizedString("Tool Library Change", comment: "Undo action name for a Tool Library edit"))
    }

    /// A presented Revision Compare: the sheet window, and the review model the panel drives.
    ///
    /// The model is returned for the same reason ``ToolLibrarySheet`` returns its own, and it
    /// is the same defect being closed: `RevisionCompareModel.onSettingsChange` and
    /// `onFocusDifference` are the review's two outward edges, they are declared in
    /// `ZPDFUIWorkflows`, and until this type existed no caller could reach them — the sheet
    /// created the model privately and dropped it.
    ///
    /// The hooks are assigned by the host rather than passed in here because both of them need
    /// the *concrete* presenter — re-detection and canvas reveal are not on `ComparePresenting`
    /// — and a sheet generic over the protocol cannot call either.
    public struct RevisionCompareSheet {
        /// The sheet window, so a caller (or a test) can end it programmatically.
        public let window: NSWindow
        /// The review model the panel edits.
        public let model: RevisionCompareModel
    }

    /// Revision Compare. With no revisions installed, or only one, the view shows its own
    /// instruction — "Select two revisions to compare" — and asserts nothing; nothing here
    /// invents a revision to compare against or reports a verdict it has not computed.
    @discardableResult
    public static func presentRevisionCompare<Presenter: ComparePresenting>(
        in parent: NSWindow,
        presenter: Presenter,
        projectArea: @escaping (Double) -> String? = { _ in nil },
        onEnd: @escaping @MainActor () -> Void = {}
    ) -> RevisionCompareSheet {
        let model = RevisionCompareModel()
        let closer = SheetCloser()
        let root = RevisionCompareView(
            presenter: presenter,
            model: model,
            onClose: { closer.close() },
            projectArea: projectArea
        ) { role in
            ZPDFEmptyState(
                glyph: .symbol(.revisionCompare),
                title: role.displayName,
                message: NSLocalizedString(
                    "Add a revision of this drawing to compare it against.",
                    comment: "Revision Compare empty canvas message"
                )
            )
        }
        let window = present(
            content: root,
            title: NSLocalizedString("Revision Compare", comment: "Sheet title"),
            size: CGSize(width: 900, height: 620),
            in: parent,
            closer: closer,
            onEnd: onEnd
        )
        return RevisionCompareSheet(window: window, model: model)
    }

    /// The recognition sheet.
    ///
    /// The model owns what the sheet shows; the caller owns the engine and reports each page back
    /// through ``OCRRunModel/record(_:)``. Closing while a run is in flight cancels it first, so a
    /// half-read page is never left claiming to be searchable.
    @discardableResult
    public static func presentOCRRun(
        in parent: NSWindow,
        model: OCRRunModel,
        onEnd: @escaping @MainActor () -> Void = {}
    ) -> NSWindow {
        let closer = SheetCloser()
        let root = OCRRunSheet(model: model, onClose: { closer.close() })
        return present(
            content: root,
            title: NSLocalizedString(
                "Read Text from Scanned Pages",
                comment: "Sheet title for the OCR run"
            ),
            size: CGSize(width: 600, height: 660),
            in: parent,
            closer: closer,
            ownsKeyboardActions: ocrRunChrome.ownsKeyboardActions,
            // The sheet's own Close is its one dismiss action (L-30).
            showsDoneButton: ocrRunChrome.showsDoneButton,
            onEnd: onEnd
        )
    }

    /// The scoped batch apply sheet.
    ///
    /// The model is returned for the same reason ``ToolLibrarySheet`` returns its model: the
    /// join between the sheet and the engine is the thing worth proving, and a hook a caller
    /// cannot reach is a hook a test cannot see. The host wires `onPlan`, `onRun`, `onCancel`
    /// and `onClose` before this returns; the sheet previews on appear and refuses Apply
    /// until it has a count to show.
    @discardableResult
    public static func presentBatchApply(
        in parent: NSWindow,
        model: BatchApplyModel,
        title: String,
        onEnd: @escaping @MainActor () -> Void = {}
    ) -> NSWindow {
        let closer = SheetCloser()
        let previousClose = model.onClose
        model.onClose = {
            previousClose?()
            closer.close()
        }
        let root = BatchApplySheet(model: model, title: title)
        return present(
            content: root,
            title: NSLocalizedString("Batch Apply", comment: "Sheet title for the scoped batch apply"),
            size: CGSize(width: 500, height: 620),
            in: parent,
            closer: closer,
            ownsKeyboardActions: batchApplyChrome.ownsKeyboardActions,
            // The panel's own Close is its one dismiss action (L-58, L-60, as L-30 for OCR).
            showsDoneButton: batchApplyChrome.showsDoneButton,
            onEnd: onEnd
        )
    }

    /// How a workflow sheet's chrome wraps its panel: whether the panel owns Return and Escape,
    /// and whether the chrome adds a Done bar under it.
    struct ChromeOptions: Equatable {
        var ownsKeyboardActions: Bool
        var showsDoneButton: Bool
    }

    /// Batch Stamp and Header, Footer or Sheet Number: the panel's footer holds Close/Cancel and
    /// Apply, so the chrome adds no Done (L-58, L-60).
    static let batchApplyChrome = ChromeOptions(
        ownsKeyboardActions: true,
        showsDoneButton: BatchApplySheet.wantsHostDoneButton
    )

    /// Read Text from Scanned Pages: its own Close is its one dismiss action (L-30).
    static let ocrRunChrome = ChromeOptions(
        ownsKeyboardActions: true,
        showsDoneButton: OCRRunSheet.wantsHostDoneButton
    )

    // MARK: - Plumbing

    /// The sheet's window. Escape backs out at the window level unless the panel owns Escape
    /// itself (BH-391). Separate from ``present`` so the wiring is testable without a sheet —
    /// `NSWindow.beginSheet` hangs a headless process.
    static func makeSheetWindow(
        hosting: NSViewController,
        closer: SheetCloser,
        ownsKeyboardActions: Bool
    ) -> WorkflowSheetWindow {
        let sheet = WorkflowSheetWindow(contentViewController: hosting)
        if !ownsKeyboardActions {
            sheet.onEscape = { closer.close() }
        }
        return sheet
    }

    private static func present<Content: View>(
        content: Content,
        title: String,
        size: CGSize,
        in parent: NSWindow,
        closer: SheetCloser,
        ownsKeyboardActions: Bool = false,
        showsDoneButton: Bool = true,
        onEnd: @escaping @MainActor () -> Void
    ) -> NSWindow {
        let hosting = NSHostingController(
            rootView: WorkflowSheetChrome(
                onClose: { closer.close() },
                ownsKeyboardActions: ownsKeyboardActions,
                showsDoneButton: showsDoneButton
            ) { content }
        )
        let sheet = makeSheetWindow(hosting: hosting, closer: closer, ownsKeyboardActions: ownsKeyboardActions)
        sheet.setContentSize(size)
        sheet.title = title
        sheet.styleMask = [.titled, .resizable]
        // No appearance of its own: the sheet inherits its window's, which follows
        // Settings ▸ Appearance (dark by default). A forced dark sheet over a Light window was
        // the one surface the setting could not reach.
        closer.bind(sheet: sheet, parent: parent)
        ZenitModalPresenter.beginSheet(sheet, on: parent, identifier: "workflow.\(title)", completion: onEnd)
        return sheet
    }
}

/// A workflow sheet's window: Escape backs out of it at the window level.
///
/// RT-12 (2026-08-31): a sheet is its own window, so the parent window controller's Escape
/// fallback never sees the key, and SwiftUI's `onExitCommand` fires only while the SwiftUI
/// content holds focus — live, Escape did nothing in Revision Compare. The first fix was a
/// zero-sized Cancel button at opacity 0 with the cancel-action shortcut: an invisible control
/// relied on to act, the same class as the LT3-01 colour well (`verify-hosted-hit-targets.sh`
/// refuses it now). The window is the honest owner of a window-wide key: Escape is offered to
/// the content first — a panel's own Cancel or Stop keeps it (BH-391) — and backs out only when
/// nothing in the sheet took it.
final class WorkflowSheetWindow: NSWindow {

    /// Ends the sheet. `nil` when the panel owns Escape itself; the key then goes the usual way.
    var onEscape: (@MainActor () -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        guard let onEscape, Self.isPlainEscape(event) else { return false }
        onEscape()
        return true
    }

    override func cancelOperation(_ sender: Any?) {
        if let onEscape {
            onEscape()
        } else {
            super.cancelOperation(sender)
        }
    }

    /// Escape with no modifier a person chose (Command-Escape and friends are not a back-out).
    static func isPlainEscape(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.keyCode == 53 else { return false }
        let chosen = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.function, .numericPad, .capsLock])
        return chosen.isEmpty
    }
}

/// One idempotent way to end a workflow sheet, shared by every close affordance in it.
///
/// The SwiftUI content is built before the sheet window exists, so its close buttons capture
/// this object and the window is bound in afterwards.
@MainActor
final class SheetCloser {

    private weak var sheet: NSWindow?
    private weak var parent: NSWindow?
    private var isClosed = false

    func bind(sheet: NSWindow, parent: NSWindow) {
        self.sheet = sheet
        self.parent = parent
    }

    func close() {
        guard !isClosed, let sheet, let parent else { return }
        isClosed = true
        parent.endSheet(sheet)
    }
}

/// A Done button and an `Escape` path around a workflow panel.
///
/// The panels carry their own header close control; the chrome adds the keyboard exits that a
/// sheet must always have: Return on Done, and `Escape` backing out (there is no
/// screen in Zenit PDF where `Escape` does nothing).
private struct WorkflowSheetChrome<Content: View>: View {

    let onClose: @MainActor () -> Void
    /// The panel carries its own Return and Escape actions — Start Reading and Stop, Apply
    /// and Cancel. The chrome's duplicates then fought them: Return could end the sheet
    /// instead of starting, and Escape during a running batch ended the sheet rather than
    /// the panel's Cancel, losing its partial-result report (BH-391).
    var ownsKeyboardActions = false
    /// `false` when the panel's footer carries its own dismiss button, so the sheet does not
    /// offer Close and Done side by side for one action (L-30).
    var showsDoneButton = true
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if showsDoneButton { doneBar }
        }
        .background(ZPDFColor.color(.background))
        .onExitCommand { onClose() }
    }

    private var doneBar: some View {
        VStack(spacing: 0) {
            ZPDFHairlineDivider()
            HStack {
                Spacer()
                // Escape is handled by the sheet's window (`WorkflowSheetWindow`), not by a
                // control here. It used to be a zero-sized Cancel button at opacity 0 carrying the
                // cancel-action keyboard shortcut — the invisible-control trick of LT3-01, in
                // a binary whose SwiftUI leaves near-transparent hosted controls out of event
                // handling. The chrome's `onExitCommand` still covers focus inside the SwiftUI content.
                if ownsKeyboardActions {
                    Button(NSLocalizedString("Done", comment: "Sheet dismissal button")) {
                        onClose()
                    }
                } else {
                    Button(NSLocalizedString("Done", comment: "Sheet dismissal button")) {
                        onClose()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(ZPDFSpacing.l)
        }
    }
}
