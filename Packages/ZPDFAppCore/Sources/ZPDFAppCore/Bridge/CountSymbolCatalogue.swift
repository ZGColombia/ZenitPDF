import Foundation
import ZPDFContracts
import ZPDFUIPresentation

/// The one table that joins the symbol a person **picks** to the glyph the renderer **draws**
/// (spec 12.13, ADR-0011 §2.1).
///
/// # Why a catalogue and not a cast
///
/// Two vocabularies met here and neither could be deleted. The preset editor picks from a fixed
/// list of system symbol names, because a picker has to show a picture and the platform's own
/// symbols are the pictures Zenit does not have to draw. The renderer names its glyphs
/// `filledCircle`, `cross`, `star` — geometry it rasterises itself into `SymbolAtlas`, with no
/// system symbol anywhere in it — and `MarkupSymbol.builtInGlyph` stores *that* name, because a
/// mark placed today has to draw the same next year on a machine whose SF Symbols set has moved
/// on.
///
/// So the join is a table, it is a bijection, and it is stated once. Before this file the two
/// lists existed and nothing connected them: a preset's Count symbol was a picture in a menu and
/// the canvas drew a hard-coded 8 × 8 oval whatever the preset said.
///
/// # Unknown names are drawn, not dropped
///
/// A tool set imported from another machine can name a symbol this build has never heard of.
/// ``glyphName(forSymbolNamed:)`` answers `nil` for it and ``symbol(for:)`` falls back to the
/// default glyph, because a count mark that draws *something* is a visible count and a mark that
/// draws nothing is a quantity the estimator will not notice is missing. The same rule
/// `ImportedArtworkScene.markups(symbol:artwork:…)` keeps at the renderer.
public enum CountSymbolCatalogue {

    /// One row of the table.
    public struct Entry: Hashable, Sendable, Identifiable {

        /// The system symbol name the preset stores and the picker shows.
        public let symbolName: String
        /// The renderer's stable glyph name, which is what a ``MarkupSymbol`` carries.
        public let glyphName: String
        /// The spoken, localized name, so a symbol is never a picture with no word attached.
        public let displayName: String

        /// Stable identity: the stored name.
        public var id: String { symbolName }

        /// Creates a row.
        public init(symbolName: String, glyphName: String, displayName: String) {
            self.symbolName = symbolName
            self.glyphName = glyphName
            self.displayName = displayName
        }
    }

    /// The glyph a count mark falls back to: a plain filled circle.
    ///
    /// Named rather than absent, for ADR-0011 §2.1's reason — "a plain filled circle" is a
    /// decision, and a decision spelled as `nil` is one every consumer has to re-interpret.
    public static let defaultGlyphName = "filledCircle"

    /// The edge of a count mark's box, in PDF points, when the preset does not say.
    ///
    /// Twelve, which is the size `ImportedArtworkScene` falls back to for an unusable one, so
    /// the mark the canvas draws and the mark the renderer draws are the same size by
    /// construction rather than by coincidence.
    public static let defaultSizePoints: Double = 12

