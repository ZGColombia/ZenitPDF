import Combine
import SwiftUI

/// Moves keyboard focus into a `ZPDFSearchField` from outside it — a ⌘F command, a menu item,
/// an AppKit controller — and reports whether the field has focus.
///
/// Hold one per field (in a presenter or window controller), pass it to the field, and call
/// `focus()`. The request reaches the field's own `@FocusState`, which makes its text view the
/// window's first responder; there is no need to walk the view tree for an `NSTextField`.
@MainActor
public final class ZPDFSearchFieldFocus: ObservableObject {
    /// Whether the field currently has keyboard focus, as last reported by the field.
    @Published public internal(set) var isFocused = false

    /// Focus requests delivered to the field.
    let requests = PassthroughSubject<Bool, Never>()

    public init() {}

    /// Puts keyboard focus in the field (and selects nothing; typing replaces nothing).
    public func focus() { requests.send(true) }
}

/// The rounded search field of the canvas bar ("Search in document") and of panel searches,
/// the Navigator's Search page among them (V-049).
///
/// Recessed `inset` ground, `borderStrong` edge that turns `accentBlue` with a focus ring while
/// it has keyboard focus, a leading magnifier, a placeholder in `textTertiary`, an optional
/// trailing note in `textSecondary` (the canvas bar's "3/12"), and a clear button that appears
/// only when there is something to clear. Escape clears first, as the clear button does; an
/// Escape with nothing to clear is not taken, so it still reaches the panel around the field.
///
/// W-047: the canvas bar used a hand-built copy of this field, and the two had drifted — its
/// Escape only dropped focus, and it had no hover paint or focus ring. Both are this field now,
/// with one Escape rule and one clear rule (``onClear`` when the owner has more to clear than the
/// text, such as a search presenter's results).
public struct ZPDFSearchField: View {
    @Binding private var text: String
    private let placeholder: String
    private let accessibilityLabel: String
    private let accessibilityValue: String?
    private let accessoryText: String?
    private let onClear: (() -> Void)?
    private let onSubmit: () -> Void
    private let focusController: ZPDFSearchFieldFocus?

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    /// - Parameters:
    ///   - text: the query.
    ///   - placeholder: shown while empty ("Search in document…").
    ///   - accessibilityLabel: what VoiceOver calls the field; defaults to the placeholder.
    ///   - accessibilityValue: spoken after the query, for example the result count; `nil` for none.
    ///   - accessoryText: a short note before the clear button — where you are among the hits,
    ///     "3/12"; `nil` for none. Not spoken: say it in `accessibilityValue`.
    ///   - focus: lets a command outside the field (⌘F) focus it; `nil` when nothing needs to.
    ///   - onClear: what the clear button and Escape do; `nil` empties the text.
    ///   - onSubmit: Return in the field — run or advance the search.
    public init(
        text: Binding<String>,
        placeholder: String,
        accessibilityLabel: String? = nil,
        accessibilityValue: String? = nil,
        accessoryText: String? = nil,
        focus: ZPDFSearchFieldFocus? = nil,
        onClear: (() -> Void)? = nil,
        onSubmit: @escaping () -> Void = {}
    ) {
        self.focusController = focus
        self._text = text
        self.placeholder = placeholder
        self.accessibilityLabel = accessibilityLabel ?? placeholder
        self.accessibilityValue = accessibilityValue
        self.accessoryText = accessoryText
        self.onClear = onClear
        self.onSubmit = onSubmit
    }

