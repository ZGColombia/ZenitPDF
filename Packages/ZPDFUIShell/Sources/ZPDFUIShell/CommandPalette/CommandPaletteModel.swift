import Foundation
import Observation
import ZPDFUIPresentation

/// One row of the command palette: something the person can do, with the name they would
/// type, where it lives, and its shortcut (NL-UX-05).
///
/// Every row's action is a route the product already had — `environment.perform`, a Tool
/// Library arming, a page turn, a canvas selection or an application command the app hands
/// in — so the palette adds no second path to anything.
@MainActor
public struct CommandPaletteItem: Identifiable {

    /// What kind of thing a row is. Shown as the row's secondary text and used to break ties.
    public enum Category: Int, Sendable, CaseIterable {
        case command
        case tool
        case preset
        case page
        case selection

        /// The category's name as the row shows it.
        public var displayName: String {
            switch self {
            case .command: return NSLocalizedString("Command", comment: "Command palette row category")
            case .tool: return NSLocalizedString("Tool", comment: "Command palette row category")
            case .preset: return NSLocalizedString("Tool Library", comment: "Sheet title")
            case .page: return NSLocalizedString("Page", comment: "Command palette row category")
            case .selection: return NSLocalizedString("Select", comment: "Command palette row category: selection")
            }
        }
    }

    /// Stable identity, used for recent-use memory.
    public let id: String
    /// The name the person types and reads.
    public let title: String
    /// Where the command lives — "View", "Tool Library", "Page".
    public let detail: String
    public let category: Category
    /// The printed shortcut, or `nil`.
    public let shortcut: String?
    /// Other words that should find this row ("scale" finds Calibrate).
    public let keywords: [String]
    /// Whether the row can run now. A disabled row is listed, greyed, and does nothing.
    public let isEnabled: Bool
    public let perform: @MainActor () -> Void

    public init(
        id: String,
        title: String,
        detail: String,
        category: Category,
        shortcut: String? = nil,
        keywords: [String] = [],
        isEnabled: Bool = true,
        perform: @escaping @MainActor () -> Void
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.category = category
        self.shortcut = shortcut
        self.keywords = keywords
        self.isEnabled = isEnabled
        self.perform = perform
    }
}

/// Where the palette remembers what was used recently. Injectable so tests use a scratch
/// suite and never the user's real defaults.
@MainActor
public protocol CommandPaletteRecentsStore: AnyObject {
    var recentIDs: [String] { get set }
}

/// The recents in a `UserDefaults` suite.
@MainActor
public final class CommandPaletteDefaultsRecents: CommandPaletteRecentsStore {
    private let defaults: UserDefaults
    private static let key = "ZenitCommandPaletteRecents"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var recentIDs: [String] {
        get { defaults.stringArray(forKey: Self.key) ?? [] }
        set { defaults.set(Array(newValue.prefix(CommandPaletteModel.recentLimit)), forKey: Self.key) }
    }
}

/// Recents kept in memory, for previews and tests.
@MainActor
public final class CommandPaletteMemoryRecents: CommandPaletteRecentsStore {
    public var recentIDs: [String] = []
    public init() {}
}

/// The command palette's behaviour, apart from its view (NL-UX-05).
///
/// Type a few letters and the rows that match rank by how well they match: a title that starts
/// with the query first, then one whose word starts with it, then a subsequence ("clb" finds
/// Calibrate). Recently used rows get a boost. ↑/↓ move, Return runs, Escape dismisses.
@MainActor
@Observable
public final class CommandPaletteModel {

    /// How many recently used rows are remembered.
    public static let recentLimit = 12
    /// How many rows the list shows at most.
    public static let resultLimit = 50

    /// What the person typed.
    public var query: String = "" {
        didSet { if query != oldValue { recompute() } }
    }
    /// The rows matching ``query``, best first.
    public private(set) var results: [CommandPaletteItem] = []
    /// The highlighted row.
    public private(set) var selectedIndex: Int = 0

    /// Called after a row ran, or on Escape.
    @ObservationIgnored public var onDismiss: (@MainActor () -> Void)?

