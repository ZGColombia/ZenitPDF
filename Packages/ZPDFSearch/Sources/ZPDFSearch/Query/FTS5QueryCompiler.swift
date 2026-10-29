import Foundation

/// How much query syntax the user is allowed.
public struct SearchQueryOptions: Sendable, Hashable {
    /// Bare uppercase `AND`, `OR` and `NOT` between terms act as operators. When off they
    /// are ordinary words.
    public var allowsBooleanOperators: Bool
    /// A trailing `*` on a term makes it a prefix match.
    public var allowsPrefixMatching: Bool
    /// `"…"` groups words into a phrase that must appear in order.
    public var allowsPhraseMatching: Bool
    /// Compile the trailing bare word as a prefix match, as if the user had typed the
    /// `*` themselves.
    ///
    /// This is what a find-as-you-type field needs: an estimator typing a littera or the
    /// first half of a long compound has finished every word they put a separator after,
    /// and is still in the middle of the last one. The convention is therefore **last
    /// token only** — every earlier term keeps its exact, whole-token match, and only the
    /// final bare word becomes a prefix. All-prefix was considered and rejected: it
    /// silently widens terms the user has already finished.
    ///
    /// The implied prefix never overrides explicit syntax:
    /// - a trailing quoted phrase stays a phrase — quotes are the user saying "exactly this";
    /// - a trailing explicit `*` already made the word a prefix, and is left as it is;
    /// - a trailing operator word or trailing whitespace means the last word was
    ///   finished, so nothing is prefixed;
    /// - when ``allowsPrefixMatching`` is off — whole-word, literal-only searching —
    ///   this option is inert.
    public var impliesTrailingPrefix: Bool
    /// The operator inserted between two adjacent terms with nothing between them.
    public var impliedOperator: SearchBooleanOperator
    /// Letters must match in the case they were typed — spec 17.5's "Case sensitive" (W-081).
    ///
    /// The index cannot do this on its own: `search_fts` is declared
    /// `tokenize='unicode61 remove_diacritics 2'`, which folds case on both sides of every
    /// match, and a second, case-keeping table would double the index for a switch most
    /// searches leave off. So the index still finds the candidates — asked
    /// ``SearchQuery/candidateExpression``, which leaves the exclusions out — and
    /// ``SearchQuery/holdsWithCase(in:)`` keeps the rows where the query holds in the typed
    /// case. Diacritics stay folded, exactly as the index folds them.
    public var isCaseSensitive: Bool

    public init(
        allowsBooleanOperators: Bool = true,
        allowsPrefixMatching: Bool = true,
        allowsPhraseMatching: Bool = true,
        impliesTrailingPrefix: Bool = false,
        impliedOperator: SearchBooleanOperator = .and,
        isCaseSensitive: Bool = false
    ) {
        self.allowsBooleanOperators = allowsBooleanOperators
        self.allowsPrefixMatching = allowsPrefixMatching
        self.allowsPhraseMatching = allowsPhraseMatching
        self.impliesTrailingPrefix = impliesTrailingPrefix
        self.impliedOperator = impliedOperator
        self.isCaseSensitive = isCaseSensitive
    }

    public static let standard = SearchQueryOptions()
    /// ``standard``, plus the word the user is still typing matches as a prefix. What an
    /// interactive search field should pass: the start of a compound word finds the whole
    /// word without the user knowing `*` exists.
    public static let findAsYouType = SearchQueryOptions(impliesTrailingPrefix: true)
    /// Everything the user types is a literal word. Nothing is an operator.
    public static let literalOnly = SearchQueryOptions(
        allowsBooleanOperators: false,
        allowsPrefixMatching: false,
        allowsPhraseMatching: false
    )
}

/// The three FTS5 boolean operators this package will emit.
public enum SearchBooleanOperator: String, Sendable, Hashable, CaseIterable {
    case and = "AND"
    case or = "OR"
    case not = "NOT"
}

