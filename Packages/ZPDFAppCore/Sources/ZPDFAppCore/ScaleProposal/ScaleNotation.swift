import Foundation
import ZPDFContracts
import ZPDFUIPresentation

/// A drawing scale written the way a title block writes it: `1:100`.
///
/// The numerator is stored rather than assumed, because the type is also the thing that
/// *refuses* a ratio. Every construction path validates, so a `ScaleRatio` that exists is
/// one whose ``metresPerPoint`` is a finite positive number.
public struct ScaleRatio: Hashable, Sendable, CustomStringConvertible {

    /// The drawn side of the ratio. Effectively always `1` — see ``init(numerator:denominator:)``.
    public let numerator: Int
    /// The real-world side of the ratio: `100` in `1:100`.
    public let denominator: Int

    /// The denominators a European construction drawing is actually drawn at.
    ///
    /// This list is the parser's main defence against a clock reading `13:37` or a vote
    /// counted `2:1`. It is a *confidence* input rather than a filter — a drawing office that
    /// prints at 1:150 exists, and refusing it outright would hide a real scale — so a
    /// denominator outside the series still produces a candidate, at a reduced confidence
    /// that the user can see.
    public static let standardSeries: Set<Int> = [
        1, 2, 5, 10, 20, 25, 50, 75, 100, 125, 200, 250, 400, 500, 1000
    ]

    /// The largest denominator this type will accept. A ratio beyond it is noise, not a scale:
    /// one PDF point would stand for more than 35 metres.
    public static let maximumDenominator = 100_000

    /// Creates a ratio, or returns `nil` when the pair is not a drawing scale.
    ///
    /// Rejects: a numerator other than `1`, a non-positive denominator, and a denominator past
    /// ``maximumDenominator``. The numerator rule is what makes `2:1` not a scale; it is stated
    /// here rather than in the parser so that no other caller can route around it.
    public init?(numerator: Int, denominator: Int) {
        guard numerator == 1 else { return nil }
        guard denominator >= 1, denominator <= Self.maximumDenominator else { return nil }
        self.numerator = numerator
        self.denominator = denominator
    }

    /// Convenience for the `1:n` form.
    public init?(denominator: Int) {
        self.init(numerator: 1, denominator: denominator)
    }

    /// Whether the denominator is one a drawing office actually uses.
    public var isStandardSeries: Bool { Self.standardSeries.contains(denominator) }

    /// The notation as a person writes it: `"1:100"`.
    public var description: String { "\(numerator):\(denominator)" }

    // MARK: - Conversion to what calibration needs

    /// Metres of real world per PDF point on a `/UserUnit 1` page, as a `Double`.
    ///
    /// One PDF point is 1/72 inch (spec 9.1). At `1:d` that point stands for `d/72` inch of
    /// building, and an inch is exactly 0.0254 m, so the factor is `0.0254 * d / (72 * n)`.
    /// Prefer ``metresPerPointExact`` when the value is on its way into storage: a scale is
    /// persisted as a decimal string and a `Double` round-trip is the drift that persistence
    /// exists to prevent. Prefer ``metresPerPoint(userUnit:)`` whenever the page is known.
    public var metresPerPoint: Double {
        (metresPerPointExact as NSDecimalNumber).doubleValue
    }

    /// Metres of real world per page unit on a page with the given `/UserUnit`, as a `Double`.
    ///
    /// - Throws: ``ZPDFContracts/PageGeometryError/invalidUserUnit(_:)`` for a user unit that is
    ///   not finite and positive. It used to swallow that into the `/UserUnit 1` factor — the
    ///   CR-128 error returned through a public entry point with no signal (BH-454).
    public func metresPerPoint(userUnit: Double) throws -> Double {
        (try metresPerPointExact(userUnit: userUnit) as NSDecimalNumber).doubleValue
    }

