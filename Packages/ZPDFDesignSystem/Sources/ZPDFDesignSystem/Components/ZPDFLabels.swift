import AppKit
import SwiftUI

// MARK: - Pill label

/// A filled measurement label pill ("Area: 620 SF", "24' - 0\"").
///
/// Drawn on the page, so the default fill is the on-paper `pillFill`. A markup whose colour
/// is the person's choice passes that colour instead — it is document data, not a palette
/// literal. The SwiftUI view and the AppKit `draw` share one geometry so a pill in a preview
/// and a pill on the canvas are the same shape.
public struct ZPDFPillLabel: View {
    private let text: String
    private let fill: Color
    private let foreground: Color

    /// A pill in a palette token (default: the on-paper label blue).
    public init(_ text: String, fill: ZPDFColorToken = .pillFill, foreground: ZPDFColorToken = .textOnAccent) {
        self.text = text
        self.fill = ZPDFColor.color(fill)
        self.foreground = ZPDFColor.color(foreground)
    }

    /// A pill in a markup's own colour.
    public init(_ text: String, markupColor: Color, foreground: ZPDFColorToken = .textOnAccent) {
        self.text = text
        self.fill = markupColor
        self.foreground = ZPDFColor.color(foreground)
    }

    public var body: some View {
        Text(text)
            .zpdfFont(.pillLabel)
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(foreground)
            .padding(.horizontal, ZPDFPillGeometry.horizontalPadding)
            .frame(height: ZPDFSpacing.Chrome.pillHeight)
            .background {
                RoundedRectangle(cornerRadius: ZPDFRadius.label, style: .continuous).fill(fill)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
    }
}

/// Geometry and AppKit drawing for measurement label pills on the canvas.
public enum ZPDFPillGeometry {
    /// Space between the text and the pill's left and right edges.
    public static let horizontalPadding: CGFloat = 8

    /// The attributes pill text is set in.
    @MainActor
    public static func textAttributes(foreground: NSColor = ZPDFColor.nsColor(.textOnAccent)) -> [NSAttributedString.Key: Any] {
        [
            .font: ZPDFTypography.nsFont(.pillLabel),
            .foregroundColor: foreground
        ]
    }

    /// The pill rectangle for `text`, centred on `center`, in the current coordinate space.
    /// `scale` lets a canvas keep pills a constant on-screen size at any zoom (pass 1 / zoom).
    @MainActor
    public static func rect(for text: String, centeredAt center: CGPoint, scale: CGFloat = 1) -> CGRect {
        let textSize = (text as NSString).size(withAttributes: textAttributes())
        let width = (ceil(textSize.width) + horizontalPadding * 2) * scale
        let height = ZPDFSpacing.Chrome.pillHeight * scale
        return CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
    }

    /// Draws a pill into the current `NSGraphicsContext` and returns the rectangle it used.
    ///
    /// - Parameters:
    ///   - text: the label, already formatted by the measurement presenter.
    ///   - center: the pill's centre.
    ///   - fill: the markup colour, or `ZPDFColor.nsColor(.pillFill)`.
    ///   - scale: points per on-screen point (1 / zoom keeps the pill a fixed screen size).
    @MainActor
    @discardableResult
    public static func draw(
        _ text: String,
        centeredAt center: CGPoint,
        fill: NSColor = ZPDFColor.nsColor(.pillFill),
        foreground: NSColor = ZPDFColor.nsColor(.textOnAccent),
        scale: CGFloat = 1
    ) -> CGRect {
        let frame = rect(for: text, centeredAt: center, scale: scale)
        let radius = ZPDFRadius.label * scale
        fill.setFill()
        NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius).fill()

        var attributes = textAttributes(foreground: foreground)
        if scale != 1, let font = attributes[.font] as? NSFont {
            attributes[.font] = NSFont(descriptor: font.fontDescriptor, size: font.pointSize * scale) ?? font
        }
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        string.draw(at: CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2))
        return frame
    }
}

// MARK: - Count badge

/// The small count box beside a summary chip's title ("Areas [2]").
public struct ZPDFCountBadge: View {
    private let text: String