/// One compiled term, kept alongside the expression so highlight lookup does not have to
/// re-parse the user's string.
public struct SearchTerm: Sendable, Hashable {
    /// Exactly the run of characters the user typed for this term — `A-102`, not the
    /// `A` and `102` the tokeniser split it into (CR-123).
    ///
    /// The tokens exist because FTS5 indexes tokens. A highlight does not: the PDF
    /// engine is asked for a literal string, and rebuilding that string by joining
    /// the tokens with a space turned `A-102` into `A 102`, which appears nowhere on
    /// a drawing. Sheet numbers, grid references, revision codes and dimension
    /// strings are all punctuated, and they are the strings a construction set is
    /// searched for most.
    public let sourceText: String
    /// The tokens of the term, in the source's own case and diacritics.
    public let tokens: [String]
    /// The same tokens folded, which is what `ocr_token.normalized_token` holds.
    public let foldedTokens: [String]
    /// `true` when the last token is a prefix match.
    public let isPrefix: Bool
    /// `true` when the tokens must appear adjacent and in order.
    public let isPhrase: Bool
    /// `true` when this term was reached through a `NOT`, and so must **not** be
    /// highlighted even though it appears in the expression.
    public let isNegated: Bool

    public init(
        sourceText: String,
        tokens: [String],
        foldedTokens: [String],
        isPrefix: Bool,
        isPhrase: Bool,
        isNegated: Bool
    ) {
        self.sourceText = sourceText
        self.tokens = tokens
        self.foldedTokens = foldedTokens
        self.isPrefix = isPrefix
        self.isPhrase = isPhrase
        self.isNegated = isNegated
    }
}

/// A user's query string, recompiled into something SQLite is guaranteed to accept.
public struct SearchQuery: Sendable, Hashable {
    /// Exactly what the user typed, for display. Never interpolated into SQL.
    public let rawText: String
    /// The FTS5 `MATCH` expression. Empty when the query has nothing to search for.
    public let matchExpression: String
    /// The positive terms, in order. Negated terms are excluded — they are what the user
    /// does *not* want and highlighting them would be wrong.
    public let highlightTerms: [SearchTerm]
    /// Every term, negated ones included.
    public let allTerms: [SearchTerm]
    /// `true` when the input was longer than ``SearchLimits/maximumQueryCharacters`` or
    /// carried more terms than ``SearchLimits/maximumQueryTerms``.
    public let wasTruncated: Bool
    /// Terms the user excluded in a way FTS5 cannot express, and which were therefore left
    /// out of the search rather than searched for (U-081): a `NOT` with no search word before
    /// it (`NOT corridor`) or one after `OR` (`room OR NOT corridor`). FTS5 has no unary
    /// `NOT`; its `a NOT b` means "a and not b" only. Non-empty means the results ignore an
    /// exclusion the user typed, and the interface is expected to say so.
    public let droppedExclusions: [SearchTerm]
    /// Whether the query must hold in the case it was typed (``SearchQueryOptions/isCaseSensitive``).
    public let isCaseSensitive: Bool
    /// What the index is asked to `MATCH`: ``matchExpression`` itself, or — for a
    /// case-sensitive query — the same expression without its exclusions. The index folds
    /// case, so `ROOM NOT Hall` run there would also drop a row that says `ROOM` and `hall`;
    /// the exclusions are applied with case by ``holdsWithCase(in:)`` instead (W-081).
    public let candidateExpression: String
    /// ``allTerms`` grouped into the expression's `OR` branches, in order. FTS5 binds `NOT`
    /// tighter than `AND` and `AND` tighter than `OR`, so the compiled expression holds
    /// exactly when one branch has every one of its positive terms and none of its negated
    /// ones — which is how ``holdsWithCase(in:)`` evaluates it.
    let branches: [[SearchTerm]]

    public init(
        rawText: String,
        matchExpression: String,
        highlightTerms: [SearchTerm],
        allTerms: [SearchTerm],
        wasTruncated: Bool,
        droppedExclusions: [SearchTerm] = []
    ) {
        self.init(
            rawText: rawText,
            matchExpression: matchExpression,
            highlightTerms: highlightTerms,
            allTerms: allTerms,
            wasTruncated: wasTruncated,
            droppedExclusions: droppedExclusions,
            isCaseSensitive: false,
            candidateExpression: matchExpression,
            branches: [allTerms]
        )
    }

    init(
        rawText: String,
        matchExpression: String,
        highlightTerms: [SearchTerm],
        allTerms: [SearchTerm],
        wasTruncated: Bool,
        droppedExclusions: [SearchTerm],
        isCaseSensitive: Bool,
        candidateExpression: String,
        branches: [[SearchTerm]]
    ) {
        self.rawText = rawText
        self.matchExpression = matchExpression
        self.highlightTerms = highlightTerms
        self.allTerms = allTerms
        self.wasTruncated = wasTruncated
        self.droppedExclusions = droppedExclusions
        self.isCaseSensitive = isCaseSensitive
        self.candidateExpression = candidateExpression
        self.branches = branches
    }

