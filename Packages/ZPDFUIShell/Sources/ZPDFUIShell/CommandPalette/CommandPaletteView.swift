import SwiftUI
import ZPDFDesignSystem

/// The command palette's view: a search field over a list of rows (NL-UX-05).
///
/// Every row shows its name, where it lives and its shortcut, so the palette doubles as the
/// place a person learns the keys. ↑/↓ move the highlight, Return runs it, Escape closes.
public struct CommandPaletteView: View {

    @Bindable private var model: CommandPaletteModel
    @FocusState private var fieldFocused: Bool

    public init(model: CommandPaletteModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: ZPDFSpacing.m) {
                ZPDFGlyphView(.symbol(.search), size: ZPDFSpacing.Control.icon)
                    .foregroundStyle(ZPDFColor.textSecondary)
                    .accessibilityHidden(true)
                TextField(
                    NSLocalizedString("Type a command, tool, page or subject", comment: "Command palette search placeholder"),
                    text: $model.query
                )
                .textFieldStyle(.plain)
                .zpdfFont(ZPDFTypography.body)
                .focused($fieldFocused)
                .onSubmit { model.performSelected() }
                .onKeyPress(.downArrow) { model.moveSelection(by: 1); return .handled }
                .onKeyPress(.upArrow) { model.moveSelection(by: -1); return .handled }
                .accessibilityLabel(Text(NSLocalizedString("Command palette search", comment: "Accessibility label of the command palette field")))
            }
            .padding(ZPDFSpacing.l)
            ZPDFHairlineDivider()
            if model.results.isEmpty {
                Text(NSLocalizedString("Nothing matches.", comment: "Command palette empty result"))
                    .zpdfText(.caption, .textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(model.results.enumerated()), id: \.element.id) { index, item in
                                row(item, isSelected: index == model.selectedIndex)
                                    .id(item.id)
                                    .onTapGesture { model.select(index: index); model.performSelected() }
                            }
                        }
                    }
                    .frame(maxHeight: 360)
                    .onChange(of: model.selectedIndex) { _, index in
                        guard model.results.indices.contains(index) else { return }
                        proxy.scrollTo(model.results[index].id)
                    }
                }
            }
        }
        .background(ZPDFColor.color(.elevated))
        .onExitCommand { model.dismiss() }
        .onAppear { fieldFocused = true }
    }

    private func row(_ item: CommandPaletteItem, isSelected: Bool) -> some View {
        HStack(spacing: ZPDFSpacing.m) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .zpdfText(.body, item.isEnabled ? .textPrimary : .textTertiary)
                    .lineLimit(1)
                Text(item.detail)
                    .zpdfText(.caption, .textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: ZPDFSpacing.m)
            if let shortcut = item.shortcut {
                Text(shortcut)
                    .zpdfText(.monoNumeric, .textSecondary)
                    .accessibilityLabel(Text(ZPDFKeyboardHintSpeech.spoken(shortcut)))
            }
        }
        .padding(.horizontal, ZPDFSpacing.l)
        .padding(.vertical, ZPDFSpacing.s)
        .background(isSelected ? ZPDFColor.color(.selectedFill) : Color.clear)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
