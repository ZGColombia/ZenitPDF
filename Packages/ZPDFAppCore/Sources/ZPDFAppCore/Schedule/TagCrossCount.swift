import Foundation
import ZPDFContracts
import ZPDFUIPresentation

/// Two independent counts that must agree (NL-AUTO-23): the symbols the matcher found, and the
/// designation tags printed on the sheet.
///
/// A count that quietly missed four doors usually still has the four "D-12" tags beside them.
/// Counting the tags as text and pairing each with the nearest found symbol costs almost nothing
/// and catches exactly that: an orphan tag is a symbol the matcher did not find (or a tag without
/// a symbol, which a person can see at a glance), an untagged symbol is a match with no label.
public struct TagCrossCount: Sendable, Hashable {
    public let symbolCount: Int
    public let tagCount: Int
    /// Tags with no found symbol within the pairing distance, centre points.
    public let orphanTags: [PDFRectValue]
    /// Found symbols with no tag within the pairing distance.
    public let untaggedSymbols: [PDFPoint]

    public var agrees: Bool { symbolCount == tagCount && orphanTags.isEmpty && untaggedSymbols.isEmpty }

    /// Counts `designation` tags in `lines` and pairs them one to one with `symbols`, nearest
    /// first, within `maximumDistance` page points.
    public static func count(
        designation: String,
        lines: [RecognisedTextLine],
        symbols: [PDFPoint],
        maximumDistance: Double
    ) -> TagCrossCount {
        let wanted = normalise(designation)
        guard !wanted.isEmpty else {
            return TagCrossCount(symbolCount: symbols.count, tagCount: 0, orphanTags: [], untaggedSymbols: symbols)
        }
        var tags: [PDFRectValue] = []
        for line in BaselineLineMerger.merge(lines) {
            guard let bounds = line.boundsInPageSpace else { continue }
            let words = line.text.split(whereSeparator: \.isWhitespace).map { normalise(String($0)) }
            let occurrences = words.filter { $0 == wanted }.count + (words.count > 1 && normalise(line.text) == wanted ? 1 : 0)
            for _ in 0..<occurrences { tags.append(bounds) }
        }
        // All pairs within reach, shortest first; each tag and each symbol used once.
        var pairs: [(distance: Double, tag: Int, symbol: Int)] = []
        for (t, tag) in tags.enumerated() {
            for (s, symbol) in symbols.enumerated() {
                let d = NearbyDesignationSuggester.distance(from: symbol, to: tag)
                if d <= maximumDistance { pairs.append((d, t, s)) }
            }
        }
        pairs.sort { $0.distance != $1.distance ? $0.distance < $1.distance : ($0.tag, $0.symbol) < ($1.tag, $1.symbol) }
        var usedTags = Set<Int>(), usedSymbols = Set<Int>()
        for pair in pairs where !usedTags.contains(pair.tag) && !usedSymbols.contains(pair.symbol) {
            usedTags.insert(pair.tag)
            usedSymbols.insert(pair.symbol)
        }
        return TagCrossCount(
            symbolCount: symbols.count,
            tagCount: tags.count,
            orphanTags: tags.indices.filter { !usedTags.contains($0) }.map { tags[$0] },
            untaggedSymbols: symbols.indices.filter { !usedSymbols.contains($0) }.map { symbols[$0] }
        )
    }

    /// Upper-cased, hyphen variants and spaces removed: "D-12", "d‑12" and "D 12" are one tag.
    static func normalise(_ text: String) -> String {
        text.uppercased().filter { !$0.isWhitespace && !"-\u{2010}\u{2011}\u{2012}\u{2013}".contains($0) }
    }
}
