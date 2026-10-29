import Foundation
import UniformTypeIdentifiers
import ZPDFUIPresentation

/// The on-disk shape of a `.zpdftools` tool set.
///
/// A tool set is a plain, versioned JSON document. It holds descriptions of tools — a name, a
/// colour, a set of defaults, at most a small symbol image — and nothing that can run. Zenit
/// exports this shape and reads it back through ``ToolSetImportValidator``, which never trusts
/// what it reads.
public struct ToolSetDocument: Codable, Hashable, Sendable {

    /// The schema version Zenit writes today.
    public static let currentSchemaVersion = 1

    /// The file extension Zenit exports and imports.
    public static let fileExtension = "zpdftools"

    /// The type identifier the application bundle exports for `.zpdftools`.
    public static let typeIdentifier = "com.zenitgroup.zenitpdf.toolset"

    /// The content type for the open and save panels: the declared type when the bundle
    /// exports it (so the panels never run on a session-local `dyn.*` type, the LT-22 failure
    /// mode), then the extension, then plain JSON.
    public static var contentType: UTType {
        contentType(declared: UTType(typeIdentifier))
    }

    /// `contentType` with the declared-type lookup injected, for tests.
    static func contentType(declared: UTType?) -> UTType {
        if let declared, declared.isDeclared { return declared }
        return UTType(filenameExtension: fileExtension, conformingTo: .json) ?? .json
    }

    /// Which version of this schema the file was written against.
    public var schemaVersion: Int
    /// The name of the set, shown at the top of the import review.
    public var name: String
    /// Who exported it, as they typed it. Treated as untrusted text.
    public var author: String?
    /// When it was exported.
    public var exportedAt: Date?
    /// The tools in the set.
    public var presets: [ToolSetPresetRecord]

    /// Creates a tool set document.
    public init(
        schemaVersion: Int = ToolSetDocument.currentSchemaVersion,
        name: String,
        author: String? = nil,
        exportedAt: Date? = nil,
        presets: [ToolSetPresetRecord]
    ) {
        self.schemaVersion = schemaVersion
        self.name = name
        self.author = author
        self.exportedAt = exportedAt
        self.presets = presets
    }

    /// Creates a document from presets already in the Tool Library.
    public init(
        name: String,
        author: String? = nil,
        exportedAt: Date? = Date(),
        exporting summaries: [ToolPresetSummary],
        embeddingArtwork: ((StampArtworkDescriptor) -> ToolSetEmbeddedImageRecord?)? = nil
    ) {
        self.init(
            name: name,
            author: author,
            exportedAt: exportedAt,
            presets: summaries.map { summary in
                var record = ToolSetPresetRecord(summary: summary)
                if let artwork = summary.stamp?.artwork {
                    record.embeddedImage = embeddingArtwork?(artwork)
                }
                return record
            }
        )
    }

    /// The document as pretty-printed JSON with stable key order, so two exports of the same
    /// set produce byte-identical files and can be diffed in version control.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// The field names this schema version defines at the document level.
    public static let knownFieldNames: Set<String> = [
        "schemaVersion", "name", "author", "exportedAt", "presets"
    ]
}

/// One tool inside a `.zpdftools` file.
///
/// Every field is stored in a form that survives a schema change: enumerations as their raw
/// strings, colours as `#RRGGBB`, quantities as display strings. A reader that meets a value it
/// does not know reports it in the review rather than guessing.
public struct ToolSetPresetRecord: Codable, Hashable, Sendable, Identifiable {