    /// `true` when there is nothing to run. A search on an empty query returns no hits
    /// rather than an error.
    public var isEmpty: Bool { matchExpression.isEmpty }

    /// Whether `text` satisfies the query in the case it was typed (W-081): one `OR` branch
    /// has every positive term in `text`, letter case and all, and none of its excluded
    /// terms. Terms are matched the way the index matches them — whole words, a phrase as
    /// consecutive words with anything but letters and digits between them, a prefix term's
    /// last word on its beginning — with diacritics and character widths folded as the
    /// index folds them, and case kept.
    public func holdsWithCase(in text: String) -> Bool {
        branches.contains { branch in
            branch.allSatisfy { term in
                let occurs = Self.occursWithCase(term, in: text)
                return term.isNegated ? !occurs : occurs
            }
        }
    }

    /// Whether `term`'s words occur in `text`, consecutively, in their typed case.
    static func occursWithCase(_ term: SearchTerm, in text: String) -> Bool {
        guard let first = term.tokens.first, !first.isEmpty else { return false }
        let options: String.CompareOptions = [.diacriticInsensitive, .widthInsensitive]
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let found = text.range(of: first, options: options, range: searchStart..<text.endIndex) {
            searchStart = text.index(after: found.lowerBound)
            // A word begins here, and the first token ends on a word boundary unless it is
            // the prefix the user is still typing.
            if found.lowerBound > text.startIndex, isWordCharacter(text[text.index(before: found.lowerBound)]) {
                continue
            }
            var end = found.upperBound
            var matched = endsWord(at: end, in: text, isOpenPrefix: term.isPrefix && term.tokens.count == 1)
            var position = 1
            while matched, position < term.tokens.count {
                // The next word starts after the separators that follow this one.
                var next = end
                while next < text.endIndex, !isWordCharacter(text[next]) { next = text.index(after: next) }
                guard next > end,
                      let word = text.range(of: term.tokens[position], options: options.union(.anchored),
                                            range: next..<text.endIndex)
                else { matched = false; break }
                end = word.upperBound
                let isLast = position == term.tokens.count - 1
                matched = endsWord(at: end, in: text, isOpenPrefix: term.isPrefix && isLast)
                position += 1
            }
            if matched { return true }
        }
        return false
    }

    private static func endsWord(at index: String.Index, in text: String, isOpenPrefix: Bool) -> Bool {
        isOpenPrefix || index == text.endIndex || !isWordCharacter(text[index])
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.contains(where: ZPDFTextNormalizer.isTokenScalar)
    }
}

/// Turns a user's query string into an FTS5 `MATCH` expression that cannot be a syntax
/// error and cannot be an injection.
///
/// ### The guarantee, and how it is obtained
///
/// The compiler never *escapes* the user's string — it never uses it at all. It reads the
/// string, extracts the alphanumeric runs with ``ZPDFTextNormalizer/tokens(in:)``, and
/// then **builds a new string** out of those runs. Every character in the output is
/// either a character the tokeniser classified as alphanumeric, a double quote this
/// compiler wrote, a space, a `*`, or one of the three literal words `AND`, `OR`, `NOT`.
/// A quote, a paren, a `NEAR(`, a `^`, a `:` or a `-` in the input cannot reach the
/// output, because there is no path from an input character to the output that does not
/// pass the alphanumeric test.
///
/// Two more properties fall out of that, and both are asserted by the fuzz test:
///
/// - **No empty phrase.** FTS5 rejects a quoted string that tokenises to nothing. A term
///   whose tokens list is empty is dropped before it is ever quoted, so `(((` compiles to
///   the empty expression and the search returns no hits.
/// - **No dangling operator.** Operators are emitted only *between* two emitted terms, so
///   an input of `AND OR NOT` compiles to the empty expression.
///
/// ### Exclusions (U-081)
///
/// `NOT` always negates the term after it, never the opposite. In an operator run `NOT` wins
/// over a preceding `AND` — `room AND NOT corridor` is FTS5's `"room" NOT "corridor"` — and
/// any other run keeps its first operator. An exclusion FTS5 cannot express — a leading `NOT`,
/// or `NOT` after `OR` — drops the excluded term and records it in
/// ``SearchQuery/droppedExclusions``; it is never searched for as if it were wanted.
public enum FTS5QueryCompiler {

