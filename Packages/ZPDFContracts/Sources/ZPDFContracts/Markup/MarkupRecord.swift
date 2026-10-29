import Foundation

/// The markup types the product creates (spec 14.1).
public enum MarkupKind: String, Codable, Hashable, Sendable, CaseIterable {
    case text
    case callout
    case note
    case highlight
    case underline
    case strikeout
    case freehand
    case line
    case arrow
    case polyline
    case rectangle
    case ellipse
    case polygon
    case cloud
    case stamp
    case image
    case hyperlink
    case measurement
    case count
    case revisionCloud
    case issue

    /// True when the kind carries a quantity that reaches the Quantity Ledger.
    public var producesQuantity: Bool {
        switch self {
        case .measurement, .count: true
        default: false
        }
    }

    /// True when the kind is anchored to a text selection rather than to free geometry.
    public var isTextMarkup: Bool {
        switch self {
        case .highlight, .underline, .strikeout: true
        default: false
        }
    }
}

/// Review status of a markup (spec 14.3).
///
/// `none` exists so that "not part of a review workflow" is a state of its own, rather than
/// being spelled as an absent value that every consumer has to interpret.
public enum MarkupStatus: String, Codable, Hashable, Sendable, CaseIterable {
    case none
    case open
    case inProgress
    case resolved
    case accepted
    case rejected
    case cancelled
    case completed
}

/// Line dash pattern.
public enum LineStyle: String, Codable, Hashable, Sendable, CaseIterable {
    case solid
    case dashed
    case dotted
    case dashDot
    case cloud
}

/// Line end decoration (spec 14.3).
public enum LineCapStyle: String, Codable, Hashable, Sendable, CaseIterable {
    case none
    case openArrow
    case closedArrow
    case circle
    case square
    case diamond
    case slash
    case butt
    case round
}

/// Horizontal text alignment inside a markup's text box.
public enum TextAlignment: String, Codable, Hashable, Sendable, CaseIterable {
    case leading
    case center
    case trailing
    case justified
}

/// Text formatting beyond family, size and alignment (ADR-0029).
///
/// One optional struct on ``MarkupStyle`` rather than four loose fields, so a style written
/// before ADR-0029 — which has no `textStyle` key — decodes as `nil` and means exactly what it
/// meant then: regular weight, upright, text in the stroke colour, no box border.
public struct MarkupTextStyle: Codable, Hashable, Sendable {
    /// Bold weight.
    public var bold: Bool
    /// Italic (oblique) face.
    public var italic: Bool
    /// The text colour, or `nil` for the stroke colour (the only colour text had before).
    public var textColor: RGBAColor?
    /// Whether a Text box draws a border in the stroke colour. A Callout always draws its box.
    public var boxBorder: Bool

    public init(bold: Bool = false, italic: Bool = false, textColor: RGBAColor? = nil, boxBorder: Bool = false) {
        self.bold = bold
        self.italic = italic
        self.textColor = textColor
        self.boxBorder = boxBorder
    }

    /// Regular, upright, stroke-coloured, unboxed — what `nil` means.
    public static let plain = MarkupTextStyle()

    private enum CodingKeys: String, CodingKey { case bold, italic, textColor, boxBorder }

    /// Every key optional, so a later field can be added on the same terms.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bold = try container.decodeIfPresent(Bool.self, forKey: .bold) ?? false
        italic = try container.decodeIfPresent(Bool.self, forKey: .italic) ?? false
        textColor = try container.decodeIfPresent(RGBAColor.self, forKey: .textColor)
        boxBorder = try container.decodeIfPresent(Bool.self, forKey: .boxBorder) ?? false
    }
}

/// How a markup's ink combines with the drawing under it (ADR-0029).
public enum MarkupBlendMode: String, Codable, Hashable, Sendable, CaseIterable {
    /// Ordinary source-over painting.
    case normal
    /// Multiply: a highlighter, whose ink darkens the linework under it instead of hiding it.
    case multiply
}

/// Where a hyperlink markup leads (ADR-0029): a page of the project or a web address.
///
/// Exactly one of the two is set. A web address is limited to `http`, `https` and `mailto`,
/// and following one is always confirmed by a person; nothing opens on its own.
public struct MarkupLinkTarget: Codable, Hashable, Sendable {
    /// A page of the same project.
    public var pageID: PageID?
    /// A web address.
    public var url: String?

