import SwiftUI

/// A small status chip for the status bar, the ledger and list rows.
///
/// Always icon plus text. Status is never carried by the tint alone, so it survives greyscale
/// printing, colour blindness and Increase Contrast.
public struct ZPDFStatusPill: View {
    private let severity: ZPDFSeverity
    private let title: String
    private let value: String?
    private let glyphOverride: ZPDFGlyph?
    private let usesMonospacedValue: Bool
    /// NL-PLAT-20: Reduce Transparency and Differentiate Without Color.
    @Environment(\.zpdfDisplayPreferences) private var displayOverride
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    /// - Parameters:
    ///   - severity: drives both the tint and the default glyph.
    ///   - title: the visible label.
    ///   - value: optional trailing value, e.g. a measurement or a count.
    ///   - glyph: overrides the severity's default glyph.
    ///   - usesMonospacedValue: draw the value with tabular figures, for live numeric readouts.
    public init(
        severity: ZPDFSeverity = .neutral,
        title: String,
        value: String? = nil,
        glyph: ZPDFGlyph? = nil,
        usesMonospacedValue: Bool = true
    ) {
        self.severity = severity
        self.title = title
        self.value = value
        self.glyphOverride = glyph
        self.usesMonospacedValue = usesMonospacedValue
    }

    public var body: some View {
        HStack(spacing: ZPDFSpacing.xs) {
            ZPDFGlyphView(glyphOverride ?? severity.glyph, size: ZPDFSpacing.Control.iconSmall)
                .foregroundStyle(ZPDFColor.color(severity.tint))
            Text(title)
                .zpdfText(.caption, .textPrimary)
                .lineLimit(1)
            if let value {
                Text(value)
                    .zpdfText(usesMonospacedValue ? .monoNumeric.withSize(11) : .caption, .textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, ZPDFSpacing.s)
        .frame(minHeight: ZPDFSpacing.Control.statusPill)
        .background {
            let paint = ZPDFStatusPillPaint.paint(
                severity: severity,
                preferences: displayOverride ?? ZPDFDisplayPreferences(
                    reduceTransparency: reduceTransparency, differentiateWithoutColor: differentiateWithoutColor))
            Capsule(style: .continuous)
                .fill(paint.solidSurface ? ZPDFColor.surface : ZPDFColor.color(severity.tint).opacity(paint.fillOpacity))
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(ZPDFColor.color(severity.tint).opacity(paint.strokeOpacity),
                                      style: StrokeStyle(lineWidth: paint.strokeWidth, dash: paint.dash))
                }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(Self.accessibilityLabel(severity: severity, title: title)))
        .accessibilityValue(value.map { Text($0) } ?? Text(verbatim: ""))
    }
}

extension ZPDFStatusPill {
    /// The pill's spoken label (IM-188): a localised "Warning: Scale inherited" for a pill
    /// whose severity means something, and the bare title for a neutral or informational one —
    /// a tool badge reading "Information: Length" is noise.
    static func accessibilityLabel(severity: ZPDFSeverity, title: String) -> String {
        switch severity {
        case .neutral, .info:
            return title
        default:
            return String(
                format: NSLocalizedString("%1$@: %2$@", comment: "Status pill spoken label: severity, then the pill's title"),
                severity.spokenName, title
            )
        }
    }
}

#if DEBUG
struct ZPDFStatusPill_Previews: PreviewProvider {
    private struct Demo: View {
        var body: some View {
            ZPDFPreviewPanel("Status pills") {
                VStack(alignment: .leading, spacing: ZPDFSpacing.m) {
                    ZPDFStatusPill(
                        severity: .success,
                        title: NSLocalizedString("Scale calibrated", comment: "Preview label"),
                        value: "1:50"
                    )
                    ZPDFStatusPill(
                        severity: .warning,
                        title: NSLocalizedString("Scale inherited", comment: "Preview label"),
                        value: NSLocalizedString("page 4", comment: "Preview label"),
                        usesMonospacedValue: false
                    )
                    ZPDFStatusPill(
                        severity: .danger,
                        title: NSLocalizedString("No scale set", comment: "Preview label")
                    )
                    ZPDFStatusPill(
                        severity: .neutral,
                        title: NSLocalizedString("Vector Snap", comment: "Preview label"),
                        glyph: .measurement(.vectorSnap),
                        usesMonospacedValue: false
                    )
                    ZPDFStatusPill(
                        severity: .info,
                        title: NSLocalizedString("Cursor", comment: "Preview label"),
                        value: "1284.0, 903.5"
                    )
                }
            }
        }
    }

    static var previews: some View {
        ZPDFAppearancePair { Demo() }
            .previewDisplayName("ZPDFStatusPill - dark and light")
    }
}
#endif
