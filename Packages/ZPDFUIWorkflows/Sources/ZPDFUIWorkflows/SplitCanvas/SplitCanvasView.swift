import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

/// Lays out the Split Canvas panes and shows which one has the keyboard.
///
/// The view does not know how to draw a page. The host passes a builder for pane content, so the
/// canvas package stays independent of this one. What lives here is the arrangement, the focus
/// ring, the pane header, and the keyboard path between panes.
public struct SplitCanvasView<PaneContent: View>: View {

    private let controller: SplitCanvasController
    private let paneContent: (SplitCanvasPaneState) -> PaneContent

    /// - Parameters:
    ///   - controller: the layout and pane state.
    ///   - paneContent: draws one pane's canvas.
    public init(
        controller: SplitCanvasController,
        @ViewBuilder paneContent: @escaping (SplitCanvasPaneState) -> PaneContent
    ) {
        self.controller = controller
        self.paneContent = paneContent
    }

    public var body: some View {
        Grid(horizontalSpacing: 1, verticalSpacing: 1) {
            ForEach(rows, id: \.first?.id) { row in
                GridRow {
                    ForEach(row) { pane in
                        paneView(pane)
                    }
                }
            }
        }
        .background(ZPDFColor.border)
        .onKeyPress(keys: [.tab]) { press in
            guard press.modifiers.contains(.control) else { return .ignored }
            if press.modifiers.contains(.shift) {
                controller.focusPreviousPane()
            } else {
                controller.focusNextPane()
            }
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(NSLocalizedString("Split Canvas", comment: "Accessibility label for the Split Canvas area")))
        .accessibilityValue(Text(controller.layout.displayName))
    }

    private var rows: [[SplitCanvasPaneState]] {
        let visible = controller.visiblePanes
        let columns = controller.layout.columnCount
        guard columns > 0 else { return [visible] }
        return stride(from: 0, to: visible.count, by: columns).map {
            Array(visible[$0..<min($0 + columns, visible.count)])
        }
    }

