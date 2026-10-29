import Foundation

/// What a stamp's artwork is, and therefore whether it stays sharp when magnified.
///
/// The presentation-layer twin of `ZPDFContracts.StampArtworkKind`. This package has no
/// dependencies by design (ADR-0008), so the vocabulary is mirrored here and bridged in
/// `ZPDFAppCore`, exactly as ``MarkupKind`` already is.
public enum StampArtworkKind: String, Codable, Hashable, Sendable, CaseIterable {

    /// Imported from a PDF page and kept as geometry. Sharp at any zoom.
    case vector
    /// Imported from an image. Fixed pixel count; it resamples when magnified past it.
    case raster
    /// No artwork: the stamp is its fields and its style.
    case none

    /// Whether magnifying the canvas keeps this artwork's edges crisp.
    public var staysSharpWhenMagnified: Bool { self != .raster }

    /// A localized name for the editor's artwork row.
    public var displayName: String {
        switch self {
        case .vector: return NSLocalizedString("Vector", comment: "Stamp artwork kind")
        case .raster: return NSLocalizedString("Image", comment: "Stamp artwork kind")
        case .none: return NSLocalizedString("No artwork", comment: "Stamp artwork kind")
        }
    }
}

/// The artwork a stamp preset carries, described without its bytes.
///
/// The bytes live once per project, keyed by ``digest``; a batch that places one stamp on
/// 312 pages must not multiply an imported PDF page by 312. What the editor and the
/// renderer need in order to *decide* things — is it vector, how big is it, where did it
/// come from — is all here, and is small enough to travel inside a preset summary.
public struct StampArtworkDescriptor: Codable, Hashable, Sendable {

    /// Whether the artwork stays sharp when magnified.
    public var kind: StampArtworkKind
    /// SHA-256 of the artwork bytes, lower-case hex. The key the bytes are stored under.
    public var digest: String
    /// Size of the stored bytes, so the editor can say what an import costs.
    public var byteCount: Int
    /// The name of the file the artwork was imported from, for provenance.
    public var sourceName: String
    /// The page of the source PDF the artwork came from. `nil` for raster artwork.
    public var sourcePageIndex: Int?
    /// Pixel width of raster artwork. `nil` for vector artwork.
    public var pixelWidth: Int?
    /// Pixel height of raster artwork. `nil` for vector artwork.
    public var pixelHeight: Int?
    /// The one colour vector artwork was drawn in, when it has exactly one; `nil` for artwork
    /// in several colours, in a colour the importer cannot state, or raster artwork.
    ///
    /// ADR-0011 §2.4 (decided 2026-09-23): an imported stamp looks as drawn by default,
    /// so adopting this artwork into a stamp preset starts the stamp's colour here. The
    /// artwork's regions stay colourless, which is what lets a colour the person chooses
    /// afterwards recolour the whole seal. Absent in presets saved before the ruling.
    public var sourceInk: ColorRGBA?

    /// Creates an artwork descriptor.
    public init(
        kind: StampArtworkKind,
        digest: String,
        byteCount: Int = 0,
        sourceName: String = "",
        sourcePageIndex: Int? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        sourceInk: ColorRGBA? = nil
    ) {
        self.kind = kind
        self.digest = digest
        self.byteCount = byteCount
        self.sourceName = sourceName
        self.sourcePageIndex = sourcePageIndex
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.sourceInk = sourceInk
    }

    /// The zoom at which raster artwork of this pixel count stops adding detail, given a
    /// stamp box of `widthPoints` PDF points, expressed as a magnification.
    ///
    /// A 300-pixel-wide seal in a 96-point box has 3.125 pixels per point, so it is
    /// resolution-limited above 312 %. Below that it is indistinguishable from vector; the
    /// editor says the number rather than a vague "this may look worse", because "worse
    /// above 312 %" is a fact the estimator can act on.
    public func sharpUntilMagnification(inBoxWidthPoints widthPoints: Double) -> Double? {
        guard kind == .raster, pixelWidth ?? 0 > 0, widthPoints > 0 else { return nil }
        return Double(mosaicColumns) / widthPoints
    }

