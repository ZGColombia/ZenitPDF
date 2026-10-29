import Foundation
import GRDB

// One record per table in spec 8.2. Each is a faithful mirror of its row: same column
// names, same nullability, same order. Nothing here interprets the data.
//
// Binary columns are typed `Data`, not `GeometryBlob`. Decoding a blob is a step that
// can fail on hostile bytes, and a failure must arrive as a typed error at the moment
// the caller asks for geometry — not as a silently `nil` row in the middle of a fetch.
// `geometry`, `polygon` and `bounds` accessors do that decode explicitly.
//
// Decimal columns are typed `DecimalString`, so a `Double` cannot be written into one
// by accident. Colour columns are typed `PackedRGBA`.

// MARK: - project

public struct ProjectRecord: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "project"

    public var id: String
    public var name: String
    public var createdAt: String
    public var modifiedAt: String
    public var schemaVersion: Int

    public enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
        case id
        case name
        case createdAt = "created_at"
        case modifiedAt = "modified_at"
        case schemaVersion = "schema_version"
    }

    public init(id: String, name: String, createdAt: String, modifiedAt: String, schemaVersion: Int) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.schemaVersion = schemaVersion
    }
}

// MARK: - document

public struct DocumentRecord: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "document"

    public var id: String
    public var projectId: String
    public var displayName: String
    /// Always relative to the package root, always under `documents/`.
    public var relativePath: String
    /// Lowercase hex SHA-256 of the file at `relativePath`.
    public var sha256: String
    public var pageCount: Int
    public var activeRevisionId: String?
    public var createdAt: String
    public var modifiedAt: String

    public enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
        case id
        case projectId = "project_id"
        case displayName = "display_name"
        case relativePath = "relative_path"
        case sha256
        case pageCount = "page_count"
        case activeRevisionId = "active_revision_id"
        case createdAt = "created_at"
        case modifiedAt = "modified_at"
    }

    public init(
        id: String, projectId: String, displayName: String, relativePath: String,
        sha256: String, pageCount: Int, activeRevisionId: String? = nil,
        createdAt: String, modifiedAt: String
    ) {
        self.id = id
        self.projectId = projectId
        self.displayName = displayName
        self.relativePath = relativePath
        self.sha256 = sha256
        self.pageCount = pageCount
        self.activeRevisionId = activeRevisionId
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }
}

// MARK: - page

public struct PageRecord: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "page"

    public var id: String
    public var documentId: String
    public var pageIndex: Int
    public var pageLabel: String?
    public var mediaX: Double
    public var mediaY: Double
    public var mediaWidth: Double
    public var mediaHeight: Double
    public var cropX: Double
    public var cropY: Double
    public var cropWidth: Double
    public var cropHeight: Double
    /// 0, 90, 180 or 270. Validated at save.
    public var rotation: Int
    public var geometryHash: String?

    public enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
        case id
        case documentId = "document_id"
        case pageIndex = "page_index"
        case pageLabel = "page_label"
        case mediaX = "media_x"
        case mediaY = "media_y"
        case mediaWidth = "media_width"
        case mediaHeight = "media_height"
        case cropX = "crop_x"
        case cropY = "crop_y"
        case cropWidth = "crop_width"
        case cropHeight = "crop_height"
        case rotation
        case geometryHash = "geometry_hash"
    }

    public init(
        id: String, documentId: String, pageIndex: Int, pageLabel: String? = nil,
        mediaX: Double, mediaY: Double, mediaWidth: Double, mediaHeight: Double,
        cropX: Double, cropY: Double, cropWidth: Double, cropHeight: Double,
        rotation: Int, geometryHash: String? = nil
    ) {
        self.id = id
        self.documentId = documentId
        self.pageIndex = pageIndex
        self.pageLabel = pageLabel
        self.mediaX = mediaX
        self.mediaY = mediaY
        self.mediaWidth = mediaWidth
        self.mediaHeight = mediaHeight
        self.cropX = cropX
        self.cropY = cropY
        self.cropWidth = cropWidth
        self.cropHeight = cropHeight
        self.rotation = rotation
        self.geometryHash = geometryHash
    }
}

// MARK: - scale_definition