    /// The table, in the order the picker offers it.
    ///
    /// Ten rows for the renderer's ten glyphs: every glyph is reachable and no glyph is
    /// reachable twice. That is asserted rather than assumed —
    /// `CountSymbolCatalogueTests.everyGlyphNameIsAGlyphTheRendererKnows` resolves each
    /// ``Entry/glyphName`` through the renderer's own `CountSymbol(name:)`, in the one test
    /// target that links both packages.
    public static let entries: [Entry] = [
        Entry(
            symbolName: "circle.fill",
            glyphName: "filledCircle",
            displayName: NSLocalizedString("Filled circle", comment: "Count symbol name")
        ),
        Entry(
            symbolName: "circle",
            glyphName: "hollowCircle",
            displayName: NSLocalizedString("Circle", comment: "Count symbol name")
        ),
        Entry(
            symbolName: "square.fill",
            glyphName: "filledSquare",
            displayName: NSLocalizedString("Filled square", comment: "Count symbol name")
        ),
        Entry(
            symbolName: "square",
            glyphName: "hollowSquare",
            displayName: NSLocalizedString("Square", comment: "Count symbol name")
        ),
        Entry(
            symbolName: "triangle.fill",
            glyphName: "filledTriangle",
            displayName: NSLocalizedString("Filled triangle", comment: "Count symbol name")
        ),
        Entry(
            symbolName: "triangle",
            glyphName: "hollowTriangle",
            displayName: NSLocalizedString("Triangle", comment: "Count symbol name")
        ),
        Entry(
            symbolName: "diamond.fill",
            glyphName: "filledDiamond",
            displayName: NSLocalizedString("Diamond", comment: "Count symbol name")
        ),
        Entry(
            symbolName: "xmark",
            glyphName: "cross",
            displayName: NSLocalizedString("Cross", comment: "Count symbol name")
        ),
        Entry(
            symbolName: "plus",
            glyphName: "plus",
            displayName: NSLocalizedString("Plus", comment: "Count symbol name")
        ),
        Entry(
            symbolName: "star.fill",
            glyphName: "star",
            displayName: NSLocalizedString("Star", comment: "Count symbol name")
        )
    ]

    /// Symbol names earlier builds offered, and the glyph each of them now means.
    ///
    /// The picker used to offer `diamond` and `hexagon`; the table above offers `diamond.fill`
    /// and `star.fill`, because the renderer has a filled diamond and a star and has never had a
    /// hexagon. A preset saved with an old name is a preset a person made, so it keeps drawing —
    /// the alias is read and never written, exactly as ``ToolPresetSummary``'s legacy depth keys
    /// are.
    public static let legacySymbolNames: [String: String] = [
        "diamond": "filledDiamond",
        "hexagon": "star"
    ]

    /// The system symbol names a preset may store, in picker order.
    public static var symbolNames: [String] { entries.map(\.symbolName) }

    /// The renderer glyph a stored symbol name means, or `nil` for a name this build does not
    /// know.
    public static func glyphName(forSymbolNamed name: String) -> String? {
        entries.first { $0.symbolName == name }?.glyphName ?? legacySymbolNames[name]
    }

    /// The system symbol name for a renderer glyph, or `nil`.
    public static func symbolName(forGlyphNamed glyph: String) -> String? {
        entries.first { $0.glyphName == glyph }?.symbolName
    }

    /// The localized name of a stored symbol, for VoiceOver and the picker's menu.
    public static func displayName(forSymbolNamed name: String) -> String? {
        entries.first { $0.symbolName == name }?.displayName
    }

    /// The symbol a preset gives every count mark made with it, or `nil` when the preset does
    /// not carry one.
    ///
    /// `nil` for a preset with no chosen symbol, so a count made with a plain tool keeps the
    /// record's `symbol` empty and the canvas keeps its historical dot. A preset that *does*
    /// name a symbol always produces one, even when the name is unknown to this build.
    public static func symbol(for preset: ToolPresetSummary) -> MarkupSymbol? {
        // Imported artwork wins over a glyph. A person who went and chose a picture for their
        // door count meant the picture; the glyph is what the preset falls back to, and both
        // are references — the mark stores a digest and a size, never bytes (ADR-0011 §2.1).
        if let template = preset.stamp, let artwork = template.artwork {
            return MarkupSymbol(
                artworkDigest: artwork.digest,
                kind: ZPDFContracts.StampArtworkKind(rawValue: artwork.kind.rawValue) ?? .none,
                builtInGlyph: preset.countSymbolName.flatMap(glyphName(forSymbolNamed:))
                    ?? defaultGlyphName,
                sizePoints: template.widthPoints > 0 ? template.widthPoints : defaultSizePoints,
                sourceName: artwork.sourceName
            )
        }
        guard let name = preset.countSymbolName, !name.isEmpty else { return nil }
        return MarkupSymbol.builtIn(
            glyphName(forSymbolNamed: name) ?? defaultGlyphName,
            sizePoints: defaultSizePoints
        )
    }

