import Foundation
import GRDB

// The v6 companion record. Same discipline as CoreRecords.swift: a faithful mirror of
// the row, no interpretation.

// MARK: - project_zone_extra

/// The per-zone facts spec 8.2's `project_zone` row cannot carry.
///
/// - `kind`: what the zone represents — room, apartment, floor, building section, trade
///   area, quantity group. Stored as the raw string so a foreign reader can read it
///   without a code table, and so an unknown value from a newer build degrades to "some
///   kind we do not know" rather than to a decode failure.
/// - `parentZoneId`: the nesting link. `ON DELETE SET NULL`, because deleting a parent
///   promotes its children rather than deleting them with it — losing a child zone's
///   markup grouping because its parent was tidied away is not a trade anyone would make.
/// - `spansPages`: `project_zone.page_id` is `NOT NULL`, but a zone with no drawn
///   boundary legitimately belongs to no page. Such a zone is written against the first
///   page with an empty polygon and this flag set; the flag is what stops a reopen from
///   claiming it lives on a page nobody put it on.
public struct ProjectZoneExtraRecord: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "project_zone_extra"

    public var zoneId: String
    public var kind: String
    public var parentZoneId: String?
    public var spansPages: Bool

    public enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
        case zoneId = "zone_id"
        case kind
        case parentZoneId = "parent_zone_id"
        case spansPages = "spans_pages"
    }

    public init(zoneId: String, kind: String, parentZoneId: String? = nil, spansPages: Bool = false) {
        self.zoneId = zoneId
        self.kind = kind
        self.parentZoneId = parentZoneId
        self.spansPages = spansPages
    }
}
