import CoreGraphics
import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

/// Names every colour on the composited overlay.
///
/// This is part of the feature, not trim. A stack of tinted revisions is distinguished by
/// hue and by nothing else, and hue alone is exactly what the house rule *"no colour-only
/// status"* forbids as the sole carrier of meaning. Each entry therefore states the
/// revision's name, its sheet designation, the spoken name of its colour and the opacity
/// it is drawn at, so the picture can be read in greyscale, by someone who cannot separate
/// two of the hues, or out loud by VoiceOver.
struct RevisionOverlayLegend: View {

    let entries: [RevisionOverlayLegendEntry]

    var body: some View {
        Group {
            if entries.isEmpty {
                Text(NSLocalizedString(
                    "No revision is showing, so there is nothing on the sheet below.",
                    comment: "Revision Overlay legend when every layer is hidden"
                ))
                .zpdfText(.caption, .textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: ZPDFSpacing.m) {
                        ForEach(entries) { entry in
                            row(entry)
                        }
                    }
                }
                .scrollIndicators(.automatic)
            }
        }
        .padding(.horizontal, ZPDFSpacing.m)
        .padding(.vertical, ZPDFSpacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ZPDFColor.surface)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(NSLocalizedString(
            "Overlay legend", comment: "Accessibility label for the Revision Overlay legend"
        )))
    }

    private func row(_ entry: RevisionOverlayLegendEntry) -> some View {
        HStack(spacing: ZPDFSpacing.xs) {
            Text("\(entry.position)")
                .zpdfText(.monoNumeric, .textSecondary)
                .accessibilityHidden(true)
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(entry.colorRGBA.swiftUIColor)
                .frame(width: 12, height: 12)
                .overlay {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .strokeBorder(ZPDFColor.border, lineWidth: ZPDFStroke.regular)
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(entry.revisionName).zpdfText(.control, .textPrimary).lineLimit(1)
                Text(String(
                    format: NSLocalizedString(
                        "%1$@ · %2$@ · %3$d %%",
                        comment: "Legend subtitle: revision designation, colour name, opacity percent"
                    ),
                    entry.revisionLabel,
                    entry.colorName,
                    Int((entry.opacity * 100).rounded())
                ))
                .zpdfText(.caption, .textSecondary)
                .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(entry.accessibilityLabel))
    }
}

/// Where a click in the overlay pane lands on the composited picture.
///
/// Split out of the view because it is the one part of the marking gesture that can be
/// wrong in a way a person would only discover by getting an alignment two millimetres
/// off, and a pure function over two sizes is a thing a test can pin down. Screen control
/// is disabled on this machine, so this arithmetic is proved by assertion or not at all.
enum RevisionOverlayGeometry {

    /// - Parameters:
    ///   - location: the click, in the pane's own coordinates, `y` downwards.
    ///   - size: the pane.
    ///   - imagePixelWidth: the composite's width in pixels.
    ///   - imagePixelHeight: the composite's height in pixels.
    /// - Returns: `0…1` across and down the *picture*, or `nil` when the click was on the
    ///   backdrop beside it.
    static func unitPoint(
        forClickAt location: CGPoint,
        in size: CGSize,
        imagePixelWidth: Int,
        imagePixelHeight: Int
    ) -> CGPoint? {
        guard size.width > 0, size.height > 0, imagePixelWidth > 0, imagePixelHeight > 0 else {
            return nil
        }
        // `aspectRatio(contentMode: .fit)`: the picture is scaled by whichever axis binds
        // first and centred in the other.
        let imageAspect = Double(imagePixelWidth) / Double(imagePixelHeight)
        let paneAspect = Double(size.width) / Double(size.height)
        let drawnWidth: Double
        let drawnHeight: Double
        if imageAspect >= paneAspect {
            drawnWidth = Double(size.width)
            drawnHeight = drawnWidth / imageAspect
        } else {
            drawnHeight = Double(size.height)
            drawnWidth = drawnHeight * imageAspect
        }
        let originX = (Double(size.width) - drawnWidth) / 2
        let originY = (Double(size.height) - drawnHeight) / 2
        let x = (Double(location.x) - originX) / drawnWidth
        let y = (Double(location.y) - originY) / drawnHeight
        guard x >= 0, x <= 1, y >= 0, y <= 1 else { return nil }
        return CGPoint(x: x, y: y)
    }
}