    public init(pageID: PageID) {
        self.pageID = pageID
        self.url = nil
    }

    public init(url: String) {
        self.pageID = nil
        self.url = url
    }

    /// The schemes a link may name.
    public static let allowedSchemes: Set<String> = ["http", "https", "mailto"]

    /// Whether the target names exactly one destination, and a web address uses an allowed scheme.
    public var isValid: Bool {
        switch (pageID, url) {
        case (.some, nil):
            return true
        case (nil, .some(let address)):
            guard let colon = address.firstIndex(of: ":") else { return false }
            let scheme = address[..<colon].lowercased()
            return Self.allowedSchemes.contains(scheme) && address.count > scheme.count + 1
        default:
            return false
        }
    }
}

/// Everything that decides how a markup looks (spec 14.3).
///
/// Fonts are named, not resolved: this package cannot import AppKit, so a `MarkupStyle` carries
/// a family name and a size and lets the design system turn that into something drawable.
public struct MarkupStyle: Codable, Hashable, Sendable {
    /// Stroke colour.
    public var color: RGBAColor
    /// Fill colour. `nil` means unfilled.
    public var fill: RGBAColor?
    /// Overall opacity, 0...1, multiplied with the colours' own alpha.
    public var opacity: Double
    /// Stroke width in PDF points.
    public var lineWidth: Double
    public var lineStyle: LineStyle
    public var startCap: LineCapStyle
    public var endCap: LineCapStyle
    /// Font family name, for example "Helvetica". Resolution happens in the design system.
    public var fontName: String
    /// Font size in PDF points.
    public var fontSize: Double
    public var textAlignment: TextAlignment
    /// Bold, italic, text colour and box border, or `nil` for plain text (ADR-0029).
    public var textStyle: MarkupTextStyle?
    /// The scallop radius of a clouded outline in PDF points, or `nil` for the automatic size
    /// (about a twelfth of the longest edge, 8…18 pt). ADR-0029.
    public var cloudArcSize: Double?
    /// Rotation about the markup's box centre in degrees, counter-clockwise in page space, or
    /// `nil` for none (ADR-0029). Stamps keep their own `StampInstance.rotationDegrees`.
    public var rotationDegrees: Double?
    /// How the ink combines with the drawing, or `nil` for normal painting (ADR-0029).
    public var blendMode: MarkupBlendMode?
    /// A measurement's caption fields, segment lengths and dragged label position, or `nil` for
    /// the headline value at the automatic position (ADR-0030 §3). Display only.
    public var measurementCaption: MeasurementCaption?

    public init(
        color: RGBAColor = .opaqueBlack,
        fill: RGBAColor? = nil,
        opacity: Double = 1.0,
        lineWidth: Double = 1.0,
        lineStyle: LineStyle = .solid,
        startCap: LineCapStyle = .none,
        endCap: LineCapStyle = .none,
        fontName: String = "Helvetica",
        fontSize: Double = 11.0,
        textAlignment: TextAlignment = .leading,
        textStyle: MarkupTextStyle? = nil,
        cloudArcSize: Double? = nil,
        rotationDegrees: Double? = nil,
        blendMode: MarkupBlendMode? = nil,
        measurementCaption: MeasurementCaption? = nil
    ) {
        self.color = color
        self.fill = fill
        self.opacity = opacity
        self.lineWidth = lineWidth
        self.lineStyle = lineStyle
        self.startCap = startCap
        self.endCap = endCap
        self.fontName = fontName
        self.fontSize = fontSize
        self.textAlignment = textAlignment
        self.textStyle = textStyle
        self.cloudArcSize = cloudArcSize
        self.rotationDegrees = rotationDegrees
        self.blendMode = blendMode
        self.measurementCaption = measurementCaption
    }

    public static let `default` = MarkupStyle()

    /// The smallest and largest scallop radius a person may set, in PDF points (ADR-0029).
    public static let cloudArcSizeRange: ClosedRange<Double> = 2...72

    /// The rotation actually drawn: finite, folded into `0..<360`, zero when unset.
    public var effectiveRotationDegrees: Double {
        guard let rotationDegrees, rotationDegrees.isFinite else { return 0 }
        let wrapped = rotationDegrees.truncatingRemainder(dividingBy: 360)
        return wrapped < 0 ? wrapped + 360 : wrapped
    }

