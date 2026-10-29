import SwiftUI
import ZPDFDesignSystem

/// Settings ▸ Keyboard Shortcuts (NL-UX-11): every command, its shortcut, and a recorder.
///
/// Click a shortcut, press the new chord; Escape cancels, Delete clears. A clash is refused
/// with the other command's name under the list.
public struct ShortcutSettingsView: View {

    @Bindable private var model: ShortcutSettingsModel

    public init(model: ShortcutSettingsModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.m) {
            ZPDFSearchField(
                text: $model.filter,
                placeholder: NSLocalizedString("Filter commands", comment: "Shortcut settings search placeholder")
            )
            List(model.rows) { row in
                HStack(spacing: ZPDFSpacing.m) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.title).zpdfText(.body, .textPrimary)
                        Text("\(row.group) · \(row.context)").zpdfText(.caption, .textSecondary)
                    }
                    Spacer()
                    ShortcutRecorderButton(model: model, row: row)
                    if row.isCustomised {
                        Button(NSLocalizedString("Default", comment: "Shortcut settings: restore one command's standard shortcut")) {
                            model.restore(row.id)
                        }
                        .buttonStyle(.link)
                        .accessibilityLabel(Text(String(
                            format: NSLocalizedString("Restore the standard shortcut for %@", comment: "Accessibility: restore one shortcut"),
                            row.title
                        )))
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 320)
            if let refusal = model.refusal {
                Text(refusal)
                    .zpdfText(.caption, .danger)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            HStack {
                Text(NSLocalizedString(
                    "Click a shortcut and press the new keys. Delete removes it; Escape cancels.",
                    comment: "Shortcut settings help line"
                ))
                .zpdfText(.caption, .textSecondary)
                Spacer()
                Button(NSLocalizedString("Restore All Defaults", comment: "Shortcut settings: restore every standard shortcut")) {
                    model.restoreAll()
                }
            }
        }
        .padding(ZPDFSpacing.l)
        .frame(minWidth: 520, minHeight: 440)
    }
}

/// The shortcut cell: shows the chord; clicked, it listens for the next one.
private struct ShortcutRecorderButton: View {
    let model: ShortcutSettingsModel
    let row: ShortcutSettingsModel.Row
    @FocusState private var focused: Bool

    private var isRecording: Bool { model.recording == row.id }

    var body: some View {
        Button {
            if isRecording { model.cancelRecording() } else { model.beginRecording(row.id); focused = true }
        } label: {
            Text(isRecording
                 ? NSLocalizedString("Type shortcut…", comment: "Shortcut recorder while listening")
                 : (row.shortcut ?? NSLocalizedString("None", comment: "Shortcut recorder: no shortcut")))
                .zpdfText(.monoNumeric, isRecording ? .accent : .textPrimary)
                .frame(minWidth: 110)
        }
        .focusable()
        .focused($focused)
        .onKeyPress(phases: .down) { press in
            guard isRecording else { return .ignored }
            if press.key == .escape { model.cancelRecording(); return .handled }
            if press.key == .delete || press.key == .deleteForward { model.clear(row.id); return .handled }
            guard let binding = ShortcutRecorderButton.binding(characters: press.characters, modifiers: press.modifiers) else {
                return .handled
            }
            model.record(binding)
            return .handled
        }
        .accessibilityLabel(Text(String(
            format: NSLocalizedString("Shortcut for %@", comment: "Accessibility label of a shortcut recorder"),
            row.title
        )))
        .accessibilityValue(Text(row.shortcut ?? NSLocalizedString("None", comment: "Shortcut recorder: no shortcut")))
    }

    /// The binding a key press names: one printable character plus its modifiers.
    static func binding(characters: String, modifiers: EventModifiers) -> ZPDFKeyBinding? {
        ShortcutRecorderInput.binding(characters: characters, command: modifiers.contains(.command),
                                      shift: modifiers.contains(.shift), option: modifiers.contains(.option),
                                      control: modifiers.contains(.control))
    }
}

/// The recorder's key → binding rule, value-level for tests.
public enum ShortcutRecorderInput {
    public static func binding(characters: String, command: Bool, shift: Bool, option: Bool, control: Bool) -> ZPDFKeyBinding? {
        guard characters.count == 1, let character = characters.lowercased().first,
              character.isLetter || character.isNumber || character.isPunctuation || character.isSymbol
        else { return nil }
        var modifiers: ZPDFModifierFlags = []
        if command { modifiers.insert(.command) }
        if shift { modifiers.insert(.shift) }
        if option { modifiers.insert(.option) }
        if control { modifiers.insert(.control) }
        return .character(character, modifiers)
    }
}