    /// Compiles `raw`. Never throws: every hostile input has a defined, harmless result.
    public static func compile(
        _ raw: String,
        options: SearchQueryOptions = .standard,
        limits: SearchLimits = .standard
    ) -> SearchQuery {
        var wasTruncated = false
        var input = raw
        if input.count > limits.maximumQueryCharacters {
            input = String(input.prefix(limits.maximumQueryCharacters))
            wasTruncated = true
        }

        let fragments = split(input, options: options)
        let impliedPrefixIndex = impliedTrailingPrefixIndex(
            in: fragments,
            input: input,
            options: options
        )

        // Second pass: fragments become terms and operators, and the operators are
        // resolved into the positions where an operator may legally appear.
        var terms: [SearchTerm] = []
        var pieces: [String] = []
        var pendingOperator: SearchBooleanOperator?
        // The operator a pending `NOT` followed in its run (`OR` in `a OR NOT b`), restored
        // when the negated term is dropped so `a OR NOT b c` keeps `a OR c`.
        var operatorBeforeNot: SearchBooleanOperator?
        var droppedExclusions: [SearchTerm] = []
        // The operator that joined each emitted term to the one before it (`nil` for the
        // first), so the expression's `OR` branches can be read back without re-parsing.
        var joins: [SearchBooleanOperator?] = []

        for (fragmentIndex, fragment) in fragments.enumerated() {
            if terms.count >= limits.maximumQueryTerms {
                wasTruncated = true
                break
            }
            switch fragment {
            case let .operatorWord(op):
                // A leading AND or OR is meaningless, but a leading NOT still negates the
                // term after it — that term must not become a wanted one (U-081). In a run,
                // NOT wins over what came before it; otherwise the run keeps its first.
                guard !pieces.isEmpty || op == .not else { continue }
                switch pendingOperator {
                case nil:
                    pendingOperator = op
                case .some(let previous) where op == .not && previous != .not:
                    operatorBeforeNot = previous
                    pendingOperator = .not
                default:
                    continue
                }

            case let .word(text, isPrefix):
                let tokens = ZPDFTextNormalizer.tokens(
                    in: queryForm(text),
                    maximumTokenLength: limits.maximumTermCharacters
                )
                guard !tokens.isEmpty else { continue }
                // A "word" the tokeniser splits (`3.5m` -> `3`, `5m`) becomes a phrase,
                // because the user typed it as one thing.
                let keptWordTokens = Array(tokens.prefix(limits.maximumPhraseTokens))
                appendTerm(
                    sourceText: literal(text, tokens: tokens, kept: keptWordTokens, limits: limits),
                    tokens: keptWordTokens,
                    isPrefix: (isPrefix || fragmentIndex == impliedPrefixIndex)
                        && options.allowsPrefixMatching,
                    pendingOperator: &pendingOperator,
                    operatorBeforeNot: &operatorBeforeNot,
                    options: options,
                    terms: &terms,
                    pieces: &pieces,
                    joins: &joins,
                    dropped: &droppedExclusions
                )

            case let .phrase(text):
                let tokens = ZPDFTextNormalizer.tokens(
                    in: queryForm(text),
                    maximumTokenLength: limits.maximumTermCharacters
                )
                guard !tokens.isEmpty else { continue }
                if tokens.count > limits.maximumPhraseTokens { wasTruncated = true }
                let keptPhraseTokens = Array(tokens.prefix(limits.maximumPhraseTokens))
                appendTerm(
                    sourceText: literal(text, tokens: tokens, kept: keptPhraseTokens, limits: limits),
                    tokens: keptPhraseTokens,
                    isPrefix: false,
                    pendingOperator: &pendingOperator,
                    operatorBeforeNot: &operatorBeforeNot,
                    options: options,
                    terms: &terms,
                    pieces: &pieces,
                    joins: &joins,
                    dropped: &droppedExclusions
                )
            }
        }

        let expression = pieces.joined(separator: " ")

        // The `OR` branches, and the expression without its exclusions (W-081). Removing a
        // `NOT term` pair leaves a valid expression, because `NOT` binds tightest: what is
        // left is every branch's positive terms, joined as they were.
        var branches: [[SearchTerm]] = []
        var candidatePieces: [String] = []
        for (term, join) in zip(terms, joins) {
            if join == .or || branches.isEmpty {
                branches.append([term])
            } else {
                branches[branches.count - 1].append(term)
            }
            guard !term.isNegated else { continue }
            if !candidatePieces.isEmpty {
                candidatePieces.append((join == .or ? SearchBooleanOperator.or : .and).rawValue)
            }
            candidatePieces.append(quotedPhrase(term.tokens, isPrefix: term.isPrefix))
        }

        return SearchQuery(
            rawText: raw,
            matchExpression: expression,
            highlightTerms: terms.filter { !$0.isNegated },
            allTerms: terms,
            wasTruncated: wasTruncated,
            droppedExclusions: droppedExclusions,
            isCaseSensitive: options.isCaseSensitive,
            candidateExpression: options.isCaseSensitive ? candidatePieces.joined(separator: " ") : expression,
            branches: branches
        )
    }