    /// The arc size actually honoured: `nil` when unset or not finite, otherwise clamped into
    /// ``cloudArcSizeRange``.
    public var effectiveCloudArcSize: Double? {
        guard let cloudArcSize, cloudArcSize.isFinite else { return nil }
        return Swift.min(Self.cloudArcSizeRange.upperBound, Swift.max(Self.cloudArcSizeRange.lowerBound, cloudArcSize))
    }
}

/// One Zenit markup, as it lives in the project database (spec 14.2, 14.3).
///
/// Zenit markups are a first-class overlay, not PDF annotations: the id is stable across
/// exports, the geometry stays in canonical page space, and the measurement travels with the
/// scale id and scale version it was computed under so a stale value is always detectable
/// (spec 10.6).
public struct MarkupRecord: Codable, Hashable, Sendable {
    /// Stable identity, minted once and never reused.
    public var id: MarkupID
    public var documentID: DocumentID
    public var pageID: PageID
    public var kind: MarkupKind
    /// The measurement tool that created it, for measurement and count kinds.
    public var tool: MeasurementTool?

    /// Free-text classification, the primary ledger grouping key (spec 14.3).
    public var subject: String
    public var label: String
    public var comment: String
    /// Author name as recorded locally. Local-first: no account, no server identity.
    public var author: String
    public var status: MarkupStatus
    public var style: MarkupStyle
    /// Optional caption drawn next to the markup.
    public var caption: String?

    public var layerID: LayerID?
    public var zoneID: ZoneID?
    public var scaleRegionID: ScaleRegionID?
    /// The scale the measurement was computed under.
    public var scaleID: ScaleID?
    /// The version of that scale. A mismatch against the live scale means the value is stale.
    public var scaleVersion: Int?

    public var locked: Bool
    public var hidden: Bool
    public var printable: Bool

    /// Original PDF-space geometry. Kept verbatim so a scale change can recompute from source
    /// rather than from a previously computed number (spec 10.6).
    public var geometry: MeasurementGeometry?
    /// Measurement parameters used, for the same reason.
    public var parameters: MeasurementParameters?
    /// The computed SI values.
    public var measurement: MeasurementResult?

    /// Parent markup for a cutout (spec 12.4).
    public var parentMarkupID: MarkupID?
    /// Cutout children, in creation order.
    public var cutoutMarkupIDs: [MarkupID]
    /// Count group, for count markups.
    public var countGroupID: CountGroupID?

    /// Custom ledger values keyed by column.
    public var customValues: [ColumnID: LedgerCellValue]

    /// The stamp this markup is, when it is one.
    ///
    /// `nil` for every markup that is not a stamp, which is almost all of them. It is on
    /// the record rather than in a side table because a stamp's frozen field values are
    /// part of *what the markup says*: undo, redo, save, reopen and export all carry whole
    /// `MarkupRecord` values, and a stamp whose text lived somewhere else would be a stamp
    /// whose text one of those five paths eventually forgot.
    ///
    /// Optional and defaulted, so every existing call site and every project written
    /// before this build decodes unchanged — the synthesized decoder reads an absent key
    /// for an `Optional` as `nil`. See ADR-0010.
    public var stamp: StampInstance?

    /// The symbol this markup draws itself as, when it draws one (spec 12.13, ADR-0011).
    ///
    /// A count mark's glyph is a property of *the mark*, not an option of the tool that made
    /// it — that is the whole point of moving it here. The value is a **reference**: it names
    /// artwork by digest in the project's own artwork store, so the mark keeps drawing what it
    /// drew after its preset is renamed, edited or deleted, and keeps drawing it on a machine
    /// that never had the preset.
    ///
    /// Optional and defaulted, so every existing call site and every project written before
    /// this build decodes unchanged. See ADR-0011.
    public var symbol: MarkupSymbol?

    /// What kind of claim this row's quantity makes: measured, derived, or read (ADR-0012).
    ///
    /// Defaulted to `.measured` — the only value that existed before ADR-0012 — and decoded
    /// as `.measured` when the key is absent, so every existing call site and every project
    /// written before this build decodes unchanged. No migration pass.
    public var provenance: QuantityProvenance

    /// The ancestry of a `.derived` or `.read` row (ADR-0012).
    ///
    /// Mandatory for those two cases and refused for `.measured`;
    /// ``quantityProvenanceViolation()`` states the rule and the decoder enforces it.
    public var derivation: QuantityDerivation?

