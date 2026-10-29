import Foundation
import ZPDFUIPresentation

/// Finds scale notations in recognised text.
///
/// The parser is a scanner, not a regular expression, for one reason: every rejection below is
/// a *position* rule — what stands immediately before the numerator, what stands immediately
/// after the denominator, which paper token belongs to which ratio — and a scanner can state
/// those rules where they are read rather than encoding them in a pattern nobody can review.
///
/// It answers one question per line and answers it conservatively:
///
/// - **The numerator must be `1`.** `2:1 vote` and `13:37` are not scales. ``ScaleRatio`` owns
///   this rule so no caller can route around it.
/// - **No leading zeros.** `01:50` is half past one.
/// - **No colon chain.** `12:34:56` and `1:2:3` are a timestamp and a list; a scale notation is
///   never followed immediately by another `:digits` group.
/// - **No decimal tail.** `1:2.5` is not read as `1:2`.
/// - **Nothing digit-like immediately before the numerator**, so the `:56` of `12:34:56` cannot
///   restart the scan as `56`.
/// - **No property designation.** `KV 1:10` is block 1, unit 10 of a tract, not a scale
///   (``designationWordsUppercased``, L-21).
///
/// What it does *not* do is decide where on the sheet the words were. Bounds are carried through
/// untouched (``ScaleCandidate/boundsInPageSpace``) and title-block proximity is judged
/// elsewhere, with the page geometry in hand.
///
/// Whitespace is tolerated one space per side of the colon (`1 : 100`), and the ratio colon may
/// be the ASCII `:`, the ratio sign `∶`, or the full-width `：`, because a recogniser produces
/// all three from the same glyph.
public struct ScaleNotationParser: Hashable, Sendable {

    /// Creates a parser. It holds no state; the type exists so the rules have one home.
    public init() {}

    /// The words that mark a ratio as a scale rather than a spacing, a slope or a vote.
    ///
    /// Stored uppercased because matching is case-insensitive and `String.uppercased()` may
    /// change a string's length (`ß` becomes `SS`), which would break any index arithmetic done
    /// across the two forms.
    public static let scaleWordsUppercased: Set<String> = [
        // Swedish, and the Nordic neighbours a Swedish drawing set travels with.
        "SKALA", "SKALOR", "MÅTTSKALA", "MÅLESTOK", "MÅLESTOKK", "MITTAKAAVA",
        // English.
        "SCALE", "SCALES",
        // The rest of the European title blocks that reach a Swedish office.
        "MASSSTAB", "MASSTAB", "ÉCHELLE", "ECHELLE", "ESCALA", "SCALA", "SCHAAL"
    ]

    /// The words that mark an `n:m` written right after them as a property or block designation,
    /// never a scale (L-21).
    ///
    /// A Swedish property designation *is* written `block:unit` — "Exempelpark 1:10" is block 1,
    /// unit 10 of the Exempelpark tract — and a title block's area or property field writes it
    /// after the word that names it: "KV 1:10 EXEMPELPARK" on a roof plan whose SKALA field says
    /// 1:50, where the old proposal offered 1:10. The neighbouring languages the
    /// scale words above cover write their property identifiers without a ratio colon
    /// (Norwegian `gnr/bnr 12/34`, Danish `matr.nr. 7a`, Finnish `91-405-12-3`, German
    /// `Flurstück 123/4`), so no word of theirs is needed here. English `BLOCK` and `LOT` are left
    /// out on purpose: "BLOCK PLAN 1:500" is a site plan's real scale.
    ///
    /// Stored uppercased, like ``scaleWordsUppercased``.
    public static let designationWordsUppercased: Set<String> = [
        "KV", "KVARTER", "KVARTERET",
        "FASTIGHET", "FASTIGHETEN", "FASTIGHETSBETECKNING", "FASTIGHETSBET"
    ]

    /// The colon glyphs a recogniser produces for a ratio separator.
    static let colonCharacters: Set<Character> = [":", "\u{2236}", "\u{FF1A}"]

    // MARK: - Entry points

    /// Finds every scale notation in a page's recognised lines, in reading order.
    ///
    /// Lines are independent: a ratio never borrows a scale word or a paper hint from a
    /// neighbouring line, because OCR line order on a title block is not reliably semantic.
    /// Where the page geometry says which line is a value's label, ``SheetScaleProposer`` joins
    /// the two through ``candidates(inLine:after:boundsInPageSpace:)``.
    public func candidates(in lines: [RecognisedTextLine]) -> [ScaleCandidate] {
        lines.flatMap { candidates(inLine: $0.text, boundsInPageSpace: $0.boundsInPageSpace) }
    }

