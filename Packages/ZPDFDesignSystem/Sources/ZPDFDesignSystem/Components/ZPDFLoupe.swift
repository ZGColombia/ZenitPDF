import SwiftUI

/// The chrome around the canvas magnifier.
///
/// This component owns the frame, the crosshair and the readout. It does not own the
/// magnification itself — the canvas hands in whatever it has rendered, which keeps the design
/// system free of any PDF or rendering dependency.
public struct ZPDFLoupe<Content: View>: View {

    /// The outline the magnified content is clipped to.
    public enum Chrome: Sendable, Hashable {
        /// A round loupe, for pointing at a vertex.
        case circle
        /// A rounded rectangle, better for reading text and dimension strings.
        case rectangle(width: CGFloat, height: CGFloat)
    }

    private let chrome: Chrome
    private let diameter: CGFloat
    private let showsCrosshair: Bool
    private let readout: String?
    private let magnification: Double?
    private let content: Content

    /// - Parameters:
    ///   - chrome: circle or rectangle.
    ///   - diameter: edge length for the circular chrome; ignored for a rectangle.
    ///   - showsCrosshair: draw the centre crosshair.
    ///   - readout: a coordinate or measurement string shown under the loupe.
    ///   - magnification: shown as a badge, e.g. 4.0 renders "4x".
    ///   - content: the magnified view.
    public init(
        chrome: Chrome = .circle,
        diameter: CGFloat = 132,
        showsCrosshair: Bool = true,
        readout: String? = nil,
        magnification: Double? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.chrome = chrome
        self.diameter = diameter
        self.showsCrosshair = showsCrosshair
        self.readout = readout
        self.magnification = magnification
        self.content = content()
    }

    public var body: some View {
        VStack(spacing: ZPDFSpacing.s) {
            lens
            if readout != nil || magnification != nil {
                caption
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(NSLocalizedString("Magnifier", comment: "Accessibility label for the canvas loupe")))
        .accessibilityValue(Text(spokenValue))
    }

    @ViewBuilder
    private var lens: some View {
        switch chrome {
        case .circle:
            lensBody(shape: Circle())
                .frame(width: diameter, height: diameter)
        case let .rectangle(width, height):
            lensBody(shape: RoundedRectangle(cornerRadius: ZPDFRadius.xLarge, style: .continuous))
                .frame(width: width, height: height)
        }
    }

    private func lensBody<S: InsettableShape>(shape: S) -> some View {
        content
            .background(ZPDFColor.canvasBackdrop)
            .clipShape(shape)
            .overlay {
                if showsCrosshair {
                    crosshair.clipShape(shape)
                }
            }
            .overlay {
                shape.strokeBorder(ZPDFColor.border, lineWidth: ZPDFStroke.regular)
            }
            .overlay {
                shape
                    .strokeBorder(ZPDFColor.elevated, lineWidth: ZPDFStroke.emphasis)
                    .padding(ZPDFStroke.regular)
            }
            .shadow(color: Color.black.opacity(0.35), radius: 10, x: 0, y: 4)
    }

    private var crosshair: some View {
        GeometryReader { proxy in
            let midX = proxy.size.width / 2
            let midY = proxy.size.height / 2
            let arm = min(proxy.size.width, proxy.size.height) * 0.18
            Path { path in
                path.move(to: CGPoint(x: midX - arm, y: midY))
                path.addLine(to: CGPoint(x: midX + arm, y: midY))
                path.move(to: CGPoint(x: midX, y: midY - arm))
                path.addLine(to: CGPoint(x: midX, y: midY + arm))
            }
            .stroke(ZPDFColor.measurementInk, style: StrokeStyle(lineWidth: ZPDFStroke.regular, lineCap: .round))
        }
        .allowsHitTesting(false)
    }

    private var caption: some View {
        HStack(spacing: ZPDFSpacing.s) {
            if let readout {
                Text(readout).zpdfText(.monoNumeric.withSize(11), .textPrimary)
            }
            if let magnification {
                Text(magnificationLabel(magnification))
                    .zpdfText(.caption, .textSecondary)
            }
        }
        .padding(.horizontal, ZPDFSpacing.m)
        .frame(minHeight: ZPDFSpacing.Control.statusPill)
        .background {
            Capsule(style: .continuous)
                .fill(ZPDFColor.elevated)
                .overlay { Capsule(style: .continuous).strokeBorder(ZPDFColor.border, lineWidth: ZPDFStroke.regular) }
        }
        .accessibilityHidden(true)
    }

    private func magnificationLabel(_ value: Double) -> String {
        LoupeMagnificationLabel.string(value)
    }

    private var spokenValue: String {
        var parts: [String] = []
        if let readout { parts.append(readout) }
        if let magnification { parts.append(magnificationLabel(magnification)) }
        return parts.joined(separator: ", ")
    }
}

/// The magnification normally stays at 4 while coordinates change at pointer frequency.
/// Cache the formatted label, including its locale and translation, rather than constructing
/// two NumberFormatters for every body evaluation (caption and accessibility value).
@MainActor
enum LoupeMagnificationLabel {
    private static var cached: (value: Double, locale: Locale, format: String, label: String)?

    static func string(_ value: Double, locale: Locale = .current) -> String {
        let format = NSLocalizedString("%@x", comment: "Loupe magnification badge, e.g. 4x")
        if let cached, cached.value == value, cached.locale == locale, cached.format == format {
            return cached.label
        }
        let label = String(format: format, ZPDFNumericField.format(value, fractionDigits: 1, locale: locale))
        cached = (value, locale, format, label)
        return label
    }
}

#if DEBUG
struct ZPDFLoupe_Previews: PreviewProvider {
    private struct FakeCanvas: View {
        var body: some View {
            ZStack {
                ZPDFColor.canvasBackdrop
                Path { path in
                    path.move(to: CGPoint(x: 10, y: 110))
                    path.addLine(to: CGPoint(x: 120, y: 40))
                    path.move(to: CGPoint(x: 66, y: 0))
                    path.addLine(to: CGPoint(x: 66, y: 132))
                }
                .stroke(ZPDFColor.textSecondary, lineWidth: 1)
            }
        }
    }

    private struct Demo: View {
        var body: some View {
            ZPDFPreviewPanel("Loupe", width: 300) {
                VStack(spacing: ZPDFSpacing.xl) {
                    ZPDFLoupe(readout: "1284.0, 903.5", magnification: 4) { FakeCanvas() }
                    ZPDFLoupe(
                        chrome: .rectangle(width: 180, height: 84),
                        showsCrosshair: false,
                        readout: "12 480 mm"
                    ) { FakeCanvas() }
                }
            }
        }
    }

    static var previews: some View {
        ZPDFAppearancePair { Demo() }
            .previewDisplayName("ZPDFLoupe - dark and light")
    }
}
#endif
