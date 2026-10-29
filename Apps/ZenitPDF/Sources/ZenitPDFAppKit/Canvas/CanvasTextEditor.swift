import AppKit
import ZPDFDesignSystem

/// The in-canvas text box: an `NSTextView` sitting over the page while a Text or Callout
/// markup is being typed.
///
/// The box appears **with the caret already in it**, typing
/// shows, and `Escape` or a click away commits. The two closures are the whole surface —
/// the controller owns the markup, the box owns nothing but the string — so the editing
/// state is testable by driving the controller with no window at all.
///
/// `Return` inserts a newline rather than committing: a callout is often two lines, and a
/// key that sometimes commits and sometimes does not is worse than one that never does.
/// `Escape` and clicking away are the two documented commits.
@MainActor
final class CanvasTextEditor: NSTextView {

    /// Raised on every keystroke with the whole string.
    var onTextChange: (@MainActor (String) -> Void)?
    /// Raised when the user presses `Escape` or the box loses first responder. Nothing the
    /// editor sees abandons the words: a tool switch commits them too (L-10).
    var onCommit: (@MainActor () -> Void)?

    /// Keeps the text system alive.
    ///
    /// Ownership in TextKit 1 runs **storage → layout manager → container**, and every link back
    /// up is unowned. A container assembled in a factory function and handed to `super.init`
    /// therefore loses its storage the moment that function returns, and the view is left with
    /// no text system at all. This property is the reference that stops that happening.
    private var retainedStorage: NSTextStorage?

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        let system = container.map { (container: $0, storage: $0.layoutManager?.textStorage) }
            ?? Self.makeTextSystem(size: frameRect.size)
        super.init(frame: frameRect, textContainer: system.container)
        retainedStorage = system.storage
        configure()
    }

    override convenience init(frame frameRect: NSRect) {
        self.init(frame: frameRect, textContainer: nil)
    }

    /// Builds the text system the editor types into.
    ///
    /// `init(frame:textContainer:)` is `NSTextView`'s **designated** initialiser, and passing it
    /// `nil` does not make it assemble a text system — it makes a view with no text storage at
    /// all. Such a view looks entirely normal: it draws its background, it takes first responder,
    /// `isEditable` is `true`, `shouldChangeText` returns `true` — and it silently discards every
    /// character.
    ///
    /// That was the Text and Callout defect where nothing could be typed into the box. The dark
    /// rectangle that showed was this view, drawing its `.elevated` background over the page,
    /// focused, and unable to hold a letter.
    ///
    /// Every existing test passed because they all drove
    /// `PDFCanvasViewController.typeIntoTextEntry`, which writes the draft straight onto the
    /// presenter and never asks the editor to hold anything. `TextEntryFocusTests` calls
    /// `insertText` instead, which is what a keystroke does, and it reproduced immediately.
    private static func makeTextSystem(size: CGSize) -> (container: NSTextContainer, storage: NSTextStorage) {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(
            size: CGSize(width: size.width, height: .greatestFiniteMagnitude)
        )
        container.widthTracksTextView = true
        container.heightTracksTextView = false
        layout.addTextContainer(container)
        return (container, storage)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func configure() {
        // Stated rather than inherited. Both default to `true` for a programmatically created
        // `NSTextView`, and both are the difference between a text box and a dark rectangle, so
        // they are written down where anyone changing this class will see them.
        isEditable = true
        isSelectable = true
        drawsBackground = true
        backgroundColor = ZPDFColor.nsColor(.elevated).withAlphaComponent(0.92)
        insertionPointColor = ZPDFColor.nsColor(.accentCyan)
        textColor = ZPDFColor.nsColor(.textPrimary)
        isRichText = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        allowsUndo = true
        textContainerInset = NSSize(width: 2, height: 1)
        setAccessibilityLabel(NSLocalizedString(
            "Markup text",
            comment: "Accessibility label of the in-canvas text box"
        ))
    }

    override func didChangeText() {
        super.didChangeText()
        onTextChange?(string)
    }

    /// `Escape`. `NSTextView` routes it here rather than to `keyDown`.
    override func cancelOperation(_ sender: Any?) {
        onCommit?()
    }

    /// Losing first responder to anything else — a panel, another window, the canvas —
    /// commits, which is the "clicking away commits" half of the rule for the cases the
    /// canvas's own click handler never sees.
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onCommit?() }
        return resigned
    }
}