    /// The literal a highlight may search for (CR-123).
    ///
    /// The raw substring is only usable when it still describes exactly the tokens the
    /// expression matched. A term the limits cut — too many tokens in a phrase, or a
    /// token longer than ``SearchLimits/maximumTermCharacters`` — would make the literal
    /// *stricter* than the search that produced the hit, so the highlight would go
    /// missing on a hit the index legitimately found. Those fall back to the tokens.
    private static func literal(
        _ raw: String,
        tokens: [String],
        kept: [String],
        limits: SearchLimits
    ) -> String {
        guard kept.count == tokens.count,
              tokens.allSatisfy({ $0.count < limits.maximumTermCharacters })
        else { return kept.joined(separator: " ") }
        let trimmed = trimmedLiteral(raw)
        return trimmed.isEmpty ? kept.joined(separator: " ") : trimmed
    }

    /// The raw fragment without what the tokeniser threw away at its edges (BH-206).
    ///
    /// `A-102,` pasted from a list, `(ROOM)`, `101.` or `*ROOM` match the index on their
    /// tokens, but the highlight searches the page for a literal, and the page reads
    /// `A-102 `, not `A-102,`. So the leading and trailing characters that are not token
    /// characters are dropped, and an interior run of whitespace (`"ROOM  101"`) becomes
    /// one space, the way the page text reads. Interior punctuation stays: it is what makes
    /// `A-102` and `3.5` the literal the user meant (CR-123).
    static func trimmedLiteral(_ raw: String) -> String {
        func isToken(_ character: Character) -> Bool {
            character.unicodeScalars.contains(where: ZPDFTextNormalizer.isTokenScalar)
        }
        guard let first = raw.firstIndex(where: isToken),
              let last = raw.lastIndex(where: isToken)
        else { return "" }
        var output = String()
        var pendingSpace = false
        for character in raw[first...last] {
            if character.isWhitespace {
                pendingSpace = true
                continue
            }
            if pendingSpace {
                output.append(" ")
                pendingSpace = false
            }
            output.append(character)
        }
        return output
    }

    /// The form a query fragment is tokenised in: the compatibility mapping the indexer
    /// applies to page text (BH-646).
    ///
    /// ``ZPDFTextNormalizer/indexable(_:options:)`` writes `12,5 m²` as `m2` and `PROﬁLE`
    /// as `PROFILE`; `unicode61` keeps `²` and `ﬁ` as token characters, so a query that
    /// carried them raw compiled to `"m²"` and matched nothing that was on the sheet. The
    /// mapping is applied per fragment, after quotes and operators have been read, so a
    /// full-width quote in the input cannot become syntax.
    static func queryForm(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
    }

    /// Emits one term plus the operator that precedes it — or, for an exclusion FTS5 cannot
    /// express (nothing wanted before it, or `NOT` after `OR`), records the term in `dropped`
    /// and emits nothing.
    private static func appendTerm(
        sourceText: String,
        tokens: [String],
        isPrefix: Bool,
        pendingOperator: inout SearchBooleanOperator?,
        operatorBeforeNot: inout SearchBooleanOperator?,
        options: SearchQueryOptions,
        terms: inout [SearchTerm],
        pieces: inout [String],
        joins: inout [SearchBooleanOperator?],
        dropped: inout [SearchTerm]
    ) {
        if pendingOperator == .not, pieces.isEmpty || operatorBeforeNot == .or {
            dropped.append(SearchTerm(
                sourceText: sourceText,
                tokens: tokens,
                foldedTokens: tokens.map(ZPDFTextNormalizer.folded),
                isPrefix: isPrefix,
                isPhrase: tokens.count > 1,
                isNegated: true
            ))
            pendingOperator = pieces.isEmpty ? nil : operatorBeforeNot
            operatorBeforeNot = nil
            return
        }
        operatorBeforeNot = nil
        var negated = false
        var join: SearchBooleanOperator?
        if !pieces.isEmpty {
            let op = pendingOperator ?? options.impliedOperator
            join = op
            if op == .not {
                // FTS5 spells "everything but" as `a NOT b`, so the operator stays in the
                // expression and the term is flagged so it is never highlighted.
                pieces.append(SearchBooleanOperator.not.rawValue)
                negated = true
            } else {
                pieces.append(op.rawValue)
            }
        }
        pendingOperator = nil

        pieces.append(quotedPhrase(tokens, isPrefix: isPrefix))
        joins.append(join)
        terms.append(
            SearchTerm(
                sourceText: sourceText,
                tokens: tokens,
                foldedTokens: tokens.map(ZPDFTextNormalizer.folded),
                isPrefix: isPrefix,
                isPhrase: tokens.count > 1,
                isNegated: negated
            )
        )
    }