    /// Identity as written by the exporter. Re-assigned on import if it collides.
    public var id: UUID
    /// The tool's name.
    public var name: String
    /// The category it groups under.
    public var category: String
    /// Raw value of the markup family, for example `"measurement"`.
    public var markupType: String
    /// Raw value of the measurement tool, for example `"area"`, or `nil`.
    public var measurementTool: String?
    /// Stroke colour as `#RRGGBB`.
    public var color: String
    /// Default takeoff subject.
    public var defaultSubject: String
    /// Raw value of the default display length unit, for example `"metre"`.
    public var displayLengthUnit: String
    /// Default values for custom Quantity Ledger columns.
    public var customDefaults: [String: String]
    /// SF Symbol name for a Count preset's symbol, or `nil`.
    public var countSymbolName: String?
    /// The ledger label a markup made with this tool starts with.
    public var labelPattern: String?
    /// Raw value of the review status a markup made with this tool starts in.
    public var defaultStatus: String?
    /// The measurement parameters — depth, wall height, slope and its azimuth, the two policies,
    /// the volume depth reference.
    ///
    /// Exported because a set that travels without them is a set of colours. A `.zpdftools` file
    /// holding `Slab 200 mm` and not the 200 mm is the file equivalent of the capture bug
    /// (styling kept, parameters dropped), and it would be invisible until somebody in another office
    /// measured a slab with no thickness.
    ///
    /// Optional so that a file written before this field existed still reads, and so that a file
    /// that omits it means "no parameters" rather than "parameters I could not write".
    public var measurementDefaults: ToolSetMeasurementRecord?
    /// A small bitmap symbol carried with the preset, or `nil`.
    public var embeddedImage: ToolSetEmbeddedImageRecord?
    /// The stamp template: its box and its dynamic fields. Its picture, when it travels at
    /// all, travels as ``embeddedImage``. Finding BH-319: the export used to drop the whole
    /// template, so a stamp arrived as a stamp that places nothing and the review said nothing.
    public var stamp: ToolSetStampRecord?
    /// The markup look beyond the colour — line width, dash, ends, fill, opacity, blend, text
    /// (V-060). Optional: a file written before it existed, or a tool that never had a round-2
    /// style, carries none, and an import that updates a matching tool then keeps that tool's
    /// own style rather than resetting it to colour-only.
    public var style: ToolSetStyleRecord?

    /// Creates a preset record.
    public init(
        id: UUID = UUID(),
        name: String,
        category: String,
        markupType: String,
        measurementTool: String? = nil,
        color: String,
        defaultSubject: String,
        displayLengthUnit: String,
        customDefaults: [String: String] = [:],
        countSymbolName: String? = nil,
        labelPattern: String? = nil,
        defaultStatus: String? = nil,
        measurementDefaults: ToolSetMeasurementRecord? = nil,
        embeddedImage: ToolSetEmbeddedImageRecord? = nil,
        stamp: ToolSetStampRecord? = nil,
        style: ToolSetStyleRecord? = nil
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.markupType = markupType
        self.measurementTool = measurementTool
        self.color = color
        self.defaultSubject = defaultSubject
        self.displayLengthUnit = displayLengthUnit
        self.customDefaults = customDefaults
        self.countSymbolName = countSymbolName
        self.labelPattern = labelPattern
        self.defaultStatus = defaultStatus
        self.measurementDefaults = measurementDefaults
        self.embeddedImage = embeddedImage
        self.stamp = stamp
        self.style = style
    }

    /// Creates a record from a Tool Library preset.
    public init(summary: ToolPresetSummary) {
        self.init(
            id: summary.id,
            name: summary.name,
            category: summary.category,
            markupType: summary.markupKind.rawValue,
            measurementTool: summary.measurementKind?.rawValue,
            color: summary.colorRGBA.hexString,
            defaultSubject: summary.defaultSubject,
            displayLengthUnit: summary.displayLengthUnit.rawValue,
            customDefaults: summary.customDefaults,
            countSymbolName: summary.countSymbolName,
            labelPattern: summary.labelPattern.isEmpty ? nil : summary.labelPattern,
            defaultStatus: summary.defaultStatus == .none ? nil : summary.defaultStatus.rawValue,
            measurementDefaults: ToolSetMeasurementRecord(defaults: summary.measurementDefaults),
            embeddedImage: nil,
            stamp: summary.stamp.map(ToolSetStampRecord.init(template:)),
            style: summary.style.map(ToolSetStyleRecord.init(style:))
        )
    }

    /// The field names this schema version defines for a preset.
    public static let knownFieldNames: Set<String> = [
        "id", "name", "category", "markupType", "measurementTool", "color",
        "defaultSubject", "displayLengthUnit", "customDefaults", "countSymbolName",
        "labelPattern", "defaultStatus", "measurementDefaults", "embeddedImage", "stamp", "style"
    ]
}

/// The markup look of one tool inside a `.zpdftools` file (V-060), as plain scalars the importer
/// bounds one field at a time, the way ``ToolSetMeasurementRecord`` does for measurement
/// parameters. The stroke is the preset's own ``ToolSetPresetRecord/color``, which is what a
/// preset's placement style takes its stroke from, so it is not written twice.
///
/// Colours are `#RRGGBB`; a fill's alpha travels as ``fillOpacity`` because a translucent fill
/// is common and the six-digit form cannot say it.
public struct ToolSetStyleRecord: Codable, Hashable, Sendable {

