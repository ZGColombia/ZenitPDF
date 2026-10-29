import AppKit
import Combine
import SwiftUI
import ZPDFDesignSystem

// The pieces of the top bar that are not tool chips: the brand block on the left, the
// separator inside the tool group, the rounded workspace group and the author badge on the
// right (2026-09-23 main-window mockup).

// MARK: - Brand

/// The brand block the 2026-09-23 mockup puts at the left of the top bar: a peak mark, the
/// wordmark `ZenitPDF` and the small letter-spaced tagline.
///
/// Identity, not a control: it takes no clicks and reads as one accessibility element.
struct ZenitToolbarBrand: View {

    /// The mark's height; its width follows ``ZenitPeakMark/aspectRatio``.
    static let markHeight: CGFloat = 22

    /// The tagline. A brand line, English in every locale and not in the catalogue; drawn
    /// uppercased.
    static let tagline = "Built for what's next"

    /// The whole block as VoiceOver reads it: the product name only — the tagline is
    /// decoration.
    static var accessibilityText: String {
        NSLocalizedString("Zenit PDF", comment: "Accessibility label for the top bar brand block")
    }

    var body: some View {
        HStack(alignment: .center, spacing: ZPDFSpacing.m) {
            ZenitPeakMark()
                .frame(width: Self.markHeight * ZenitPeakMark.aspectRatio, height: Self.markHeight)
            // "ZenitPDF" is the product's wordmark: one word, never translated.
            Text(verbatim: "ZenitPDF")
                .zpdfFont(ZPDFTypography.brandWordmark)
                .foregroundStyle(ZPDFColor.color(ZenitTopBarStyle.wordmark))
                .fixedSize()
            Text(verbatim: Self.tagline.uppercased())
                .zpdfFont(ZPDFTypography.brandTagline)
                .foregroundStyle(ZPDFColor.color(ZenitTopBarStyle.tagline))
                .lineLimit(1)
                .fixedSize()
                .padding(.leading, ZPDFSpacing.s)
        }
        .padding(.horizontal, ZPDFSpacing.xs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(Self.accessibilityText))
        .accessibilityAddTraits(.isImage)
    }
}

/// The peak mark: a summit with a ridge line cut down its right face and a valley notch at
/// its foot — the zenith the product is named after.
struct ZenitPeakMark: View {

    /// Width over height of the mark's 40 × 22 design grid.
    static let aspectRatio: CGFloat = 40.0 / 22.0

