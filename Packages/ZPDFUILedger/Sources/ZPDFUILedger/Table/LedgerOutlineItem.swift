import AppKit
import ZPDFUIPresentation

/// One node in the grouped outline, as `NSOutlineView` wants it: a reference type with
/// stable identity for as long as the view can see it.
///
/// Row items are created on demand and evicted when they leave the working set, so an
/// outline over a hundred thousand rows holds a few hundred objects, not a hundred
/// thousand. Identity is the *payload*, not the pointer, so an item recreated after an
/// eviction is still equal to the one the view remembers.
@MainActor
public final class LedgerOutlineItem: NSObject {

    /// What the item stands for.
    public enum Payload: Hashable, Sendable {
        /// A group heading.
        case group(path: String)
        /// A data row at a display position in ``LedgerGroupPlan/order``.
        case row(displayPosition: Int)
    }

    /// What the item stands for.
    public let payload: Payload
    /// The group slice, for a group item.
    public let slice: LedgerGroupSlice?

    /// Creates a group item.
    public init(slice: LedgerGroupSlice) {
        self.payload = .group(path: slice.path)
        self.slice = slice
        super.init()
    }

    /// Creates a row item.
    public init(displayPosition: Int) {
        self.payload = .row(displayPosition: displayPosition)
        self.slice = nil
        super.init()
    }

    /// Whether the item is a group heading.
    public var isGroup: Bool { slice != nil }

    /// The display position of a row item.
    public var displayPosition: Int? {
        if case let .row(position) = payload { return position }
        return nil
    }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? LedgerOutlineItem else { return false }
        return payload == other.payload
    }

    public override var hash: Int {
        payload.hashValue
    }
}

/// A bounded cache of outline items.
///
/// `NSOutlineView` asks for the item behind a row only when it needs to draw or query it,
/// so the cache stays roughly the size of the visible window plus the expanded group
/// headings. Group items are never evicted because there are few of them and they carry
/// the expansion state.
@MainActor
public final class LedgerOutlineItemCache {

    /// Maximum number of row items kept alive.
    public let rowLimit: Int

    private var groups: [String: LedgerOutlineItem] = [:]
    private var rows: [Int: LedgerOutlineItem] = [:]
    private var rowOrder: [Int] = []
    private var pinned: Set<Int> = []

    /// Creates a cache.
    public init(rowLimit: Int = 4096) {
        self.rowLimit = max(64, rowLimit)
    }

    /// Discards every cached item, for example after a regroup.
    public func removeAll() {
        groups.removeAll(keepingCapacity: true)
        rows.removeAll(keepingCapacity: true)
        rowOrder.removeAll(keepingCapacity: true)
        pinned.removeAll(keepingCapacity: true)
    }

    /// Keeps a set of display positions resident, which is how the selection survives eviction.
    public func pin(displayPositions: Set<Int>) {
        pinned = displayPositions
    }

    /// The item for a group slice.
    ///
    /// Identity is the path. The cache is emptied whenever the plan is rebuilt, so within
    /// one plan a path names exactly one slice; the lookup used to compare the cached slice
    /// with the asked-for one as well, and a slice's synthesized equality walks its whole
    /// subtree and both subtotal dictionaries — on every `child:ofItem:` call (IM-097).
    public func item(for slice: LedgerGroupSlice) -> LedgerOutlineItem {
        if let existing = groups[slice.path] { return existing }
        let item = LedgerOutlineItem(slice: slice)
        groups[slice.path] = item
        return item
    }

    /// The item for a row display position.
    public func item(displayPosition: Int) -> LedgerOutlineItem {
        if let existing = rows[displayPosition] { return existing }
        let item = LedgerOutlineItem(displayPosition: displayPosition)
        rows[displayPosition] = item
        rowOrder.append(displayPosition)
        evictIfNeeded()
        return item
    }

    /// Number of live row items, which the benchmark asserts stays bounded.
    public var residentRowCount: Int { rows.count }

    /// Evicts in batches: once over the limit, down to three quarters of it. Evicting to
    /// exactly the limit rebuilt the survivor list on every insert once the cache was full,
    /// an O(limit) loop per new row while flinging (IM-097).
    private func evictIfNeeded() {
        guard rowOrder.count > rowLimit else { return }
        var removed = 0
        let target = rowOrder.count - (rowLimit * 3) / 4
        var survivors: [Int] = []
        survivors.reserveCapacity(rowOrder.count)
        for position in rowOrder {
            if removed < target, !pinned.contains(position) {
                rows.removeValue(forKey: position)
                removed += 1
            } else {
                survivors.append(position)
            }
        }
        rowOrder = survivors
    }
}