    /// The group this markup belongs to, or `nil` (ADR-0029). Group members select, move,
    /// restyle and delete as one; a group is simply the set of records sharing the value.
    public var groupID: MarkupGroupID?

    /// Where a `hyperlink` markup leads, or `nil` (ADR-0029). Ignored on every other kind.
    public var link: MarkupLinkTarget?

    /// Creation time, supplied by an injected ``TimestampProviding``.
    public var createdAt: Date
    /// Last modification time, supplied by an injected ``TimestampProviding``.
    public var modifiedAt: Date

    public init(
        id: MarkupID,
        documentID: DocumentID,
        pageID: PageID,
        kind: MarkupKind,
        tool: MeasurementTool? = nil,
        subject: String = "",
        label: String = "",
        comment: String = "",
        author: String = "",
        status: MarkupStatus = .none,
        style: MarkupStyle = .default,
        caption: String? = nil,
        layerID: LayerID? = nil,
        zoneID: ZoneID? = nil,
        scaleRegionID: ScaleRegionID? = nil,
        scaleID: ScaleID? = nil,
        scaleVersion: Int? = nil,
        locked: Bool = false,
        hidden: Bool = false,
        printable: Bool = true,
        geometry: MeasurementGeometry? = nil,
        parameters: MeasurementParameters? = nil,
        measurement: MeasurementResult? = nil,
        parentMarkupID: MarkupID? = nil,
        cutoutMarkupIDs: [MarkupID] = [],
        countGroupID: CountGroupID? = nil,
        customValues: [ColumnID: LedgerCellValue] = [:],
        stamp: StampInstance? = nil,
        symbol: MarkupSymbol? = nil,
        provenance: QuantityProvenance = .measured,
        derivation: QuantityDerivation? = nil,
        groupID: MarkupGroupID? = nil,
        link: MarkupLinkTarget? = nil,
        createdAt: Date,
        modifiedAt: Date
    ) {
        self.id = id
        self.documentID = documentID
        self.pageID = pageID
        self.kind = kind
        self.tool = tool
        self.subject = subject
        self.label = label
        self.comment = comment
        self.author = author
        self.status = status
        self.style = style
        self.caption = caption
        self.layerID = layerID
        self.zoneID = zoneID
        self.scaleRegionID = scaleRegionID
        self.scaleID = scaleID
        self.scaleVersion = scaleVersion
        self.locked = locked
        self.hidden = hidden
        self.printable = printable
        self.geometry = geometry
        self.parameters = parameters
        self.measurement = measurement
        self.parentMarkupID = parentMarkupID
        self.cutoutMarkupIDs = cutoutMarkupIDs
        self.countGroupID = countGroupID
        self.customValues = customValues
        self.stamp = stamp
        self.symbol = symbol
        self.provenance = provenance
        self.derivation = derivation
        self.groupID = groupID
        self.link = link
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, documentID, pageID, kind, tool
        case subject, label, comment, author, status, style, caption
        case layerID, zoneID, scaleRegionID, scaleID, scaleVersion
        case locked, hidden, printable
        case geometry, parameters, measurement
        case parentMarkupID, cutoutMarkupIDs, countGroupID
        case customValues, stamp, symbol
        case provenance, derivation
        case groupID, link
        case createdAt, modifiedAt
    }

