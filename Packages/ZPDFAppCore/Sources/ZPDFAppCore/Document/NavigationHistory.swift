import Foundation

/// Where a person was looking: a sheet, and the page-space point at the top-left of the view
/// (NL-DOCS-09). `point` is `nil` when the view had not been laid out yet.
public struct NavigationPlace: Sendable, Hashable {
    public var pageID: UUID
    public var left: Double?
    public var top: Double?

    public init(pageID: UUID, left: Double? = nil, top: Double? = nil) {
        self.pageID = pageID
        self.left = left
        self.top = top
    }
}

/// Back and forward through the jumps a person made — following a link, a bookmark, a search
/// hit, the sheet index — not every page turn (NL-DOCS-09). ⌘[ goes back to the sheet *and*
/// viewport the jump left; ⌘] returns. A new jump clears what lay ahead, as a browser does.
public struct NavigationHistory: Sendable, Hashable {

    /// The most places kept behind; older ones fall off.
    public static let capacity = 100

    public private(set) var back: [NavigationPlace] = []
    public private(set) var forward: [NavigationPlace] = []

    public init() {}

    /// Records the place a jump is leaving. A jump from the place already on top is recorded once.
    public mutating func willJump(from place: NavigationPlace) {
        if back.last != place { back.append(place) }
        if back.count > Self.capacity { back.removeFirst(back.count - Self.capacity) }
        forward.removeAll()
    }

    /// The place to go back to, given where the person is now; `nil` when there is none.
    public mutating func goBack(from current: NavigationPlace) -> NavigationPlace? {
        guard let target = back.popLast() else { return nil }
        forward.append(current)
        return target
    }

    /// The place to go forward to, given where the person is now; `nil` when there is none.
    public mutating func goForward(from current: NavigationPlace) -> NavigationPlace? {
        guard let target = forward.popLast() else { return nil }
        back.append(current)
        return target
    }

    /// Drops places on sheets that are gone from the set.
    public mutating func keep(only pageIDs: Set<UUID>) {
        back.removeAll { !pageIDs.contains($0.pageID) }
        forward.removeAll { !pageIDs.contains($0.pageID) }
    }
}
