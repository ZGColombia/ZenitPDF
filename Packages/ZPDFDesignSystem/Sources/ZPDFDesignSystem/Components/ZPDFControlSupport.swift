import SwiftUI

/// Either an SF Symbol or one of Zenit's own measurement glyphs.
///
/// Components take a `ZPDFGlyph` rather than a raw name so a toolbar button, a status pill and
/// an empty state can all be driven from the same icon vocabulary.
public enum ZPDFGlyph: Sendable, Hashable {
    case symbol(ZPDFSymbol)
    case measurement(ZPDFIconKind)

    /// The description VoiceOver would use if the glyph stood on its own.
    public var accessibilityLabel: String {
        switch self {
        case let .symbol(symbol): return symbol.accessibilityLabel
        case let .measurement(kind): return kind.accessibilityLabel
        }
    }
}

/// Draws a `ZPDFGlyph` at a given size. Always decorative — the enclosing control owns the
/// accessibility label so VoiceOver never says the same word twice.
public struct ZPDFGlyphView: View {
    private let glyph: ZPDFGlyph
    private let size: CGFloat

    public init(_ glyph: ZPDFGlyph, size: CGFloat = ZPDFSpacing.Control.icon) {
        self.glyph = glyph
        self.size = size
    }

    public var body: some View {
        Group {
            switch glyph {
            case let .symbol(symbol):
                symbol.image
                    .font(.system(size: size * 0.82, weight: .regular))
                    .imageScale(.medium)
            case let .measurement(kind):
                ZPDFIconView(kind, size: size)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A visible keyboard focus ring.
///
/// Custom SwiftUI control styles lose AppKit's automatic focus ring, and a pro tool with no
/// visible focus is unusable from the keyboard. Every Zenit control draws this instead.
public struct ZPDFFocusRingModifier: ViewModifier {
    private let isFocused: Bool
    private let cornerRadius: CGFloat

    public init(isFocused: Bool, cornerRadius: CGFloat) {
        self.isFocused = isFocused
        self.cornerRadius = cornerRadius
    }

    public func body(content: Content) -> some View {
        content.overlay {
            RoundedRectangle(cornerRadius: cornerRadius + 1, style: .continuous)
                .strokeBorder(ZPDFColor.accentBlue, lineWidth: ZPDFStroke.focusRing)
                .padding(-1.5)
                .opacity(isFocused ? 1 : 0)
                .allowsHitTesting(false)
        }
    }
}

public extension View {
    /// Draws the Zenit keyboard focus ring around this view when `isFocused`.
    func zpdfFocusRing(_ isFocused: Bool, cornerRadius: CGFloat = ZPDFRadius.medium) -> some View {
        modifier(ZPDFFocusRingModifier(isFocused: isFocused, cornerRadius: cornerRadius))
    }

    /// A one-token background with a hairline border, the standard Zenit control ground.
    func zpdfControlBackground(
        fill: ZPDFColorToken = .elevated,
        stroke: ZPDFColorToken = .border,
        cornerRadius: CGFloat = ZPDFRadius.medium,
        lineWidth: CGFloat = ZPDFStroke.regular
    ) -> some View {
        background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(ZPDFColor.color(fill))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(ZPDFColor.color(stroke), lineWidth: lineWidth)
                }
        }
    }
}

/// Severity shared by status pills and inline warnings.
///
/// Each level carries its own glyph and its own spoken name, so severity is never communicated
/// by colour alone.
public enum ZPDFSeverity: String, CaseIterable, Sendable, Hashable {
    case neutral
    case info
    case success
    case warning
    case danger

    public var glyph: ZPDFGlyph {
        switch self {
        case .neutral: return .symbol(.info)
        case .info: return .symbol(.info)
        case .success: return .symbol(.success)
        case .warning: return .symbol(.warning)
        case .danger: return .symbol(.error)
        }
    }

    public var tint: ZPDFColorToken {
        switch self {
        case .neutral: return .textSecondary
        case .info: return .accentBlue
        case .success: return .success
        case .warning: return .warning
        case .danger: return .danger
        }
    }

    /// Spoken severity name, prefixed to the message for VoiceOver.
    public var spokenName: String {
        switch self {
        case .neutral: return NSLocalizedString("Status", comment: "Severity level: plain status")
        case .info: return NSLocalizedString("Information", comment: "Severity level: informational")
        case .success: return NSLocalizedString("Valid", comment: "Severity level: valid or confirmed")
        case .warning: return NSLocalizedString("Warning", comment: "Severity level: needs attention")
        case .danger: return NSLocalizedString("Error", comment: "Severity level: blocking problem")
        }
    }
}

#if DEBUG
/// Wraps preview content in a Zenit panel so previews look like the app, not like a blank canvas.
struct ZPDFPreviewPanel<Content: View>: View {
    private let title: String
    private let width: CGFloat
    private let content: Content

    init(_ title: String, width: CGFloat = 340, @ViewBuilder content: () -> Content) {
        self.title = title
        self.width = width
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.l) {
            Text(title).zpdfText(.sectionHeader, .textSecondary)
            content
        }
        .padding(ZPDFSpacing.xl)
        .frame(width: width, alignment: .leading)
        .background(ZPDFColor.surface)
    }
}

/// Renders one preview body in both appearances, which is the minimum bar for a design-system
/// component: a token that only works in dark mode is a bug.
struct ZPDFAppearancePair<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 0) {
            content.environment(\.colorScheme, .dark)
            content.environment(\.colorScheme, .light)
        }
    }
}
#endif
