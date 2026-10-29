import Foundation
import ZPDFContracts

/// Feature 13 — check a measurement against the dimension printed beside it. **Opt-in.**
///
/// The drawing says 5 400; the user measured 5 380. When those disagree by more than the
/// user's own tolerance, something is wrong — usually the calibration — and saying so early is
/// worth an entire re-measure. The check is off by default and the caller owns the toggle.
///
/// # Never accuse on a guess
///
/// That is the invariant, and the shape of everything here. A false alarm teaches people to
/// ignore the real one, so every uncertain path resolves to *silence*, not to a warning:
///
/// - a candidate below ``DimensionCheckOptions/minimumConfidence`` is discarded;
/// - text that does not parse as a dimension is discarded, and the parser is strict — it
///   refuses `5.400` with no unit outright, because that text is `5.4 m` on one drawing and a
///   thousands-separated `5400 mm` on another, and guessing between them is exactly the
///   accusation this feature must never make;
/// - a dimension that is nowhere near the measured value — outside the plausibility band —
///   is treated as *some other measurement's* dimension, not as evidence against this one.
///   A stray detail number "12" beside a 5.38 m wall must not produce "drawn 12 mm, you
///   measured 5 380". It produces nothing.
///
/// A warning therefore means: a confidently-read, cleanly-parsed dimension that plausibly
/// refers to this measurement disagrees with it by more than the user's stated tolerance.
public enum DimensionChecker {

    /// One piece of text the OCR found near the measurement, with the OCR's own confidence.
    /// The caller does the spatial pairing (what counts as "near"); the checker never sees
    /// coordinates, so it cannot invent a pairing of its own.
    public struct Candidate: Sendable, Hashable {
        public var text: String
        /// The recogniser's confidence in `text`, 0...1.
        public var confidence: Double

        public init(text: String, confidence: Double) {
            self.text = text
            self.confidence = confidence
        }
    }

    public struct Options: Sendable, Hashable {
        /// The user's tolerance, in metres. Shown wherever a warning is shown — a warning that
        /// hides its threshold cannot be argued with. Default 10 mm: one drawn quantum on a
        /// millimetre-dimensioned plan, plus room for line-weight snapping.
        public var toleranceMetres: Decimal
        /// Candidates the OCR is less sure of than this are discarded unread.
        public var minimumConfidence: Double
        /// A drawn value further than this fraction from the measured one is assumed to be a
        /// different measurement's dimension and is never used to accuse. A calibration error
        /// big enough to matter is a few percent; a mismatch of half an order of magnitude is
        /// a mispaired text.
        public var plausibilityBand: Double

        public init(
            toleranceMetres: Decimal = Decimal(string: "0.010")!,
            minimumConfidence: Double = 0.8,
            plausibilityBand: Double = 0.25
        ) {
            self.toleranceMetres = toleranceMetres
            self.minimumConfidence = minimumConfidence
            self.plausibilityBand = plausibilityBand
        }
    }

    public enum Verdict: Sendable, Hashable {
        /// A confident drawn dimension agrees with the measurement within the tolerance.
        case agrees(drawnMetres: Decimal)
        /// A confident, plausibly-paired drawn dimension disagrees beyond the tolerance.
        /// Everything the warning text needs travels with the verdict, tolerance included.
        case disagrees(
            drawnMetres: Decimal,
            measuredMetres: Decimal,
            differenceMetres: Decimal,
            toleranceMetres: Decimal
        )
        /// Nothing near the measurement was confident, parseable and plausible — so nothing
        /// is said. Silence, not accusation.
        case noConfidentDimension
    }

    /// Checks one measured length against the dimension texts found beside it.
    ///
    /// Agreement wins over disagreement: dimension chains put several figures near a line, and
    /// if *any* confident candidate matches the measurement, the drawing and the takeoff agree.
    /// Only when every plausible candidate disagrees does the closest one become a warning.
    public static func check(
        measuredMetres: Decimal,
        candidates: [Candidate],
        options: Options = Options()
    ) -> Verdict {
        guard measuredMetres > 0 else { return .noConfidentDimension }

        var closestDisagreement: (drawn: Decimal, difference: Decimal)?
        for candidate in candidates {
            guard candidate.confidence >= options.minimumConfidence else { continue }
            guard let drawn = parseDimensionMetres(candidate.text), drawn > 0 else { continue }

            // Plausibility: is this figure even about this measurement?
            let relative = abs(doubleValue(drawn) - doubleValue(measuredMetres))
                / doubleValue(measuredMetres)
            guard relative <= options.plausibilityBand else { continue }

            let difference = abs(drawn - measuredMetres)
            if difference <= options.toleranceMetres {
                return .agrees(drawnMetres: drawn)
            }
            if closestDisagreement == nil || difference < closestDisagreement!.difference {
                closestDisagreement = (drawn, difference)
            }
        }

        if let disagreement = closestDisagreement {
            return .disagrees(
                drawnMetres: disagreement.drawn,
                measuredMetres: measuredMetres,
                differenceMetres: disagreement.difference,
                toleranceMetres: options.toleranceMetres
            )
        }
        return .noConfidentDimension
    }