    /// Decodes a record, keeping every project written before ADR-0012 readable.
    ///
    /// Hand-written for exactly two departures from the synthesized decoder:
    ///
    /// 1. An absent `provenance` key decodes as `.measured` — the only claim any row could
    ///    make before ADR-0012 — so old files need no migration pass.
    /// 2. The provenance/derivation pairing rule is enforced here, so a `.derived` or `.read`
    ///    row without its ancestry (or a `.measured` row carrying one) is refused at the door
    ///    rather than stored and trusted.
    ///
    /// Every other key keeps the synthesized behaviour: required when the property is
    /// non-optional, `decodeIfPresent` when it is optional.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(MarkupID.self, forKey: .id)
        documentID = try container.decode(DocumentID.self, forKey: .documentID)
        pageID = try container.decode(PageID.self, forKey: .pageID)
        kind = try container.decode(MarkupKind.self, forKey: .kind)
        tool = try container.decodeIfPresent(MeasurementTool.self, forKey: .tool)
        subject = try container.decode(String.self, forKey: .subject)
        label = try container.decode(String.self, forKey: .label)
        comment = try container.decode(String.self, forKey: .comment)
        author = try container.decode(String.self, forKey: .author)
        status = try container.decode(MarkupStatus.self, forKey: .status)
        style = try container.decode(MarkupStyle.self, forKey: .style)
        caption = try container.decodeIfPresent(String.self, forKey: .caption)
        layerID = try container.decodeIfPresent(LayerID.self, forKey: .layerID)
        zoneID = try container.decodeIfPresent(ZoneID.self, forKey: .zoneID)
        scaleRegionID = try container.decodeIfPresent(ScaleRegionID.self, forKey: .scaleRegionID)
        scaleID = try container.decodeIfPresent(ScaleID.self, forKey: .scaleID)
        scaleVersion = try container.decodeIfPresent(Int.self, forKey: .scaleVersion)
        locked = try container.decode(Bool.self, forKey: .locked)
        hidden = try container.decode(Bool.self, forKey: .hidden)
        printable = try container.decode(Bool.self, forKey: .printable)
        geometry = try container.decodeIfPresent(MeasurementGeometry.self, forKey: .geometry)
        parameters = try container.decodeIfPresent(MeasurementParameters.self, forKey: .parameters)
        measurement = try container.decodeIfPresent(MeasurementResult.self, forKey: .measurement)
        parentMarkupID = try container.decodeIfPresent(MarkupID.self, forKey: .parentMarkupID)
        cutoutMarkupIDs = try container.decode([MarkupID].self, forKey: .cutoutMarkupIDs)
        countGroupID = try container.decodeIfPresent(CountGroupID.self, forKey: .countGroupID)
        customValues = try container.decode([ColumnID: LedgerCellValue].self, forKey: .customValues)
        stamp = try container.decodeIfPresent(StampInstance.self, forKey: .stamp)
        symbol = try container.decodeIfPresent(MarkupSymbol.self, forKey: .symbol)
        provenance = try container.decodeIfPresent(QuantityProvenance.self, forKey: .provenance)
            ?? .measured
        derivation = try container.decodeIfPresent(QuantityDerivation.self, forKey: .derivation)
        // ADR-0029: absent in every record written before it, and nil then.
        groupID = try container.decodeIfPresent(MarkupGroupID.self, forKey: .groupID)
        link = try container.decodeIfPresent(MarkupLinkTarget.self, forKey: .link)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        modifiedAt = try container.decode(Date.self, forKey: .modifiedAt)

        if let violation = quantityProvenanceViolation() {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath + [CodingKeys.derivation],
                    debugDescription: violation.description
                )
            )
        }
    }

    /// True when the record's stored measurement was not computed under `scale` as it is now:
    /// under an older version of it, or under a different scale altogether.
    ///
    /// The caller names the scale in force for this record. A record that says it was measured
    /// under scale R, asked about scale P, holds a number computed under a transform that is
    /// no longer the one governing it, and answers stale (BH-490 — it used to answer `false`
    /// whenever the ids differed, which was safe only because the one caller pre-checked the
    /// id itself). A record with no `scaleID` claims no scale and cannot be stale against one.
    /// The version path is unchanged: a version mismatch is stale whether or not a
    /// measurement is present, and a missing version is stale only when one is.
    public func isMeasurementStale(against scale: ScaleTransform) -> Bool {
        guard let scaleID else { return false }
        guard scaleID == scale.id else { return true }
        guard let scaleVersion else { return measurement != nil }
        return scaleVersion != scale.version
    }

    /// True when the record is a cutout of another markup.
    public var isCutout: Bool { parentMarkupID != nil }
}

// MARK: - Style rotation (ADR-0029), one rule for every reader

extension MarkupRecord {

    /// Whether the record is drawn turned by ``MarkupStyle/effectiveRotationDegrees``
    /// (ADR-0029): text and the drawn shapes do; a stamp turns through its own instance, an
    /// image by its placement, and a measurement never turns — its geometry is the quantity.
    ///
    /// One rule for the canvas that draws the turn and for the snap index that must offer the
    /// turned outline, not the stored one (ADR-0037, T-071): the snap engine used to read the
    /// stored points, so a rotated rectangle snapped at corners where nothing was drawn.
    public var turnsWithStyleRotation: Bool {
        switch kind {
        case .text, .callout, .line, .arrow, .polyline, .rectangle, .ellipse, .polygon, .cloud,
             .freehand, .hyperlink, .note, .image:
            return tool == nil
        default:
            return false
        }
    }

