import SwiftUI

/// Motion tokens.
///
/// Zenit animates to explain state, never to decorate. Every duration is short enough that a
/// user dragging a measurement never waits on the interface, and every token collapses to an
/// instant state change when Reduce Motion is on.
public enum ZPDFMotion {

    /// The easing shape a token uses.
    public enum Curve: Sendable, Hashable {
        case easeOut
        case easeInOut
    }

    /// A named duration + curve pair.
    public struct Token: Sendable, Hashable {
        public let duration: Double
        public let curve: Curve

        public init(duration: Double, curve: Curve) {
            self.duration = duration
            self.curve = curve
        }

        /// The SwiftUI animation for this token, ignoring accessibility settings.
        /// Prefer `ZPDFMotion.animation(_:reduceMotion:)` in view code.
        public var animation: Animation {
            switch curve {
            case .easeOut:
                return .easeOut(duration: duration)
            case .easeInOut:
                return .easeInOut(duration: duration)
            }
        }
    }

    public static let micro = Token.micro
    public static let quick = Token.quick
    public static let standard = Token.standard

    /// The animation for a token, or `nil` when Reduce Motion is on.
    ///
    /// A `nil` animation is not "no change" — the state still changes, it just changes
    /// instantly, which is exactly what Reduce Motion asks for.
    public static func animation(_ token: Token, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : token.animation
    }

    /// A transition that becomes a plain opacity swap, then nothing, as motion is reduced.
    public static func transition(_ base: AnyTransition, reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .identity : base
    }
}

public extension ZPDFMotion.Token {
    /// 0.09s - hover and press feedback. Below this the change reads as a glitch.
    static let micro = ZPDFMotion.Token(duration: 0.09, curve: .easeOut)
    /// 0.16s - selection, toggle, pill state.
    static let quick = ZPDFMotion.Token(duration: 0.16, curve: .easeOut)
    /// 0.24s - panel reveal, inspector section expand.
    static let standard = ZPDFMotion.Token(duration: 0.24, curve: .easeInOut)
}

/// Applies a Zenit motion token to a value change, honouring Reduce Motion automatically.
public struct ZPDFAnimationModifier<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let token: ZPDFMotion.Token
    private let value: Value

    public init(token: ZPDFMotion.Token, value: Value) {
        self.token = token
        self.value = value
    }

    public func body(content: Content) -> some View {
        content.animation(ZPDFMotion.animation(token, reduceMotion: reduceMotion), value: value)
    }
}

public extension View {
    /// Animates changes to `value` with a Zenit motion token; instant under Reduce Motion.
    func zpdfAnimation<Value: Equatable>(_ token: ZPDFMotion.Token, value: Value) -> some View {
        modifier(ZPDFAnimationModifier(token: token, value: value))
    }
}