    /// The mark's outline at a given size, in the 40 × 22 grid scaled to fit.
    static func path(in rect: CGRect) -> Path {
        let sx = rect.width / 40
        let sy = rect.height / 22
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy)
        }
        var summit = Path()
        summit.move(to: p(0, 22))
        summit.addLine(to: p(27, 0))
        summit.addLine(to: p(40, 22))
        summit.closeSubpath()

        // The ridge: a band parallel to the right face, which leaves the apex whole and a
        // slim second ridge along the right edge.
        var ridge = Path()
        ridge.move(to: p(22, 0))
        ridge.addLine(to: p(25, 0))
        ridge.addLine(to: p(38, 22))
        ridge.addLine(to: p(35, 22))
        ridge.closeSubpath()

        // The valley at the foot.
        var valley = Path()
        valley.move(to: p(9, 22))
        valley.addLine(to: p(15.5, 15))
        valley.addLine(to: p(22, 22))
        valley.closeSubpath()

        return summit.subtracting(ridge).subtracting(valley)
    }

    var body: some View {
        GeometryReader { proxy in
            let accent = ZPDFColor.color(ZenitTopBarStyle.mark)
            Self.path(in: CGRect(origin: .zero, size: proxy.size))
                .fill(LinearGradient(
                    colors: [accent, accent.opacity(0.78)],
                    startPoint: .top,
                    endPoint: .bottom
                ))
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Separator

/// The hairline between the drawing tools and the markup tools (after Measure, before Text).
///
/// An AppKit view rather than a hosted SwiftUI one so it can be genuinely absent from the
/// accessibility tree — a hosting view reports itself as an element whatever its content
/// says. It draws one device pixel, centred, in the hairline token, resolved against the
/// view's own appearance at draw time.
final class ZenitToolSeparatorView: NSView {

    override var intrinsicContentSize: NSSize {
        NSSize(width: ZenitTopBarStyle.separatorWidth, height: ZenitTopBarStyle.chipHeight)
    }

    nonisolated override var isFlipped: Bool { true }

    override func isAccessibilityElement() -> Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let width = 1 / max(scale, 1)
        let height = min(ZenitTopBarStyle.separatorHeight, bounds.height)
        let x = ((bounds.midX * scale).rounded(.down) / scale)
        let rect = NSRect(x: x, y: (bounds.height - height) / 2, width: width, height: height)
        ZPDFColor.nsColor(ZenitTopBarStyle.hairline).setFill()
        rect.fill()
    }
}

// MARK: - Workspace group

/// The rounded group on the right of the top bar: Tool Library, Search, Compare, Export.
struct ZenitWorkspaceGroup: View {

    /// The chips, in mockup order.
    let chips: [ZenitToolChip]

    @Environment(\.displayScale) private var displayScale

    /// The group's name for VoiceOver.
    static var accessibilityText: String {
        NSLocalizedString("Workspace", comment: "Accessibility label for the top bar's Tool Library, Search, Compare and Export group")
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ZenitTopBarStyle.groupCornerRadius, style: .continuous)
        HStack(spacing: 2) {
            ForEach(chips.indices, id: \.self) { index in
                chips[index]
            }
        }
        .padding(ZenitTopBarStyle.groupInset)
        .background { shape.fill(ZPDFColor.color(ZenitTopBarStyle.groupFill)) }
        .overlay {
            shape.strokeBorder(
                ZPDFColor.color(ZenitTopBarStyle.hairline),
                lineWidth: 1 / max(displayScale, 1)
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(Self.accessibilityText))
    }
}

// MARK: - Author badge

/// The round badge at the far right of the top bar: the initials of the name new markups are
/// signed with.
///
/// The name is the real author identity (``ZenitToolbarModel/authorNameProvider``), re-read
/// whenever the user defaults change, so a rename in Settings shows at once. A click opens
/// Settings — the one place the name is changed — by running the
/// application menu's own Settings item, so it goes exactly where ⌘, goes.
struct ZenitAuthorBadge: View {

    let toolbar: ZenitToolbarModel

    @Environment(\.displayScale) private var displayScale
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    /// The badge's VoiceOver label.
    static func accessibilityText(name: String) -> String {
        String(
            format: NSLocalizedString(
                "Author: %@",
                comment: "Accessibility label for the top bar author badge; the argument is the author name"
            ),
            name
        )
    }

    /// The badge's VoiceOver hint.
    static var accessibilityHint: String {
        NSLocalizedString(
            "Opens Settings to change the author name",
            comment: "Accessibility hint for the top bar author badge"
        )
    }

    /// The badge's tooltip.
    static func helpText(name: String) -> String {
        String(
            format: NSLocalizedString(
                "Author: %@\nNew markups and measurements are signed with this name. Click to change it in Settings.",
                comment: "Tooltip for the top bar author badge; the argument is the author name"
            ),
            name
        )
    }

    var body: some View {
        let initials = toolbar.authorInitials
        Button {
            toolbar.openAuthorSettings()
        } label: {
            ZStack {
                Circle()
                    .fill(ZPDFColor.color(ZenitTopBarStyle.badgeFill))
                if isHovering {
                    Circle().fill(ZPDFColor.color(ZenitTopBarStyle.hoverFill))
                }
                Circle()
                    .strokeBorder(ZPDFColor.color(ZenitTopBarStyle.badgeRing), lineWidth: 1 / max(displayScale, 1))
                if initials.isEmpty {
                    Image(systemName: "person.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(ZPDFColor.color(ZenitTopBarStyle.badgeForeground))
                } else {
                    Text(verbatim: initials)
                        .zpdfFont(ZPDFTypography.avatarInitials)
                        .foregroundStyle(ZPDFColor.color(ZenitTopBarStyle.badgeForeground))
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                }
            }
            .frame(width: ZenitTopBarStyle.badgeDiameter, height: ZenitTopBarStyle.badgeDiameter)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($isFocused)
        .zpdfFocusRing(isFocused, cornerRadius: ZenitTopBarStyle.badgeDiameter / 2)
        .onHover { isHovering = $0 }
        .zpdfAnimation(.micro, value: isHovering)
        .padding(.horizontal, ZPDFSpacing.xs)
        .help(Self.helpText(name: toolbar.authorName))
        .accessibilityLabel(Text(Self.accessibilityText(name: toolbar.authorName)))
        .accessibilityHint(Text(Self.accessibilityHint))
        .onAppear { toolbar.refreshAuthorName() }
        .onReceive(
            NotificationCenter.default
                .publisher(for: UserDefaults.didChangeNotification)
                .receive(on: RunLoop.main)
        ) { _ in
            toolbar.refreshAuthorName()
        }
    }
}
