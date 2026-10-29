import Foundation
import ZPDFContracts
import ZPDFUIPresentation

/// A named count symbol backed by imported artwork — a drain counted with a drain.
///
/// # What this type is
///
/// The `Count Symbols` panel of the Tool Library holds presets whose face is a picture the
/// person imported through the ADR-0011 pipeline: `StampArtworkImporter` compiled it,
/// `ProjectArtworkStore` stored it content-addressed, and the preset carries the
/// ``StampArtworkDescriptor`` — a digest and a description, never bytes. This type is that
/// preset shape, named: creating one, listing them, and recognising one in a library all go
/// through here, so "a custom count symbol" is a definition rather than a convention.
///
/// # Persistence is the Tool Library's
///
/// ``asPreset(sortIndex:)`` produces an ordinary ``ToolPresetSummary`` in the
/// ``ToolLibraryPanel/countSymbols`` panel, which ``ToolPresetScopeRule`` files into the
/// container — so a custom symbol persists exactly like every other preset, through
/// ``ToolPresetContainerStore``, and follows the estimator from job to job.
///
/// # Placement freezes the symbol — this type cannot reach a placed mark
///
/// Invariant: editing a symbol never changes a mark already placed. The mechanism is ADR-0011's:
/// at placement, `CountSymbolCatalogue.symbol(for:)` resolves the preset into a
/// `MarkupSymbol` holding the artwork **digest**, and that value is frozen onto the
/// `MarkupRecord`. Nothing re-reads the preset when a mark is drawn, so editing or deleting a
/// custom symbol cannot rewrite last month's count. `CustomCountSymbolTests` places a mark,
/// re-points the symbol at different artwork, and reads the old digest back off the record.
public struct CustomCountSymbol: Codable, Hashable, Sendable, Identifiable {

    /// Stable identity, shared with the preset that carries the symbol.
    public let id: UUID
    /// The symbol's name — `"Floor Drain"`, `"Smoke Detector"`.
    public var name: String
    /// The imported artwork the symbol draws: a digest into the project's artwork store and
    /// the descriptor around it. Required — a custom symbol without artwork is a built-in
    /// glyph, and those already have a vocabulary of their own.
    public var artwork: StampArtworkDescriptor
    /// Edge of the symbol's square box on the sheet, in PDF points.
    public var sizePoints: Double
    /// The colour count marks made with this symbol are drawn in.
    public var colorRGBA: ColorRGBA
    /// The takeoff subject a count made with this symbol files under.
    public var defaultSubject: String
    /// Where the symbol came from.
    public var provenance: ToolPresetProvenance

    /// Creates a custom count symbol over imported artwork.
    public init(
        id: UUID = UUID(),
        name: String,
        artwork: StampArtworkDescriptor,
        sizePoints: Double = CountSymbolCatalogue.defaultSizePoints,
        colorRGBA: ColorRGBA,
        defaultSubject: String = "",
        provenance: ToolPresetProvenance = ToolPresetProvenance(origin: .createdHere)
    ) {
        self.id = id
        self.name = name
        self.artwork = artwork
        self.sizePoints = sizePoints
        self.colorRGBA = colorRGBA
        self.defaultSubject = defaultSubject
        self.provenance = provenance
    }

    // MARK: - The preset shape

    /// The category custom symbols group under in the panel.
    public static var category: String {
        NSLocalizedString("Custom Symbols", comment: "Category of user-made count symbols")
    }

    /// The symbol as the Tool Library preset it is stored and armed as.
    ///
    /// A Count preset whose `stamp` template carries the artwork in a square box — the shape
    /// `ToolPresetDraft.adoptArtwork` builds when a person imports a picture onto a count
    /// preset in the editor, produced here without a draft in between.
    public func asPreset(sortIndex: Int = 0) -> ToolPresetSummary {
        ToolPresetSummary(
            id: id,
            name: name,
            category: Self.category,
            panel: .countSymbols,
            markupKind: .count,
            measurementKind: .count,
            colorRGBA: colorRGBA,
            defaultSubject: defaultSubject,
            stamp: StampTemplate(
                id: id,
                widthPoints: sizePoints,
                heightPoints: sizePoints,
                artwork: artwork,
                fields: []
            ),
            provenance: provenance,
            sortIndex: sortIndex
        )
    }

    /// Reads a custom count symbol back out of a library preset, or `nil` for a preset that
    /// is not one: wrong panel, not a Count, or no imported artwork on it.
    public init?(preset: ToolPresetSummary) {
        guard preset.panel == .countSymbols,
              preset.measurementKind == .count,
              let stamp = preset.stamp,
              let artwork = stamp.artwork
        else { return nil }
        self.init(
            id: preset.id,
            name: preset.name,
            artwork: artwork,
            sizePoints: stamp.widthPoints > 0
                ? stamp.widthPoints
                : CountSymbolCatalogue.defaultSizePoints,
            colorRGBA: preset.colorRGBA,
            defaultSubject: preset.defaultSubject,
            provenance: preset.provenance
        )
    }

    /// The custom symbols in a library, in library order.
    public static func symbols(in presets: [ToolPresetSummary]) -> [CustomCountSymbol] {
        presets.compactMap(CustomCountSymbol.init(preset:))
    }

    // MARK: - The placed form

    /// The `MarkupSymbol` a placement freezes onto the record, resolved through the same
    /// join every placement uses — ``CountSymbolCatalogue/symbol(for:)`` — so this type and
    /// the placement path cannot disagree about what a symbol becomes.
    public var markupSymbol: MarkupSymbol? {
        CountSymbolCatalogue.symbol(for: asPreset())
    }

    /// Whether magnifying the canvas keeps this symbol's edges crisp.
    ///
    /// True exactly when the artwork is vector — compiled geometry through the ADR-0011
    /// pipeline, where magnification multiplies coordinates and cannot resample. A raster
    /// symbol is accepted and says so, the same honesty the stamp editor keeps.
    public var staysSharpWhenMagnified: Bool { artwork.kind == .vector }
}
