import Foundation
import ZPDFContracts

/// The modifier keys of `SNAP_CONTRACT` 13.8, as an option set.
///
/// `Backspace`, `Enter` and `Escape` from the same table are tool-level commands, not snap
/// modifiers: they remove a vertex, finish, and cancel. They belong to the markup tool's state
/// machine, not to this one, and are deliberately absent.
public struct SnapModifiers: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// Constrain angles.
    public static let shift = SnapModifiers(rawValue: 1 << 0)
    /// Toggle snap temporarily.
    public static let command = SnapModifiers(rawValue: 1 << 1)
    /// Bypass the snap for as long as it is held.
    public static let option = SnapModifiers(rawValue: 1 << 2)

    public static let none: SnapModifiers = []
}

/// Discrete inputs the modifier machine accepts, distinct from the held-key state.
public enum SnapModifierInput: Sendable, Hashable {
    /// The set of currently held keys changed.
    case keysChanged(SnapModifiers)
    /// `Tab`: advance to the next overlapping candidate.
    case cycleForward
    /// `Shift-Tab`: step back.
    case cycleBackward
    /// `Option` pressed and released without the cursor moving: `SNAP_CONTRACT` 13.8 gives Option
    /// both meanings ("bypass / current candidate cycle"); held is bypass, tapped is cycle.
    case optionTapped
    /// The gesture ended, or `Escape`: forget the cycle and the held candidate.
    case reset
}

/// What the engine should do this event, derived from the modifier state.
public struct SnapModifierEffect: Sendable, Hashable, Codable {
    /// Snapping is off for this event and the raw cursor point is used.
    public let bypassesSnap: Bool
    /// Angles are constrained to the configured increment about the in-progress point.
    public let constrainsAngle: Bool
    /// How many places to advance into the ranked candidate list.
    public let cycleAdvance: Int
    /// The cycle and the held candidate were cleared this event.
    public let didReset: Bool
}

/// The modifier semantics of `SNAP_CONTRACT` 13.8, as a state machine that knows nothing about
/// views, events loops or `NSEvent`.
///
/// Keeping it separate from the view layer is not tidiness. The stability and determinism
/// suites of `QUALITY_BAR` 3.3 and 3.4 replay modifier changes as data; a state machine that
/// lived in a view controller could only be tested through a view controller, and the 20-process
/// determinism run could not drive it at all.
public struct SnapModifierMachine: Sendable, Hashable, Codable {

    public private(set) var keys: SnapModifiers

    /// Net `Tab` presses since the last reset. Signed: `Shift-Tab` steps back.
    public private(set) var cycleAdvance: Int

    /// `true` while `Option` is held.
    public var isBypassing: Bool { keys.contains(.option) }

    /// `true` while `Shift` is held.
    public var constrainsAngle: Bool { keys.contains(.shift) }

    /// `true` while `Command` is held. `Command` *inverts* the configured enabled state, so it
    /// switches snapping on when the user has turned it off as well as off when it is on —
    /// "toggle snap temporarily" reads both ways and the symmetric reading is the useful one.
    public var togglesEnabledState: Bool { keys.contains(.command) }

    public init(keys: SnapModifiers = .none, cycleAdvance: Int = 0) {
        self.keys = keys
        self.cycleAdvance = cycleAdvance
    }

    @discardableResult
    public mutating func apply(_ input: SnapModifierInput) -> SnapModifierEffect {
        var didReset = false
        switch input {
        case .keysChanged(let newKeys):
            // Releasing Option ends a bypass but must not silently jump the user to a
            // different candidate, so the cycle position is preserved across key changes.
            keys = newKeys
        case .cycleForward:
            cycleAdvance &+= 1
        case .cycleBackward:
            cycleAdvance &-= 1
        case .optionTapped:
            cycleAdvance &+= 1
        case .reset:
            cycleAdvance = 0
            didReset = true
        }
        return effect(didReset: didReset)
    }

    public func effect(didReset: Bool = false) -> SnapModifierEffect {
        SnapModifierEffect(
            bypassesSnap: isBypassing,
            constrainsAngle: constrainsAngle,
            cycleAdvance: cycleAdvance,
            didReset: didReset
        )
    }

    /// Whether snapping is live, given the configured setting and `Command`.
    public func isSnapEnabled(configured: Bool) -> Bool {
        togglesEnabledState ? !configured : configured
    }
}