    /// The same, for the `(text, bounds)` pair shape a recogniser hands over directly.
    public func candidates(in lines: [(String, boundsInPageSpace: PDFRectValue?)]) -> [ScaleCandidate] {
        candidates(in: lines.map { RecognisedTextLine(text: $0.0, boundsInPageSpace: $0.boundsInPageSpace) })
    }

    /// Finds every scale notation in one line, left to right.
    ///
    /// A line may yield more than one candidate: `1:100, 1:200 (A3)` is the dual notation a
    /// sheet carries when it is drawn at one size and printed at another, and both ratios are
    /// real. Which of them applies is ``ScaleProposalEngine``'s question, not this one's.
    public func candidates(inLine text: String, boundsInPageSpace: PDFRectValue? = nil) -> [ScaleCandidate] {
        candidates(in: Array(text), sourceText: text, from: 0, boundsInPageSpace: boundsInPageSpace)
    }

    /// The notations in one line, read as if `context` stood right before it (L-21).
    ///
    /// A title block lays a field out as a label over or beside its value: "SKALA" in the cell's
    /// top-left corner and "1:50" under it, or "KV" and "1:10" as two runs the text layer split.
    /// ``SheetScaleProposer`` finds that neighbour with the page geometry in hand; this applies it
    /// with the same position rules a single line gets — a scale word reaches the ratio only
    /// across bridge text, a designation word must stand directly before it. Only the notations
    /// in `text` are returned, never one from `context`, and each carries `"context text"` as
    /// its ``ScaleCandidate/sourceText`` so the evidence shows the label it was read with.
    public func candidates(
        inLine text: String,
        after context: String,
        boundsInPageSpace: PDFRectValue? = nil
    ) -> [ScaleCandidate] {
        guard !context.isEmpty else { return candidates(inLine: text, boundsInPageSpace: boundsInPageSpace) }
        let joined = context + " " + text
        return candidates(
            in: Array(joined),
            sourceText: joined,
            from: Array(context).count + 1,
            boundsInPageSpace: boundsInPageSpace
        )
    }

    /// Every notation starting at or after `offset`, with the rules that judge it applied over
    /// the whole of `characters`.
    ///
    /// The notations themselves are found exactly as in the text alone: the metric scanner
    /// consumes whole pairs and sees the joining space before the first one, and the imperial
    /// grammar reads only from `offset`, because its mixed-number form (`1 1/2"`) would otherwise
    /// take a context ending in "PLAN 2" as the whole inches of the value's `1/8"`.
    private func candidates(
        in characters: [Character],
        sourceText: String,
        from offset: Int,
        boundsInPageSpace: PDFRectValue?
    ) -> [ScaleCandidate] {
        let imperial = Self.imperialNotations(in: Array(characters[offset...])).map {
            Notation(
                range: ($0.range.lowerBound + offset)..<($0.range.upperBound + offset),
                ratio: $0.ratio,
                isImperial: true
            )
        }
        let notations = (Self.notations(in: characters) + imperial)
            .sorted { $0.range.lowerBound < $1.range.lowerBound }
        guard !notations.isEmpty else { return [] }
        let hints = Self.paperSizeHints(in: characters)

        return notations.enumerated().compactMap { position, notation in
            guard notation.range.lowerBound >= offset else { return nil }
            // A designation stays in `notations` above, so a paper token after it is not lent
            // to an earlier ratio; it is only never offered as a scale itself.
            guard !Self.isDesignation(before: notation.range.lowerBound, in: characters) else { return nil }
            let nextStart = position + 1 < notations.count
                ? notations[position + 1].range.lowerBound
                : characters.count
            let hint = hints.first {
                $0.index >= notation.range.upperBound && $0.index < nextStart
            }?.size
            let prefixed = Self.hasScaleWord(before: notation.range.lowerBound, in: characters)
            return ScaleCandidate(
                ratio: notation.ratio,
                matchedText: String(characters[notation.range]),
                sourceText: sourceText,
                boundsInPageSpace: boundsInPageSpace,
                paperSizeHint: hint,
                hasExplicitPrefix: prefixed,
                confidence: ScaleCandidate.confidence(
                    hasExplicitPrefix: prefixed,
                    isStandardSeries: notation.isImperial
                        ? Self.imperialStandardSeries.contains(notation.ratio.denominator)
                        : notation.ratio.isStandardSeries
                )
            )
        }
    }

    // MARK: - Scanning

    struct Notation {
        let range: Range<Int>
        let ratio: ScaleRatio
        /// Written as paper inches equal to real feet and inches (`1/8" = 1'-0"`).
        var isImperial = false
    }

