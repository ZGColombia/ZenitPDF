import Foundation
import ZPDFUIPresentation

/// Whether a candidate's paper-size hint agrees with the sheet it was read from.
public enum PaperSizeAgreement: String, Hashable, Sendable, CaseIterable {
    /// The candidate carried no hint, or the page box is not a standard sheet.
    case unknown
    /// The hint names the paper this page actually is.
    case agrees
    /// The hint names a different paper size than this page.
    case disagrees
}

/// A candidate with the rank ``ScaleProposalEngine`` gave it on one specific page.
///
/// ``ScaleCandidate/confidence`` stays what the parser measured — how the notation is written —
/// and never moves. The page-dependent judgement lives here instead, so that "the notation is
/// good" and "the notation fits this sheet" remain two separately inspectable facts rather than
/// one number that has already lost its reasons.
public struct RankedScaleCandidate: Hashable, Sendable {

    /// The candidate as the parser produced it.
    public let candidate: ScaleCandidate
    /// Notation confidence adjusted for paper agreement, clamped to `0...1`.
    public let score: Double
    /// How the candidate's paper hint compares with the page box.
    public let paperSizeAgreement: PaperSizeAgreement

    /// Creates a ranked candidate. Callers outside the engine exist only in tests.
    public init(candidate: ScaleCandidate, score: Double, paperSizeAgreement: PaperSizeAgreement) {
        self.candidate = candidate
        self.score = score
        self.paperSizeAgreement = paperSizeAgreement
    }
}

/// A scale read off the drawing, offered to the user. **It is never applied.**
///
/// This type is a proposal and only a proposal. Nothing in this file writes a
/// ``ZPDFContracts/ScaleTransform``, and no caller may treat a `ScaleProposal` as one: a scale
/// the user did not confirm is the first entry on `CORE_LOOP.md`'s silent-wrongness list —
/// *measuring on a page that was never calibrated* — wearing a title block's clothes. Every
/// number in a takeoff descends from the scale, so the one thing a wrong scale must not be is
/// quiet. The value carries ``ranked`` precisely so the confirming surface can show what else
/// the sheet said, and ``needsUserChoice`` so it knows when it must ask rather than offer.
///
/// The conversion it does carry is the arithmetic, nothing more: `1:100` means one PDF point of
/// 1/72 inch stands for 100/72 inch of building, so `0.0254 * 100 / 72` metres per point.
public struct ScaleProposal: Hashable, Sendable {

    /// The ratio being proposed — the top of ``ranked``.
    public let ratio: ScaleRatio
    /// The page's `/UserUnit`, which ``metresPerPoint`` and ``metresPerPointExact`` honour
    /// (CR-128). `1` for a page that declares none.
    public let userUnit: Double
    /// Metres of real world per page unit, as a `Double`, for geometry maths.
    public let metresPerPoint: Double
    /// The same factor as an exact `Decimal`, which is the form a stored scale takes.
    ///
    /// Already multiplied by ``userUnit``: applying the proposal as a two-point calibration
    /// with `knownLength = metresPerPointExact × 100` over two synthetic points 100 page units
    /// apart yields the factor the drawing content actually lives at.
    public let metresPerPointExact: Decimal
    /// The ratio as a person reads it: `"1:100"`.
    public let displayString: String
    /// The winning candidate's rank score on this page, `0...1`.
    public let score: Double
    /// The winning candidate's notation confidence, before any page-dependent adjustment.
    public let notationConfidence: Double
    /// The text this proposal was read from.
    public let evidence: ScaleCandidate
    /// Every candidate on the page, best first. Includes ``evidence`` at index 0.
    public let ranked: [RankedScaleCandidate]
    /// The page box this proposal was ranked against.
    public let pageBoxSizeInPoints: PDFSizeValue
    /// The standard paper this page is, when it is one.
    public let pagePaperSize: ISOPaperSize?

    /// Creates a proposal. Callers outside the engine exist only in tests.
    ///
    /// A non-finite or non-positive `userUnit` — which a validated page cannot carry — falls
    /// back to `1`: a proposal is never applied unconfirmed, so the fallback is shown, not
    /// measured against.
    public init(
        ratio: ScaleRatio,
        score: Double,
        notationConfidence: Double,
        evidence: ScaleCandidate,
        ranked: [RankedScaleCandidate],
        pageBoxSizeInPoints: PDFSizeValue,
        pagePaperSize: ISOPaperSize?,
        userUnit: Double = 1
    ) {
        let unit = (userUnit.isFinite && userUnit > 0) ? userUnit : 1
        self.ratio = ratio
        self.userUnit = unit
        // `unit` is finite and positive by the line above, so the exact factor cannot refuse.
        let exact = (try? ratio.metresPerPointExact(userUnit: unit)) ?? ratio.metresPerPointExact
        self.metresPerPointExact = exact
        self.metresPerPoint = (exact as NSDecimalNumber).doubleValue
        self.displayString = ratio.description
        self.score = score
        self.notationConfidence = notationConfidence
        self.evidence = evidence
        self.ranked = ranked
        self.pageBoxSizeInPoints = pageBoxSizeInPoints
        self.pagePaperSize = pagePaperSize
    }

