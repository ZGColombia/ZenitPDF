import CoreGraphics
import Foundation
import ZPDFPDFKitBridge

/// Resolves `pdf-text` highlight rectangles through the PDF engine.
///
/// The FTS index knows that page `A-102` contains `ROOM 101`; it does not know where on
/// the sheet, because storing a rectangle per token for a text layer would triple the
/// index for a highlight the user asks for on maybe one hit in fifty. So the rectangles
/// are resolved on demand, by asking the engine to search that one page — which is what
/// ``ZPDFPDFKitBridge/PDFDocumentProviding/search(in:query:options:)`` is for, and reusing
/// it means the highlight a search draws is the same geometry the viewer's own find bar
/// would draw.
///
/// The document map is passed in rather than discovered, because only the caller knows
/// which `document.id` corresponds to which open handle, and this type must not be able to
/// open a file on its own.
public struct PDFKitTextBoundsResolver: SearchTextBoundsResolving {

    private let provider: any PDFDocumentProviding
    private let handles: [String: DocumentHandle]
    private let options: TextSearchOptions
    private let maximumWordsPerPrefix: Int

    /// Distinct whole words one prefix term may expand to on one page (BH-209).
    public static let defaultMaximumWordsPerPrefix = 16

    /// - Parameters:
    ///   - provider: the engine holding the documents open.
    ///   - handles: `document.id` to open handle. A hit in a document that is not in the
    ///     map resolves to no rectangles rather than to an error: a result list must not
    ///     fail because one of its documents happens to be closed.
    ///   - options: how the per-page search compares. The defaults match the FTS
    ///     tokeniser's own behaviour — case-insensitive and diacritic-insensitive — so a
    ///     hit the index found does not fail to highlight. Whole-word matching is applied
    ///     to every term whatever `options` says (BH-207): the index only ever matches
    ///     whole tokens, so a substring box around `ROOM` inside `BATHROOM` is never a
    ///     rectangle the hit is about.
    ///   - maximumWordsPerPrefix: how many distinct whole words one prefix term expands
    ///     to on one page, each costing one engine search. The first keystroke of a
    ///     find-as-you-type query (`1` on a dimensioned sheet) would otherwise fan out to
    ///     hundreds of page searches per hit (BH-209). Words are taken in page order.
    public init(
        provider: any PDFDocumentProviding,
        handles: [String: DocumentHandle],
        options: TextSearchOptions = TextSearchOptions(
            isCaseInsensitive: true,
            isDiacriticInsensitive: true,
            matchesWholeWordsOnly: true,
            excerptContextLength: 0
        ),
        maximumWordsPerPrefix: Int = PDFKitTextBoundsResolver.defaultMaximumWordsPerPrefix
    ) {
        self.provider = provider
        self.handles = handles
        self.options = options
        self.maximumWordsPerPrefix = max(1, maximumWordsPerPrefix)
    }

    public func textBounds(
        documentId: String,
        pageIndex: Int,
        terms: [SearchBoundsTerm]
    ) async -> [CGRect] {
        guard let handle = handles[documentId], !terms.isEmpty else { return [] }
        var pageOptions = options
        pageOptions.pageIndices = [pageIndex]
        // BH-207: the FTS index matched whole tokens, so the highlight does too.
        pageOptions.matchesWholeWordsOnly = true

        // The page's own text, read at most once and only when a prefix term needs it.
        var pageText: String??

        var rectangles: [CGRect] = []
        var seenRectangles: Set<RectangleKey> = []
        // One engine search per distinct literal per page, across all terms.
        var searchedLiterals: Set<String> = []
        for term in terms {
            let trimmed = term.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            // A case-sensitive hit is boxed only where the page has the typed case (W-081).
            var termOptions = pageOptions
            if term.isCaseSensitive { termOptions.isCaseInsensitive = false }

            var literals = [trimmed]
            if term.isPrefix {
                if pageText == nil {
                    pageText = try? await provider.pageText(of: handle, pageIndex: pageIndex).string
                }
                // CR-140: a prefix is a word the user has not finished typing, so the
                // highlight belongs on the whole word. Searching the typed glyphs put a
                // box around `ROO` inside `ROOM`, which reads as a rendering fault
                // rather than as a match. The whole words are taken from the page's own
                // text, and each is then searched as a word so the rectangles come from
                // the same engine path every other highlight uses.
                //
                // BH-208: when nothing on the page completes the prefix there is nothing
                // to box. The old fallback searched the typed glyphs as a substring and
                // drew exactly the partial-glyph box CR-140 removed.
                literals = Self.wholeWords(
                    startingWith: trimmed,
                    in: (pageText ?? nil) ?? "",
                    limit: maximumWordsPerPrefix,
                    foldsCase: termOptions.isCaseInsensitive,
                    foldsDiacritics: termOptions.isDiacriticInsensitive
                )
            }

            for literal in literals {
                let key = Self.literalKey(
                    literal,
                    foldsCase: termOptions.isCaseInsensitive,
                    foldsDiacritics: termOptions.isDiacriticInsensitive
                )
                guard searchedLiterals.insert(key).inserted else { continue }
                // A failure here is not a search failure. A document that is locked,
                // damaged, or whose engine raised is a document with no highlight, and
                // the hit is still a hit — it is in the index because its text was read
                // at index time.
                guard let results = try? await provider.search(
                    in: handle,
                    query: literal,
                    options: termOptions
                ) else { continue }
                for hit in results.hits where hit.pageIndex == pageIndex {
                    for rect in hit.lineRects.isEmpty ? [hit.bounds] : hit.lineRects
                    where seenRectangles.insert(RectangleKey(rect)).inserted {
                        rectangles.append(rect)
                    }
                }
            }
        }
        return rectangles
    }

