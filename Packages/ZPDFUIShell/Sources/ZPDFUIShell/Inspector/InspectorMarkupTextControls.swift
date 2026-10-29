import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

/// The Inspector rows nl-markup adds to the Markup tab: line ends for open markups
/// (NL-MARKUP-07) and font family and alignment for text-bearing ones (NL-MARKUP-08).
///
/// `MarkupStyle` has always stored all four, and none of them was editable: the ends were
/// written once at creation, and the font and alignment never changed from their defaults.
/// Each row follows the Markup tab's rules — one bulk edit per change, a mixed selection
/// shows "Mixed" and writes nothing until a value is picked, locked markups disable the row.
extension InspectorPanel {

    /// Kinds whose two ends can carry decorations.
    public static func holdsLineEnds(_ kind: MarkupKind) -> Bool {
        switch kind {
        case .line, .arrow, .polyline, .freehand, .callout: return true
        default: return false
        }
    }

    /// Kinds whose words take a font family and an alignment.
    public static func holdsTextFormatting(_ kind: MarkupKind) -> Bool {
        kind == .text || kind == .callout
    }

    /// Kinds that draw the Cloud line style as scallops (NL-MARKUP-16). Elsewhere the popup does
    /// not offer it: it used to write a style and an undo step that drew nothing.
    public static func drawsCloudStyle(_ kind: MarkupKind) -> Bool {
        switch kind {
        case .rectangle, .ellipse, .polygon, .cloud, .revisionCloud: return true
        default: return false
        }
    }

    /// Line ends, when every selected markup is an open stroke.
    @ViewBuilder
    func lineEndsRow(_ summary: InspectorSelectionSummary, enabled: Bool) -> some View {
        if !summary.isEmpty, summary.markups.allSatisfy({ Self.holdsLineEnds($0.kind) }) {
            let starts = summary.markups.map { $0.startCap ?? .none }
            let ends = summary.markups.map { $0.endCap ?? .none }
            InspectorInlineRow(label: NSLocalizedString("Line ends", comment: "Inspector row label: the decorations at the start and end of a line")) {
                HStack(spacing: ZPDFSpacing.m) {
                    InspectorChoiceControl(
                        choices: MarkupLineCap.offered,
                        value: InspectorSelectionSummary.commonValue(starts),
                        isEnabled: enabled,
                        accessibilityLabel: NSLocalizedString("Start of line", comment: "Accessibility label of the line start decoration menu"),
                        name: { $0.displayName }
                    ) { applyStyle(MarkupStyleEdit(startCap: $0), to: summary) }
                    Image(systemName: "arrow.right")
                        .foregroundStyle(ZPDFColor.textSecondary)
                        .accessibilityHidden(true)
                    InspectorChoiceControl(
                        choices: MarkupLineCap.offered,
                        value: InspectorSelectionSummary.commonValue(ends),
                        isEnabled: enabled,
                        accessibilityLabel: NSLocalizedString("End of line", comment: "Accessibility label of the line end decoration menu"),
                        name: { $0.displayName }
                    ) { applyStyle(MarkupStyleEdit(endCap: $0), to: summary) }
                }
            }
        }
    }

    /// Font family and alignment, when every selected markup draws words.
    @ViewBuilder
    func textFormattingRows(_ summary: InspectorSelectionSummary, enabled: Bool) -> some View {
        if !summary.isEmpty, summary.markups.allSatisfy({ Self.holdsTextFormatting($0) }) {
            let fonts = summary.markups.map { $0.fontName ?? "Helvetica" }
            let alignments = summary.markups.map { $0.textAlignment ?? .leading }
            InspectorInlineRow(label: NSLocalizedString("Font", comment: "Inspector row label: the text's font family")) {
                InspectorChoiceControl(
                    choices: Self.fontChoices(including: fonts),
                    value: InspectorSelectionSummary.commonValue(fonts),
                    isEnabled: enabled,
                    accessibilityLabel: NSLocalizedString("Font family", comment: "Accessibility label of the markup font menu"),
                    name: { MarkupFontFamilies.displayName($0) }
                ) { applyStyle(MarkupStyleEdit(fontName: $0), to: summary) }
            }
            InspectorInlineRow(label: NSLocalizedString("Align", comment: "Inspector row label: the text's horizontal alignment")) {
                InspectorAlignmentControl(
                    value: InspectorSelectionSummary.commonValue(alignments),
                    isEnabled: enabled
                ) { applyStyle(MarkupStyleEdit(textAlignment: $0), to: summary) }
            }
        }
    }

