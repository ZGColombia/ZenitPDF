import Foundation
import ZPDFUILedger
import ZPDFUIPresentation

/// The docked Quantity Ledger's persisted view choices: what it groups by, and which
/// groups are collapsed — collapsed state persists.
///
/// Backed by `UserDefaults` so the choices are app-wide, like the toolbar arrangement and
/// the split positions. The suite is injectable so tests never touch the user's real
/// preferences.
///
/// "No grouping" is a real stored choice, distinct from "never chose": the default —
/// grouped by measurement type — applies only until the user picks anything, including
/// the flat list.
@MainActor
public final class LedgerPanePreferences {

    /// The stored grouping choice, as raw column identifiers.
    public static let groupingKey = "Zenit.QuantityLedger.Grouping"
    /// The stored collapsed group paths.
    public static let collapsedGroupsKey = "Zenit.QuantityLedger.CollapsedGroups"
    /// The stored named filters.
    public static let savedFiltersKey = "Zenit.QuantityLedger.SavedFilters"
    /// The stored named column layouts.
    public static let columnLayoutsKey = "Zenit.QuantityLedger.ColumnLayouts"
    /// Whether group heading rows show their subtotals.
    public static let showsSubtotalsKey = "Zenit.QuantityLedger.ShowsSubtotals"

    private let defaults: UserDefaults

    /// Creates a store over a defaults suite.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The grouping levels the pane opens with, outermost first.
    ///
    /// Unset means the default: grouped by measurement type. An explicitly
    /// stored empty array is the flat list and stays the flat list.
    public var groupingColumns: [LedgerColumnID] {
        get {
            guard let stored = defaults.array(forKey: Self.groupingKey) as? [String] else {
                return LedgerDefaultColumns.defaultGroupingColumns
            }
            return stored.map { LedgerColumnID(rawValue: $0) }
        }
        set {
            defaults.set(newValue.map(\.rawValue), forKey: Self.groupingKey)
        }
    }

    /// The user's named filters (`LedgerSavedFilterStore`, JSON).
    ///
    /// App-wide rather than per-project on purpose: "Unresolved on this sheet" and
    /// "Concrete only" are how a person works, not facts about one drawing, and a saved
    /// filter that vanished when the next drawing opened would not be worth naming.
    /// Undecodable data reads as an empty store rather than throwing — a corrupted
    /// preference must not stop the pane opening.
    public var savedFilters: LedgerSavedFilterStore {
        get {
            guard let data = defaults.data(forKey: Self.savedFiltersKey),
                  let store = try? LedgerSavedFilterStore.decoded(from: data)
            else { return LedgerSavedFilterStore() }
            return store
        }
        set {
            guard let data = try? newValue.encoded() else { return }
            defaults.set(data, forKey: Self.savedFiltersKey)
        }
    }

    /// The user's named column layouts — which columns are shown, in what order, at what
    /// width, pinned or not (`LedgerColumnLayoutStore`, JSON).
    ///
    /// "Save Layout…" in the ledger's header menu used to reach
    /// `LedgerTableHost.onSaveLayoutRequested` and stopped there, so the store the menu reads
    /// its "Apply Layout" list from was only ever empty and only ever in memory. Stored
    /// app-wide for the same reason the saved filters are: a column arrangement is how a
    /// person reads a takeoff, not a fact about one drawing.
    ///
    /// Undecodable data reads as an empty store rather than throwing — a corrupted
    /// preference must not stop the pane opening.
    public var columnLayouts: LedgerColumnLayoutStore {
        get {
            guard let data = defaults.data(forKey: Self.columnLayoutsKey),
                  let store = try? LedgerColumnLayoutStore.decoded(from: data)
            else { return LedgerColumnLayoutStore() }
            return store
        }
        set {
            guard let data = try? newValue.encoded() else { return }
            defaults.set(data, forKey: Self.columnLayoutsKey)
        }
    }

    /// Whether group heading rows print their subtotals. Unset means shown, the default.
    public var showsSubtotals: Bool {
        get { defaults.object(forKey: Self.showsSubtotalsKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.showsSubtotalsKey) }
    }

    /// Group paths the user collapsed. Paths for groups that are not currently in the
    /// plan are kept, so a group that reappears comes back collapsed.
    public var collapsedGroupPaths: Set<String> {
        get {
            Set(defaults.array(forKey: Self.collapsedGroupsKey) as? [String] ?? [])
        }
        set {
            defaults.set(newValue.sorted(), forKey: Self.collapsedGroupsKey)
        }
    }
}