public struct ScaleDefinitionRecord: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "scale_definition"

    public var id: String
    public var pageId: String
    public var name: String
    /// The affine scale matrix, decimal strings so a 1:87.1 scale survives a round trip.
    public var matrixA: DecimalString
    public var matrixB: DecimalString
    public var matrixC: DecimalString
    public var matrixD: DecimalString
    public var translationX: DecimalString
    public var translationY: DecimalString
    public var baseLengthUnit: String
    public var sourceType: String
    public var calibrationJson: String?
    public var precisionMode: String
    public var version: Int
    public var locked: Bool
    public var createdAt: String
    public var modifiedAt: String

    public enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
        case id
        case pageId = "page_id"
        case name
        case matrixA = "matrix_a"
        case matrixB = "matrix_b"
        case matrixC = "matrix_c"
        case matrixD = "matrix_d"
        case translationX = "translation_x"
        case translationY = "translation_y"
        case baseLengthUnit = "base_length_unit"
        case sourceType = "source_type"
        case calibrationJson = "calibration_json"
        case precisionMode = "precision_mode"
        case version
        case locked
        case createdAt = "created_at"
        case modifiedAt = "modified_at"
    }

    public init(
        id: String, pageId: String, name: String,
        matrixA: DecimalString, matrixB: DecimalString,
        matrixC: DecimalString, matrixD: DecimalString,
        translationX: DecimalString, translationY: DecimalString,
        baseLengthUnit: String, sourceType: String, calibrationJson: String? = nil,
        precisionMode: String, version: Int, locked: Bool = false,
        createdAt: String, modifiedAt: String
    ) {
        self.id = id
        self.pageId = pageId
        self.name = name
        self.matrixA = matrixA
        self.matrixB = matrixB
        self.matrixC = matrixC
        self.matrixD = matrixD
        self.translationX = translationX
        self.translationY = translationY
        self.baseLengthUnit = baseLengthUnit
        self.sourceType = sourceType
        self.calibrationJson = calibrationJson
        self.precisionMode = precisionMode
        self.version = version
        self.locked = locked
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }
}

// MARK: - scale_region

public struct ScaleRegionRecord: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "scale_region"

    public var id: String
    public var pageId: String
    public var name: String
    public var polygonBlob: Data
    public var scaleId: String
    public var priority: Int
    public var colorRgba: PackedRGBA
    public var visible: Bool
    public var locked: Bool

    public enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
        case id
        case pageId = "page_id"
        case name
        case polygonBlob = "polygon_blob"
        case scaleId = "scale_id"
        case priority
        case colorRgba = "color_rgba"
        case visible
        case locked
    }

    public init(
        id: String, pageId: String, name: String, polygonBlob: Data, scaleId: String,
        priority: Int, colorRgba: PackedRGBA, visible: Bool = true, locked: Bool = false
    ) {
        self.id = id
        self.pageId = pageId
        self.name = name
        self.polygonBlob = polygonBlob
        self.scaleId = scaleId
        self.priority = priority
        self.colorRgba = colorRgba
        self.visible = visible
        self.locked = locked
    }

    /// Decodes `polygon_blob`, or reports why it could not be decoded.
    public func polygon() throws -> GeometryBlob {
        do {
            return try GeometryBlob.decode(polygonBlob)
        } catch {
            throw ZPDFPersistenceError.malformedGeometryBlob(error)
        }
    }
}

// MARK: - project_zone

public struct ProjectZoneRecord: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "project_zone"

    public var id: String
    public var pageId: String
    public var name: String
    public var polygonBlob: Data
    public var sortOrder: Int
    public var colorRgba: PackedRGBA
    public var visible: Bool
    public var locked: Bool

    public enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
        case id
        case pageId = "page_id"
        case name
        case polygonBlob = "polygon_blob"
        case sortOrder = "sort_order"
        case colorRgba = "color_rgba"
        case visible
        case locked
    }

    public init(
        id: String, pageId: String, name: String, polygonBlob: Data, sortOrder: Int,
        colorRgba: PackedRGBA, visible: Bool = true, locked: Bool = false
    ) {
        self.id = id
        self.pageId = pageId
        self.name = name
        self.polygonBlob = polygonBlob
        self.sortOrder = sortOrder
        self.colorRgba = colorRgba
        self.visible = visible
        self.locked = locked
    }

    public func polygon() throws -> GeometryBlob {
        do {
            return try GeometryBlob.decode(polygonBlob)
        } catch {
            throw ZPDFPersistenceError.malformedGeometryBlob(error)
        }
    }
}