    // MARK: - Imperial notations (NL-MEASURE-17)

    /// The ratios the architectural and engineering imperial scales produce: `1/8" = 1'-0"` is
    /// 1:96, `1/4"` 1:48, `3/16"` 1:64, `1" = 20'` 1:240. A confidence input, like
    /// ``ScaleRatio/standardSeries``.
    public static let imperialStandardSeries: Set<Int> = [
        1, 2, 4, 8, 12, 16, 24, 32, 48, 64, 96, 128, 192, 120, 240, 360, 480, 600, 720, 960, 1200, 2400
    ]

    /// Every `paper" = real` notation in a line, as a `1:d` ratio.
    ///
    /// Paper: a whole number, a fraction or a mixed number (`1-1/2`, `1 1/2`) of inches, with an
    /// inch mark (`"`, `″`, `”` or two apostrophes). Real: feet with an optional inch part
    /// (`1'-0"`, `20'`, `1' 6"`) or plain inches (`12"`). The ratio is real inches over paper
    /// inches, taken only when it is a whole number — `3/16" = 1'-0"` is exactly 1:64 — so a
    /// notation that does not reduce to `1:d` is left out rather than rounded.
    static func imperialNotations(in characters: [Character]) -> [Notation] {
        // One character per input character, so ranges map back one to one.
        let normalized = String(characters.map { character -> Character in
            switch character {
            case "\u{2033}", "\u{201D}", "\u{201C}": return "\""
            case "\u{2032}", "\u{2019}", "\u{2018}": return "'"
            case "\u{2013}", "\u{2014}": return "-"
            default: return character
            }
        })
        let inch = #"(?:"|'')"#
        let pattern = #"(?<![\d/.,])(?:(\d{1,2})(?:-|\s))?(?:(\d+)/(\d+)|(\d+(?:\.\d+)?))\s*"# + inch
            + #"\s*=\s*(?:(\d+)\s*'(?!')(?:\s*-?\s*(\d+)(?:\s+(\d+)/(\d+))?\s*"# + inch + #")?|(\d+)\s*"# + inch + ")"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let text = normalized as NSString
        var result: [Notation] = []
        for match in expression.matches(in: normalized, range: NSRange(location: 0, length: text.length)) {
            func group(_ index: Int) -> Decimal? {
                let range = match.range(at: index)
                guard range.location != NSNotFound else { return nil }
                return Decimal(string: text.substring(with: range), locale: Locale(identifier: "en_US_POSIX"))
            }
            var paper: Decimal
            if let numerator = group(2), let denominator = group(3) {
                guard denominator > 0 else { continue }
                paper = (group(1) ?? 0) + numerator / denominator
            } else if let whole = group(4) {
                guard group(1) == nil else { continue }
                paper = whole
            } else { continue }
            var real: Decimal
            if let feet = group(5) {
                real = feet * 12 + (group(6) ?? 0)
                if let numerator = group(7), let denominator = group(8), denominator > 0 { real += numerator / denominator }
            } else if let inches = group(9) {
                real = inches
            } else { continue }
            guard paper > 0, real > 0 else { continue }
            var quotient = real / paper
            var rounded = Decimal()
            NSDecimalRound(&rounded, &quotient, 0, .plain)
            guard rounded == quotient, let denominator = Int(exactly: NSDecimalNumber(decimal: rounded).doubleValue),
                  let ratio = ScaleRatio(denominator: denominator),
                  let range = Range(match.range, in: normalized) else { continue }
            let lower = normalized.distance(from: normalized.startIndex, to: range.lowerBound)
            let upper = normalized.distance(from: normalized.startIndex, to: range.upperBound)
            result.append(Notation(range: lower..<upper, ratio: ratio, isImperial: true))
        }
        return result
    }

