import SwiftUI

/// An inline banner: glyph, message, optional action.
///
/// The glyph and the spoken severity carry the meaning; the tint only reinforces it. A user in
/// greyscale, or with Increase Contrast on, reads exactly the same information.
public struct ZPDFInlineWarning: View {
    private let severity: ZPDFSeverity
    private let message: String
    private let actionTitle: String?
    private let action: (() -> Void)?
    private let onDismiss: (() -> Void)?

    @FocusState private var focusedControl: Control?

    private enum Control: Hashable {
        case action
        case dismiss
    }

    /// - Parameters:
    ///   - severity: `.info`, `.warning` or `.danger`; drives the glyph and the spoken prefix.
    ///   - message: what is wrong, in plain language.
    ///   - actionTitle: label for the corrective action, if there is one.
    ///   - action: the corrective action.
    ///   - onDismiss: pass a closure to show a dismiss control.
    public init(
        severity: ZPDFSeverity = .warning,
        message: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        self.severity = severity
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
        self.onDismiss = onDismiss
    }

    public var body: some View {
        HStack(alignment: .top, spacing: ZPDFSpacing.m) {
            ZPDFGlyphView(severity.glyph, size: ZPDFSpacing.Control.icon)
                .foregroundStyle(ZPDFColor.color(severity.tint))

            VStack(alignment: .leading, spacing: ZPDFSpacing.xs) {
                Text(message)
                    .zpdfText(.control, .textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                if let actionTitle, let action {
                    Button(action: action) {
                        Text(actionTitle)
                            .zpdfFont(.control.withWeight(.semibold))
                            .underline()
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(ZPDFColor.accentBlue)
                    .focusable()
                    .focused($focusedControl, equals: .action)
                    .zpdfFocusRing(focusedControl == .action, cornerRadius: ZPDFRadius.hairline)
                    .accessibilityLabel(actionTitle)
                }
            }

            Spacer(minLength: 0)

            if let onDismiss {
                Button(action: onDismiss) {
                    ZPDFGlyphView(.symbol(.remove), size: ZPDFSpacing.Control.iconSmall)
                        .frame(width: ZPDFSpacing.Control.minimumHitTarget, height: ZPDFSpacing.Control.minimumHitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(ZPDFColor.textSecondary)
                .focusable()
                .focused($focusedControl, equals: .dismiss)
                .zpdfFocusRing(focusedControl == .dismiss, cornerRadius: ZPDFRadius.small)
                .accessibilityLabel(NSLocalizedString("Dismiss", comment: "Action: hide an inline warning"))
            }
        }
        .padding(.horizontal, ZPDFSpacing.l)
        .padding(.vertical, ZPDFSpacing.m)
        .background {
            RoundedRectangle(cornerRadius: ZPDFRadius.medium, style: .continuous)
                .fill(ZPDFColor.color(severity.tint).opacity(0.12))
                .overlay {
                    RoundedRectangle(cornerRadius: ZPDFRadius.medium, style: .continuous)
                        .strokeBorder(ZPDFColor.color(severity.tint).opacity(0.5), lineWidth: ZPDFStroke.regular)
                }
        }
        .overlay(alignment: .leading) {
            // A shape cue as well as a tint: severity survives greyscale.
            Rectangle()
                .fill(ZPDFColor.color(severity.tint))
                .frame(width: ZPDFStroke.emphasis + 1)
                .clipShape(RoundedRectangle(cornerRadius: ZPDFRadius.hairline, style: .continuous))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("\(severity.spokenName): \(message)"))
    }
}

#if DEBUG
struct ZPDFInlineWarning_Previews: PreviewProvider {
    private struct Demo: View {
        var body: some View {
            ZPDFPreviewPanel("Inline warnings", width: 400) {
                VStack(alignment: .leading, spacing: ZPDFSpacing.m) {
                    ZPDFInlineWarning(
                        severity: .warning,
                        message: NSLocalizedString("This page has no scale. Measurements are shown in page units.", comment: "Preview label"),
                        actionTitle: NSLocalizedString("Calibrate Scale", comment: "Preview label"),
                        action: {}
                    )
                    ZPDFInlineWarning(
                        severity: .danger,
                        message: NSLocalizedString("The revision could not be compared: the page count differs.", comment: "Preview label"),
                        actionTitle: NSLocalizedString("Choose Pages", comment: "Preview label"),
                        action: {},
                        onDismiss: {}
                    )
                    ZPDFInlineWarning(
                        severity: .info,
                        message: NSLocalizedString("Vector Snap is building a geometry index for this page.", comment: "Preview label")
                    )
                }
            }
        }
    }

    static var previews: some View {
        ZPDFAppearancePair { Demo() }
            .previewDisplayName("ZPDFInlineWarning - dark and light")
    }
}
#endif
