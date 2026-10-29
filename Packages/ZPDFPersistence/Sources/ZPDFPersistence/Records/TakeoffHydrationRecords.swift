import Foundation
import GRDB

// The v5 companion records (ADR-0009). Same discipline as CoreRecords.swift: a faithful
// mirror of the row, no interpretation.

// MARK: - takeoff_state

/// The per-document takeoff facts no spec 8.2 row carries.
///
/// One row per document that has had its takeoff saved by a v5+ build. Its *absence*
/// is meaningful: an older package, or a document whose takeoff was never saved.
public struct TakeoffStateRecord: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "takeoff_state"

    public var documentId: String
    /// The document default scale (`scale_definition.id`), or `nil` before calibration.
    public var defaultScaleId: String?
    public var savedAt: String

    public enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
        case documentId = "document_id"
        case defaultScaleId = "default_scale_id"
        case savedAt = "saved_at"
    }

    public init(documentId: String, defaultScaleId: String?, savedAt: String) {
        self.documentId = documentId
        self.defaultScaleId = defaultScaleId
        self.savedAt = savedAt
    }
}

// MARK: - markup_extra

/// The per-markup facts spec 8.2's `markup` row cannot carry (ADR-0009).
///
/// - `kind`: the markup kind behind the tool (`measurement`, `polygon`, …), so a cutout
///   hydrates as the kind it was committed as.
/// - `sortOrder`: the in-document draw order. `created_at` cannot serve — two markups
///   committed in the same millisecond would tie.
/// - `parentMarkupId`: the cutout link of spec 12.4. The parent's `geometry_blob`
///   already carries the holes; this is what keeps the *records* related.
/// - `parametersJson`: the `MeasurementParameters` the value was computed under, JSON,
///   written only when they differ from the defaults. NULL means "defaults".
/// - `geometryJson`: full-fidelity geometry for the shapes the ZPG1 blob cannot express
///   exactly (count points with identities, arcs, circles, multi-polygon compounds).
///   NULL for the common shapes, where the blob alone is exact. When present it is
///   written in the same transaction as the blob and is the hydration source of truth;
///   the blob stays the foreign-reader projection.
public struct MarkupExtraRecord: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "markup_extra"

    public var markupId: String
    public var kind: String
    public var sortOrder: Int
    public var parentMarkupId: String?
    public var countGroupId: String?
    public var caption: String?
    public var printable: Bool
    public var parametersJson: String?
    public var geometryJson: String?
    /// The markup's custom ledger cells (`{column-uuid: LedgerCellValue}` JSON), written
    /// only when non-empty. The spec's `custom_value` table needs `custom_column` rows
    /// the product cannot author yet; until it can, this keeps a takeoff whole.
    public var customValuesJson: String?
    /// ADR-0012: the row's quantity claim (`measured`/`derived`/`read`); NULL reads as
    /// `measured`, mirroring the JSON contract's absent-key rule.
    public var provenance: String?
    /// ADR-0012: the `QuantityDerivation` JSON for `derived` and `read` rows.
    public var derivationJson: String?
    /// ADR-0031 (v17): how the markup's geometry was captured — the `CaptureMethod` JSON — for a
    /// geometry a detector proposed; NULL reads as drawn by hand.
    public var captureJson: String?
    /// ADR-0032 (v18): the markup layer the markup belongs to; NULL is the project's default layer.
    public var layerId: String?

    public enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
        case markupId = "markup_id"
        case kind
        case sortOrder = "sort_order"
        case parentMarkupId = "parent_markup_id"
        case countGroupId = "count_group_id"
        case caption
        case printable
        case parametersJson = "parameters_json"
        case geometryJson = "geometry_json"
        case customValuesJson = "custom_values_json"
        case provenance
        case derivationJson = "derivation_json"
        case captureJson = "capture_json"
        case layerId = "layer_id"
    }

    public init(
        markupId: String, kind: String, sortOrder: Int,
        parentMarkupId: String? = nil, countGroupId: String? = nil,
        caption: String? = nil, printable: Bool = true,
        parametersJson: String? = nil, geometryJson: String? = nil,
        customValuesJson: String? = nil,
        provenance: String? = nil, derivationJson: String? = nil,
        captureJson: String? = nil,
        layerId: String? = nil
    ) {
        self.markupId = markupId
        self.kind = kind
        self.sortOrder = sortOrder
        self.parentMarkupId = parentMarkupId
        self.countGroupId = countGroupId
        self.caption = caption
        self.printable = printable
        self.parametersJson = parametersJson
        self.geometryJson = geometryJson
        self.customValuesJson = customValuesJson
        self.provenance = provenance
        self.derivationJson = derivationJson
        self.captureJson = captureJson
        self.layerId = layerId
    }
}

// MARK: - page_scale (v9)

/// Which scale is **the page's own** scale (schema v9).
///
/// The row behind the middle rung of the resolution order: a measurement resolves to the Scale
/// Region containing its geometry, else to this, else it is refused. One row per page at most,
/// enforced by the primary key — a page cannot have two page scales, which is the shape that
/// would let a measurement pick one silently.
///
/// `migrated` distinguishes a person's calibration from the v9 upgrade's reading of an older
/// file, where the document-wide default scale was interpreted as belonging to the page it was
/// recorded against and to no other. It is a fact about *where the assignment came from* and it
/// is kept so a disclosure can say so rather than presenting an inference as a measurement.
public struct PageScaleRecord: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "page_scale"

    public var pageId: String
    public var scaleId: String
    public var migrated: Bool

    public enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
        case pageId = "page_id"
        case scaleId = "scale_id"
        case migrated
    }

    public init(pageId: String, scaleId: String, migrated: Bool = false) {
        self.pageId = pageId
        self.scaleId = scaleId
        self.migrated = migrated
    }
}
