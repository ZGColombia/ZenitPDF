import Foundation
import ZPDFUIPresentation

/// The per-column state a saved layout remembers.
public struct LedgerColumnState: Codable, Hashable, Sendable, Identifiable {

    /// The column this state belongs to.
    public let id: LedgerColumnID
    /// Rendered width in points.
    public var width: Double
    /// Whether the column is shown.
    public var visible: Bool
    /// Whether the column stays put while the table scrolls horizontally.
    public var pinned: Bool
    /// Cell alignment.
    public var alignment: LedgerColumnAlignment

    /// Creates a column state.
    public init(
        id: LedgerColumnID,
        width: Double,
        visible: Bool,
        pinned: Bool,
        alignment: LedgerColumnAlignment
    ) {
        self.id = id
        self.width = width
        self.visible = visible
        self.pinned = pinned
        self.alignment = alignment
    }

    /// Captures the state of a column.
    public init(capturing column: LedgerColumn) {
        self.init(
            id: column.id,
            width: column.width,
            visible: column.visible,
            pinned: column.pinned,
            alignment: column.alignment
        )
    }
}

/// A named arrangement of the ledger's columns.
///
/// A layout stores order, width, visibility, pinning and alignment. It never stores the
/// column's meaning, so applying an estimator's layout to another project keeps working
/// as long as the column identifiers still exist; unknown identifiers are ignored and
/// columns the layout does not mention keep their current state and move to the end.
public struct LedgerColumnLayout: Codable, Hashable, Sendable, Identifiable {

    /// Stable identity.
    public let id: UUID
    /// User-visible name.
    public var name: String
    /// Column states in display order.
    public var states: [LedgerColumnState]
    /// When the layout was last written.
    public var modified: Date

    /// Creates a layout.
    public init(id: UUID, name: String, states: [LedgerColumnState], modified: Date = Date()) {
        self.id = id
        self.name = name
        self.states = states
        self.modified = modified
    }

    /// Captures the current arrangement of a column set.
    public static func capturing(
        _ columns: [LedgerColumn],
        name: String,
        id: UUID = UUID(),
        now: Date = Date()
    ) -> LedgerColumnLayout {
        LedgerColumnLayout(
            id: id,
            name: name,
            states: columns.map(LedgerColumnState.init(capturing:)),
            modified: now
        )
    }

    /// Column identifiers in the layout's display order.
    public var orderedIDs: [LedgerColumnID] { states.map(\.id) }

    /// Applies the layout to a column set.
    ///
    /// Columns the layout does not know about keep their own state and are appended in
    /// their original relative order, so a project that gained a custom column since the
    /// layout was saved does not lose it.
    public func applied(to columns: [LedgerColumn]) -> [LedgerColumn] {
        var byID: [LedgerColumnID: LedgerColumn] = [:]
        for column in columns { byID[column.id] = column }

        var result: [LedgerColumn] = []
        result.reserveCapacity(columns.count)
        var consumed: Set<LedgerColumnID> = []

        for state in states {
            guard var column = byID[state.id] else { continue }
            column.width = state.width
            column.visible = state.visible
            column.pinned = state.pinned
            column.alignment = state.alignment
            result.append(column)
            consumed.insert(state.id)
        }
        for column in columns where !consumed.contains(column.id) {
            result.append(column)
        }
        return LedgerColumnLayout.pinnedFirst(result)
    }

    /// Reorders a column set so pinned columns lead, keeping relative order inside each band.
    ///
    /// Pinning is a layout rule, not a paint: the pinned columns physically lead the table
    /// so keyboard order, VoiceOver order and the horizontal scroll all agree.
    public static func pinnedFirst(_ columns: [LedgerColumn]) -> [LedgerColumn] {
        let pinned = columns.filter(\.pinned)
        let rest = columns.filter { !$0.pinned }
        return pinned + rest
    }

    /// Whether a column's cells should use monospaced, tabular digits.
    public static func usesMonospacedDigits(_ column: LedgerColumn) -> Bool {
        switch column.kind {
        case .number, .currency:
            return true
        case .formula:
            return column.dimension != nil
        case .text, .date, .checkbox, .choice:
            return false
        }
    }
}

/// The saved column layouts of one project.
public struct LedgerColumnLayoutStore: Codable, Hashable, Sendable {

    /// Format version.
    public private(set) var version: Int
    /// Saved layouts, ordered by name.
    public private(set) var layouts: [LedgerColumnLayout]
    /// The layout that was applied last, so the ledger can reopen in it.
    public var activeLayoutID: UUID?

    /// Creates a store.
    public init(layouts: [LedgerColumnLayout] = [], activeLayoutID: UUID? = nil) {
        self.version = 1
        self.layouts = layouts.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        self.activeLayoutID = activeLayoutID
    }

    /// Saves a layout under a name, replacing an existing layout with the same name.
    @discardableResult
    public mutating func save(
        _ columns: [LedgerColumn],
        name: String,
        id: UUID = UUID(),
        now: Date = Date()
    ) -> LedgerColumnLayout? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        layouts.removeAll { $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }
        let layout = LedgerColumnLayout.capturing(columns, name: trimmed, id: id, now: now)
        layouts.append(layout)
        layouts.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        activeLayoutID = layout.id
        return layout
    }

    /// Removes a layout.
    public mutating func remove(id: UUID) {
        layouts.removeAll { $0.id == id }
        if activeLayoutID == id { activeLayoutID = nil }
    }

    /// Looks a layout up by identity.
    public func layout(id: UUID) -> LedgerColumnLayout? {
        layouts.first { $0.id == id }
    }

    /// Looks a layout up by name.
    public func layout(named name: String) -> LedgerColumnLayout? {
        layouts.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }

    /// Encodes the store for on-disk storage.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// Restores a store written by ``encoded()``.
    public static func decoded(from data: Data) throws -> LedgerColumnLayoutStore {
        try JSONDecoder().decode(LedgerColumnLayoutStore.self, from: data)
    }
}