    /// Every distinct ratio the page offered, best first.
    ///
    /// One entry means the sheet said one thing. Two or more means it said `1:100, 1:200 (A3)`
    /// or similar, and ``needsUserChoice`` is `true`.
    public var distinctRatios: [ScaleRatio] {
        var seen: Set<ScaleRatio> = []
        return ranked.compactMap { seen.insert($0.candidate.ratio).inserted ? $0.candidate.ratio : nil }
    }

    /// Whether the page offered more than one ratio, so the confirming surface must ask which
    /// rather than offer one.
    public var needsUserChoice: Bool { distinctRatios.count > 1 }
}

/// Turns scale notations into at most one proposal per page.
///
/// Two jobs, both narrow:
///
/// 1. **Rank.** Notation quality first, then paper agreement. A `1:200 (A3)` on a sheet that
///    really is A3 outranks the bare `1:100` printed beside it, and on an A1 sheet the same two
///    swap places — which is the whole reason the dual notation is written that way.
/// 2. **Convert.** Ratio to metres per PDF point, and nothing else.
///
/// Ranking does not look at where the text sat, and nothing here applies anything; see
/// ``ScaleProposal`` for why the last of those is structural rather than an omission. Where the
/// text sat is read once, before ranking, by the line entry points
/// (``proposal(forRecognisedLines:pageBox:userUnit:titleBlock:parser:)``), which every surface
/// that reads a sheet's text shares.
public struct ScaleProposalEngine: Hashable, Sendable {

    /// Added to a candidate whose paper hint names the sheet it was read from.
    public static let paperAgreementBonus = 0.15
    /// Subtracted from a candidate whose paper hint names a different sheet.
    public static let paperDisagreementPenalty = 0.20

    /// Allowed deviation per page edge, in points, when identifying the sheet's paper size.
    public let paperSizeTolerance: Double

    /// Creates an engine.
    ///
    /// - Parameter paperSizeTolerance: how far a page box may sit from a nominal ISO size and
    ///   still be called that size. The default of 6 pt is about 2 mm — plotter bleed and
    ///   rounding, not the gap between two paper sizes.
    public init(paperSizeTolerance: Double = 6.0) {
        self.paperSizeTolerance = paperSizeTolerance
    }

    /// Scores and orders candidates for one page, best first.
    ///
    /// The order is total and deterministic:
    ///
    /// 1. **A labelled ratio first** — one a scale word introduced, on its line or as the field
    ///   caption over or beside it — unless its own paper hint names another sheet. A title
    ///   block's SKALA field is the drawing's statement of its scale; a bare `1:10` elsewhere may
    ///   be a slope, a spacing or a property designation, and a well-formed denominator or a
    ///   paper hint does not make it outrank that statement (L-21: "SKALA 1:150" used to lose to a
    ///   bare "1:100" on the series step alone). A labelled ratio whose hint names a different
    ///   paper is the other half of a dual notation, stated for another print, and competes with
    ///   the rest on score instead.
    /// 2. **Score**, descending: the notation's confidence plus the paper-agreement adjustment.
    ///   Between two labelled ratios the series step (0.35) outweighs the agreement bonus (0.15),
    ///   so the sheet size only decides between equally well-written notations — which is what
    ///   the dual form `1:100 (A1), 1:200 (A3)` needs.
    /// 3. The order the candidates were read in. Two identical notations on one sheet therefore
    ///   keep the order they appear, which is the order a person reading the title block would
    ///   see them.
    ///
    /// The published ``RankedScaleCandidate/score`` is the step-2 number, so a labelled ratio
    /// can stand above an unlabelled one with a higher score; step 1 is the reason.
    public func rank(
        _ candidates: [ScaleCandidate],
        pageBoxSizeInPoints: PDFSizeValue
    ) -> [RankedScaleCandidate] {
        let paper = ISOPaperSize.matching(
            boxSizeInPoints: pageBoxSizeInPoints,
            tolerance: paperSizeTolerance
        )
        let scored: [(order: Int, labelled: Bool, raw: Double, ranked: RankedScaleCandidate)] = candidates.enumerated().map {
            order, candidate in
            let agreement: PaperSizeAgreement
            switch (candidate.paperSizeHint, paper) {
            case (nil, _), (_, nil):
                agreement = .unknown
            case let (hint?, page?):
                agreement = hint == page ? .agrees : .disagrees
            }
            let adjustment: Double
            switch agreement {
            case .unknown: adjustment = 0
            case .agrees: adjustment = Self.paperAgreementBonus
            case .disagrees: adjustment = -Self.paperDisagreementPenalty
            }
            // Ranked on the *unclamped* sum, published clamped. A prefixed standard ratio already
            // scores 1.0, so clamping before the sort erased the paper-agreement bonus exactly
            // when it mattered: "SKALA 1:100, 1:200 (A3)" on an A3 print tied at 1.0, fell to
            // reading order, and proposed 1:100 — every length at half its size (BH-014).
            let raw = candidate.confidence + adjustment
            let score = Swift.min(1.0, Swift.max(0.0, raw))
            return (
                order,
                candidate.hasExplicitPrefix && agreement != .disagrees,
                raw,
                RankedScaleCandidate(
                    candidate: candidate, score: score, paperSizeAgreement: agreement
                )
            )
        }
        return scored
            .sorted { left, right in
                if left.labelled != right.labelled {
                    return left.labelled
                }
                if left.raw != right.raw {
                    return left.raw > right.raw
                }
                return left.order < right.order
            }
            .map(\.ranked)
    }