    /// - Parameter text: the count, already formatted for the locale.
    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .zpdfFont(ZPDFTextStyle.chipTitle.withWeight(.medium))
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(ZPDFColor.textSecondary)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 16)
            .background {
                RoundedRectangle(cornerRadius: ZPDFRadius.label, style: .continuous)
                    .fill(ZPDFColor.color(.stateHover))
                    .overlay {
                        RoundedRectangle(cornerRadius: ZPDFRadius.label, style: .continuous)
                            .strokeBorder(ZPDFColor.border, lineWidth: ZPDFStroke.regular)
                    }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Summary chip

/// One quantity-kind chip in the ledger bar: kind icon in its ink, title, count and total
/// ("Areas · 2 · 2,480 SF"). Every string arrives formatted from the ledger presenter.
///
/// Pass an `action` only when the chip really does something (filter the ledger to its kind);
/// without one it is a plain read-out, never a button that does nothing.
public struct ZPDFSummaryChip: View {
    private let glyph: ZPDFGlyph
    private let tint: ZPDFColorToken
    private let title: String
    private let count: String?
    private let total: String?
    private let isSelected: Bool
    private let action: (() -> Void)?

    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    /// - Parameters:
    ///   - glyph: the quantity kind's icon.
    ///   - tint: the icon's colour token (the kind's markup ink).
    ///   - title: the kind ("Areas").
    ///   - count: the number of items, formatted.
    ///   - total: the kind's total with its unit, formatted; `nil` for kinds without one (Counts).
    ///   - isSelected: whether the ledger is currently filtered to this kind.
    ///   - action: what clicking the chip does, or `nil` for a read-out.
    public init(
        glyph: ZPDFGlyph,
        tint: ZPDFColorToken = .accentBlue,
        title: String,
        count: String?,
        total: String? = nil,
        isSelected: Bool = false,
        action: (() -> Void)? = nil
    ) {
        self.glyph = glyph
        self.tint = tint
        self.title = title
        self.count = count
        self.total = total
        self.isSelected = isSelected
        self.action = action
    }

    public var body: some View {
        Group {
            if let action {
                Button(action: action) { content }
                    .buttonStyle(.plain)
                    .focusable()
                    .focused($isFocused)
                    .zpdfFocusRing(isFocused, cornerRadius: ZPDFRadius.card)
                    .onHover { isHovering = $0 }
                    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            } else {
                content
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(title: title, count: count, total: total))
        .zpdfAnimation(.micro, value: isHovering)
    }

    private var content: some View {
        let paint = Self.paint(isSelected: isSelected, isHovering: isHovering, isInteractive: action != nil)
        return HStack(alignment: .center, spacing: ZPDFSpacing.m) {
            ZPDFGlyphView(glyph, size: ZPDFSpacing.Control.iconLarge)
                .foregroundStyle(ZPDFColor.color(tint))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: ZPDFSpacing.s) {
                    Text(title)
                        .zpdfText(.chipTitle, .textSecondary)
                        .lineLimit(1)
                    if let count {
                        ZPDFCountBadge(count)
                    }
                }
                if let total {
                    Text(total)
                        .zpdfText(.chipValue, paint.foreground)
                        .lineLimit(1)
                }
            }
            .fixedSize()
        }
        .padding(.horizontal, ZPDFSpacing.l)
        .frame(minHeight: ZPDFSpacing.Chrome.summaryChipHeight)
        .background { ZPDFPaintedBackground(paint, cornerRadius: ZPDFRadius.card) }
        .contentShape(RoundedRectangle(cornerRadius: ZPDFRadius.card, style: .continuous))
    }

    /// The chip's paint; the view uses exactly this.
    public static func paint(isSelected: Bool, isHovering: Bool, isInteractive: Bool) -> ZPDFControlPaint {
        ZPDFControlPaints.summaryChip(
            isSelected: isSelected,
            state: .resolve(isHovering: isHovering, isPressed: false),
            isInteractive: isInteractive
        )
    }

    /// What VoiceOver reads: "Areas, 2 items, total 2,480 SF".
    public static func accessibilityLabel(title: String, count: String?, total: String?) -> String {
        var parts = [title]
        if let count, !count.isEmpty {
            parts.append(String(
                format: NSLocalizedString("%@ items", comment: "Summary chip: the number of items of one kind, already formatted"),
                count
            ))
        }
        if let total, !total.isEmpty {
            parts.append(String(
                format: NSLocalizedString("total %@", comment: "Summary chip: the total of one kind with its unit, already formatted"),
                total
            ))
        }
        return parts.joined(separator: ", ")
    }
}

#if DEBUG
struct ZPDFLabels_Previews: PreviewProvider {
    static var previews: some View {
        ZPDFAppearancePair {
            ZPDFPreviewPanel("Pills and summary chips", width: 520) {
                HStack {
                    ZPDFPillLabel("Area: 620 SF")
                    ZPDFPillLabel("24' - 0\"")
                }
                HStack(spacing: 0) {
                    ZPDFSummaryChip(glyph: .measurement(.area), tint: .inkBlue, title: "Areas", count: "2", total: "2,480 SF") {}
                    ZPDFSummaryChip(glyph: .measurement(.length), tint: .inkBlue, title: "Lengths", count: "7", total: "312' - 6\"", isSelected: true) {}
                    ZPDFSummaryChip(glyph: .measurement(.count), tint: .success, title: "Counts", count: "12")
                }
            }
        }
        .previewDisplayName("ZPDFPillLabel / ZPDFSummaryChip - dark and light")
    }
}
#endif