    /// Stroke width in PDF points.
    public var lineWidth: Double?
    /// Fill colour, or `nil` for no fill.
    public var fill: String?
    /// The fill colour's own alpha, 0…1, or `nil` for opaque.
    public var fillOpacity: Double?
    /// Raw ``MarkupLineStyle``, or `nil` for the kind's default.
    public var lineStyle: String?
    /// Whole-markup opacity, 0…1.
    public var opacity: Double?
    /// Raw ``MarkupLineCap`` of the start, or `nil` for the kind's default.
    public var startCap: String?
    /// Raw ``MarkupLineCap`` of the end, or `nil` for the kind's default.
    public var endCap: String?
    /// Raw ``MarkupTextAlignment``, or `nil` for leading.
    public var textAlignment: String?
    /// Whether the ink multiplies with the drawing (the highlighter).
    public var multiplyBlend: Bool?
    /// Scallop radius of a clouded outline in PDF points, or `nil` for automatic.
    public var cloudArcSize: Double?
    /// Font family for text-bearing markups.
    public var fontName: String?
    /// Font size in PDF points.
    public var fontSize: Double?
    /// Bold text.
    public var bold: Bool?
    /// Italic text.
    public var italic: Bool?
    /// Text colour, or `nil` for the stroke colour.
    public var textColor: String?
    /// Whether a Text box draws a border.
    public var boxBorder: Bool?

    /// Creates a record.
    public init(
        lineWidth: Double? = nil,
        fill: String? = nil,
        fillOpacity: Double? = nil,
        lineStyle: String? = nil,
        opacity: Double? = nil,
        startCap: String? = nil,
        endCap: String? = nil,
        textAlignment: String? = nil,
        multiplyBlend: Bool? = nil,
        cloudArcSize: Double? = nil,
        fontName: String? = nil,
        fontSize: Double? = nil,
        bold: Bool? = nil,
        italic: Bool? = nil,
        textColor: String? = nil,
        boxBorder: Bool? = nil
    ) {
        self.lineWidth = lineWidth
        self.fill = fill
        self.fillOpacity = fillOpacity
        self.lineStyle = lineStyle
        self.opacity = opacity
        self.startCap = startCap
        self.endCap = endCap
        self.textAlignment = textAlignment
        self.multiplyBlend = multiplyBlend
        self.cloudArcSize = cloudArcSize
        self.fontName = fontName
        self.fontSize = fontSize
        self.bold = bold
        self.italic = italic
        self.textColor = textColor
        self.boxBorder = boxBorder
    }

    /// The record for a preset's style. Flags are written only when set and optional fields
    /// only when present, as ``ToolStyleSelection`` encodes itself.
    public init(style: ToolStyleSelection) {
        self.init(
            lineWidth: style.lineWidth,
            fill: style.fill?.hexString,
            fillOpacity: style.fill.flatMap { $0.alpha < 1 ? $0.alpha : nil },
            lineStyle: style.lineStyle?.rawValue,
            opacity: style.opacity,
            startCap: style.startCap?.rawValue,
            endCap: style.endCap?.rawValue,
            textAlignment: style.textAlignment?.rawValue,
            multiplyBlend: style.multiplyBlend ? true : nil,
            cloudArcSize: style.cloudArcSize,
            fontName: style.fontName,
            fontSize: style.fontSize,
            bold: style.bold ? true : nil,
            italic: style.italic ? true : nil,
            textColor: style.textColor?.hexString,
            boxBorder: style.boxBorder ? true : nil
        )
    }

    /// The ranges an imported style's numbers must lie in: the Inspector's own steppers for
    /// width and size, the contract's for opacity and the cloud's scallop radius. A value
    /// outside is dropped and reported, never clamped.
    static let lineWidthRange: ClosedRange<Double> = 0.25...48
    static let fontSizeRange: ClosedRange<Double> = 4...288
    static let unitRange: ClosedRange<Double> = 0...1
    static let cloudArcSizeRange: ClosedRange<Double> = 2...72
    /// The longest font name an import keeps.
    static let maximumFontNameLength = 128

    /// The field names this schema version defines for a style block.
    public static let knownFieldNames: Set<String> = [
        "lineWidth", "fill", "fillOpacity", "lineStyle", "opacity", "startCap", "endCap",
        "textAlignment", "multiplyBlend", "cloudArcSize", "fontName", "fontSize", "bold",
        "italic", "textColor", "boxBorder"
    ]
}