    private func paneView(_ pane: SplitCanvasPaneState) -> some View {
        let isFocused = pane.id == controller.focusedPaneID
        return VStack(spacing: 0) {
            if controller.layout != .single {
                SplitCanvasPaneHeader(
                    pane: pane,
                    isFocused: isFocused,
                    onDetach: controller.onDetachPane.map { detach in { detach(pane.id) } }
                )
            }
            if controller.detachedPaneIDs.contains(pane.id) {
                // The pane is on its own window; closing that window brings it back here.
                Text(NSLocalizedString("Shown in its own window", comment: "Split Canvas pane moved to a separate window"))
                    .zpdfText(.body, .textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                paneContent(pane)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(ZPDFColor.canvasBackdrop)
        .overlay {
            // The focus ring is a real border, not a tint: it survives greyscale, Increase
            // Contrast, and a person who cannot pick the accent out of the backdrop.
            Rectangle()
                .strokeBorder(
                    isFocused ? ZPDFColor.accentCyan : Color.clear,
                    lineWidth: ZPDFStroke.focusRing
                )
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onTapGesture { controller.focusPane(pane.id) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(pane.accessibilityLabel))
        .accessibilityValue(Text(isFocused
            ? NSLocalizedString("Active pane", comment: "Accessibility value for the focused Split Canvas pane")
            : NSLocalizedString("Inactive pane", comment: "Accessibility value for an unfocused Split Canvas pane")))
        .accessibilityAddTraits(isFocused ? .isSelected : [])
    }
}

/// The strip above a pane: which document, which page, and whether it has the keyboard.
public struct SplitCanvasPaneHeader: View {

    private let pane: SplitCanvasPaneState
    private let isFocused: Bool
    private let onDetach: (() -> Void)?

    /// Creates a pane header. `onDetach` offers Move to Window (NL-DOCS-14).
    public init(pane: SplitCanvasPaneState, isFocused: Bool, onDetach: (() -> Void)? = nil) {
        self.pane = pane
        self.isFocused = isFocused
        self.onDetach = onDetach
    }

    public var body: some View {
        HStack(spacing: ZPDFSpacing.xs) {
            ZPDFGlyphView(.symbol(.splitCanvas), size: ZPDFSpacing.Control.iconSmall)
                .foregroundStyle(isFocused ? ZPDFColor.accentCyan : ZPDFColor.textSecondary)
                .accessibilityHidden(true)
            Text(pane.isEmpty
                ? NSLocalizedString("Empty", comment: "Split Canvas pane header for an empty pane")
                : pane.documentTitle)
                .zpdfText(.caption, .textPrimary)
                .lineLimit(1)
            Spacer(minLength: ZPDFSpacing.xs)
            if !pane.pageLabel.isEmpty {
                Text(pane.pageLabel).zpdfText(.monoNumeric, .textSecondary)
            }
            Text("\(Int((pane.zoom * 100).rounded()))%")
                .zpdfText(.monoNumeric, .textSecondary)
            if let onDetach, !pane.isEmpty {
                Button(action: onDetach) {
                    ZPDFGlyphView(.symbol(.detach), size: ZPDFSpacing.Control.iconSmall)
                }
                .buttonStyle(.borderless)
                .help(NSLocalizedString("Move to Window", comment: "Split Canvas pane header: show this pane in a window of its own"))
                .accessibilityLabel(Text(NSLocalizedString("Move to Window", comment: "Split Canvas pane header: show this pane in a window of its own")))
            }
        }
        .padding(.horizontal, ZPDFSpacing.s)
        .frame(height: ZPDFSpacing.Control.statusBar)
        .background(isFocused ? ZPDFColor.elevated : ZPDFColor.surface)
        .accessibilityElement(children: onDetach == nil ? .ignore : .contain)
        .accessibilityHidden(onDetach == nil)
    }
}

/// The layout switch, the three sync toggles, and the way out of Split Canvas.
public struct SplitCanvasControls: View {

    private let controller: SplitCanvasController
    private let onClose: () -> Void

    /// - Parameters:
    ///   - controller: the layout and pane state.
    ///   - onClose: leaves Split Canvas and returns the canvas to the previous view. Required —
    ///     the mode must never be on screen without a way out.
    ///     Stays enabled in every layout, including single.
    public init(controller: SplitCanvasController, onClose: @escaping () -> Void) {
        self.controller = controller
        self.onClose = onClose
    }

    public var body: some View {
        HStack(spacing: ZPDFSpacing.m) {
            // The layout switch is outside the disabled group. It sat inside it, so the one-pane
            // layout the host opens for a single one-page drawing could never gain a pane: the
            // picker was greyed out and only Close worked. Finding BH-312.
            ZPDFSegmentedControl(
                    selection: Binding(
                        get: { controller.layout },
                        set: { controller.setLayout($0) }
                    ),
                    segments: SplitCanvasLayout.allCases.map {
                        .init(
                            value: $0,
                            title: $0.displayName,
                            glyph: .symbol(.splitCanvas),
                            helpText: "\($0.displayName) · \($0.shapeDescription)"
                        )
                    },
                    accessibilityTitle: NSLocalizedString("Canvas layout", comment: "Accessibility title for the Split Canvas layout switch")
                )
                .fixedSize()

            Divider().frame(height: ZPDFSpacing.Control.toolbarControl)

            Group {

                syncToggle(
                    title: NSLocalizedString("Scroll", comment: "Split Canvas sync toggle"),
                    isOn: Binding(
                        get: { controller.syncOptions.syncsScroll },
                        set: { controller.syncOptions.syncsScroll = $0 }
                    )
                )
                syncToggle(
                    title: NSLocalizedString("Zoom", comment: "Split Canvas sync toggle"),
                    isOn: Binding(
                        get: { controller.syncOptions.syncsZoom },
                        set: { controller.syncOptions.syncsZoom = $0 }
                    )
                )
                syncToggle(
                    title: NSLocalizedString("Page", comment: "Split Canvas sync toggle"),
                    isOn: Binding(
                        get: { controller.syncOptions.syncsPage },
                        set: { controller.syncOptions.syncsPage = $0 }
                    )
                )
            }
            // Synchronising needs a second pane; the layout switch above is how to get one.
            .disabled(!controller.syncControlsAreEnabled)

            Spacer(minLength: 0)

            // The close control sits outside the disabled group on purpose: the way out of the
            // mode must work from every layout, single included.
            WorkflowPanelCloseButton(
                panelName: NSLocalizedString("Split Canvas", comment: "Panel name"),
                action: onClose
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(NSLocalizedString(
            "Split Canvas controls",
            comment: "Accessibility label for the Split Canvas control strip"
        )))
    }

    private func syncToggle(title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title).zpdfText(.caption, .textSecondary)
        }
        .toggleStyle(.checkbox)
        .accessibilityLabel(Text(String(
            format: NSLocalizedString("Synchronise %@", comment: "Accessibility label for a Split Canvas sync toggle"),
            title
        )))
    }
}