// MARK: - markup

public struct MarkupRecord: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "markup"

    public var id: String
    public var documentId: String
    public var pageId: String
    public var type: String
    public var subject: String
    public var label: String?
    public var comment: String?
    public var geometryBlob: Data
    public var styleBlob: Data
    public var scaleId: String?
    /// The scale generation this markup was measured against. Present whenever
    /// `scaleId` is, so a scale edit can tell stale rows from fresh ones.
    public var scaleVersion: Int?
    public var scaleRegionId: String?
    public var zoneId: String?
    public var layerName: String?
    public var status: String?
    public var author: String?
    public var locked: Bool
    public var hidden: Bool
    public var createdAt: String
    public var modifiedAt: String
    public var revision: Int

    public enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
        case id
        case documentId = "document_id"
        case pageId = "page_id"
        case type
        case subject
        case label
        case comment
        case geometryBlob = "geometry_blob"
        case styleBlob = "style_blob"
        case scaleId = "scale_id"
        case scaleVersion = "scale_version"
        case scaleRegionId = "scale_region_id"
        case zoneId = "zone_id"
        case layerName = "layer_name"
        case status
        case author
        case locked
        case hidden
        case createdAt = "created_at"
        case modifiedAt = "modified_at"
        case revision
    }

    public init(
        id: String, documentId: String, pageId: String, type: String, subject: String,
        label: String? = nil, comment: String? = nil,
        geometryBlob: Data, styleBlob: Data,
        scaleId: String? = nil, scaleVersion: Int? = nil, scaleRegionId: String? = nil,
        zoneId: String? = nil, layerName: String? = nil, status: String? = nil,
        author: String? = nil, locked: Bool = false, hidden: Bool = false,
        createdAt: String, modifiedAt: String, revision: Int = 1
    ) {
        self.id = id
        self.documentId = documentId
        self.pageId = pageId
        self.type = type
        self.subject = subject
        self.label = label
        self.comment = comment
        self.geometryBlob = geometryBlob
        self.styleBlob = styleBlob
        self.scaleId = scaleId
        self.scaleVersion = scaleVersion
        self.scaleRegionId = scaleRegionId
        self.zoneId = zoneId
        self.layerName = layerName
        self.status = status
        self.author = author
        self.locked = locked
        self.hidden = hidden
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.revision = revision
    }

    public func geometry() throws -> GeometryBlob {
        do {
            return try GeometryBlob.decode(geometryBlob)
        } catch {
            throw ZPDFPersistenceError.malformedGeometryBlob(error)
        }
    }
}

// MARK: - measurement_value

