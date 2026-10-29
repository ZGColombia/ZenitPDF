import SwiftUI

/// The placeholder a panel shows when it has nothing to display.
///
/// An empty panel should say what it is for and offer the next step, not just sit blank.
public struct ZPDFEmptyState: View {
    private let glyph: ZPDFGlyph
    private let title: String
    private let message: String?
    private let actionTitle: String?
    private let action: (() -> Void)?

    @FocusState private var isFocused: Bool

    public init(
        glyph: ZPDFGlyph,
        title: String,
        message: String? = nil,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.glyph = glyph
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        VStack(spacing: ZPDFSpacing.m) {
            ZPDFGlyphView(glyph, size: 28)
                .foregroundStyle(ZPDFColor.textSecondary)
            Text(title)
                .zpdfText(.body.withWeight(.semibold), .textPrimary)
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .zpdfText(.caption, .textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .zpdfFont(.control)
                        .padding(.horizontal, ZPDFSpacing.l)
                        .frame(minHeight: ZPDFSpacing.Control.toolbarControl)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(ZPDFColor.accentBlue)
                .zpdfControlBackground(fill: .elevated)
                .focusable()
                .focused($isFocused)
                .zpdfFocusRing(isFocused)
                .accessibilityLabel(actionTitle)
            }
        }
        .padding(ZPDFSpacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

#if DEBUG
struct ZPDFEmptyState_Previews: PreviewProvider {
    private struct Demo: View {
        var body: some View {
            ZPDFPreviewPanel("Empty state") {
                ZPDFEmptyState(
                    glyph: .measurement(.count),
                    title: NSLocalizedString("No measurements yet", comment: "Preview label"),
                    message: NSLocalizedString("Pick a measurement tool and draw on the page. Results land in the Quantity Ledger.", comment: "Preview label"),
                    actionTitle: NSLocalizedString("Calibrate Scale", comment: "Preview label")
                ) {}
                .frame(height: 220)
                .zpdfControlBackground(fill: .surface, cornerRadius: ZPDFRadius.large)
            }
        }
    }

    static var previews: some View {
        ZPDFAppearancePair { Demo() }
            .previewDisplayName("ZPDFEmptyState - dark and light")
    }
}
#endif
