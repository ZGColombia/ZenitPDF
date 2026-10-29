import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

/// One preset drawn as a tile in the grid.
///
/// The colour swatch is never the only signal: the tool glyph, the name and the category all
/// carry the same information, so the tile still reads in greyscale and under Increase Contrast.
public struct ToolPresetTile: View {

    private let preset: ToolPresetSummary
    private let isArmed: Bool
    private let slotNumber: Int?
    private let onActivate: () -> Void
    private let onEdit: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    /// - Parameters:
    ///   - preset: the preset to draw.
    ///   - isArmed: whether this preset is the one the next canvas gesture will use.
    ///   - slotNumber: the one-based number key that arms this preset, or `nil` when it sits
    ///     past the ninth slot of its set. Derived from position by ``ToolSlotOrder``, never
    ///     read off the preset: the stored `shortcutDisplayString` was once printed here while
    ///     being bound to nothing, and a shortcut badge that lies is
    ///     worse than no badge.
    ///   - onActivate: arms the preset. Bound to a double-click and to Return.
    ///   - onEdit: opens the edit sheet.
    public init(
        preset: ToolPresetSummary,
        isArmed: Bool,
        slotNumber: Int? = nil,
        onActivate: @escaping () -> Void,
        onEdit: @escaping () -> Void
    ) {
        self.preset = preset
        self.isArmed = isArmed
        self.slotNumber = slotNumber
        self.onActivate = onActivate
        self.onEdit = onEdit
    }