public struct MeasurementValueRecord: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "measurement_value"

    public var markupId: String
    public var countValue: DecimalString?
    public var planLengthSi: DecimalString?
    public var trueLengthSi: DecimalString?
    public var perimeterSi: DecimalString?
    public var planAreaSi: DecimalString?
    public var trueAreaSi: DecimalString?
    public var wallAreaSi: DecimalString?
    public var volumeSi: DecimalString?
    public var riseSi: DecimalString?
    public var runSi: DecimalString?
    public var slopeRatio: DecimalString?
    public var slopePercent: DecimalString?
    public var slopeAngleRadians: DecimalString?
    public var depthSi: DecimalString?
    public var heightSi: DecimalString?
    public var radiusSi: DecimalString?
    public var diameterSi: DecimalString?
    public var formulaVersion: Int

    public enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
        case markupId = "markup_id"
        case countValue = "count_value"
        case planLengthSi = "plan_length_si"
        case trueLengthSi = "true_length_si"
        case perimeterSi = "perimeter_si"
        case planAreaSi = "plan_area_si"
        case trueAreaSi = "true_area_si"
        case wallAreaSi = "wall_area_si"
        case volumeSi = "volume_si"
        case riseSi = "rise_si"
        case runSi = "run_si"
        case slopeRatio = "slope_ratio"
        case slopePercent = "slope_percent"
        case slopeAngleRadians = "slope_angle_radians"
        case depthSi = "depth_si"
        case heightSi = "height_si"
        case radiusSi = "radius_si"
        case diameterSi = "diameter_si"
        case formulaVersion = "formula_version"
    }

    public init(
        markupId: String,
        countValue: DecimalString? = nil,
        planLengthSi: DecimalString? = nil,
        trueLengthSi: DecimalString? = nil,
        perimeterSi: DecimalString? = nil,
        planAreaSi: DecimalString? = nil,
        trueAreaSi: DecimalString? = nil,
        wallAreaSi: DecimalString? = nil,
        volumeSi: DecimalString? = nil,
        riseSi: DecimalString? = nil,
        runSi: DecimalString? = nil,
        slopeRatio: DecimalString? = nil,
        slopePercent: DecimalString? = nil,
        slopeAngleRadians: DecimalString? = nil,
        depthSi: DecimalString? = nil,
        heightSi: DecimalString? = nil,
        radiusSi: DecimalString? = nil,
        diameterSi: DecimalString? = nil,
        formulaVersion: Int
    ) {
        self.markupId = markupId
        self.countValue = countValue
        self.planLengthSi = planLengthSi
        self.trueLengthSi = trueLengthSi
        self.perimeterSi = perimeterSi
        self.planAreaSi = planAreaSi
        self.trueAreaSi = trueAreaSi
        self.wallAreaSi = wallAreaSi
        self.volumeSi = volumeSi
        self.riseSi = riseSi
        self.runSi = runSi
        self.slopeRatio = slopeRatio
        self.slopePercent = slopePercent
        self.slopeAngleRadians = slopeAngleRadians
        self.depthSi = depthSi
        self.heightSi = heightSi
        self.radiusSi = radiusSi
        self.diameterSi = diameterSi
        self.formulaVersion = formulaVersion
    }
}

// MARK: - custom_column

public struct CustomColumnRecord: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "custom_column"

    public var id: String
    public var projectId: String
    public var name: String
    public var type: String
    public var dimensionJson: String?
    public var currencyCode: String?
    public var formula: String?
    public var choiceValuesJson: String?
    public var defaultValue: String?
    public var sortOrder: Int
    public var visible: Bool
    /// The application's complete column definition — key, precision, display unit,
    /// editability — as JSON (schema v11, BH-075). `nil` on every row written before
    /// v11 and on a row whose writer had nothing beyond spec 8.2's columns to say.
    /// See ``CustomColumnStore`` for the typed read and write.
    public var definitionJson: String?

    public enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
        case id
        case projectId = "project_id"
        case name
        case type
        case dimensionJson = "dimension_json"
        case currencyCode = "currency_code"
        case formula
        case choiceValuesJson = "choice_values_json"
        case defaultValue = "default_value"
        case sortOrder = "sort_order"
        case visible
        case definitionJson = "definition_json"
    }

    public init(
        id: String, projectId: String, name: String, type: String,
        dimensionJson: String? = nil, currencyCode: String? = nil, formula: String? = nil,
        choiceValuesJson: String? = nil, defaultValue: String? = nil,
        sortOrder: Int, visible: Bool = true, definitionJson: String? = nil
    ) {
        self.id = id
        self.projectId = projectId
        self.name = name
        self.type = type
        self.dimensionJson = dimensionJson
        self.currencyCode = currencyCode
        self.formula = formula
        self.choiceValuesJson = choiceValuesJson
        self.defaultValue = defaultValue
        self.sortOrder = sortOrder
        self.visible = visible
        self.definitionJson = definitionJson
    }

    /// Decodes a row, reading `definition_json` only when the row carries the column — a
    /// database opened read-only before its v11 migration has run does not, and its rows
    /// must still read (as `nil`).
    public init(row: Row) throws {
        self.init(
            id: row[CodingKeys.id.stringValue],
            projectId: row[CodingKeys.projectId.stringValue],
            name: row[CodingKeys.name.stringValue],
            type: row[CodingKeys.type.stringValue],
            dimensionJson: row[CodingKeys.dimensionJson.stringValue],
            currencyCode: row[CodingKeys.currencyCode.stringValue],
            formula: row[CodingKeys.formula.stringValue],
            choiceValuesJson: row[CodingKeys.choiceValuesJson.stringValue],
            defaultValue: row[CodingKeys.defaultValue.stringValue],
            sortOrder: row[CodingKeys.sortOrder.stringValue],
            visible: row[CodingKeys.visible.stringValue],
            definitionJson: row.hasColumn(CodingKeys.definitionJson.stringValue)
                ? row[CodingKeys.definitionJson.stringValue]
                : nil
        )
    }
}