    // MARK: - Parsing

    /// Parses one dimension text into metres, or `nil` for anything not clearly a dimension.
    ///
    /// The grammar of a construction dimension, strictly:
    ///
    /// - `5400`, `5 400` — a whole number, optionally in groups of three, is **millimetres**;
    ///   that is what dimension strings on a millimetre-dimensioned plan are.
    /// - `5,4` / `5.4` (one or two decimals), with or without `m` — **metres**.
    /// - `5400 mm`, `540 cm`, `5.4 m` — an explicit unit always wins.
    /// - `5,400 mm`, `5.400 mm`, `1,250 cm` — with `mm` or `cm`, a three-digit tail after the mark
    ///   is a thousands group (5400 mm, 12.5 m).
    /// - `5.400` or `5,400` with **no unit** — refused. Metres to three places on one drawing,
    ///   a thousands separator on another; parsing it either way is a guess.
    /// - `+5.400`, `±0.000` — an elevation, not a length. Refused.
    /// - anything with other letters or symbols — refused.
    static func parseDimensionMetres(_ raw: String) -> Decimal? {
        // The spaces OCR and CAD fonts produce inside digit groups.
        var text = raw
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{2009}", with: " ")
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // Elevations and signed values are not lengths.
        if text.hasPrefix("+") || text.hasPrefix("-") || text.hasPrefix("±") { return nil }

        // Split off an explicit unit, if any.
        var unitDivisor: Decimal?
        for (suffix, divisor) in [("mm", Decimal(1000)), ("cm", Decimal(100)), ("m", Decimal(1))] {
            if text.lowercased().hasSuffix(suffix) {
                unitDivisor = divisor
                text = String(text.dropLast(suffix.count))
                    .trimmingCharacters(in: .whitespaces)
                break
            }
        }
        guard !text.isEmpty else { return nil }

        // Whatever remains must be digits, group spaces, and at most one decimal mark.
        let allowed = Set("0123456789 ,.")
        guard text.allSatisfy({ allowed.contains($0) }) else { return nil }

        let decimalMarks = text.filter { $0 == "," || $0 == "." }
        switch decimalMarks.count {
        case 0:
            // A whole number: plain (`5400`), or space-grouped in threes (`5 400`). When there
            // are groups, the first holds one to three digits and the rest exactly three —
            // `54 00` is OCR debris, not a dimension.
            let groups = text.split(separator: " ", omittingEmptySubsequences: false)
            guard groups.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
            if groups.count == 1 {
                guard (1...6).contains(groups[0].count) else { return nil }
            } else {
                guard (1...3).contains(groups[0].count),
                      groups.dropFirst().allSatisfy({ $0.count == 3 })
                else { return nil }
            }
            guard let value = Decimal(string: groups.joined()) else { return nil }
            // Unitless whole numbers are millimetres — the drawing convention this check exists for.
            return value / (unitDivisor ?? 1000)
        case 1:
            guard !text.contains(" ") else { return nil }
            let mark = decimalMarks.first!
            let parts = text.split(separator: mark, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  (1...3).contains(parts[0].count), parts[0].allSatisfy(\.isNumber),
                  (1...3).contains(parts[1].count), parts[1].allSatisfy(\.isNumber)
            else { return nil }
            // Exactly three decimals with no unit is the ambiguous thousands-separator shape.
            if parts[1].count == 3 && unitDivisor == nil { return nil }
            // With a millimetre or centimetre unit, three digits after the mark are a thousands
            // group: nobody dimensions a wall to a thousandth of a millimetre, and `5,400 mm` is
            // 5400 mm on every drawing that writes it. It used to parse as 5.4 mm = 0.0054 m, fall
            // out of the plausibility band and silence a real disagreement (BH-563). With `m`,
            // three decimals stay metres to the millimetre (`5.400 m`).
            if parts[1].count == 3, let divisor = unitDivisor, divisor != 1 {
                guard let grouped = Decimal(string: parts.joined()) else { return nil }
                return grouped / divisor
            }
            guard let value = Decimal(string: parts.joined(separator: ".")) else { return nil }
            // A decimal number is metres unless the unit says otherwise.
            return value / (unitDivisor ?? 1)
        default:
            return nil
        }
    }

    private static func doubleValue(_ value: Decimal) -> Double {
        (value as NSDecimalNumber).doubleValue
    }
}