    /// Metres per PDF point on a `/UserUnit 1` page, as an exact `Decimal`.
    ///
    /// This is the form ``ZPDFContracts/ScaleTransform/uniform(id:pageID:version:metresPerPoint:units:source:label:allowExtreme:)``
    /// takes. Prefer ``metresPerPointExact(userUnit:)`` whenever the page is known: a page
    /// with `/UserUnit 2` is drawn in units of 2/72 inch, so every preset factor on it doubles.
    public var metresPerPointExact: Decimal {
        // `1` is a valid user unit and the ratio's terms are positive by construction, so the
        // contract's factor cannot refuse; the fallback is the same arithmetic without it.
        (try? metresPerPointExact(userUnit: 1))
            ?? (Decimal(string: "0.0254", locale: nil) ?? Decimal(254) / Decimal(10_000))
                * Decimal(denominator) / (Decimal(72) * Decimal(numerator))
    }

    /// Metres per page unit on a page with the given `/UserUnit`, as an exact `Decimal`.
    ///
    /// Through ``ZPDFContracts/AffineScaleMatrix/metresPerPoint(ratioNumerator:ratioDenominator:userUnit:)``
    /// — the one place the point-to-real conversion honours the page's user unit. Until code
    /// review CR-128 the proposal path computed its own factor and read the field nowhere, so a
    /// `1:100` title block on a `/UserUnit 2` sheet was applied at half its real size.
    ///
    /// - Throws: ``ZPDFContracts/PageGeometryError/invalidUserUnit(_:)`` for a non-finite or
    ///   non-positive user unit.
    public func metresPerPointExact(userUnit: Double) throws -> Decimal {
        try AffineScaleMatrix.metresPerPoint(
            ratioNumerator: Decimal(numerator),
            ratioDenominator: Decimal(denominator),
            userUnit: userUnit
        )
    }
}

/// An ISO paper size, the hint a title block puts beside a scale.
///
/// `Skala 1:100 (A1)` means *this ratio holds on an A1 print*. On an A3 reduction of the same
/// sheet the ratio is 1:200, which is why the dual form `1:100, 1:200 (A3)` exists at all. The
/// hint is what lets ``ScaleProposalEngine`` tell those two apart using the page box it was
/// handed, instead of guessing.
public enum ISOPaperSize: String, Hashable, Sendable, CaseIterable {
    case a0 = "A0", a1 = "A1", a2 = "A2", a3 = "A3", a4 = "A4", a5 = "A5", a6 = "A6"
    case b0 = "B0", b1 = "B1", b2 = "B2", b3 = "B3", b4 = "B4", b5 = "B5", b6 = "B6"

    /// Short and long edge in millimetres, as ISO 216 defines them.
    public var millimetres: (short: Double, long: Double) {
        switch self {
        case .a0: return (841, 1189)
        case .a1: return (594, 841)
        case .a2: return (420, 594)
        case .a3: return (297, 420)
        case .a4: return (210, 297)
        case .a5: return (148, 210)
        case .a6: return (105, 148)
        case .b0: return (1000, 1414)
        case .b1: return (707, 1000)
        case .b2: return (500, 707)
        case .b3: return (353, 500)
        case .b4: return (250, 353)
        case .b5: return (176, 250)
        case .b6: return (125, 176)
        }
    }

    /// Short and long edge in PDF points, 72 per inch.
    public var points: (short: Double, long: Double) {
        let perMillimetre = 72.0 / 25.4
        let mm = millimetres
        return (mm.short * perMillimetre, mm.long * perMillimetre)
    }

    /// Whether a page box is this paper size, in either orientation.
    ///
    /// - Parameters:
    ///   - boxSizeInPoints: the page's box, in PDF points.
    ///   - tolerance: allowed deviation per edge, in points. The default of 6 pt (about 2 mm)
    ///     covers the bleed and rounding a plotter introduces without letting A3 answer for A4.
    public func matches(boxSizeInPoints size: PDFSizeValue, tolerance: Double = 6.0) -> Bool {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            return false
        }
        let short = Swift.min(size.width, size.height)
        let long = Swift.max(size.width, size.height)
        let expected = points
        return abs(short - expected.short) <= tolerance && abs(long - expected.long) <= tolerance
    }

    /// The paper size a page box is, or `nil` when it is not a standard sheet.
    public static func matching(boxSizeInPoints size: PDFSizeValue, tolerance: Double = 6.0) -> ISOPaperSize? {
        allCases.first { $0.matches(boxSizeInPoints: size, tolerance: tolerance) }
    }
}