// MARK: - tool_preset

public struct ToolPresetRecord: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "tool_preset"

    public var id: String
    /// `nil` for a preset that belongs to the application rather than this project.
    public var projectId: String?
    public var name: String
    public var category: String
    public var markupType: String
    public var styleBlob: Data
    public var defaultsJson: String
    public var symbolData: Data?
    public var source: String
    public var sortOrder: Int

    public enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
        case id
        case projectId = "project_id"
        case name
        case category
        case markupType = "markup_type"
        case styleBlob = "style_blob"
        case defaultsJson = "defaults_json"
        case symbolData = "symbol_data"
        case source
        case sortOrder = "sort_order"
    }

    public init(
        id: String, projectId: String?, name: String, category: String, markupType: String,
        styleBlob: Data, defaultsJson: String, symbolData: Data? = nil,
        source: String, sortOrder: Int
    ) {
        self.id = id
        self.projectId = projectId
        self.name = name
        self.category = category
        self.markupType = markupType
        self.styleBlob = styleBlob
        self.defaultsJson = defaultsJson
        self.symbolData = symbolData
        self.source = source
        self.sortOrder = sortOrder
    }
}

// MARK: - ocr_token

public struct OCRTokenRecord: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "ocr_token"

    /// `INTEGER PRIMARY KEY`, so this is the rowid and SQLite assigns it on insert.
    public var id: Int64?
    public var pageId: String
    public var token: String
    /// Case-folded and diacritic-stripped, matching the FTS5 tokenizer's own rules.
    public var normalizedToken: String
    public var confidence: Double
    public var boundsBlob: Data
    public var lineIndex: Int
    public var tokenIndex: Int

    public enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
        case id
        case pageId = "page_id"
        case token
        case normalizedToken = "normalized_token"
        case confidence
        case boundsBlob = "bounds_blob"
        case lineIndex = "line_index"
        case tokenIndex = "token_index"
    }

    public init(
        id: Int64? = nil, pageId: String, token: String, normalizedToken: String,
        confidence: Double, boundsBlob: Data, lineIndex: Int, tokenIndex: Int
    ) {
        self.id = id
        self.pageId = pageId
        self.token = token
        self.normalizedToken = normalizedToken
        self.confidence = confidence
        self.boundsBlob = boundsBlob
        self.lineIndex = lineIndex
        self.tokenIndex = tokenIndex
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public func bounds() throws -> GeometryBlob {
        do {
            return try GeometryBlob.decode(boundsBlob)
        } catch {
            throw ZPDFPersistenceError.malformedGeometryBlob(error)
        }
    }
}

// MARK: - search_fts

/// A row of the FTS5 index.
///
/// The tokenizer is `unicode61 remove_diacritics 2`, so the index folds case and strips
/// diacritics across the full Unicode range — "Kök" and "kok" find each other, which is
/// the whole point on Swedish, Norwegian and German drawing sets. Version 2 of the
/// diacritic rule is the one that also handles characters outside Latin-1, unlike
/// version 1.
public struct SearchIndexRecord: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "search_fts"

    public var projectId: String
    public var documentId: String?
    public var pageId: String?
    /// `markup`, `ocr`, `zone`, `document` — whatever produced the text.
    public var sourceType: String
    /// The primary key of the row in that source table.
    public var sourceId: String
    public var content: String

    public enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
        case projectId = "project_id"
        case documentId = "document_id"
        case pageId = "page_id"
        case sourceType = "source_type"
        case sourceId = "source_id"
        case content
    }

    public init(
        projectId: String, documentId: String?, pageId: String?,
        sourceType: String, sourceId: String, content: String
    ) {
        self.projectId = projectId
        self.documentId = documentId
        self.pageId = pageId
        self.sourceType = sourceType
        self.sourceId = sourceId
        self.content = content
    }
}
