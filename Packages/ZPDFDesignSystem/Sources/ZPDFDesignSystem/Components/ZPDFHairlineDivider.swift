import SwiftUI

/// A one-device-pixel rule.
///
/// Uses the real display scale rather than a hard-coded 0.5pt, so the line is exactly one
/// pixel on Retina and on an attached 1x display alike, and never blurs between them.
public struct ZPDFHairlineDivider: View {
    private let axis: Axis
    private let leadingInset: CGFloat
    private let trailingInset: CGFloat
    private let token: ZPDFColorToken

    @Environment(\.displayScale) private var displayScale

    public init(
        axis: Axis = .horizontal,
        leadingInset: CGFloat = 0,
        trailingInset: CGFloat = 0,
        token: ZPDFColorToken = .border
    ) {
        self.axis = axis
        self.leadingInset = leadingInset
        self.trailingInset = trailingInset
        self.token = token
    }

    public var body: some View {
        let thickness = ZPDFStroke.devicePixel(displayScale: displayScale)
        Rectangle()
            .fill(ZPDFColor.color(token))
            .frame(
                width: axis == .vertical ? thickness : nil,
                height: axis == .horizontal ? thickness : nil
            )
            .padding(axis == .horizontal ? .leading : .top, leadingInset)
            .padding(axis == .horizontal ? .trailing : .bottom, trailingInset)
            .accessibilityHidden(true)
    }
}

#if DEBUG
struct ZPDFHairlineDivider_Previews: PreviewProvider {
    private struct Demo: View {
        var body: some View {
            ZPDFPreviewPanel("Hairline divider") {
                VStack(alignment: .leading, spacing: ZPDFSpacing.m) {
                    Text(NSLocalizedString("Above", comment: "Preview label")).zpdfText(.body)
                    ZPDFHairlineDivider()
                    Text(NSLocalizedString("Below", comment: "Preview label")).zpdfText(.body)
                    ZPDFHairlineDivider(leadingInset: ZPDFSpacing.xl)
                    HStack(spacing: ZPDFSpacing.m) {
                        Text(NSLocalizedString("Left", comment: "Preview label")).zpdfText(.body)
                        ZPDFHairlineDivider(axis: .vertical).frame(height: 18)
                        Text(NSLocalizedString("Right", comment: "Preview label")).zpdfText(.body)
                    }
                }
            }
        }
    }

    static var previews: some View {
        ZPDFAppearancePair { Demo() }
            .previewDisplayName("ZPDFHairlineDivider - dark and light")
    }
}
#endif
