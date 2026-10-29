import AppKit

/// Counts a window's left presses the way a person means them: a double-click is two presses at
/// the same place inside the double-click interval, not any two presses inside it (L-108).
///
/// The system counts every press inside `NSEvent.doubleClickInterval` of the last one, wherever
/// it lands. AppKit then acts on that count before any view sees the press:
/// `-[NSWindow _handleMouseDownEvent:isDelayedEvent:]` (read from AppKit's code, macOS 26) sends a
/// left press whose `clickCount` is 2 or more to the view that took the window's *previous* left
/// press, without hit-testing where the pointer is. So a click on the canvas followed within
/// half a second by a click on an Inspector tab, a Navigator tab or a toolbar chip sent the second
/// press to the canvas, outside its page, and the control under the pointer never heard of it
/// (live 2026-10-05: Comments stayed on Properties, Layers stayed on Pages, Length did not arm).
/// The same rule took a canvas click right after a toolbar chip away from the canvas.
///
/// Counted here, a press farther than ``slop`` from the previous one starts a new count at 1, so
/// AppKit hit-tests it like any first press. A press at the same place keeps counting, so a real
/// double-click — finishing a shape on the canvas, the top band's titlebar double-click, a ledger
/// row, a text box — still arrives as one, at the view that took its first press. A release
/// carries the count its press was given.
///
/// A value, so the rule is testable without a window; ``ZPDFProjectWindow`` runs every left press
/// and release through one before AppKit dispatches it.
public struct ZPDFClickCounter: Sendable, Equatable {

    /// How far apart, in window points, the presses of a double-click may land. The canvas's
    /// own double-click rule uses the same distance (L-36).
    public static let slop: CGFloat = 5

    /// A press as counted: when, where in the window, and the count it was given.
    public struct Press: Sendable, Equatable {
        public var timestamp: TimeInterval
        public var location: CGPoint
        public var count: Int
    }

    /// The last left press counted.
    public private(set) var lastPress: Press?
    /// The count the next release carries, when its press was re-counted.
    public private(set) var pendingReleaseCount: Int?

    public init() {}

    /// The count a left press is dispatched with.
    ///
    /// - Parameters:
    ///   - systemCount: the press's `clickCount` as the system counted it.
    ///   - timestamp: the press's `timestamp`.
    ///   - location: the press's location in the window.
    ///   - interval: the double-click interval (`NSEvent.doubleClickInterval`).
    public mutating func countForPress(
        systemCount: Int,
        timestamp: TimeInterval,
        location: CGPoint,
        interval: TimeInterval
    ) -> Int {
        let count: Int
        if systemCount <= 1 {
            count = systemCount
        } else if let last = lastPress, Self.continues(last, timestamp: timestamp, location: location, interval: interval) {
            // The system's count is the upper bound: its pair may have begun in another window.
            count = min(systemCount, last.count + 1)
        } else {
            count = 1
        }
        lastPress = Press(timestamp: timestamp, location: location, count: max(count, 1))
        pendingReleaseCount = count == systemCount ? nil : count
        return count
    }

    /// The count a left release is dispatched with: its press's count, when that was re-counted.
    public mutating func countForRelease(systemCount: Int) -> Int {
        defer { pendingReleaseCount = nil }
        return pendingReleaseCount ?? systemCount
    }

    /// Whether a press continues the count of `last`: inside the interval and within ``slop``.
    static func continues(_ last: Press, timestamp: TimeInterval, location: CGPoint, interval: TimeInterval) -> Bool {
        let elapsed = timestamp - last.timestamp
        guard elapsed >= 0, elapsed <= interval else { return false }
        return hypot(location.x - last.location.x, location.y - last.location.y) <= slop
    }
}