/// A stamp template inside a `.zpdftools` file: its box, rotation and dynamic fields, as plain
/// scalars the importer bounds one at a time. The artwork is described, not carried — the
/// bytes live in the exporting project's store and travel only as an embedded image when the
/// host can supply one — so a recipient's review can say plainly that a picture stayed behind.
public struct ToolSetStampRecord: Codable, Hashable, Sendable {

    /// Box width in PDF points.
    public var widthPoints: Double
    /// Box height in PDF points.
    public var heightPoints: Double
    /// Rotation in degrees.
    public var rotationDegrees: Double
    /// What the exporter's artwork was (`vector`, `raster` or `none`).
    public var artworkKind: String
    /// The file the exporter's artwork came from, for the recipient's review.
    public var artworkSourceName: String?
    /// The dynamic fields.
    public var fields: [ToolSetStampFieldRecord]

    /// Creates a record.
    public init(
        widthPoints: Double,
        heightPoints: Double,
        rotationDegrees: Double = 0,
        artworkKind: String = StampArtworkKind.none.rawValue,
        artworkSourceName: String? = nil,
        fields: [ToolSetStampFieldRecord] = []
    ) {
        self.widthPoints = widthPoints
        self.heightPoints = heightPoints
        self.rotationDegrees = rotationDegrees
        self.artworkKind = artworkKind
        self.artworkSourceName = artworkSourceName
        self.fields = fields
    }

    /// The record for a preset's template.
    public init(template: StampTemplate) {
        self.init(
            widthPoints: template.widthPoints,
            heightPoints: template.heightPoints,
            rotationDegrees: template.rotationDegrees,
            artworkKind: template.artworkKind.rawValue,
            artworkSourceName: template.artwork.flatMap { $0.sourceName.isEmpty ? nil : $0.sourceName },
            fields: template.fields.map(ToolSetStampFieldRecord.init(field:))
        )
    }

    /// The field names this schema version defines for a stamp block.
    public static let knownFieldNames: Set<String> = [
        "widthPoints", "heightPoints", "rotationDegrees", "artworkKind", "artworkSourceName", "fields"
    ]
}

/// One dynamic field of a stamp inside a `.zpdftools` file, as bounded scalars.
public struct ToolSetStampFieldRecord: Codable, Hashable, Sendable {
    /// Raw ``StampFieldKind``.
    public var kind: String
    /// Slot among fields of the same kind.
    public var slot: Int
    /// Placement prompt of a free-text field.
    public var prompt: String
    /// Date format of a date field.
    public var dateFormat: String
    /// Text written before the value.
    public var textPrefix: String
    /// Frame inside the stamp box, as fractions of the box.
    public var frameX: Double
    public var frameY: Double
    public var frameWidth: Double
    public var frameHeight: Double
    /// Font name.
    public var fontName: String
    /// Font size as a fraction of the box height.
    public var fontSizeFraction: Double
    /// Raw ``StampFieldAlignment``.
    public var alignment: String
    /// Text colour as six-digit hex.
    public var color: String

    /// The record for one field definition.
    public init(field: StampFieldDefinition) {
        kind = field.kind.rawValue
        slot = field.slot
        prompt = field.prompt
        dateFormat = field.dateFormat
        textPrefix = field.textPrefix
        frameX = field.normalizedFrame.origin.x
        frameY = field.normalizedFrame.origin.y
        frameWidth = field.normalizedFrame.size.width
        frameHeight = field.normalizedFrame.size.height
        fontName = field.fontName
        fontSizeFraction = field.fontSizeFraction
        alignment = field.alignment.rawValue
        color = field.colorRGBA.hexString
    }

    /// The field names this schema version defines for a stamp field.
    public static let knownFieldNames: Set<String> = [
        "kind", "slot", "prompt", "dateFormat", "textPrefix", "frameX", "frameY", "frameWidth",
        "frameHeight", "fontName", "fontSizeFraction", "alignment", "color"
    ]
}

/// The measurement parameters of one tool inside a `.zpdftools` file.
///
/// Flat scalars rather than the ``ToolPresetMeasurementDefaults`` value itself, for the reason
/// every other field in this file is a scalar: a tool set is read from a file somebody else
/// wrote, and a shape whose fields are plain numbers and raw strings can be bounds-checked one
/// field at a time by ``ToolSetImportValidator``. Decoding straight into the domain type would
/// make the decoder the validator, which is exactly the arrangement the import review exists to
/// avoid.
///
/// Lengths are metres, matching what the preset stores. `nil` means the tool does not say.
public struct ToolSetMeasurementRecord: Codable, Hashable, Sendable {