    public var body: some View {
        let paint = Self.paint(isFocused: isFocused, isHovering: isHovering, isEnabled: isEnabled)
        HStack(spacing: ZPDFSpacing.s) {
            ZPDFGlyphView(.symbol(.search), size: ZPDFSpacing.Control.icon - 3)
                .foregroundStyle(ZPDFColor.textTertiary)
            TextField("", text: $text)
            .textFieldStyle(.plain)
            .zpdfFont(.control)
            .foregroundStyle(ZPDFColor.color(paint.foreground).opacity(paint.foregroundOpacity))
            // The placeholder is drawn by hand: a plain field's own prompt ignores its colour and
            // renders as bright as typed text, which the mockup's tertiary hint is not.
            .background(alignment: .leading) {
                if text.isEmpty {
                    Text(placeholder)
                        .zpdfFont(.control)
                        .foregroundStyle(ZPDFColor.textTertiary)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .focused($isFocused)
            .onSubmit(onSubmit)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(accessibilityValue.map { Text($0) } ?? Text(verbatim: ""))
            if let accessoryText {
                Text(accessoryText)
                    .zpdfFont(.caption)
                    .foregroundStyle(ZPDFColor.textSecondary)
                    .monospacedDigit()
                    .fixedSize()
                    .accessibilityHidden(true)
            }
            if Self.showsClearButton(text: text) {
                Button {
                    Self.clear(text: $text, onClear: onClear)
                } label: {
                    ZPDFGlyphView(.symbol(.clear), size: ZPDFSpacing.Control.iconSmall)
                        .frame(width: ZPDFSpacing.Control.icon, height: ZPDFSpacing.Control.icon)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(ZPDFColor.textTertiary)
                .help(Self.clearLabel)
                .accessibilityLabel(Self.clearLabel)
            }
        }
        .padding(.horizontal, ZPDFSpacing.m + 2)
        .frame(height: ZPDFSpacing.Chrome.searchFieldHeight)
        .background { ZPDFPaintedBackground(paint, cornerRadius: ZPDFRadius.control) }
        .zpdfFocusRing(isFocused, cornerRadius: ZPDFRadius.control)
        .onHover { isHovering = $0 }
        // `nil` with nothing to clear: the field does not claim an Escape it has no use for, so
        // an idle Escape still reaches the panel (the Navigator closes Search on it). A handler
        // that did nothing swallowed the key all the same (V-049).
        .onExitCommand(perform: Self.exitCommand(text: $text, onClear: onClear))
        .onReceive(focusController?.requests.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()) { wantsFocus in
            isFocused = wantsFocus
        }
        .onChange(of: isFocused) { _, focused in
            focusController?.isFocused = focused
        }
        .zpdfAnimation(.micro, value: isHovering)
        .zpdfAnimation(.quick, value: isFocused)
    }

    /// The field's paint; the view uses exactly this.
    public static func paint(isFocused: Bool, isHovering: Bool, isEnabled: Bool) -> ZPDFControlPaint {
        ZPDFControlPaints.field(
            isFocused: isFocused,
            state: .resolve(isHovering: isHovering, isPressed: false, isEnabled: isEnabled),
            isEnabled: isEnabled
        )
    }

    /// Whether the clear button shows: whenever the query is not empty (a query of spaces is
    /// still something the person typed and may want gone).
    public static func showsClearButton(text: String) -> Bool {
        !text.isEmpty
    }

    /// What Escape does in the field: what the clear button does to a query that has something
    /// in it, or `nil` — no handler, so the key goes on to the field's container — when there is
    /// nothing to clear.
    public static func exitCommand(text: Binding<String>, onClear: (() -> Void)? = nil) -> (() -> Void)? {
        guard showsClearButton(text: text.wrappedValue) else { return nil }
        return { clear(text: text, onClear: onClear) }
    }

    /// The one clear rule, for the button and for Escape: the owner's `onClear` when it gave one,
    /// else the text emptied.
    static func clear(text: Binding<String>, onClear: (() -> Void)?) {
        if let onClear {
            onClear()
        } else {
            text.wrappedValue = ""
        }
    }

    /// The clear button's label and help.
    public static var clearLabel: String {
        NSLocalizedString("Clear Search", comment: "Button in a search field: empty the query")
    }
}

#if DEBUG
struct ZPDFSearchField_Previews: PreviewProvider {
    private struct Demo: View {
        @State private var empty = ""
        @State private var filled = "RFI"

        var body: some View {
            ZPDFPreviewPanel("Search field") {
                ZPDFSearchField(text: $empty, placeholder: NSLocalizedString("Search in document…", comment: "Preview label"))
                ZPDFSearchField(text: $filled, placeholder: NSLocalizedString("Search in document…", comment: "Preview label"))
            }
        }
    }

    static var previews: some View {
        ZPDFAppearancePair { Demo() }
            .previewDisplayName("ZPDFSearchField - dark and light")
    }
}
#endif