    /// Exact identity of a rectangle, so one occurrence reached through two literals is
    /// drawn once (BH-647): a translucent highlight drawn twice reads as a darker box.
    private struct RectangleKey: Hashable {
        let x, y, width, height: Double
        init(_ rect: CGRect) {
            x = Double(rect.origin.x)
            y = Double(rect.origin.y)
            width = Double(rect.size.width)
            height = Double(rect.size.height)
        }
    }

    /// The key two literals share when the engine search would treat them as the same.
    static func literalKey(_ literal: String, foldsCase: Bool, foldsDiacritics: Bool) -> String {
        var options: String.CompareOptions = [.widthInsensitive]
        if foldsCase { options.insert(.caseInsensitive) }
        if foldsDiacritics { options.insert(.diacriticInsensitive) }
        return literal.folding(options: options, locale: nil)
    }

    /// The distinct whole words of `text` that begin with `prefix`.
    ///
    /// A "word" is a run of the FTS tokeniser's own tokens, so the word the highlight
    /// covers is the word the index matched. A prefix of one token (`ROO`) matches one
    /// page token that starts with it; a punctuated prefix (`A-10`, `3.5`) is several
    /// tokens, and matches where the page has the same leading tokens followed by one
    /// that starts with the last — the way FTS5 matched `"A 10"*` — and the word is the
    /// page's own text from the first token to the end of the last, `A-102` (BH-208).
    ///
    /// Comparison folds case and diacritics through the same normaliser the index was
    /// written with, so `ROO` finds `Room` and `RÖO` finds `RÖOM` — except that with
    /// `foldsCase` off (a case-sensitive search, W-081) case is kept, so `ROO` finds `ROOM`
    /// and not `Room`. Words that differ only in what the engine search folds anyway are
    /// returned once (BH-647), and at most `limit` words are returned, in page order (BH-209).
    static func wholeWords(
        startingWith prefix: String,
        in text: String,
        limit: Int = .max,
        foldsCase: Bool = true,
        foldsDiacritics: Bool = true
    ) -> [String] {
        func fold(_ text: String) -> String {
            foldsCase ? ZPDFTextNormalizer.folded(text) : ZPDFTextNormalizer.caseKept(text)
        }
        let wanted = ZPDFTextNormalizer.tokens(in: prefix).map(fold)
        guard !wanted.isEmpty, limit > 0 else { return [] }

        // The page's tokens with their ranges in `text`, so a multi-token word can be cut
        // out of the page verbatim, separators and all.
        var spans: [(folded: String, range: Range<String.Index>)] = []
        var start: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let isToken = text[index].unicodeScalars.contains(where: ZPDFTextNormalizer.isTokenScalar)
            if isToken {
                if start == nil { start = index }
            } else if let from = start {
                spans.append((fold(String(text[from..<index])), from..<index))
                start = nil
            }
            index = text.index(after: index)
        }
        if let from = start {
            spans.append((fold(String(text[from..<text.endIndex])), from..<text.endIndex))
        }

        let width = wanted.count
        var found: [String] = []
        var seen: Set<String> = []
        guard spans.count >= width else { return [] }
        for first in 0...(spans.count - width) {
            var matches = true
            for offset in 0..<width {
                let actual = spans[first + offset].folded
                let expected = wanted[offset]
                let isLast = offset == width - 1
                if isLast ? !actual.hasPrefix(expected) : actual != expected {
                    matches = false
                    break
                }
            }
            guard matches else { continue }
            let word = String(text[spans[first].range.lowerBound..<spans[first + width - 1].range.upperBound])
            guard seen.insert(literalKey(word, foldsCase: foldsCase, foldsDiacritics: foldsDiacritics)).inserted
            else { continue }
            found.append(word)
            if found.count >= limit { break }
        }
        return found
    }
}