    // MARK: - Lexing

    private enum Fragment: Sendable, Hashable {
        case word(String, isPrefix: Bool)
        case phrase(String)
        case operatorWord(SearchBooleanOperator)
    }

    /// Splits the raw string into quoted phrases, bare words and operator words.
    ///
    /// An unbalanced quote runs to the end of the string, which is what every search box
    /// in the world does and is the only behaviour that cannot fail.
    private static func split(_ input: String, options: SearchQueryOptions) -> [Fragment] {
        var fragments: [Fragment] = []
        var buffer = String()
        let characters = Array(input)
        var index = 0

        func flushWord(isPrefix: Bool) {
            guard !buffer.isEmpty else { return }
            if options.allowsBooleanOperators,
               let op = SearchBooleanOperator(rawValue: buffer),
               buffer == buffer.uppercased() {
                fragments.append(.operatorWord(op))
            } else {
                fragments.append(.word(buffer, isPrefix: isPrefix))
            }
            buffer = String()
        }

        while index < characters.count {
            let character = characters[index]

            if character == "\"", options.allowsPhraseMatching {
                flushWord(isPrefix: false)
                index += 1
                var phrase = String()
                while index < characters.count, characters[index] != "\"" {
                    phrase.append(characters[index])
                    index += 1
                }
                if index < characters.count { index += 1 }   // the closing quote
                if !phrase.isEmpty { fragments.append(.phrase(phrase)) }
                continue
            }

            if character == "*", options.allowsPrefixMatching, !buffer.isEmpty {
                flushWord(isPrefix: true)
                index += 1
                continue
            }

            if character.isWhitespace {
                flushWord(isPrefix: false)
                index += 1
                continue
            }

            buffer.append(character)
            index += 1
        }
        flushWord(isPrefix: false)
        return fragments
    }

    /// The fragment ``SearchQueryOptions/impliesTrailingPrefix`` applies to, or `nil`.
    ///
    /// It is the final fragment, and only when that fragment is a bare word the user may
    /// still be typing. A trailing quoted phrase is explicit syntax and stays exact; a
    /// trailing operator word means the last word was finished; trailing whitespace means
    /// so was this one. And when the word already carries an explicit `*`, marking it
    /// again changes nothing — the emitted term is the same either way.
    private static func impliedTrailingPrefixIndex(
        in fragments: [Fragment],
        input: String,
        options: SearchQueryOptions
    ) -> Int? {
        guard options.impliesTrailingPrefix, options.allowsPrefixMatching else { return nil }
        guard let lastCharacter = input.last, !lastCharacter.isWhitespace else { return nil }
        guard let last = fragments.last, case .word = last else { return nil }
        return fragments.count - 1
    }

    // MARK: - Emitting

    /// Wraps tokens as one FTS5 string literal, optionally prefix-matched.
    ///
    /// Public so a test can assert the exact bytes, and so a caller building its own
    /// expression uses this rather than string interpolation.
    public static func quotedPhrase(_ tokens: [String], isPrefix: Bool) -> String {
        let body = tokens.map(escape).joined(separator: " ")
        return isPrefix ? "\"\(body)\"*" : "\"\(body)\""
    }

    /// Doubles any double quote, as SQLite's string-literal rule requires.
    ///
    /// Belt and braces: a token cannot contain a quote, because a quote is not
    /// alphanumeric and ``ZPDFTextNormalizer/tokens(in:)`` produced the token. The
    /// function exists so that a future caller who does pass raw text still cannot break
    /// out of the literal.
    public static func escape(_ token: String) -> String {
        token.replacingOccurrences(of: "\"", with: "\"\"")
    }
}
