import SwiftUI
import ZPDFDesignSystem

/// The ears sitting on one edge of the project window.
///
/// One strip per edge, built from ``ZPDFClosableSurface/surfaces(on:)`` rather than from a
/// hand-written list, so a surface added to the enumeration gets its ear without anybody
/// remembering to add one. The strip draws nothing at all when no pane on its edge is closed —
/// its intrinsic size is then zero, which is what keeps it out of the way of the canvas rather
/// than sitting invisibly on top of it.
struct PaneEarStrip: View {

    /// Gap between two ears sharing an edge: enough that they read as two controls, small
    /// enough that they read as one group.
    static let spacing: CGFloat = 3

    let edge: ZPDFPaneEdge
    let environment: ProjectShellEnvironment
    let panelState: ShellPanelState
    let onActivate: @MainActor (ZPDFClosableSurface) -> Void

    @State private var isDropTargeted = false

    private var showing: [ZPDFClosableSurface] {
        ZPDFClosableSurface.surfaces(on: edge).filter { panelState.showsEar(for: $0) }
    }

    var body: some View {
        let surfaces = showing
        Group {
            if surfaces.isEmpty {
                // Zero intrinsic size: the strip is present in the view tree at all times so
                // its constraints never have to be rebuilt, and occupies nothing until a pane
                // is actually closed.
                Color.clear.frame(width: 0, height: 0)
            } else if edge.isHorizontalRun {
                HStack(spacing: Self.spacing) { ears(surfaces) }
            } else {
                VStack(spacing: Self.spacing) { ears(surfaces) }
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func ears(_ surfaces: [ZPDFClosableSurface]) -> some View {
        ForEach(surfaces) { surface in
            ear(surface, badge: Self.badge(for: surface, among: surfaces))
        }
    }

    /// The small glyph that tells two ears on one edge apart (IM-120).
    ///
    /// Closing the bottom pane raises the Quantity Ledger's ear *and* History's — deliberately,
    /// because an affordance present for one tab of a closed pane and absent for the other
    /// teaches a rule and then breaks it. But both were drawn as the same
    /// chevron, and only the tooltip told them apart. An ear alone on its edge needs no badge;
    /// ears that share one each carry their surface's glyph, so the two targets differ by
    /// shape, not by colour and not by hover text.
    static func badge(
        for surface: ZPDFClosableSurface,
        among showing: [ZPDFClosableSurface]
    ) -> ZPDFSymbol? {
        guard showing.count > 1 else { return nil }
        switch surface {
        case .quantityLedger: return .quantityLedger
        case .history: return .undo
        case .navigator: return .navigator
        case .inspector: return .inspector
        }
    }

    @ViewBuilder
    private func ear(_ surface: ZPDFClosableSurface, badge: ZPDFSymbol?) -> some View {
        let control = ZPDFPaneEar(
            edge: edge,
            paneName: surface.displayName,
            accessibilityTitle: surface.showTitle,
            keyboardHint: environment.commands.command(surface.command)?.binding?.displayString
        ) {
            onActivate(surface)
        }
        .overlay(alignment: edge.isHorizontalRun ? .leading : .top) {
            if let badge {
                // Decorative: the ear already speaks its surface's name.
                ZPDFGlyphView(.symbol(badge), size: 8)
                    .foregroundStyle(ZPDFColor.textSecondary)
                    .padding(edge.isHorizontalRun ? .leading : .top, 5)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        // The ear is a drop target for the same drags the pane accepts. The
        // Navigator is the one pane that accepts a drag — drawings dropped onto its page
        // column — so its ear takes the same drop and inserts at the top, and the other two
        // ears deliberately take none rather than pretending.
        if surface == .navigator {
            control.dropDestination(for: URL.self) { urls, _ in
                let accepted = NavigatorDropPolicy.acceptedURLs(urls)
                guard !accepted.isEmpty else { return false }
                onActivate(surface)
                return environment.onNavigatorDropFiles?(accepted, 0) ?? false
            } isTargeted: { targeted in
                isDropTargeted = targeted && environment.onNavigatorDropFiles != nil
            }
            .overlay {
                RoundedRectangle(cornerRadius: ZPDFRadius.small, style: .continuous)
                    .strokeBorder(ZPDFColor.accentBlue, lineWidth: ZPDFStroke.emphasis)
                    .opacity(isDropTargeted ? 1 : 0)
                    .allowsHitTesting(false)
            }
        } else {
            control
        }
    }
}
