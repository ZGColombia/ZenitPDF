import SwiftUI
import ZPDFDesignSystem

/// The visible way out of a panel, in the panel's own header.
///
/// Every panel has a visible close control, and `Escape` always
/// backs out one level. This button is both — the close glyph the person can see and click, and
/// the cancel-action target `Escape` lands on. A panel that cannot take this button in its
/// header should not exist.
public struct WorkflowPanelCloseButton: View {

    /// The identifier of the ``ZPDFViewMarker`` behind every panel close button.
    ///
    /// It lets a test find the rendered button and click it where it is drawn (CR-202): the
    /// dismissibility test used to call its own close closure and assert that the closure ran,
    /// which would pass against a view that ignored `onClose`. The marker draws nothing and
    /// never takes a hit, exactly like the Inspector's swatch markers.
    public static let markerIdentifier = "zpdf.workflow.panel-close"

    private let panelName: String
    private let isEscapeRouted: Bool
    private let action: () -> Void

    @State private var isHovering = false

    /// - Parameters:
    ///   - panelName: the localized panel name, spoken as "Close <name>".
    ///   - isEscapeRouted: whether this button is the `Escape` target of its container. Pass
    ///     `false` only when another control in the same container already owns the cancel
    ///     action, so `Escape` never has two answers on one screen.
    ///   - action: closes the panel. Never destructive.
    public init(panelName: String, isEscapeRouted: Bool = true, action: @escaping () -> Void) {
        self.panelName = panelName
        self.isEscapeRouted = isEscapeRouted
        self.action = action
    }

    public var body: some View {
        if isEscapeRouted {
            button.keyboardShortcut(.cancelAction)
        } else {
            button
        }
    }

    private var button: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: ZPDFSpacing.Control.iconSmall * 0.82, weight: .semibold))
                .foregroundStyle(isHovering ? ZPDFColor.textPrimary : ZPDFColor.textSecondary)
                .frame(width: ZPDFSpacing.Control.icon, height: ZPDFSpacing.Control.icon)
                .background {
                    RoundedRectangle(cornerRadius: ZPDFRadius.small, style: .continuous)
                        .fill(isHovering ? ZPDFColor.elevated : Color.clear)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(helpText)
        .accessibilityLabel(Text(closeLabel))
        .zpdfMarker(Self.markerIdentifier)
    }

    private var closeLabel: String {
        String(
            format: NSLocalizedString("Close %@", comment: "Close a named panel"),
            panelName
        )
    }

    private var helpText: String {
        guard isEscapeRouted else { return closeLabel }
        return String(
            format: NSLocalizedString("%@ (Esc)", comment: "Help tag: action name plus its Escape shortcut"),
            closeLabel
        )
    }
}
