import Foundation

/// What the indexer does to a page's text before it reaches FTS5.
public struct TextNormalizationOptions: Sendable, Hashable {

    /// Expand compatibility forms: the `ﬁ` ligature becomes `fi`, `№` becomes `No`,
    /// fullwidth digits become ASCII digits.
    ///
    /// Type-1 fonts in CAD title blocks emit ligatures constantly, and PDFKit hands them
    /// back as the single code point they are. Without this, `PROFILE` typeset with an
    /// `ﬁ` ligature is unfindable by anybody typing `profile`.
    public var expandsCompatibilityForms: Bool

    /// Join a word broken across a line break by a hyphen: `COR-\nRIDOR` becomes
    /// `CORRIDOR`.
    ///
    /// Only a hyphen that sits between two letters and is immediately followed by a line
    /// break is removed. A hyphen inside `A-102` keeps its line, because the sheet number
    /// `A-102` is the single most searched string in a construction set and turning it
    /// into `A102` would destroy it.
    public var joinsHyphenationAcrossLineBreaks: Bool

    /// Collapse every run of whitespace to a single space, and drop control characters.
    ///
    /// PDF text extraction produces column-aligned padding, vertical tabs and stray
    /// `\r`; none of it survives tokenisation anyway, and keeping it makes snippets
    /// unreadable.
    public var collapsesWhitespace: Bool

    public init(
        expandsCompatibilityForms: Bool = true,
        joinsHyphenationAcrossLineBreaks: Bool = true,
        collapsesWhitespace: Bool = true
    ) {
        self.expandsCompatibilityForms = expandsCompatibilityForms
        self.joinsHyphenationAcrossLineBreaks = joinsHyphenationAcrossLineBreaks
        self.collapsesWhitespace = collapsesWhitespace
    }

    public static let standard = TextNormalizationOptions()
}

/// The one place text is folded, in this package and for anything that indexes into it.
///
/// ### Why there are two different foldings
///
/// The FTS5 table is declared `tokenize='unicode61 remove_diacritics 2'`, so SQLite folds
/// case and strips diacritics **on both sides of a match, by itself**. Storing text that
/// has already been case-folded would therefore buy nothing and cost the snippet: a hit
/// list showing `room 101` where the sheet says `ROOM 101` looks like a bug. So
/// ``indexable(_:options:)`` fixes what SQLite *cannot* fix — ligatures, hyphenation
/// across a line break, control characters — and leaves case and diacritics alone.
///
/// ``folded(_:)`` is the aggressive one, and it exists for exactly one job: the
/// `ocr_token.normalized_token` column, which this package both writes and reads. Its
/// contract is internal consistency with itself, not byte-parity with `unicode61`. It may
/// fold slightly more than SQLite does (`Æ` to `ae`, for instance); the consequence is a
/// highlight rectangle drawn around a token SQLite would not have matched, never a
/// missing hit.
public enum ZPDFTextNormalizer {

    // MARK: - Indexable text

    /// Normalises a page's raw extracted text into the form written to `search_fts.content`.
    public static func indexable(
        _ raw: String,
        options: TextNormalizationOptions = .standard
    ) -> String {
        var text = raw

        if options.expandsCompatibilityForms {
            // NFKC, not NFKD: compatibility decomposition expands the ligature, canonical
            // recomposition puts `e` + combining acute back together as `é` so the
            // character count stays sane and the snippet renders as the sheet reads.
            text = text.precomposedStringWithCompatibilityMapping
        }

        if options.joinsHyphenationAcrossLineBreaks {
            text = joinHyphenation(text)
        }

        if options.collapsesWhitespace {
            text = collapseWhitespace(text)
        }

        return text
    }