    /// Extrusion depth or slab thickness, in metres.
    public var depthMetres: Decimal?
    /// Wall height, in metres.
    public var wallHeightMetres: Decimal?
    /// Wall height at the far end of the run, in metres.
    public var wallHeightAtEndMetres: Decimal?
    /// Slope magnitude as a percentage.
    public var slopePercent: Double?
    /// Fall-line azimuth in degrees counter-clockwise from the page-space +x axis.
    public var slopeAzimuthDegrees: Double?
    /// Raw value of the volume depth reference.
    public var volumeDepthReference: String?
    /// Raw value of the cutout policy.
    public var cutoutPolicy: String?
    /// Raw value of the perimeter policy.
    public var perimeterPolicy: String?

    /// Creates a record.
    public init(
        depthMetres: Decimal? = nil,
        wallHeightMetres: Decimal? = nil,
        wallHeightAtEndMetres: Decimal? = nil,
        slopePercent: Double? = nil,
        slopeAzimuthDegrees: Double? = nil,
        volumeDepthReference: String? = nil,
        cutoutPolicy: String? = nil,
        perimeterPolicy: String? = nil
    ) {
        self.depthMetres = depthMetres
        self.wallHeightMetres = wallHeightMetres
        self.wallHeightAtEndMetres = wallHeightAtEndMetres
        self.slopePercent = slopePercent
        self.slopeAzimuthDegrees = slopeAzimuthDegrees
        self.volumeDepthReference = volumeDepthReference
        self.cutoutPolicy = cutoutPolicy
        self.perimeterPolicy = perimeterPolicy
    }

    /// The record for a preset's defaults, or `nil` when the preset says nothing at all.
    ///
    /// The two policies are written only when they differ from the engine's own defaults, so a
    /// file exported from a library of plain colour presets carries no measurement block and
    /// reads exactly as it did before this field existed.
    public init?(defaults: ToolPresetMeasurementDefaults) {
        let cutout: String? = defaults.cutoutPolicy == .subtractFromArea
            ? nil : defaults.cutoutPolicy.rawValue
        let perimeter: String? = defaults.perimeterPolicy == .outerOnly
            ? nil : defaults.perimeterPolicy.rawValue
        guard defaults.carriesAnyValue || cutout != nil || perimeter != nil else { return nil }
        self.init(
            depthMetres: defaults.depth?.value,
            wallHeightMetres: defaults.wallHeight?.value,
            wallHeightAtEndMetres: defaults.wallHeightAtEnd?.value,
            slopePercent: defaults.slopePercent,
            slopeAzimuthDegrees: defaults.slopeAzimuthDegrees,
            volumeDepthReference: defaults.volumeDepthReference?.rawValue,
            cutoutPolicy: cutout,
            perimeterPolicy: perimeter
        )
    }

    /// The field names this schema version defines for a measurement block.
    public static let knownFieldNames: Set<String> = [
        "depthMetres", "wallHeightMetres", "wallHeightAtEndMetres", "slopePercent",
        "slopeAzimuthDegrees", "volumeDepthReference", "cutoutPolicy", "perimeterPolicy"
    ]
}

/// A bitmap symbol travelling inside a tool set.
///
/// Zenit records what the file *claims* about the image and shows that in the review before
/// anything is decoded. The bytes stay base64 text until the user has said yes.
public struct ToolSetEmbeddedImageRecord: Codable, Hashable, Sendable {

    /// Name shown in the review list.
    public var fileName: String
    /// Declared format. Only `png` and `jpeg` are accepted.
    public var format: String
    /// Declared width in pixels.
    public var pixelWidth: Int
    /// Declared height in pixels.
    public var pixelHeight: Int
    /// The image as base64 text. Never decoded during the review.
    public var base64Data: String

    /// Creates an embedded image record.
    public init(
        fileName: String,
        format: String,
        pixelWidth: Int,
        pixelHeight: Int,
        base64Data: String
    ) {
        self.fileName = fileName
        self.format = format
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.base64Data = base64Data
    }

    /// The formats Zenit will accept.
    public static let acceptedFormats: Set<String> = ["png", "jpeg"]

    /// The field names this schema version defines for an embedded image.
    public static let knownFieldNames: Set<String> = [
        "fileName", "format", "pixelWidth", "pixelHeight", "base64Data"
    ]
}