    /// The page's proposal, or `nil` when nothing on it reads as a scale.
    ///
    /// `nil` is a result, not a failure: a drawing whose scale cannot be read must say so and
    /// offer manual calibration. It must never fall back to 1:1.
    ///
    /// - Parameter userUnit: the page's `/UserUnit` (``ZPDFContracts/PageDescriptor/userUnit``).
    ///   The proposal's factor honours it (CR-128); a caller that has the page passes it, and a
    ///   caller that only has a box size gets a `/UserUnit 1` proposal, which is right for every
    ///   page that declares none.
    public func proposal(
        from candidates: [ScaleCandidate],
        pageBoxSizeInPoints: PDFSizeValue,
        userUnit: Double = 1
    ) -> ScaleProposal? {
        let ranked = rank(candidates, pageBoxSizeInPoints: pageBoxSizeInPoints)
        guard let best = ranked.first else { return nil }
        return ScaleProposal(
            ratio: best.candidate.ratio,
            score: best.score,
            notationConfidence: best.candidate.confidence,
            evidence: best.candidate,
            ranked: ranked,
            pageBoxSizeInPoints: pageBoxSizeInPoints,
            pagePaperSize: ISOPaperSize.matching(
                boxSizeInPoints: pageBoxSizeInPoints, tolerance: paperSizeTolerance
            ),
            userUnit: userUnit
        )
    }

    /// Convenience: read the page's recognised lines and propose in one step, for a caller that
    /// has only the page box's size.
    ///
    /// The lines are read exactly as ``proposal(forRecognisedLines:pageBox:userUnit:titleBlock:parser:)``
    /// reads them, against a page box at the origin — where PDF page space puts every box that
    /// declares no offset. A caller holding the real box passes it to that method instead, so a
    /// shifted crop box moves the title-block corner with it.
    ///
    /// Still a proposal. Still never applied.
    public func proposal(
        forRecognisedLines lines: [RecognisedTextLine],
        pageBoxSizeInPoints: PDFSizeValue,
        userUnit: Double = 1,
        parser: ScaleNotationParser = ScaleNotationParser()
    ) -> ScaleProposal? {
        proposal(
            forRecognisedLines: lines,
            pageBox: PDFRectValue(
                x: 0, y: 0, width: pageBoxSizeInPoints.width, height: pageBoxSizeInPoints.height
            ),
            userUnit: userUnit,
            parser: parser
        )
    }

    /// Convenience: read the page's recognised lines and propose in one step.
    ///
    /// Every surface that turns a sheet's text into a proposal comes through here — the Page
    /// Scales sheet, the per-sheet offer in the warning tray and the takeoff assistant — so they
    /// cannot disagree about one sheet (L-21: the warning tray offered the roof plan's SKALA 1:50
    /// while Page Scales, still parsing one line at a time, proposed the area field's 1:10). The
    /// reading is ``SheetScaleProposer/orderedCandidates(in:pageBox:titleBlock:parser:)``: split
    /// runs rejoined on their baseline, each value read after its field caption and its left
    /// neighbour, the title-block corner's candidates first. Lines without bounds are read on
    /// their own, as before.
    ///
    /// - Parameters:
    ///   - pageBox: the box the lines' bounds are in, normally the crop box.
    ///   - titleBlock: where the title block is, when a person has boxed it; the bottom-right
    ///     corner zone of `pageBox` otherwise.
    ///
    /// Still a proposal. Still never applied.
    public func proposal(
        forRecognisedLines lines: [RecognisedTextLine],
        pageBox: PDFRectValue,
        userUnit: Double = 1,
        titleBlock: PDFRectValue? = nil,
        parser: ScaleNotationParser = ScaleNotationParser()
    ) -> ScaleProposal? {
        proposal(
            from: SheetScaleProposer.orderedCandidates(
                in: lines, pageBox: pageBox, titleBlock: titleBlock, parser: parser
            ),
            pageBoxSizeInPoints: pageBox.size,
            userUnit: userUnit
        )
    }
}