    /// The columns the artwork is actually stored at.
    ///
    /// BH-166: raster artwork is kept as a mosaic of at most 96 cells
    /// on its longer side, so the detail available is the mosaic's, not the source file's —
    /// the same formula as `ImportedArtwork.mosaicColumns` in ZPDFPersistence.
    public var mosaicColumns: Int {
        guard let pixelWidth, pixelWidth > 0 else { return 0 }
        let longerSide = max(pixelWidth, pixelHeight ?? pixelWidth)
        return longerSide <= 96
            ? pixelWidth
            : Int((Double(pixelWidth) * 96 / Double(longerSide)).rounded())
    }

    /// ``sharpUntilMagnification(inBoxWidthPoints:)`` for artwork **letterboxed** into a box.
    ///
    /// The canvas fits the artwork into the box with its aspect preserved, so a 300 × 300 px
    /// seal in a 160 × 60 pt box is drawn 60 pt wide — 5 px/pt, sharp to 500 % — not 160 pt
    /// wide. Dividing by the box width stated 188 % (BH-794).
    public func sharpUntilMagnification(inBoxWidthPoints widthPoints: Double, heightPoints: Double) -> Double? {
        guard kind == .raster, let pixelWidth, pixelWidth > 0, widthPoints > 0 else { return nil }
        guard let pixelHeight, pixelHeight > 0, heightPoints > 0 else {
            return sharpUntilMagnification(inBoxWidthPoints: widthPoints)
        }
        let aspect = Double(pixelWidth) / Double(pixelHeight)
        let boxAspect = widthPoints / heightPoints
        let drawnWidth = aspect >= boxAspect ? widthPoints : heightPoints * aspect
        guard drawnWidth > 0 else { return nil }
        return Double(mosaicColumns) / drawnWidth
    }
}

/// Where a stamp field sits inside the stamp box, and how it is drawn.
///
/// The frame is **normalized**: `0...1` across the stamp box in both axes, origin at the
/// box's lower-left. A stamp resized from 96 points wide to 200 keeps its layout, which is
/// what makes one template usable on an A4 detail and an A0 sheet.
public struct StampFieldDefinition: Codable, Hashable, Sendable, Identifiable {

    /// Stable identity inside the template.
    public let id: UUID
    /// Which dynamic field this is.
    public var kind: StampFieldKind
    /// Distinguishes two fields of the same kind on one template.
    public var slot: Int
    /// The question the placement prompt asks, for a ``StampFieldKind/freeText`` field.
    public var prompt: String
    /// A `DateFormatter` template for a ``StampFieldKind/date`` field, for example
    /// `"yyyy-MM-dd"`. Empty means the locale's short date.
    public var dateFormat: String
    /// Text drawn immediately before the resolved value, for example `"Rev. "`.
    public var textPrefix: String
    /// The field's box inside the stamp, normalized to `0...1`.
    public var normalizedFrame: PDFRectValue
    /// Font family name.
    public var fontName: String
    /// Font size as a fraction of the stamp box height, so text scales with the stamp.
    public var fontSizeFraction: Double
    /// Horizontal alignment inside ``normalizedFrame``.
    public var alignment: StampFieldAlignment
    /// Text colour.
    public var colorRGBA: ColorRGBA