    /// *Set as Default for ⟨kind⟩* (NL-MARKUP-04): shown when the selection is one markup a
    /// tool draws, so its whole look becomes what that tool draws next, after a restart too.
    @ViewBuilder
    func setAsDefaultRow(_ summary: InspectorSelectionSummary) -> some View {
        if summary.markups.count == 1, let markup = summary.markups.first, ZenitToolMode.isDrawable(markup.kind) {
            HStack {
                Spacer(minLength: 0)
                Button(Self.setAsDefaultTitle(for: markup.kind)) {
                    environment.toolbar.setAsDefault(markup)
                }
                .buttonStyle(.link)
                .help(NSLocalizedString(
                    "New markups of this kind are drawn with this markup's colour, fill, width, line style, ends and text style.",
                    comment: "Set as Default help"
                ))
            }
        }
    }

    /// "Set as Default for Cloud".
    public static func setAsDefaultTitle(for kind: MarkupKind) -> String {
        String(
            format: NSLocalizedString(
                "Set as Default for %@", comment: "Makes the selected markup's style the default for its kind; the kind's name"
            ),
            kind.displayName
        )
    }

    /// The offered families, plus any stored one the list does not have — a markup imported
    /// with a family the list lacks still shows its own name rather than a wrong one.
    static func fontChoices(including stored: [String]) -> [String] {
        var choices = MarkupFontFamilies.all
        for family in stored where !choices.contains(family) { choices.append(family) }
        return choices
    }
}

/// A boxed popup over a fixed set of choices, showing "Mixed" when the selection disagrees.
struct InspectorChoiceControl<Value: Hashable>: View {

    let choices: [Value]
    let value: Value?
    let isEnabled: Bool
    let accessibilityLabel: String
    let name: (Value) -> String
    let onChange: (Value) -> Void

    private var title: String {
        value.map(name) ?? InspectorAppearanceText.mixed
    }

    var body: some View {
        InspectorPopup(title: title, isEnabled: isEnabled) {
            ForEach(choices, id: \.self) { choice in
                Button {
                    guard choice != value else { return }
                    onChange(choice)
                } label: {
                    if choice == value {
                        Label(name(choice), systemImage: "checkmark")
                    } else {
                        Text(name(choice))
                    }
                }
            }
        }
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityValue(Text(title))
        .help(InspectorAppearanceText.helpText(isEnabled: isEnabled))
    }
}

/// Left, centre, right, justified: four buttons, the current one marked, each labelled for
/// VoiceOver by name rather than by its glyph.
struct InspectorAlignmentControl: View {

    let value: MarkupTextAlignment?
    let isEnabled: Bool
    let onChange: (MarkupTextAlignment) -> Void

    var body: some View {
        HStack(spacing: ZPDFSpacing.xs) {
            ForEach(MarkupTextAlignment.allCases) { alignment in
                Button {
                    guard alignment != value else { return }
                    onChange(alignment)
                } label: {
                    Image(systemName: alignment.symbolName)
                        .frame(width: ZPDFSpacing.Control.iconSmall + ZPDFSpacing.s, height: ZPDFSpacing.Control.iconSmall + ZPDFSpacing.s)
                        .foregroundStyle(ZPDFColor.color(alignment == value ? .accentBlue : .textSecondary))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!isEnabled)
                .accessibilityLabel(Text(alignment.displayName))
                .accessibilityAddTraits(alignment == value ? .isSelected : [])
                .help(alignment.displayName)
            }
        }
    }
}