/// One line of recognised text, with the page-space rectangle it was recognised in.
///
/// Bounds are optional because a text layer extracted from the PDF's own content stream may
/// arrive without them, and a scale is readable from the string alone. They are carried, never
/// interpreted: this type says *where the words were*, and nothing in this file draws a
/// conclusion from that — see ``ScaleCandidate/confidence``.
public struct RecognisedTextLine: Hashable, Sendable {

    /// The recognised text, verbatim.
    public var text: String
    /// Where the line sits in canonical PDF page space, when the recogniser reported it.
    public var boundsInPageSpace: PDFRectValue?

    /// Creates a recognised line.
    public init(text: String, boundsInPageSpace: PDFRectValue? = nil) {
        self.text = text
        self.boundsInPageSpace = boundsInPageSpace
    }
}

/// One scale notation found in one line of text.
///
/// A candidate is an observation, not a decision. It records what was written, where, and how
/// good the *notation* is — nothing else. In particular ``confidence`` is deliberately blind to
/// where on the sheet the line sits: title-block proximity is a different judgement, made by a
/// different layer with the page geometry in hand, and folding it in here would produce a
/// single number nobody could take apart afterwards.
public struct ScaleCandidate: Hashable, Sendable {

    /// The ratio read from the notation.
    public let ratio: ScaleRatio
    /// Exactly the characters the ratio was written as, `"1 : 100"` included.
    public let matchedText: String
    /// The whole line the notation was found in.
    public let sourceText: String
    /// The line's page-space bounds, when the recogniser reported them. Never interpreted here.
    public let boundsInPageSpace: PDFRectValue?
    /// The paper size written beside this ratio, when the line carried one.
    public let paperSizeHint: ISOPaperSize?
    /// Whether an explicit scale word (`SKALA`, `Scale`, `Maßstab`, …) introduced the notation.
    public let hasExplicitPrefix: Bool
    /// Notation quality, `0...1`. See ``ScaleCandidate`` for what it is *not*.
    public let confidence: Double

    /// Creates a candidate. Callers outside the parser exist only in tests.
    public init(
        ratio: ScaleRatio,
        matchedText: String,
        sourceText: String,
        boundsInPageSpace: PDFRectValue?,
        paperSizeHint: ISOPaperSize?,
        hasExplicitPrefix: Bool,
        confidence: Double
    ) {
        self.ratio = ratio
        self.matchedText = matchedText
        self.sourceText = sourceText
        self.boundsInPageSpace = boundsInPageSpace
        self.paperSizeHint = paperSizeHint
        self.hasExplicitPrefix = hasExplicitPrefix
        self.confidence = confidence
    }

    /// The confidence a notation with these two properties earns.
    ///
    /// Two inputs, both about how the ratio is *written*:
    ///
    /// | | standard series | outside the series |
    /// |---|---|---|
    /// | `SKALA 1:100` | 1.00 | 0.65 |
    /// | bare `1:100`  | 0.70 | 0.35 |
    ///
    /// An explicit word outranks a bare ratio because a bare ratio on a construction drawing is
    /// as likely to be a reinforcement spacing or a slope as a scale; the series outranks a
    /// stray denominator for the same reason. Nothing else moves the number.
    public static func confidence(hasExplicitPrefix: Bool, isStandardSeries: Bool) -> Double {
        let base = hasExplicitPrefix ? 0.80 : 0.50
        let series = isStandardSeries ? 0.20 : -0.15
        return Swift.min(1.0, Swift.max(0.0, base + series))
    }
}