    /// Creates a field definition.
    public init(
        id: UUID = UUID(),
        kind: StampFieldKind,
        slot: Int = 0,
        prompt: String = "",
        dateFormat: String = "",
        textPrefix: String = "",
        normalizedFrame: PDFRectValue = PDFRectValue(x: 0.05, y: 0.05, width: 0.9, height: 0.3),
        fontName: String = "Helvetica",
        fontSizeFraction: Double = 0.2,
        alignment: StampFieldAlignment = .leading,
        colorRGBA: ColorRGBA = ColorRGBA(red: 0, green: 0, blue: 0)
    ) {
        self.id = id
        self.kind = kind
        self.slot = slot
        self.prompt = prompt
        self.dateFormat = dateFormat
        self.textPrefix = textPrefix
        self.normalizedFrame = normalizedFrame
        self.fontName = fontName
        self.fontSizeFraction = fontSizeFraction
        self.alignment = alignment
        self.colorRGBA = colorRGBA
    }

    /// A stable key for the field's resolved value.
    public var key: String { slot == 0 ? kind.rawValue : "\(kind.rawValue).\(slot)" }
}

/// Horizontal alignment of a stamp field inside its box.
public enum StampFieldAlignment: String, Codable, Hashable, Sendable, CaseIterable {
    case leading
    case center
    case trailing
}

/// The dynamic content a stamp can carry.
///
/// The presentation-layer twin of `ZPDFContracts.StampFieldKind`.
public enum StampFieldKind: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {

    case date
    case author
    case pageLabel
    case documentName
    case revision
    case projectName
    case freeText

    public var id: String { rawValue }

    /// Whether placing the stamp has to ask the person for this field's text.
    public var isPrompted: Bool { self == .freeText }

    /// A localized name for the field row in the preset editor.
    public var displayName: String {
        switch self {
        case .date: return NSLocalizedString("Date", comment: "Stamp field")
        case .author: return NSLocalizedString("Author", comment: "Stamp field")
        case .pageLabel: return NSLocalizedString("Page label", comment: "Stamp field")
        case .documentName: return NSLocalizedString("Document name", comment: "Stamp field")
        case .revision: return NSLocalizedString("Revision", comment: "Stamp field")
        case .projectName: return NSLocalizedString("Project name", comment: "Stamp field")
        case .freeText: return NSLocalizedString("Free text", comment: "Stamp field")
        }
    }
}

/// A stamp preset's artwork, layout and dynamic fields.
///
/// A template is a *recipe*. Placing it produces a `StampInstance` whose fields are text —
/// see ``resolve(in:)``. Nothing in the product ever re-resolves a placed stamp, and this
/// type deliberately has no method that could: the resolution direction is one-way.
public struct StampTemplate: Codable, Hashable, Sendable, Identifiable {

    /// Stable identity, shared with the preset that owns it.
    public let id: UUID
    /// The template's own revision, bumped whenever the template is edited. A placed stamp
    /// records the revision it was made from, so "this stamp predates the current template"
    /// is answerable.
    public var revision: Int
    /// The stamp box width in PDF points at 100 %.
    public var widthPoints: Double
    /// The stamp box height in PDF points at 100 %.
    public var heightPoints: Double
    /// Rotation about the anchor, in degrees counter-clockwise.
    public var rotationDegrees: Double
    /// The artwork, or `nil` when the stamp is fields and a border only.
    public var artwork: StampArtworkDescriptor?
    /// The dynamic fields, in draw order.
    public var fields: [StampFieldDefinition]

    /// Creates a stamp template.
    public init(
        id: UUID,
        revision: Int = 1,
        widthPoints: Double = 160,
        heightPoints: Double = 60,
        rotationDegrees: Double = 0,
        artwork: StampArtworkDescriptor? = nil,
        fields: [StampFieldDefinition] = []
    ) {
        self.id = id
        self.revision = revision
        self.widthPoints = widthPoints
        self.heightPoints = heightPoints
        self.rotationDegrees = rotationDegrees
        self.artwork = artwork
        self.fields = fields
    }

    /// The artwork's kind, or ``StampArtworkKind/none`` when there is no artwork.
    public var artworkKind: StampArtworkKind { artwork?.kind ?? .none }

    /// Whether this stamp will blur when the estimator magnifies the canvas.
    public var artworkIsRaster: Bool { artworkKind == .raster }