    /// Every accepted `n:d` notation in a character array, in order.
    static func notations(in characters: [Character]) -> [Notation] {
        var found: [Notation] = []
        let count = characters.count
        var index = 0

        while index < count {
            guard isASCIIDigit(characters[index]) else {
                index += 1
                continue
            }
            // A numerator may follow a letter (`SKALA1:100` is one token in some title blocks)
            // but never a digit, a colon or a decimal separator: those mean this run is the
            // tail of something longer that has already been judged.
            //
            // A comma is the exception when the run after it is itself a numerator — followed by a
            // colon. "1:100,1:200" is a tight dual notation (PDF text layers and OCR drop the
            // space), not 1:100 with a decimal tail: reading it as one dropped 1:200 and attached
            // the "(A3)" hint to 1:100, so the wrong scale was offered with extra confidence
            // (BH-118).
            if index > 0 {
                let preceding = characters[index - 1]
                let isListComma = preceding == "," && isNumerator(at: index, in: characters)
                if !isListComma, isASCIIDigit(preceding) || colonCharacters.contains(preceding)
                    || preceding == "." || preceding == "," {
                    while index < count, isASCIIDigit(characters[index]) { index += 1 }
                    continue
                }
            }

            var cursor = index
            while cursor < count, isASCIIDigit(characters[cursor]) { cursor += 1 }
            let numeratorText = String(characters[index..<cursor])

            var probe = cursor
            if probe < count, characters[probe] == " " { probe += 1 }
            guard probe < count, colonCharacters.contains(characters[probe]) else {
                index = cursor
                continue
            }
            probe += 1
            if probe < count, characters[probe] == " " { probe += 1 }
            guard probe < count, isASCIIDigit(characters[probe]) else {
                index = cursor
                continue
            }

            let denominatorStart = probe
            while probe < count, isASCIIDigit(characters[probe]) { probe += 1 }
            let denominatorText = String(characters[denominatorStart..<probe])
            let end = probe

            if let ratio = ratio(numeratorText: numeratorText, denominatorText: denominatorText),
               !isChainedOrDecimal(at: end, in: characters) {
                found.append(Notation(range: index..<end, ratio: ratio))
            }
            // Whether accepted or rejected, the whole pair is consumed. Restarting inside it is
            // how `12:34:56` would otherwise become the candidate `56`.
            index = end
        }
        return found
    }

    /// A ratio from two digit runs, or `nil` when the runs are not a scale notation.
    static func ratio(numeratorText: String, denominatorText: String) -> ScaleRatio? {
        guard !hasLeadingZero(numeratorText), !hasLeadingZero(denominatorText) else { return nil }
        guard let numerator = Int(numeratorText), let denominator = Int(denominatorText) else {
            return nil
        }
        return ScaleRatio(numerator: numerator, denominator: denominator)
    }

    /// `true` when the notation is followed by another colon group or a decimal fraction.
    ///
    /// Both decimal separators count. Only the dot did, so "SKALA 1:2,5" — the Swedish way to
    /// write 1:2.5 — was read as 1:2 with full prefix confidence and proposed a scale 25 % off,
    /// while the numerator rule above already treated a comma as a decimal separator (BH-455).
    /// A comma whose next run is the numerator of another notation is a list separator instead.
    static func isChainedOrDecimal(at end: Int, in characters: [Character]) -> Bool {
        guard end < characters.count else { return false }
        let next = characters[end]
        if colonCharacters.contains(next) { return true }
        guard next == "." || next == ",", end + 1 < characters.count, isASCIIDigit(characters[end + 1]) else {
            return false
        }
        if next == ",", isNumerator(at: end + 1, in: characters) { return false }
        return true
    }

    /// Whether the digit run starting at `start` is followed by a colon — the numerator of a
    /// notation rather than the fraction of a number.
    static func isNumerator(at start: Int, in characters: [Character]) -> Bool {
        var cursor = start
        guard cursor < characters.count, isASCIIDigit(characters[cursor]) else { return false }
        while cursor < characters.count, isASCIIDigit(characters[cursor]) { cursor += 1 }
        if cursor < characters.count, characters[cursor] == " " { cursor += 1 }
        return cursor < characters.count && colonCharacters.contains(characters[cursor])
    }

    // MARK: - Paper size hints

    struct PaperSizeHint {
        let index: Int
        let size: ISOPaperSize
    }

    /// Every standalone ISO paper token in a line, with the index it starts at.
    ///
    /// The delimiter rules are what keep a drawing number out: `(A1)` and ` A3,` are hints,
    /// `A1-101` and `A3.02` are sheet identifiers and are ignored.
    static func paperSizeHints(in characters: [Character]) -> [PaperSizeHint] {
        var hints: [PaperSizeHint] = []
        let count = characters.count
        var index = 0
        while index < count {
            defer { index += 1 }
            let letter = characters[index]
            guard letter == "A" || letter == "B" || letter == "a" || letter == "b" else { continue }
            guard index + 1 < count, isASCIIDigit(characters[index + 1]) else { continue }
            if index > 0 {
                let before = characters[index - 1]
                guard before == " " || before == "\t" || before == "(" || before == "[" else {
                    continue
                }
            }
            let afterIndex = index + 2
            if afterIndex < count {
                let after = characters[afterIndex]
                guard after == " " || after == "\t" || after == ")" || after == "]"
                    || after == "," || after == ";" else { continue }
            }
            let token = String(letter).uppercased() + String(characters[index + 1])
            guard let size = ISOPaperSize(rawValue: token) else { continue }
            hints.append(PaperSizeHint(index: index, size: size))
        }
        return hints
    }