    /// The `tool_preset.symbol_data` payload for a preset, or `nil` when it has no symbol and
    /// no artwork.
    ///
    /// The column's documented job (ADR-0011 §2.3): a **descriptor**, never bytes. A count
    /// preset contributes its glyph; a stamp preset contributes the artwork it points at and
    /// the box it proposes.
    public static func payload(for preset: ToolPresetSummary) -> ToolPresetSymbolDescriptor? {
        if let stamp = preset.stamp, let artwork = stamp.artwork {
            return ToolPresetSymbolDescriptor(
                artworkDigest: artwork.digest,
                artworkKind: artwork.kind.rawValue,
                builtInGlyph: nil,
                sourceName: artwork.sourceName,
                sourcePageIndex: artwork.sourcePageIndex,
                pixelWidth: artwork.pixelWidth,
                pixelHeight: artwork.pixelHeight,
                byteCount: artwork.byteCount,
                boxWidthPoints: stamp.widthPoints,
                boxHeightPoints: stamp.heightPoints
            )
        }
        guard let symbol = symbol(for: preset) else { return nil }
        return ToolPresetSymbolDescriptor(
            artworkDigest: nil,
            artworkKind: symbol.kind.rawValue,
            builtInGlyph: symbol.builtInGlyph,
            sourceName: "",
            sourcePageIndex: nil,
            pixelWidth: nil,
            pixelHeight: nil,
            byteCount: 0,
            boxWidthPoints: symbol.sizePoints,
            boxHeightPoints: symbol.sizePoints
        )
    }
}

/// What `tool_preset.symbol_data` holds, in the vocabulary this tier speaks.
///
/// The one definition of that column's JSON (V-096): ``ToolPresetArchive`` writes it from
/// ``CountSymbolCatalogue/payload(for:)`` and decodes it as this type, and
/// `CountSymbolAndSkipReportTests.thePresetsSymbolRoundTripsThroughSymbolData` holds the round
/// trip. The persistence tier keeps `symbol_data` as opaque bytes.
public struct ToolPresetSymbolDescriptor: Codable, Hashable, Sendable {

    /// SHA-256 of the artwork in the project's store, or `nil` for a built-in glyph.
    public var artworkDigest: String?
    /// `vector`, `raster` or `none`.
    public var artworkKind: String
    /// The built-in glyph's name, when there is no imported artwork.
    public var builtInGlyph: String?
    /// The file the artwork came from.
    public var sourceName: String
    /// The page of that file, for vector artwork.
    public var sourcePageIndex: Int?
    /// Pixel width of a raster source.
    public var pixelWidth: Int?
    /// Pixel height of a raster source.
    public var pixelHeight: Int?
    /// Size of the stored bytes.
    public var byteCount: Int
    /// The box the preset proposes, in PDF points.
    public var boxWidthPoints: Double
    /// The box height the preset proposes, in PDF points.
    public var boxHeightPoints: Double

    /// Creates a descriptor.
    public init(
        artworkDigest: String? = nil,
        artworkKind: String,
        builtInGlyph: String? = nil,
        sourceName: String = "",
        sourcePageIndex: Int? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        byteCount: Int = 0,
        boxWidthPoints: Double = 96,
        boxHeightPoints: Double = 48
    ) {
        self.artworkDigest = artworkDigest
        self.artworkKind = artworkKind
        self.builtInGlyph = builtInGlyph
        self.sourceName = sourceName
        self.sourcePageIndex = sourcePageIndex
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.byteCount = byteCount
        self.boxWidthPoints = boxWidthPoints
        self.boxHeightPoints = boxHeightPoints
    }

    /// The presentation-tier artwork descriptor this payload names, or `nil` for a glyph.
    public var artworkDescriptor: StampArtworkDescriptor? {
        guard let artworkDigest else { return nil }
        return StampArtworkDescriptor(
            kind: ZPDFUIPresentation.StampArtworkKind(rawValue: artworkKind) ?? .none,
            digest: artworkDigest,
            byteCount: byteCount,
            sourceName: sourceName,
            sourcePageIndex: sourcePageIndex,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
    }
}
