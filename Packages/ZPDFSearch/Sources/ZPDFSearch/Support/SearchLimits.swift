import Foundation

/// Every ceiling this package enforces, in one place.
///
/// A query string is typed by a user but pasted from anywhere; a PDF's text layer is
/// written by someone else entirely. Each field below turns an unbounded loop or
/// allocation into a bounded one, and each is configurable because a takeoff project is
/// a 1 000-sheet set, not a memo.
public struct SearchLimits: Sendable, Hashable {

    /// Characters of a raw query string considered. Longer input is truncated, not
    /// refused: a truncated search is a usable answer, a thrown error is not.
    public var maximumQueryCharacters: Int
    /// Terms compiled out of one query. Extra terms are dropped.
    public var maximumQueryTerms: Int
    /// Tokens inside one quoted phrase.
    public var maximumPhraseTokens: Int
    /// Characters of a single token. A 10 000-character "word" is not a word.
    public var maximumTermCharacters: Int

    /// Hits one search may return before it stops early.
    public var maximumHits: Int
    /// Characters of the snippet FTS5 builds around a hit.
    public var snippetTokenCount: Int

    /// Characters of one page's text written into the index.
    public var maximumIndexedCharactersPerPage: Int
    /// `ocr_token` rows written for one page.
    public var maximumOCRTokensPerPage: Int
    /// Pages one OCR run may process.
    public var maximumOCRPages: Int
    /// `ocr_token` rows read back when resolving highlight bounds for one hit.
    public var maximumBoundsTokensPerHit: Int

    public init(
        maximumQueryCharacters: Int = 1024,
        maximumQueryTerms: Int = 64,
        maximumPhraseTokens: Int = 32,
        maximumTermCharacters: Int = 128,
        maximumHits: Int = 2000,
        snippetTokenCount: Int = 16,
        maximumIndexedCharactersPerPage: Int = 4_000_000,
        maximumOCRTokensPerPage: Int = 20_000,
        maximumOCRPages: Int = 20_000,
        maximumBoundsTokensPerHit: Int = 512
    ) {
        self.maximumQueryCharacters = max(1, maximumQueryCharacters)
        self.maximumQueryTerms = max(1, maximumQueryTerms)
        self.maximumPhraseTokens = max(1, maximumPhraseTokens)
        self.maximumTermCharacters = max(1, maximumTermCharacters)
        self.maximumHits = max(1, maximumHits)
        // FTS5 rejects a snippet token count outside 1...64.
        self.snippetTokenCount = min(64, max(1, snippetTokenCount))
        self.maximumIndexedCharactersPerPage = max(1, maximumIndexedCharactersPerPage)
        self.maximumOCRTokensPerPage = max(1, maximumOCRTokensPerPage)
        self.maximumOCRPages = max(1, maximumOCRPages)
        self.maximumBoundsTokensPerHit = max(1, maximumBoundsTokensPerHit)
    }

    /// The shipping defaults.
    public static let standard = SearchLimits()
}