    /// The turn actually applied to the stored geometry, in degrees counter-clockwise: the
    /// style's rotation when ``turnsWithStyleRotation``, else `0`.
    public var drawnRotationDegrees: Double {
        turnsWithStyleRotation ? style.effectiveRotationDegrees : 0
    }

    /// The unturned box the record turns about: a callout's text box (the two corners after its
    /// target), a Text box's or an Image's two corners, otherwise the geometry's bounding box (a
    /// clouded callout's included). `nil` without geometry.
    ///
    /// One rule for the canvas, which turns the strokes about this box's centre and puts the
    /// rotation knob on it (`CanvasSceneBuilder.rotationBox(of:)`), and for the snap index,
    /// which turns the outline about ``styleRotationCentre`` (X-046). The two used to be written
    /// twice, agreeing only because nothing had yet changed one of them.
    public var styleRotationBox: PDFRect? {
        guard let geometry else { return nil }
        let points = geometry.points
        switch kind {
        case .callout where points.count >= 3:
            return PDFRect(corner: points[1], opposite: points[2])
        case .text where points.count >= 2, .image where points.count >= 2:
            return PDFRect(corner: points[0], opposite: points[1])
        default:
            return geometry.bounds
        }
    }

    /// The point the record turns about: the centre of ``styleRotationBox``.
    public var styleRotationCentre: PDFPoint? {
        styleRotationBox?.center
    }

    /// `point` turned by ``drawnRotationDegrees`` about ``styleRotationCentre``, in page space
    /// (y up, counter-clockwise positive); `point` itself when the record does not turn.
    public func drawnPosition(of point: PDFPoint) -> PDFPoint {
        let degrees = drawnRotationDegrees
        guard degrees != 0, let centre = styleRotationCentre else { return point }
        let radians = degrees * Double.pi / 180
        let dx = point.x - centre.x
        let dy = point.y - centre.y
        return PDFPoint(
            x: centre.x + dx * Foundation.cos(radians) - dy * Foundation.sin(radians),
            y: centre.y + dx * Foundation.sin(radians) + dy * Foundation.cos(radians)
        )
    }
}

// MARK: - Drawn outline of ellipses and boxes (ADR-0037 §4.3), one rule for every reader

extension MarkupRecord {

    /// The box an ellipse record is drawn inscribed in, or `nil` for any other record.
    ///
    /// An Ellipse annotation is its first two points. An Ellipse Area or Ellipse Cutout is its
    /// ``MeasurementGeometry/ellipseBox``, the box the measurement engine measures.
    ///
    /// One rule for the canvas that draws the ellipse and the snap index that offers it (T-071):
    /// the snap read this box and the canvas drew an Ellipse Area as a dimensioned line through
    /// its stored corners and an Ellipse Cutout as its box ring, so the two disagreed.
    public var inscribedEllipseBox: PDFRect? {
        guard let geometry else { return nil }
        switch tool {
        case .ellipseArea?, .ellipseCutout?:
            return geometry.ellipseBox
        case nil:
            guard kind == .ellipse, geometry.points.count >= 2 else { return nil }
            return PDFRect(corner: geometry.points[0], opposite: geometry.points[1])
        default:
            return nil
        }
    }

    /// Whether the record's stored points are the corners of a box rather than a path: a Text
    /// box, a Callout (target, then two corners), a Note, a Link, an Image, and a Cloud that
    /// carries a callout box (target, then two corners, beside its ring).
    public var storesBoxCorners: Bool {
        guard tool == nil else { return false }
        switch kind {
        case .text, .callout, .note, .hyperlink, .image, .cloud: return true
        default: return false
        }
    }

    /// The target a callout's leader points at — the first stored point of a Callout, or of a
    /// Cloud that carries a callout box — or `nil`.
    public var calloutTarget: PDFPoint? {
        guard tool == nil, kind == .callout || kind == .cloud, let points = geometry?.points, points.count >= 3 else {
            return nil
        }
        return points[0]
    }