    // MARK: - Scale words

    /// Whether an explicit scale word introduces the notation starting at `matchStart`.
    ///
    /// The word must precede the ratio, and everything between the two must be *bridge* text —
    /// punctuation, digits, another ratio, a paper token. A letter in between ends the reach, so
    /// in `SKALA 1:100  RITNINGSNR 1:250` only the first ratio is prefixed, which is the
    /// intended reading of that line.
    static func hasScaleWord(before matchStart: Int, in characters: [Character]) -> Bool {
        guard matchStart > 0 else { return false }
        let prefix = Array(String(characters[0..<matchStart]).uppercased())
        var wordEnd: Int?

        for word in scaleWordsUppercased {
            let needle = Array(word)
            guard needle.count <= prefix.count else { continue }
            var start = prefix.count - needle.count
            while start >= 0 {
                if Array(prefix[start..<(start + needle.count)]) == needle {
                    let boundedLeft = start == 0 || !isLetterOrDigit(prefix[start - 1])
                    let after = start + needle.count
                    let boundedRight = after >= prefix.count || !prefix[after].isLetter
                    if boundedLeft && boundedRight {
                        wordEnd = Swift.max(wordEnd ?? after, after)
                        break
                    }
                }
                start -= 1
            }
        }

        guard let end = wordEnd else { return false }
        return prefix[end...].allSatisfy(isBridgeCharacter)
    }

    /// Characters that may stand between a scale word and the ratio it introduces.
    static func isBridgeCharacter(_ character: Character) -> Bool {
        if character.isWhitespace { return true }
        if isASCIIDigit(character) { return true }
        // `A`/`B` only ever appear here as an ISO paper token's letter.
        if character == "A" || character == "B" { return true }
        return ",;.:-–—()[]/".contains(character) || colonCharacters.contains(character)
    }

    // MARK: - Designations and labels (L-21)

    /// Whether a property or block designation word stands directly before the notation
    /// starting at `matchStart` — `KV 1:10`, `Kv. 1:10`, `FASTIGHET: 1:10`.
    ///
    /// *Directly* means only whitespace and separating punctuation in between: no digit, no
    /// letter, no other ratio. That is narrower than a scale word's reach on purpose — a scale
    /// word that reaches too far costs a confidence step, a designation word that reaches too
    /// far deletes a real scale, so "KV EXEMPLET SITUATIONSPLAN 1:500" keeps its 1:500.
    static func isDesignation(before matchStart: Int, in characters: [Character]) -> Bool {
        var cursor = matchStart
        while cursor > 0, isDesignationSeparator(characters[cursor - 1]) { cursor -= 1 }
        let wordEnd = cursor
        while cursor > 0, characters[cursor - 1].isLetter { cursor -= 1 }
        guard cursor < wordEnd else { return false }
        if cursor > 0, isLetterOrDigit(characters[cursor - 1]) { return false }
        return designationWordsUppercased.contains(String(characters[cursor..<wordEnd]).uppercased())
    }

    /// What may stand between a designation word and its `block:unit`.
    static func isDesignationSeparator(_ character: Character) -> Bool {
        character.isWhitespace || ".:,;-–—(".contains(character)
    }

    /// Whether a line is nothing but a scale label — the field caption a title block prints over
    /// or beside the value: `SKALA`, `Skala:`, `SKALA/SCALE`, `Scale (A1)`.
    ///
    /// Every word must be a scale word or an ISO paper token, and at least one must be a scale
    /// word. A line with any other word or any number is not a caption: "DETALJ 3 SKALA 1:20"
    /// states its own scale and must never lend its word to a ratio printed under it.
    public static func isScaleLabel(_ text: String) -> Bool {
        let tokens = text.uppercased()
            .split { !isLetterOrDigit($0) }
            .map(String.init)
        guard !tokens.isEmpty else { return false }
        var sawScaleWord = false
        for token in tokens {
            if scaleWordsUppercased.contains(token) {
                sawScaleWord = true
            } else if ISOPaperSize(rawValue: token) == nil {
                return false
            }
        }
        return sawScaleWord
    }

    // MARK: - Character predicates

    static func isASCIIDigit(_ character: Character) -> Bool {
        guard let ascii = character.asciiValue else { return false }
        return ascii >= 48 && ascii <= 57
    }

    static func isLetterOrDigit(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    static func hasLeadingZero(_ text: String) -> Bool {
        text.count > 1 && text.first == "0"
    }
}