    /// The warning the preset editor shows, or `nil` when there is nothing to warn about.
    ///
    /// A raster-sourced stamp is *marked as such in the editor*, because the user should know
    /// which of their stamps will blur. This is that mark,
    /// and it is derived from the artwork rather than typed in, so it cannot be stale.
    public var rasterSharpnessWarning: String? {
        guard let artwork, artwork.kind == .raster else { return nil }
        // BH-280: the box width comes from a file, and 1e-300 made the magnification infinite;
        // `Int(_:)` then trapped. A figure that is not a plausible percentage is not stated.
        if let magnification = artwork.sharpUntilMagnification(inBoxWidthPoints: widthPoints, heightPoints: heightPoints),
           magnification.isFinite, magnification > 0, magnification * 100 < Double(Int32.max) {
            let format = NSLocalizedString(
                "Image artwork. Sharp to about %d %% magnification, then it resamples. Vector artwork stays sharp at any zoom.",
                comment: "Preset editor warning for a raster-sourced stamp. %d is a magnification percentage"
            )
            return String(format: format, Int((magnification * 100).rounded()))
        }
        return NSLocalizedString(
            "Image artwork. It resamples when the canvas is magnified. Vector artwork stays sharp at any zoom.",
            comment: "Preset editor warning for a raster-sourced stamp of unknown pixel size"
        )
    }

    /// The prompt to show when placing, or `nil` when the stamp asks nothing.
    public var placementPrompt: String? {
        placementPrompts.first?.prompt
    }

    /// Every question placing this stamp asks, one per prompted field, in draw order.
    ///
    /// BH-796: a template with "Checked by" and "Note" asked only the first question and
    /// wrote the answer into both. Each prompted field is asked for its own text, keyed by
    /// its (de-duplicated) slot in ``StampResolutionContext/promptedTexts``.
    public var placementPrompts: [StampPlacementPrompt] {
        normalizedFields.filter { $0.kind.isPrompted }.map { field in
            StampPlacementPrompt(
                slot: field.slot,
                prompt: field.prompt.isEmpty
                    ? NSLocalizedString("Stamp text", comment: "Default prompt for a stamp's free-text field")
                    : field.prompt
            )
        }
    }

    /// The fields with every slot made unique per kind.
    ///
    /// Two `.freeText` fields both left on the default slot 0 shared the key `freeText`, so
    /// the audit trail — a dictionary keyed by field — kept only one of them (BH-795). The
    /// first field of a kind keeps its slot; a later duplicate takes the next free one.
    public var normalizedFields: [StampFieldDefinition] {
        var used: [StampFieldKind: Set<Int>] = [:]
        return fields.map { field in
            var field = field
            var slot = field.slot
            while used[field.kind, default: []].contains(slot) { slot += 1 }
            used[field.kind, default: []].insert(slot)
            field.slot = slot
            return field
        }
    }
}

/// One question the placement prompt asks.
public struct StampPlacementPrompt: Hashable, Sendable {
    /// The prompted field's slot, the key its answer goes under.
    public var slot: Int
    /// The question.
    public var prompt: String

    public init(slot: Int, prompt: String) {
        self.slot = slot
        self.prompt = prompt
    }
}

/// Everything a stamp's dynamic fields resolve against, at the instant of placement.
///
/// A value, with no clock and no environment of its own: `now` is a parameter, the author
/// is a parameter, the page label is a parameter. That is what makes "a stamp that says
/// 2026-08-24 must still say that next year" a testable statement rather than a hope — the
/// test hands in a date from 2026 and reads it back from a stamp resolved in 2027.
public struct StampResolutionContext: Hashable, Sendable {