    /// The rectangle a box-drawn record draws as a frame, or `nil` when nothing is drawn around
    /// it (ADR-0037 §4.3):
    ///
    /// - a Text box only when it has a border (``MarkupTextStyle/boxBorder``) or a fill
    ///   (ADR-0029) — an unframed Text box is words, with nothing at its corners;
    /// - a Callout's text box, and a clouded callout's box, always;
    /// - a Note's and a Link's box, always;
    /// - an Image's box: the picture is placed at its own aspect ratio and fills it, and the box
    ///   is the solid object the selection and the hit test read.
    ///
    /// The canvas draws exactly this frame, and the snap index offers its four corners and four
    /// edges — never the two stored corners alone (T-071).
    public var drawnFrameBox: PDFRect? {
        guard storesBoxCorners, let points = geometry?.points else { return nil }
        switch kind {
        case .text:
            guard points.count >= 2, style.textStyle?.boxBorder == true || style.fill != nil else { return nil }
            return PDFRect(corner: points[0], opposite: points[1])
        case .callout, .cloud:
            guard points.count >= 3 else { return nil }
            return PDFRect(corner: points[1], opposite: points[2])
        case .note, .hyperlink, .image:
            guard points.count >= 2 else { return nil }
            return PDFRect(corner: points[0], opposite: points[1])
        default:
            return nil
        }
    }
}

// MARK: - Drawn chain of a point list (X-042), one rule for every reader

extension MarkupRecord {

    /// The open chain the record's point list is drawn as, or `nil` with fewer than two points.
    ///
    /// A point-form Arc Length of three points is the arc the measurement engine measures through
    /// them — start, a point on the arc, end: a chain from the first point to the third whose one
    /// edge bends through the second (``BulgeArc/bulge(from:to:through:)``). Three points the
    /// engine refuses to put an arc through — two coincident, or collinear to its normalised
    /// floor `|cross| / maxEdge² ≤ 1e-9` (the default `collinearityThreshold`) — stay the
    /// polyline that was placed, rather than an arc of an absurd circle. Every other chain is its
    /// points with their stored ``MeasurementGeometry/pointBulges``.
    ///
    /// One rule for the canvas that draws the chain and the snap index that offers it: both drew
    /// and indexed an Arc Length as two chords through its three points while its value was the
    /// arc's (X-042).
    public var drawnPointChain: PolygonRing? {
        guard let geometry, geometry.points.count >= 2 else { return nil }
        let points = geometry.points
        if tool == .arcLength, geometry.arcs.isEmpty, points.count == 3,
           Self.spansArc(points[0], points[1], points[2]),
           let bulge = BulgeArc.bulge(from: points[0], to: points[2], through: points[1]), bulge != 0 {
            return PolygonRing(points: [points[0], points[2]], isClosed: false, bulges: [bulge, 0])
        }
        return PolygonRing(points: points, isClosed: false, bulges: geometry.pointBulges)
    }

    /// Whether three points define an arc the engine measures: the normalised measure
    /// `|cross| / maxEdge²` above `1e-9`, the engine's default collinearity floor.
    private static func spansArc(_ a: PDFPoint, _ b: PDFPoint, _ c: PDFPoint) -> Bool {
        guard a.isFinite, b.isFinite, c.isFinite else { return false }
        let cross = (a.x - c.x) * (b.y - c.y) - (a.y - c.y) * (b.x - c.x)
        let maxEdge = Swift.max(a.distance(to: b), Swift.max(b.distance(to: c), c.distance(to: a)))
        guard maxEdge > 0 else { return false }
        return Swift.abs(cross) / (maxEdge * maxEdge) > 1e-9
    }
}

/// The undoable mutations of the markup engine (spec 14.5).
///
/// The list is frozen because the undo stack is persisted per document and a command name is
/// part of the on-disk format.
public enum MarkupCommandKind: String, Codable, Hashable, Sendable, CaseIterable {
    case addMarkup
    case removeMarkup
    case moveMarkup
    case changeStyle
    case editVertices
    case changeScale
    case recalculateMeasurements
    case addCutout
    case editCustomValue
    case batchStatusChange
    case reorderPage
}

/// The three export shapes (spec 14.2).
public enum MarkupExportMode: String, Codable, Hashable, Sendable, CaseIterable {
    /// Standard PDF annotations where possible, plus an optional Zenit custom dictionary.
    case editableAnnotated
    /// Markups drawn into the page content stream.
    case flattened
    /// No Zenit markups at all.
    case clean
}
