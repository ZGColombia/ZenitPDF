#if DEBUG
import SwiftUI

/// A debug-only gallery of the raw tokens: palette, type ramp, spacing and radii.
///
/// It exists so a designer can eyeball every token side by side in both appearances without
/// launching the app. Nothing here is public API and none of it ships in a release build.
struct ZPDFTokenGallery: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ZPDFSpacing.xl) {
                palette
                typeRamp
                metrics
            }
            .padding(ZPDFSpacing.xl)
        }
        .background(ZPDFColor.background)
    }

    private var palette: some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.m) {
            Text(verbatim: "Palette").zpdfText(.sectionHeader, .textSecondary)
            ForEach(ZPDFColorToken.allCases, id: \.self) { token in
                HStack(spacing: ZPDFSpacing.m) {
                    RoundedRectangle(cornerRadius: ZPDFRadius.small, style: .continuous)
                        .fill(ZPDFColor.color(token))
                        .frame(width: 40, height: 20)
                        .overlay {
                            RoundedRectangle(cornerRadius: ZPDFRadius.small, style: .continuous)
                                .strokeBorder(ZPDFColor.border, lineWidth: ZPDFStroke.regular)
                        }
                    Text(token.rawValue).zpdfText(.control, .textPrimary)
                    Spacer(minLength: ZPDFSpacing.m)
                    Text(ZPDFColor.rgba(token, .dark).hexString)
                        .zpdfText(.monoNumeric.withSize(11), .textSecondary)
                    Text(ZPDFColor.rgba(token, .light).hexString)
                        .zpdfText(.monoNumeric.withSize(11), .textSecondary)
                }
            }
        }
    }

    private var typeRamp: some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.m) {
            Text(verbatim: "Type ramp").zpdfText(.sectionHeader, .textSecondary)
            ForEach(ZPDFTypography.allStyles, id: \.name) { entry in
                HStack(alignment: .firstTextBaseline, spacing: ZPDFSpacing.m) {
                    Text(entry.name)
                        .zpdfText(.caption, .textSecondary)
                        .frame(width: 130, alignment: .leading)
                    Text(verbatim: "1 234.50 m² — Graphite Workshop")
                        .zpdfText(entry.style, .textPrimary)
                }
            }
        }
    }

    private var metrics: some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.m) {
            Text(verbatim: "Spacing and radius").zpdfText(.sectionHeader, .textSecondary)
            HStack(alignment: .bottom, spacing: ZPDFSpacing.m) {
                ForEach(Array(ZPDFSpacing.ramp.enumerated()), id: \.offset) { _, step in
                    VStack(spacing: ZPDFSpacing.xs) {
                        Rectangle()
                            .fill(ZPDFColor.accentCyan)
                            .frame(width: step, height: step)
                        Text(step.formatted()).zpdfText(.monoNumeric.withSize(10), .textSecondary)
                    }
                }
            }
            HStack(spacing: ZPDFSpacing.m) {
                ForEach([ZPDFRadius.hairline, ZPDFRadius.small, ZPDFRadius.medium, ZPDFRadius.large, ZPDFRadius.xLarge], id: \.self) { radius in
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(ZPDFColor.elevated)
                        .overlay {
                            RoundedRectangle(cornerRadius: radius, style: .continuous)
                                .strokeBorder(ZPDFColor.border, lineWidth: ZPDFStroke.regular)
                        }
                        .frame(width: 40, height: 28)
                        .overlay {
                            Text(radius.formatted()).zpdfText(.monoNumeric.withSize(10), .textSecondary)
                        }
                }
            }
        }
    }
}

struct ZPDFTokenGallery_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            ZPDFTokenGallery()
                .frame(width: 520, height: 760)
                .preferredColorScheme(.dark)
                .previewDisplayName("Tokens - Dark")
            ZPDFTokenGallery()
                .frame(width: 520, height: 760)
                .preferredColorScheme(.light)
                .previewDisplayName("Tokens - Light")
        }
    }
}
#endif
