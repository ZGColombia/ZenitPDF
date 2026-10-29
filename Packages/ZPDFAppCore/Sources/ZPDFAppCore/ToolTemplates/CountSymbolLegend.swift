import Foundation
import ZPDFContracts
import ZPDFUIPresentation

/// One row of the Quantity Ledger's count-symbol legend: this subject is counted with this
/// symbol, this many times.
///
/// The ledger's legend shows the symbol each subject is counted with. The ledger's *view* lives
/// in the app tier; this is the presenter-level data it renders — name, digest, glyph and
/// count per subject — derived from the placed marks themselves rather than from the preset
/// library, because the marks are the record. A symbol whose preset was deleted last week
/// still appears here, under the digest it was placed with, which is exactly the property
/// ADR-0011 froze into `MarkupSymbol`.
public struct CountSymbolLegendEntry: Hashable, Sendable, Identifiable {

    /// The takeoff subject the counts file under. Empty when the marks carry none.
    public let subject: String
    /// The symbol's spoken name: the artwork's source file for an imported symbol, the
    /// glyph's localized name for a built-in, so the legend is never a picture with no word.
    public let symbolDisplayName: String
    /// SHA-256 of the imported artwork the marks reference, or `nil` for a built-in glyph.
    public let artworkDigest: String?
    /// The renderer's glyph name, when the marks draw a built-in glyph.
    public let builtInGlyph: String?
    /// Whether the symbol keeps crisp edges when magnified — vector artwork and every
    /// built-in glyph do; a raster symbol does not, and the legend can say so.
    public let staysSharpWhenMagnified: Bool
    /// How many marks this subject-and-symbol pair has on the sheets.
    public let markCount: Int

    /// Stable identity: the subject and the symbol reference — the digest *and* the glyph when
    /// the marks carry artwork, because the grouping keeps both. One artwork placed under two
    /// glyph names is two rows, and they used to share one id, which gave the ledger's list
    /// duplicate identities (BH-463).
    public var id: String {
        if let artworkDigest { return "\(subject)|\(artworkDigest)|\(builtInGlyph ?? "")" }
        return "\(subject)|\(builtInGlyph ?? "dot")"
    }

    /// Creates a legend entry.
    public init(
        subject: String,
        symbolDisplayName: String,
        artworkDigest: String?,
        builtInGlyph: String?,
        staysSharpWhenMagnified: Bool,
        markCount: Int
    ) {
        self.subject = subject
        self.symbolDisplayName = symbolDisplayName
        self.artworkDigest = artworkDigest
        self.builtInGlyph = builtInGlyph
        self.staysSharpWhenMagnified = staysSharpWhenMagnified
        self.markCount = markCount
    }
}

/// Builds the legend from the takeoff's markups.
public enum CountSymbolLegend {

    /// The legend entries for a set of markups, deterministically ordered: by subject, then
    /// by symbol name, then by reference — so two rebuilds over one takeoff are one legend.
    ///
    /// Only count marks contribute. A count mark with no symbol is the canvas's plain dot,
    /// listed under the default glyph's name rather than dropped: a quantity with no legend
    /// row is a quantity the estimator cannot check.
    public static func entries(markups: [MarkupRecord]) -> [CountSymbolLegendEntry] {
        struct Key: Hashable {
            var subject: String
            var digest: String?
            var glyph: String?
        }
        var counts: [Key: Int] = [:]
        var samples: [Key: MarkupSymbol] = [:]
        for record in markups where record.kind == .count || record.tool == .count {
            let symbol = record.symbol ?? MarkupSymbol.builtIn(CountSymbolCatalogue.defaultGlyphName)
            let key = Key(
                subject: record.subject,
                digest: symbol.artworkDigest,
                glyph: symbol.artworkDigest == nil
                    ? (symbol.builtInGlyph ?? CountSymbolCatalogue.defaultGlyphName)
                    : symbol.builtInGlyph
            )
            // A Count commit is one record holding every clicked mark, so a record counts for its
            // marks, not for one: forty clicks read "×1" beside a ledger row of forty (BH-015).
            counts[key, default: 0] += markCount(of: record)
            if samples[key] == nil { samples[key] = symbol }
        }
        return counts
            .map { key, count -> CountSymbolLegendEntry in
                let symbol = samples[key] ?? MarkupSymbol.builtIn(CountSymbolCatalogue.defaultGlyphName)
                return CountSymbolLegendEntry(
                    subject: key.subject,
                    symbolDisplayName: displayName(for: symbol),
                    artworkDigest: key.digest,
                    builtInGlyph: key.glyph,
                    staysSharpWhenMagnified: symbol.artworkDigest == nil
                        || symbol.staysSharpWhenMagnified,
                    markCount: count
                )
            }
            .sorted {
                ($0.subject, $0.symbolDisplayName, $0.artworkDigest ?? "", $0.builtInGlyph ?? "")
                    < ($1.subject, $1.symbolDisplayName, $1.artworkDigest ?? "", $1.builtInGlyph ?? "")
            }
    }

    /// How many marks one count record holds: its count points, or the placed point of a
    /// Place-mode mark, and never fewer than one.
    static func markCount(of record: MarkupRecord) -> Int {
        guard let geometry = record.geometry else { return 1 }
        if !geometry.countPoints.isEmpty { return geometry.countPoints.count }
        return max(1, geometry.points.count)
    }

    /// The spoken name of a placed symbol.
    ///
    /// Imported artwork is named by its source file, kept verbatim on the mark for exactly
    /// this purpose; a built-in glyph resolves through ``CountSymbolCatalogue`` to the name
    /// the picker showed. A glyph the catalogue no longer lists keeps its stored name — an
    /// honest identifier beats a wrong translation.
    static func displayName(for symbol: MarkupSymbol) -> String {
        if symbol.artworkDigest != nil, !symbol.sourceName.isEmpty {
            return symbol.sourceName
        }
        if symbol.artworkDigest != nil {
            return NSLocalizedString(
                "Imported symbol", comment: "Legend name for artwork whose source name is unknown"
            )
        }
        let glyph = symbol.builtInGlyph ?? CountSymbolCatalogue.defaultGlyphName
        if let symbolName = CountSymbolCatalogue.symbolName(forGlyphNamed: glyph),
           let display = CountSymbolCatalogue.displayName(forSymbolNamed: symbolName) {
            return display
        }
        return glyph
    }
}