    public var body: some View {
        VStack(spacing: ZPDFSpacing.xs) {
            swatch
            Text(preset.name)
                .zpdfText(.caption, .textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .padding(ZPDFSpacing.s)
        .frame(width: 92, height: 88)
        .zpdfControlBackground(
            fill: isArmed ? .selection : (isHovering ? .elevated : .surface),
            cornerRadius: ZPDFRadius.medium
        )
        .overlay(alignment: .topTrailing) { badges }
        .zpdfFocusRing(isFocused)
        .focusable(true)
        .focused($isFocused)
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2, perform: onActivate)
        .onTapGesture(count: 1) { isFocused = true }
        .onKeyPress(.return) {
            onActivate()
            return .handled
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(preset.accessibilityLabel))
        .accessibilityValue(Text(ToolPresetAccessibility.value(isArmed: isArmed, slotNumber: slotNumber)))
        .accessibilityHint(Text(NSLocalizedString(
            "Press Return to use this tool, or drag it onto the drawing.",
            comment: "Accessibility hint for a Tool Library preset"
        )))
        .accessibilityAddTraits(isArmed ? [.isButton, .isSelected] : .isButton)
        .help(helpText)
    }

    private var swatch: some View {
        ZStack {
            RoundedRectangle(cornerRadius: ZPDFRadius.small, style: .continuous)
                .fill(preset.colorRGBA.swiftUIColor.opacity(0.22))
                .overlay {
                    RoundedRectangle(cornerRadius: ZPDFRadius.small, style: .continuous)
                        .strokeBorder(preset.colorRGBA.swiftUIColor, lineWidth: ZPDFStroke.measurement)
                }
            ZPDFGlyphView(WorkflowGlyphs.glyph(for: preset), size: ZPDFSpacing.Control.iconLarge)
                .foregroundStyle(ZPDFColor.textPrimary)
        }
        .frame(width: 40, height: 32)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var badges: some View {
        HStack(spacing: 2) {
            if let slotNumber, let key = ToolSlotOrder.displayString(slot: slotNumber) {
                Text(key)
                    .zpdfText(.monoNumeric, .textSecondary)
            }
            if preset.isReadOnly {
                ZPDFGlyphView(.symbol(.lock), size: ZPDFSpacing.Control.iconSmall)
                    .foregroundStyle(ZPDFColor.textSecondary)
            }
            if preset.isFavorite {
                ZPDFGlyphView(.symbol(.success), size: ZPDFSpacing.Control.iconSmall)
                    .foregroundStyle(ZPDFColor.accentCyan)
            }
        }
        .padding(ZPDFSpacing.xs)
        .accessibilityHidden(true)
    }

    private var helpText: String {
        var parts = [preset.name, preset.category]
        if let slotNumber, let key = ToolSlotOrder.displayString(slot: slotNumber) {
            parts.append(key)
        }
        if preset.isReadOnly {
            parts.append(NSLocalizedString("Read-only", comment: "Help tag for a preset from a shared library"))
        }
        return parts.joined(separator: " · ")
    }
}

/// One preset drawn as a dense list row.
public struct ToolPresetRow: View {

    private let preset: ToolPresetSummary
    private let isArmed: Bool
    private let slotNumber: Int?
    private let onActivate: () -> Void

    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    /// Creates a preset row.
    ///
    /// - Parameter slotNumber: the number key that arms this preset, or `nil` past the ninth
    ///   slot. See ``ToolPresetTile/init(preset:isArmed:slotNumber:onActivate:onEdit:)`` for
    ///   why it is a position and not a stored string.
    public init(
        preset: ToolPresetSummary,
        isArmed: Bool,
        slotNumber: Int? = nil,
        onActivate: @escaping () -> Void
    ) {
        self.preset = preset
        self.isArmed = isArmed
        self.slotNumber = slotNumber
        self.onActivate = onActivate
    }

    public var body: some View {
        HStack(spacing: ZPDFSpacing.s) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(preset.colorRGBA.swiftUIColor)
                .frame(width: 3, height: ZPDFSpacing.Control.listRow - 6)
                .accessibilityHidden(true)
            ZPDFGlyphView(WorkflowGlyphs.glyph(for: preset), size: ZPDFSpacing.Control.icon)
                .foregroundStyle(ZPDFColor.textSecondary)
                .accessibilityHidden(true)
            Text(preset.name)
                .zpdfText(isArmed ? .body.withWeight(.semibold) : .body, .textPrimary)
                .lineLimit(1)
            Spacer(minLength: ZPDFSpacing.s)
            if let slotNumber, let key = ToolSlotOrder.displayString(slot: slotNumber) {
                Text(key)
                    .zpdfText(.monoNumeric, .textSecondary)
                    .accessibilityHidden(true)
            }
            if preset.isReadOnly {
                ZPDFGlyphView(.symbol(.lock), size: ZPDFSpacing.Control.iconSmall)
                    .foregroundStyle(ZPDFColor.textSecondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, ZPDFSpacing.s)
        .frame(height: ZPDFSpacing.Control.listRow)
        .background {
            RoundedRectangle(cornerRadius: ZPDFRadius.small, style: .continuous)
                .fill(isArmed
                    ? ZPDFColor.selection
                    : (isHovering ? ZPDFColor.elevated : Color.clear))
        }
        .zpdfFocusRing(isFocused, cornerRadius: ZPDFRadius.small)
        .focusable(true)
        .focused($isFocused)
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2, perform: onActivate)
        .onKeyPress(.return) {
            onActivate()
            return .handled
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(preset.accessibilityLabel))
        .accessibilityValue(Text(ToolPresetAccessibility.value(isArmed: isArmed, slotNumber: slotNumber)))
        .accessibilityAddTraits(isArmed ? [.isButton, .isSelected] : .isButton)
    }
}

/// The bar that appears after a delete, offering the way back.
public struct ToolPresetUndoBar: View {

    private let deletion: PendingToolPresetDeletion
    private let onUndo: () -> Void
    private let onDismiss: () -> Void

    /// Creates the undo bar.
    public init(
        deletion: PendingToolPresetDeletion,
        onUndo: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.deletion = deletion
        self.onUndo = onUndo
        self.onDismiss = onDismiss
    }

    public var body: some View {
        ZPDFInlineWarning(
            severity: .info,
            message: deletion.message,
            actionTitle: NSLocalizedString("Put It Back", comment: "Undo a tool preset deletion"),
            action: onUndo,
            onDismiss: onDismiss
        )
        .accessibilityAddTraits(.isSummaryElement)
    }
}

/// The spoken state of a Tool Library preset, shared by the tile and the row so the two
/// cannot describe the same preset differently.
enum ToolPresetAccessibility {

    /// "Active tool, shortcut 3" — the armed state, plus the number key when it has one.
    ///
    /// The badge on screen is a bare digit, which a screen reader would otherwise read as a
    /// stray number next to a tool name. Saying "shortcut" is the whole difference between a
    /// keyboard path that is discoverable and one that is only visible.
    static func value(isArmed: Bool, slotNumber: Int?) -> String {
        let state = isArmed
            ? NSLocalizedString("Active tool", comment: "Accessibility value for the armed Tool Library preset")
            : NSLocalizedString("Not active", comment: "Accessibility value for a Tool Library preset that is not armed")
        guard let slotNumber, let spoken = ToolSlotOrder.accessibilityDescription(slot: slotNumber) else {
            return state
        }
        return String(
            format: NSLocalizedString(
                "%1$@, %2$@",
                comment: "Accessibility value for a Tool Library preset: armed state, then its number-key shortcut"
            ),
            state,
            spoken
        )
    }
}