    @ObservationIgnored private let source: @MainActor () -> [CommandPaletteItem]
    @ObservationIgnored private var items: [CommandPaletteItem] = []
    @ObservationIgnored private let recents: any CommandPaletteRecentsStore

    public init(
        recents: any CommandPaletteRecentsStore,
        source: @escaping @MainActor () -> [CommandPaletteItem]
    ) {
        self.recents = recents
        self.source = source
        reload()
    }

    /// Re-reads the rows (the palette is rebuilt each time it opens, so presets, pages and
    /// enablement are current).
    public func reload() {
        items = source()
        recompute()
    }

    /// The highlighted row, if any.
    public var selectedItem: CommandPaletteItem? {
        results.indices.contains(selectedIndex) ? results[selectedIndex] : nil
    }

    /// Moves the highlight, clamped to the list.
    public func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), results.count - 1)
    }

    /// Highlights one row.
    public func select(index: Int) {
        guard results.indices.contains(index) else { return }
        selectedIndex = index
    }

    /// Runs the highlighted row. Returns whether anything ran.
    @discardableResult
    public func performSelected() -> Bool {
        guard let item = selectedItem else { return false }
        return perform(item)
    }

    /// Runs one row: dismisses first (so the action lands on the window, not the palette),
    /// remembers it, then performs it. A disabled row does nothing.
    @discardableResult
    public func perform(_ item: CommandPaletteItem) -> Bool {
        guard item.isEnabled else { return false }
        var ids = recents.recentIDs.filter { $0 != item.id }
        ids.insert(item.id, at: 0)
        recents.recentIDs = Array(ids.prefix(Self.recentLimit))
        onDismiss?()
        item.perform()
        return true
    }

    /// Escape.
    public func dismiss() {
        onDismiss?()
    }

    // MARK: - Ranking

    private func recompute() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let recentIDs = recents.recentIDs
        let scored: [(item: CommandPaletteItem, score: Int, order: Int)] = items.enumerated().compactMap { offset, item in
            guard let base = Self.score(query: trimmed, item: item) else { return nil }
            var score = base
            if let rank = recentIDs.firstIndex(of: item.id) {
                score += (Self.recentLimit - rank) * 4
            }
            if !item.isEnabled { score -= 50 }
            return (item, score, offset)
        }
        results = scored
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.item.category != rhs.item.category {
                    return lhs.item.category.rawValue < rhs.item.category.rawValue
                }
                return lhs.order < rhs.order
            }
            .prefix(Self.resultLimit)
            .map(\.item)
        selectedIndex = 0
    }

    /// How well an item matches, or `nil` when it does not. An empty query matches everything
    /// equally, so the list is recents first, then table order.
    static func score(query: String, item: CommandPaletteItem) -> Int? {
        guard !query.isEmpty else { return 0 }
        var best: Int?
        for (index, text) in ([item.title] + item.keywords).enumerated() {
            guard let value = score(query: query, text: text) else { continue }
            // A keyword hit counts a little less than a title hit.
            let adjusted = index == 0 ? value : value - 15
            best = max(best ?? adjusted, adjusted)
        }
        return best
    }

    /// The match score of `query` against one string, or `nil`.
    ///
    /// 100 + for a prefix of the whole title, 80 + for a prefix of any word, 60 + for a
    /// substring, 20 + for an in-order subsequence; shorter texts win ties, so "Area" outranks
    /// "Wall Area" for "are".
    static func score(query: String, text: String) -> Int? {
        let needle = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let haystack = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        guard !needle.isEmpty, !haystack.isEmpty else { return nil }
        let brevity = max(0, 20 - haystack.count / 2)
        if haystack.hasPrefix(needle) { return 100 + brevity }
        let words = haystack.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if words.contains(where: { $0.hasPrefix(needle) }) { return 80 + brevity }
        if haystack.contains(needle) { return 60 + brevity }
        var iterator = needle.makeIterator()
        var next = iterator.next()
        for character in haystack {
            if character == next { next = iterator.next() }
            if next == nil { return 20 + brevity }
        }
        return nil
    }
}
