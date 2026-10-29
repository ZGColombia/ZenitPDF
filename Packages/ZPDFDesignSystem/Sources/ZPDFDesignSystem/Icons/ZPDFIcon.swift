import AppKit
import SwiftUI

/// Entry point for Zenit's own iconography.
public enum ZPDFIcon {

    /// The glyph's geometry, fitted into `rect`.
    public static func path(_ kind: ZPDFIconKind, in rect: CGRect) -> Path {
        ZPDFIconGeometry.path(for: kind, in: rect)
    }

    /// A rendered template image for AppKit surfaces: `NSToolbarItem`, `NSMenuItem`,
    /// `NSButton`, `NSTableCellView`.
    ///
    /// The image is a template, so AppKit tints it with the control's own colour and it follows
    /// selection, disabled and vibrancy states without any extra work. Its
    /// `accessibilityDescription` is set, which is what VoiceOver reads for an image-only button.
    @MainActor
    public static func image(_ kind: ZPDFIconKind, size: CGFloat = ZPDFSpacing.Control.icon) -> NSImage {
        let side = max(size, 4)
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
            let path = ZPDFIconGeometry.path(for: kind, in: rect)
            let bezier = NSBezierPath(cgPath: path.cgPath)
            bezier.lineWidth = ZPDFIconGeometry.strokeWidth(for: min(rect.width, rect.height))
            bezier.lineCapStyle = .round
            bezier.lineJoinStyle = .round
            NSColor.black.setStroke()
            bezier.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = kind.accessibilityLabel
        return image
    }
}

/// A Zenit measurement glyph rendered for SwiftUI, with the right stroke weight for its size.
public struct ZPDFIconView: View {
    private let kind: ZPDFIconKind
    private let size: CGFloat
    private let token: ZPDFColorToken?

    /// - Parameters:
    ///   - kind: which glyph to draw.
    ///   - size: the square edge length in points.
    ///   - token: an explicit tint, or `nil` to inherit the surrounding `foregroundStyle`.
    public init(_ kind: ZPDFIconKind, size: CGFloat = ZPDFSpacing.Control.icon, token: ZPDFColorToken? = nil) {
        self.kind = kind
        self.size = size
        self.token = token
    }

    public var body: some View {
        Group {
            if let token {
                stroked.foregroundStyle(ZPDFColor.color(token))
            } else {
                stroked
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// The glyph stroked at the weight its size calls for, before any tint is applied.
    private var stroked: some View {
        ZPDFIconShape(kind)
            .stroke(
                style: StrokeStyle(
                    lineWidth: ZPDFIconGeometry.strokeWidth(for: size),
                    lineCap: .round,
                    lineJoin: .round
                )
            )
    }
}

#if DEBUG
struct ZPDFIconView_Previews: PreviewProvider {
    private static var grid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(84), spacing: ZPDFSpacing.m), count: 5), spacing: ZPDFSpacing.l) {
            ForEach(ZPDFIconKind.allCases, id: \.self) { kind in
                VStack(spacing: ZPDFSpacing.xs) {
                    ZPDFIconView(kind, size: 24, token: .textPrimary)
                    Text(kind.rawValue)
                        .zpdfText(.caption, .textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        }
        .padding(ZPDFSpacing.xl)
        .background(ZPDFColor.surface)
    }

    static var previews: some View {
        Group {
            grid.preferredColorScheme(.dark).previewDisplayName("Measurement icons - Dark")
            grid.preferredColorScheme(.light).previewDisplayName("Measurement icons - Light")
        }
    }
}
#endif