    /// Removes a hyphen that only exists because the line ran out.
    ///
    /// The rule is deliberately narrow: `letter`, `hyphen`, optional spaces, `line break`,
    /// optional spaces, `letter`. Everything else — `A-102`, an em dash, a hyphen at the
    /// end of the last line — is left exactly as it was.
    private static func joinHyphenation(_ text: String) -> String {
        // Soft hyphen and Unicode hyphen count as hyphens here; a minus sign and the
        // dashes do not, because nobody breaks a word with an em dash.
        let hyphens: Set<Character> = ["-", "\u{00AD}", "\u{2010}"]
        var output = String()
        output.reserveCapacity(text.count)

        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            guard hyphens.contains(character), index > 0, characters[index - 1].isLetter else {
                output.append(character)
                index += 1
                continue
            }

            // Look ahead: spaces, then at least one newline, then spaces, then a letter.
            var lookahead = index + 1
            while lookahead < characters.count, characters[lookahead] == " " || characters[lookahead] == "\t" {
                lookahead += 1
            }
            var sawNewline = false
            while lookahead < characters.count, characters[lookahead].isNewline {
                sawNewline = true
                lookahead += 1
            }
            guard sawNewline else {
                output.append(character)
                index += 1
                continue
            }
            while lookahead < characters.count, characters[lookahead] == " " || characters[lookahead] == "\t" {
                lookahead += 1
            }
            guard lookahead < characters.count, characters[lookahead].isLetter else {
                output.append(character)
                index += 1
                continue
            }

            // The hyphen, the break and the padding around it all disappear; the two
            // halves of the word become one token.
            index = lookahead
        }
        return output
    }

    /// Collapses whitespace runs to one space and strips control characters.
    private static func collapseWhitespace(_ text: String) -> String {
        var output = String()
        output.reserveCapacity(text.count)
        var pendingSpace = false
        var wroteAnything = false

        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                pendingSpace = wroteAnything
                continue
            }
            // Control characters other than whitespace carry no meaning in a drawing's
            // text layer and break snippet rendering.
            if CharacterSet.controlCharacters.contains(scalar) { continue }
            if pendingSpace {
                output.unicodeScalars.append(" ")
                pendingSpace = false
            }
            output.unicodeScalars.append(scalar)
            wroteAnything = true
        }
        return output
    }

    // MARK: - Folding

    /// Case-folded, diacritic-stripped, compatibility-expanded. The form stored in
    /// `ocr_token.normalized_token` and used to look a token up again.
    public static func folded(_ raw: String) -> String {
        raw
            .precomposedStringWithCompatibilityMapping
            .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
    }

    /// ``folded(_:)`` with letter case kept: what a case-sensitive search compares (W-081),
    /// so `ROOM` and `Room` stay apart while `RÖOM` and `ROOM` still meet, as they do in the
    /// index.
    public static func caseKept(_ raw: String) -> String {
        raw
            .precomposedStringWithCompatibilityMapping
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    // MARK: - Tokenising

    /// Splits text the way `unicode61` does: runs of alphanumerics, everything else a
    /// separator.
    ///
    /// Combining marks are kept with the letter they modify, so a decomposed `ö` does not
    /// split `KÖK` into `K` and `K`.
    ///
    /// - Parameter maximumTokenLength: tokens longer than this are truncated rather than
    ///   dropped, so a pathological run of 100 000 letters costs a bounded amount.
    public static func tokens(in text: String, maximumTokenLength: Int = 128) -> [String] {
        var tokens: [String] = []
        var current = String.UnicodeScalarView()

        func flush() {
            guard !current.isEmpty else { return }
            var token = String(current)
            if token.count > maximumTokenLength {
                token = String(token.prefix(maximumTokenLength))
            }
            tokens.append(token)
            current = String.UnicodeScalarView()
        }

        for scalar in text.unicodeScalars {
            if isTokenScalar(scalar) {
                current.append(scalar)
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }

    /// `true` for a scalar `unicode61` treats as part of a token rather than a separator.
    @inlinable
    public static func isTokenScalar(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.alphanumerics.contains(scalar) || CharacterSet.nonBaseCharacters.contains(scalar)
    }
}
