import Foundation
import ZPDFUIPresentation

/// A filter the user named and kept.
public struct LedgerSavedFilter: Codable, Hashable, Sendable, Identifiable {

    /// Stable identity.
    public let id: UUID
    /// User-visible name.
    public var name: String
    /// The stored rule tree.
    public var filter: LedgerFilterGroup
    /// When the filter was last written.
    public var modified: Date

    /// Creates a saved filter.
    public init(id: UUID, name: String, filter: LedgerFilterGroup, modified: Date = Date()) {
        self.id = id
        self.name = name
        self.filter = filter
        self.modified = modified
    }
}

/// A named collection of saved filters, persisted as JSON alongside the project.
public struct LedgerSavedFilterStore: Codable, Hashable, Sendable {

    /// Format version, so a future rename can migrate rather than discard.
    public private(set) var version: Int
    /// The saved filters, ordered by name.
    public private(set) var filters: [LedgerSavedFilter]

    /// Creates a store.
    public init(filters: [LedgerSavedFilter] = []) {
        self.version = 1
        self.filters = filters.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Saves a filter under a name, replacing any filter that already uses that name.
    public mutating func save(name: String, filter: LedgerFilterGroup, id: UUID = UUID(), now: Date = Date()) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // BH-714: an entry with the same id is replaced too, so the store can never hold two
        // filters sharing one identity (duplicate ForEach ids; one delete removing both).
        filters.removeAll {
            $0.id == id || $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
        }
        filters.append(LedgerSavedFilter(id: id, name: trimmed, filter: filter, modified: now))
        sort()
    }

    /// Removes a saved filter.
    public mutating func remove(id: UUID) {
        filters.removeAll { $0.id == id }
    }

    /// Looks a filter up by name.
    public func filter(named name: String) -> LedgerSavedFilter? {
        filters.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }

    private mutating func sort() {
        filters.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Encodes the store for on-disk storage.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// Restores a store written by ``encoded()``.
    public static func decoded(from data: Data) throws -> LedgerSavedFilterStore {
        try JSONDecoder().decode(LedgerSavedFilterStore.self, from: data)
    }
}

/// Pure edits on a filter tree.
///
/// The filter builder is a view over an immutable value: every gesture produces a new
/// tree, which is what makes undo, live match counts and saved filters trivial.
public enum LedgerFilterTreeEditor {

    /// Adds a rule to one group.
    public static func insertingRule(
        _ rule: LedgerFilterRule,
        intoGroup groupID: UUID,
        in tree: LedgerFilterGroup
    ) -> LedgerFilterGroup {
        transform(tree) { group in
            guard group.id == groupID else { return group }
            var updated = group
            updated.rules.append(rule)
            return updated
        }
    }

    /// Replaces a rule wherever it lives.
    public static func updating(
        _ rule: LedgerFilterRule,
        in tree: LedgerFilterGroup
    ) -> LedgerFilterGroup {
        transform(tree) { group in
            guard let index = group.rules.firstIndex(where: { $0.id == rule.id }) else { return group }
            var updated = group
            updated.rules[index] = rule
            return updated
        }
    }

    /// Removes a rule wherever it lives.
    public static func removingRule(
        id: UUID,
        in tree: LedgerFilterGroup
    ) -> LedgerFilterGroup {
        transform(tree) { group in
            var updated = group
            updated.rules.removeAll { $0.id == id }
            return updated
        }
    }

    /// Adds a nested group.
    public static func insertingGroup(
        _ child: LedgerFilterGroup,
        intoGroup groupID: UUID,
        in tree: LedgerFilterGroup
    ) -> LedgerFilterGroup {
        transform(tree) { group in
            guard group.id == groupID else { return group }
            var updated = group
            updated.groups.append(child)
            return updated
        }
    }

    /// Removes a nested group. The root group can never be removed.
    public static func removingGroup(
        id: UUID,
        in tree: LedgerFilterGroup
    ) -> LedgerFilterGroup {
        transform(tree) { group in
            var updated = group
            updated.groups.removeAll { $0.id == id }
            return updated
        }
    }

    /// Changes how one group combines its children.
    public static func setting(
        conjunction: LedgerFilterConjunction,
        forGroup groupID: UUID,
        in tree: LedgerFilterGroup
    ) -> LedgerFilterGroup {
        transform(tree) { group in
            guard group.id == groupID else { return group }
            var updated = group
            updated.conjunction = conjunction
            return updated
        }
    }

    /// Inverts one group.
    public static func setting(
        negated: Bool,
        forGroup groupID: UUID,
        in tree: LedgerFilterGroup
    ) -> LedgerFilterGroup {
        transform(tree) { group in
            guard group.id == groupID else { return group }
            var updated = group
            updated.isNegated = negated
            return updated
        }
    }

    /// Empties a tree, keeping the root identity so bindings stay attached.
    public static func cleared(_ tree: LedgerFilterGroup) -> LedgerFilterGroup {
        LedgerFilterGroup(id: tree.id, conjunction: tree.conjunction)
    }

    /// Applies a transform bottom-up to every group in the tree.
    private static func transform(
        _ group: LedgerFilterGroup,
        _ body: (LedgerFilterGroup) -> LedgerFilterGroup
    ) -> LedgerFilterGroup {
        var updated = group
        updated.groups = group.groups.map { transform($0, body) }
        return body(updated)
    }
}
