import SwiftUI

/// A compact toolbar or palette button.
///
/// Selection is never signalled by colour alone: a selected button gets a filled ground, a
/// weight change, an underline indicator and the `isSelected` accessibility trait.
public struct ZPDFToolbarButton: View {

    /// How much visual weight the button carries.
    public enum Prominence: Sendable, Hashable {
        /// The default: quiet until hovered or selected.
        case standard
        /// A primary action, tinted with the Zenit accent.
        case accent
        /// A destructive action.
        case destructive
    }

    private let glyph: ZPDFGlyph
    private let title: String
    private let showsTitle: Bool
    private let isSelected: Bool
    private let prominence: Prominence
    private let helpText: String?
    private let keyboardHint: String?
    private let spokenKeyboardHint: String?
    private let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    /// - Parameters:
    ///   - glyph: the icon to draw.
    ///   - title: the accessibility label, and the visible label when `showsTitle` is on.
    ///   - showsTitle: whether the label is drawn next to the icon.
    ///   - isSelected: whether this button represents the active tool or state.
    ///   - prominence: visual weight.
    ///   - helpText: hover help; falls back to `title`.
    ///   - keyboardHint: the shortcut, appended to the help tag and spoken by VoiceOver.
    ///   - action: what the button does.
    public init(
        glyph: ZPDFGlyph,
        title: String,
        showsTitle: Bool = false,
        isSelected: Bool = false,
        prominence: Prominence = .standard,
        helpText: String? = nil,
        keyboardHint: String? = nil,
        spokenKeyboardHint: String? = nil,
        action: @escaping () -> Void
    ) {
        self.spokenKeyboardHint = spokenKeyboardHint
        self.glyph = glyph
        self.title = title
        self.showsTitle = showsTitle
        self.isSelected = isSelected
        self.prominence = prominence
        self.helpText = helpText
        self.keyboardHint = keyboardHint
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: ZPDFSpacing.xs) {
                ZPDFGlyphView(glyph, size: ZPDFSpacing.Control.icon)
                if showsTitle {
                    Text(title).zpdfFont(isSelected ? .control.withWeight(.medium) : .control)
                }
            }
            .padding(.horizontal, showsTitle ? ZPDFSpacing.m : ZPDFSpacing.s)
            .frame(
                minWidth: ZPDFSpacing.Control.minimumHitTarget,
                minHeight: ZPDFSpacing.Control.toolbarButton
            )
            .overlay(alignment: .bottom) {
                // A shape cue for selection, so the state survives greyscale and colour blindness.
                ZPDFIndicatorBar(token: isSelected ? .accentBlue : nil, inset: ZPDFSpacing.s)
            }
        }
        .buttonStyle(ZPDFPaintedButtonStyle(paints, cornerRadius: ZPDFRadius.control, isHovering: isHovering, isEnabled: isEnabled))
        .focusable(isEnabled)
        .focused($isFocused)
        .zpdfFocusRing(isFocused, cornerRadius: ZPDFRadius.control)
        .onHover { isHovering = $0 }
        .zpdfAnimation(.micro, value: isHovering)
        .zpdfAnimation(.quick, value: isSelected)
        .help(helpTag)
        .accessibilityLabel(title)
        // IM-059: the shortcut is spoken as words, not read as glyphs.
        .accessibilityHint(Text(Self.spokenHint(display: keyboardHint, spoken: spokenKeyboardHint)))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// The paint in each interaction state, from the shared chrome table.
    var paints: ZPDFControlPaintSet {
        ZPDFControlPaintSet { state in
            ZPDFControlPaints.toolbarButton(isSelected: isSelected, prominence: prominence, state: state, isEnabled: isEnabled)
        }
    }

    /// The hint VoiceOver reads for a shortcut: the explicit spoken form, else the display
    /// string turned into words.
    static func spokenHint(display: String?, spoken: String?) -> String {
        if let spoken, !spoken.isEmpty { return spoken }
        guard let display, !display.isEmpty else { return "" }
        return ZPDFKeyboardHintSpeech.spoken(display)
    }

    private var helpTag: String {
        let base = helpText ?? title
        guard let keyboardHint, !keyboardHint.isEmpty else { return base }
        return "\(base) (\(keyboardHint))"
    }

}

#if DEBUG
struct ZPDFToolbarButton_Previews: PreviewProvider {
    private struct Demo: View {
        @State private var selected = 1

        var body: some View {
            ZPDFPreviewPanel("Toolbar buttons") {
                HStack(spacing: ZPDFSpacing.s) {
                    ZPDFToolbarButton(
                        glyph: .symbol(.select),
                        title: NSLocalizedString("Select", comment: "Preview label"),
                        isSelected: selected == 0,
                        keyboardHint: "V"
                    ) { selected = 0 }
                    ZPDFToolbarButton(
                        glyph: .measurement(.length),
                        title: NSLocalizedString("Length", comment: "Preview label"),
                        isSelected: selected == 1,
                        keyboardHint: "Command L"
                    ) { selected = 1 }
                    ZPDFToolbarButton(
                        glyph: .measurement(.area),
                        title: NSLocalizedString("Area", comment: "Preview label"),
                        isSelected: selected == 2
                    ) { selected = 2 }
                    ZPDFToolbarButton(
                        glyph: .symbol(.export),
                        title: NSLocalizedString("Export", comment: "Preview label"),
                        showsTitle: true,
                        prominence: .accent
                    ) {}
                }
                HStack(spacing: ZPDFSpacing.s) {
                    ZPDFToolbarButton(
                        glyph: .symbol(.delete),
                        title: NSLocalizedString("Delete", comment: "Preview label"),
                        showsTitle: true,
                        prominence: .destructive
                    ) {}
                    ZPDFToolbarButton(
                        glyph: .symbol(.undo),
                        title: NSLocalizedString("Undo", comment: "Preview label")
                    ) {}
                    .disabled(true)
                }
            }
        }
    }

    static var previews: some View {
        ZPDFAppearancePair { Demo() }
            .previewDisplayName("ZPDFToolbarButton - dark and light")
    }
}
#endif