    /// The instant the stamp is being placed.
    public var now: Date
    /// The local author name.
    public var author: String
    /// The label of the page the stamp is landing on.
    public var pageLabel: String
    /// The document's display name.
    public var documentName: String
    /// The document's active revision name.
    public var revision: String
    /// The project's name.
    public var projectName: String
    /// The text the person supplied at the placement prompt — the answer to the first
    /// question, and the one a single-question prompt fills.
    public var promptedText: String
    /// Answers to further questions, keyed by the prompted field's slot
    /// (``StampTemplate/placementPrompts``). A slot missing here resolves to
    /// ``promptedText`` for the first prompted field and to empty text for the others.
    public var promptedTexts: [Int: String]
    /// The locale the date is formatted in.
    public var localeIdentifier: String
    /// The time zone the date is formatted in.
    public var timeZoneIdentifier: String

    /// Creates a resolution context.
    public init(
        now: Date,
        author: String = "",
        pageLabel: String = "",
        documentName: String = "",
        revision: String = "",
        projectName: String = "",
        promptedText: String = "",
        promptedTexts: [Int: String] = [:],
        localeIdentifier: String = "en_US_POSIX",
        timeZoneIdentifier: String = "UTC"
    ) {
        self.promptedTexts = promptedTexts
        self.now = now
        self.author = author
        self.pageLabel = pageLabel
        self.documentName = documentName
        self.revision = revision
        self.projectName = projectName
        self.promptedText = promptedText
        self.localeIdentifier = localeIdentifier
        self.timeZoneIdentifier = timeZoneIdentifier
    }
}

/// One field, resolved.
public struct ResolvedStampField: Hashable, Sendable {

    /// Which field this was.
    public var kind: StampFieldKind
    /// Which slot of that kind.
    public var slot: Int
    /// The text, prefix included, exactly as it will be drawn and stored.
    public var text: String

    /// Creates a resolved field.
    public init(kind: StampFieldKind, slot: Int, text: String) {
        self.kind = kind
        self.slot = slot
        self.text = text
    }
}

extension StampTemplate {

    /// Resolves every dynamic field against a placement context, once.
    ///
    /// Pure: same template, same context, same output, on any machine, in any year. The
    /// caller freezes the result into the markup; there is no path back from a placed
    /// stamp to this function.
    public func resolve(in context: StampResolutionContext) -> [ResolvedStampField] {
        let normalized = normalizedFields
        let firstPrompted = normalized.first { $0.kind.isPrompted }?.id
        return normalized.map { field in
            var text = Self.value(of: field, in: context)
            if field.kind.isPrompted {
                text = context.promptedTexts[field.slot]
                    ?? (field.id == firstPrompted ? context.promptedText : "")
            }
            return ResolvedStampField(kind: field.kind, slot: field.slot, text: field.textPrefix + text)
        }
    }

    /// The resolved value of one field, without its prefix.
    static func value(of field: StampFieldDefinition, in context: StampResolutionContext) -> String {
        switch field.kind {
        case .date:
            return formattedDate(context.now, format: field.dateFormat, context: context)
        case .author:
            return context.author
        case .pageLabel:
            return context.pageLabel
        case .documentName:
            return context.documentName
        case .revision:
            return context.revision
        case .projectName:
            return context.projectName
        case .freeText:
            return context.promptedText
        }
    }

    /// Formats a date deterministically.
    ///
    /// An explicit `format` is treated as a fixed pattern under the context's locale and
    /// time zone. An empty one falls back to the locale's short date. Both go through the
    /// context's locale and time zone rather than the system's, so a golden test is a test
    /// and not a report on the machine it ran on.
    static func formattedDate(
        _ date: Date,
        format: String,
        context: StampResolutionContext
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: context.localeIdentifier)
        formatter.timeZone = TimeZone(identifier: context.timeZoneIdentifier) ?? TimeZone(secondsFromGMT: 0)
        if format.isEmpty {
            formatter.dateStyle = .short
            formatter.timeStyle = .none
        } else {
            formatter.dateFormat = format
        }
        return formatter.string(from: date)
    }
}
